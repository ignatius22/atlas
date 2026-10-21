import { describe, expect, it } from "vitest";
import { buildChain, verdict, worstChain } from "./chain";
import type { Backup } from "./types";

const NOW = Date.parse("2026-10-20T12:00:00Z");
const hoursAgo = (h: number) => (NOW - h * 3600 * 1000) / 1000;

function backup(over: Partial<Backup> = {}): Backup {
  return {
    filename: "myapp-20261020.sql.gz",
    size_bytes: 1024,
    size_human: "1.0 KB",
    modified: "2026-10-20 10:00:00 UTC",
    modified_epoch: hoursAgo(2),
    sha256: "abc123",
    sha256_short: "abc123...",
    has_age: true,
    age_size_bytes: 1100,
    synced: true,
    metadata: {},
    ...over,
  };
}

describe("buildChain", () => {
  it("marks an app recoverable when the newest backup is fresh and offsite", () => {
    const chain = buildChain("myapp", [backup()], undefined, NOW);
    expect(chain.health).toBe("recoverable");
    expect(chain.links.find((l) => l.key === "offsite")?.state).toBe("ok");
    expect(chain.links.find((l) => l.key === "drill")?.state).toBe("unknown");
  });

  it("is at risk when the newest backup has not reached offsite storage", () => {
    const chain = buildChain(
      "myapp",
      [backup({ synced: false, modified_epoch: hoursAgo(1) }), backup({ modified_epoch: hoursAgo(7) })],
      undefined,
      NOW,
    );
    expect(chain.health).toBe("at-risk");
    expect(chain.links.find((l) => l.key === "offsite")?.state).toBe("warn");
  });

  it("is unprotected when nothing was ever confirmed offsite", () => {
    const chain = buildChain("myapp", [backup({ synced: false })], undefined, NOW);
    expect(chain.health).toBe("unprotected");
    expect(chain.links.find((l) => l.key === "offsite")?.state).toBe("broken");
  });

  it("flags backups that stopped running even if the last one synced", () => {
    const chain = buildChain("myapp", [backup({ modified_epoch: hoursAgo(30) })], undefined, NOW);
    expect(chain.health).toBe("at-risk");
    expect(chain.links.find((l) => l.key === "dumped")?.state).toBe("warn");
  });

  it("parses the legacy modified string when no epoch is sent", () => {
    const chain = buildChain(
      "myapp",
      [backup({ modified_epoch: undefined, modified: "2026-10-20 11:00:00 UTC" })],
      undefined,
      NOW,
    );
    expect(chain.health).toBe("recoverable");
  });

  it("shows a failed restore test as a broken link and downgrades the app", () => {
    const chain = buildChain("myapp", [backup()], { passed: false, at: NOW }, NOW);
    expect(chain.links.find((l) => l.key === "drill")?.state).toBe("broken");
    expect(chain.health).toBe("drill-failed");
  });

  it("handles apps with no backups", () => {
    const chain = buildChain("myapp", [], undefined, NOW);
    expect(chain.health).toBe("no-backups");
  });
});

describe("verdict", () => {
  it("summarises the worst case first", () => {
    const good = buildChain("a", [backup()], undefined, NOW);
    const bad = buildChain("b", [backup({ synced: false })], undefined, NOW);
    expect(verdict([good]).tone).toBe("good");
    expect(verdict([good, bad])).toEqual({
      tone: "bad",
      text: "1 of 2 apps would lose data if this server disappeared.",
    });
    expect(verdict([]).tone).toBe("empty");
  });
});

describe("recorded restore drills", () => {
  const drill = (over: Partial<NonNullable<Backup["drill"]>> = {}) => ({
    passed: true,
    checked_at: NOW / 1000 - 3600,
    reason: "",
    tables_verified: 5,
    rows_found: 1334,
    ...over,
  });

  it("uses the newest recorded drill and shows what it verified", () => {
    const chain = buildChain(
      "myapp",
      [backup({ drill: drill() }), backup({ filename: "old.sql.gz", modified_epoch: hoursAgo(30), drill: drill({ passed: false, checked_at: NOW / 1000 - 90000 }) })],
      undefined,
      NOW,
    );
    const link = chain.links.find((l) => l.key === "drill")!;
    expect(link.state).toBe("ok");
    expect(link.detail).toContain("5 tables, 1,334 rows verified");
    expect(chain.health).toBe("recoverable");
  });

  it("marks proof older than two days as stale", () => {
    const chain = buildChain("myapp", [backup({ drill: drill({ checked_at: NOW / 1000 - 3 * 86400 }) })], undefined, NOW);
    expect(chain.links.find((l) => l.key === "drill")?.state).toBe("warn");
  });

  it("downgrades the app and explains why when the last drill failed", () => {
    const chain = buildChain(
      "myapp",
      [backup({ drill: drill({ passed: false, reason: "public.users: expected 1,300, found 1,234" }) })],
      undefined,
      NOW,
    );
    expect(chain.health).toBe("drill-failed");
    expect(chain.summary).toContain("public.users");
    expect(verdict([chain]).tone).toBe("bad");
    expect(verdict([chain, buildChain("b", [backup()], undefined, NOW)]).text).toBe(
      "1 of 2 apps failed its last restore drill.",
    );
  });

  it("says whether the daily drill is scheduled when nothing has been tested", () => {
    const on = buildChain("myapp", [backup()], undefined, NOW, { drillsScheduled: true });
    const off = buildChain("myapp", [backup()], undefined, NOW, { drillsScheduled: false });
    expect(on.links.find((l) => l.key === "drill")?.detail).toContain("03:30");
    expect(off.links.find((l) => l.key === "drill")?.detail).toContain("off");
  });

  it("treats a page-run drill and its recorded result as the same run", () => {
    const chain = buildChain("myapp", [backup({ drill: drill({ checked_at: NOW / 1000 - 10 }) })], { passed: true, at: NOW }, NOW);
    expect(chain.links.find((l) => l.key === "drill")?.detail).toContain("rows verified");
  });
});

describe("files chains", () => {
  const archive = (over: Partial<Backup> = {}) =>
    backup({
      filename: "myapp-files-20261020T000000Z.tar.gz",
      contents: null,
      files: { files: 1204, bytes: 3_400_000, sources: [{ kind: "volume", name: "uploads", files: 1204 }] },
      ...over,
    });

  it("allows a daily schedule before calling files late", () => {
    const chain = buildChain("myapp", [archive({ modified_epoch: hoursAgo(20) })], undefined, NOW, {
      kind: "files",
      lateAfterHours: 26,
    });
    expect(chain.kind).toBe("files");
    expect(chain.health).toBe("recoverable");
    expect(chain.links[0].label).toBe("Archived");
    expect(chain.links[0].detail).toContain("1,204 files");
  });

  it("shows verified file counts from a files drill", () => {
    const chain = buildChain(
      "myapp",
      [archive({ drill: { passed: true, checked_at: NOW / 1000 - 60, reason: "", files_found: 1204 } })],
      undefined,
      NOW,
      { kind: "files", lateAfterHours: 26 },
    );
    expect(chain.links.find((l) => l.key === "drill")?.detail).toContain("1,204 files verified");
  });

  it("rates an app by the weaker of its database and files", () => {
    const db = buildChain("myapp", [backup()], undefined, NOW);
    const files = buildChain("myapp", [archive({ synced: false })], undefined, NOW, { kind: "files", lateAfterHours: 26 });
    expect(worstChain([db, files]).kind).toBe("files");
    expect(worstChain([db, files]).health).toBe("unprotected");
  });
});
