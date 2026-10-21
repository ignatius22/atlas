import type { Backup } from "./types";

// The chain of custody a backup must pass through before we call an app recoverable.
export type LinkKey = "dumped" | "checksum" | "encrypted" | "offsite" | "drill";
export type LinkState = "ok" | "warn" | "broken" | "unknown";

export interface ChainLink {
  key: LinkKey;
  label: string;
  state: LinkState;
  detail: string;
}

export type AppHealth = "recoverable" | "at-risk" | "drill-failed" | "unprotected" | "no-backups";

export interface DrillResult {
  passed: boolean;
  at: number; // epoch ms
  reason?: string;
  tables?: number;
  rows?: number;
  files?: number;
  engine?: string | null;
}

// MongoDB stores collections of documents; SQL databases tables of rows.
export function unitWords(engine?: string | null): { table: string; row: string } {
  return engine === "mongodb" ? { table: "collection", row: "document" } : { table: "table", row: "row" };
}

function plural(n: number, word: string): string {
  return `${n.toLocaleString("en-US")} ${word}${n === 1 ? "" : "s"}`;
}

// A daily drill plus a day of slack before the last proof counts as stale.
export const DRILL_STALE_HOURS = 48;

export interface ChainOptions {
  drillsScheduled?: boolean;
  // "files" chains describe volume and directory archives, which run daily by default.
  kind?: "database" | "files";
  lateAfterHours?: number;
}

// The newest recorded drill across an app's backups.
export function latestRecordedDrill(backups: Backup[]): DrillResult | undefined {
  let best: DrillResult | undefined;
  for (const b of backups) {
    const d = b.drill;
    if (!d || !d.checked_at) continue;
    const at = d.checked_at * 1000;
    if (!best || at > best.at) {
      best = {
        passed: d.passed,
        at,
        reason: d.reason || undefined,
        tables: d.tables_verified,
        rows: d.rows_found,
        files: d.files_found,
        engine: d.engine,
      };
    }
  }
  return best;
}

export interface AppChain {
  app: string;
  kind: "database" | "files";
  health: AppHealth;
  summary: string;
  newest?: Backup;
  newestSynced?: Backup;
  links: ChainLink[];
}

// A 6-hour schedule plus an hour of slack before a backup counts as late.
export const LATE_AFTER_HOURS = 7;

export function backupTime(b: Backup): number {
  if (typeof b.modified_epoch === "number") return b.modified_epoch * 1000;
  // Fallback for servers that only send "YYYY-MM-DD HH:MM:SS UTC".
  const iso = b.modified.replace(" UTC", "Z").replace(" ", "T");
  const t = Date.parse(iso);
  return Number.isNaN(t) ? 0 : t;
}

export function ago(ms: number, now: number): string {
  const s = Math.max(0, Math.round((now - ms) / 1000));
  if (s < 90) return "just now";
  const m = Math.round(s / 60);
  if (m < 90) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 36) return `${h} h ago`;
  return `${Math.round(h / 24)} days ago`;
}

export function buildChain(
  app: string,
  backups: Backup[],
  sessionDrill: DrillResult | undefined,
  now: number,
  options: ChainOptions = {},
): AppChain {
  // Prefer whichever proof is newest: the recorded drill or one run from this page.
  const recorded = latestRecordedDrill(backups);
  // A drill run from the page is also recorded by the server moments earlier,
  // so treat a recorded result within five minutes as the same run.
  const drill =
    !recorded ? sessionDrill
    : !sessionDrill ? recorded
    : sessionDrill.at - recorded.at > 5 * 60 * 1000 ? sessionDrill
    : recorded;
  const kind = options.kind ?? "database";
  const isFiles = kind === "files";
  const lateAfter = options.lateAfterHours ?? LATE_AFTER_HOURS;
  const sorted = [...backups].sort((a, b) => backupTime(b) - backupTime(a));
  const newest = sorted[0];
  const newestSynced = sorted.find((b) => b.synced);

  if (!newest) {
    return {
      app,
      kind,
      health: "no-backups",
      summary: isFiles
        ? "No file backups yet. They run with the next scheduled backup."
        : "No backups yet. Run a backup to start the chain.",
      links: [
        { key: "dumped", label: "Dumped", state: "broken", detail: "No backup files found" },
        { key: "checksum", label: "Checksummed", state: "unknown", detail: "Waiting for a backup" },
        { key: "encrypted", label: "Encrypted", state: "unknown", detail: "Waiting for a backup" },
        { key: "offsite", label: "Offsite", state: "unknown", detail: "Waiting for a backup" },
        drillLink(drill, now, options),
      ],
    };
  }

  const age = now - backupTime(newest);
  const late = age > lateAfter * 3600 * 1000;

  const links: ChainLink[] = [
    {
      key: "dumped",
      label: isFiles ? "Archived" : "Dumped",
      state: late ? "warn" : "ok",
      detail: late
        ? `Last backup ${ago(backupTime(newest), now)}, later than its schedule`
        : [
            ago(backupTime(newest), now),
            newest.size_human,
            newest.contents ? plural(newest.contents.tables, unitWords(newest.contents.engine).table) : "",
            newest.files ? `${newest.files.files.toLocaleString("en-US")} files` : "",
          ]
            .filter(Boolean)
            .join(", "),
    },
    {
      key: "checksum",
      label: "Checksummed",
      state: newest.sha256 ? "ok" : "broken",
      detail: newest.sha256 ? `SHA-256 ${newest.sha256_short}` : "No checksum file",
    },
    {
      key: "encrypted",
      label: "Encrypted",
      state: newest.has_age ? "ok" : "warn",
      detail: newest.has_age ? "Sealed with your age public key" : "Not encrypted yet; it is encrypted during offsite sync",
    },
    offsiteLink(newest, newestSynced, now),
    drillLink(drill, now, options),
  ];

  let health: AppHealth;
  let summary: string;
  if (drill && !drill.passed && newestSynced) {
    // A copy that failed to restore is not a recovery plan, however fresh it is.
    health = "drill-failed";
    summary = drill.reason
      ? `The last restore drill failed. ${drill.reason}.`
      : "The last restore drill failed. Check its output before relying on these backups.";
  } else if (newest.synced && !late) {
    health = "recoverable";
    summary = `Recoverable from an offsite copy made ${ago(backupTime(newest), now)}.`;
  } else if (newestSynced) {
    health = "at-risk";
    summary = late
      ? `Backups have stopped. The newest offsite copy is from ${ago(backupTime(newestSynced), now)}.`
      : `The latest backup is not offsite yet. The newest offsite copy is from ${ago(backupTime(newestSynced), now)}.`;
  } else {
    health = "unprotected";
    summary = "Only local copies exist. If this server is lost, this app's data is lost.";
  }

  return { app, kind, health, summary, newest, newestSynced, links };
}

