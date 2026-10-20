import { describe, expect, it } from "vitest";
import { buildChain, verdict } from "./chain";
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
    expect(chain.health).toBe("at-risk");
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