const SEVERITY: Record<AppHealth, number> = {
  unprotected: 0,
  "drill-failed": 1,
  "no-backups": 2,
  "at-risk": 3,
  recoverable: 4,
};

export function severity(health: AppHealth): number {
  return SEVERITY[health];
}

// An app is only as recoverable as the weakest of its database and files.
export function worstChain(chains: AppChain[]): AppChain {
  return chains.reduce((worst, c) => (SEVERITY[c.health] < SEVERITY[worst.health] ? c : worst));
}

function offsiteLink(newest: Backup, newestSynced: Backup | undefined, now: number): ChainLink {
  if (newest.synced) {
    return { key: "offsite", label: "Offsite", state: "ok", detail: "Upload confirmed in remote storage" };
  }
  if (newestSynced) {
    return {
      key: "offsite",
      label: "Offsite",
      state: "warn",
      detail: `Latest not uploaded; last confirmed copy ${ago(backupTime(newestSynced), now)}`,
    };
  }
  return { key: "offsite", label: "Offsite", state: "broken", detail: "No copy confirmed in remote storage" };
}

function drillLink(drill: DrillResult | undefined, now: number, options: ChainOptions): ChainLink {
  const label = "Restore tested";
  if (!drill) {
    return {
      key: "drill",
      label,
      state: "unknown",
      detail: options.drillsScheduled ? "Not tested yet; the daily drill runs at 03:30 UTC" : "Never tested; daily drills are off",
    };
  }
  if (!drill.passed) {
    return { key: "drill", label, state: "broken", detail: `Drill failed ${ago(drill.at, now)}` };
  }
  const proof =
    drill.tables !== undefined && drill.rows !== undefined
      ? `${plural(drill.tables, unitWords(drill.engine).table)}, ${plural(drill.rows, unitWords(drill.engine).row)} verified`
      : drill.files !== undefined
        ? `${drill.files.toLocaleString("en-US")} files verified`
        : "Restore verified";
  const stale = now - drill.at > DRILL_STALE_HOURS * 3600 * 1000;
  return {
    key: "drill",
    label,
    state: stale ? "warn" : "ok",
    detail: stale ? `Last verified ${ago(drill.at, now)}` : `${proof} ${ago(drill.at, now)}`,
  };
}

export function verdict(chains: AppChain[]): { tone: "good" | "warn" | "bad" | "empty"; text: string } {
  if (chains.length === 0) {
    return { tone: "empty", text: "No apps registered yet. Add your apps to config/apps.yml." };
  }
  const total = chains.length;
  const recoverable = chains.filter((c) => c.health === "recoverable").length;
  const unprotected = chains.filter((c) => c.health === "unprotected" || c.health === "no-backups").length;
  const noun = total === 1 ? "app" : "apps";

  if (recoverable === total) {
    return {
      tone: "good",
      text: total === 1
        ? "Your app can be recovered from a verified offsite copy."
        : `All ${total} ${noun} can be recovered from verified offsite copies.`,
    };
  }
  if (unprotected > 0) {
    return {
      tone: "bad",
      text: `${unprotected} of ${total} ${noun} would lose data if this server disappeared.`,
    };
  }
  const drillFailed = chains.filter((c) => c.health === "drill-failed").length;
  if (drillFailed > 0) {
    return {
      tone: "bad",
      text: drillFailed === total
        ? total === 1
          ? "Your app's last restore drill failed. Its backups are not proven to work."
          : `All ${total} apps failed their last restore drill.`
        : `${drillFailed} of ${total} ${noun} failed ${drillFailed === 1 ? "its" : "their"} last restore drill.`,
    };
  }
  const atRisk = total - recoverable; // all remaining apps are "at-risk" here
  return {
    tone: "warn",
    text: atRisk === 1
      ? `1 of ${total} ${noun} can only be recovered from an older offsite copy.`
      : `${atRisk} of ${total} ${noun} can only be recovered from older offsite copies.`,
  };
}
