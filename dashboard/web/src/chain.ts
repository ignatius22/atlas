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

export type AppHealth = "recoverable" | "at-risk" | "unprotected" | "no-backups";

export interface DrillResult {
  passed: boolean;
  at: number; // epoch ms
}

export interface AppChain {
  app: string;
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
  drill: DrillResult | undefined,
  now: number,
): AppChain {
  const sorted = [...backups].sort((a, b) => backupTime(b) - backupTime(a));
  const newest = sorted[0];
  const newestSynced = sorted.find((b) => b.synced);

  if (!newest) {
    return {
      app,
      health: "no-backups",
      summary: "No backups yet. Run a backup to start the chain.",
      links: [
        { key: "dumped", label: "Dumped", state: "broken", detail: "No backup files found" },
        { key: "checksum", label: "Checksummed", state: "unknown", detail: "Waiting for a backup" },
        { key: "encrypted", label: "Encrypted", state: "unknown", detail: "Waiting for a backup" },
        { key: "offsite", label: "Offsite", state: "unknown", detail: "Waiting for a backup" },
        drillLink(drill, now),
      ],
    };
  }

  const age = now - backupTime(newest);
  const late = age > LATE_AFTER_HOURS * 3600 * 1000;

  const links: ChainLink[] = [
    {
      key: "dumped",
      label: "Dumped",
      state: late ? "warn" : "ok",
      detail: late
        ? `Last backup ${ago(backupTime(newest), now)}, later than the 6-hour schedule`
        : `${ago(backupTime(newest), now)}, ${newest.size_human}`,
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
    drillLink(drill, now),
  ];

  let health: AppHealth;
  let summary: string;
  if (drill && !drill.passed && newestSynced) {
    // A copy that failed to restore is not a recovery plan, however fresh it is.
    health = "at-risk";
    summary = "The last test restore failed. Check its output below before relying on these backups.";
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

  return { app, health, summary, newest, newestSynced, links };
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

function drillLink(drill: DrillResult | undefined, now: number): ChainLink {
  if (!drill) {
    return { key: "drill", label: "Restore tested", state: "unknown", detail: "Not tested this session" };
  }
  return drill.passed
    ? { key: "drill", label: "Restore tested", state: "ok", detail: `Test restore passed ${ago(drill.at, now)}` }
    : { key: "drill", label: "Restore tested", state: "broken", detail: `Test restore failed ${ago(drill.at, now)}` };
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
  const atRisk = total - recoverable;
  return {
    tone: "warn",
    text: atRisk === 1
      ? `1 of ${total} ${noun} can only be recovered from an older offsite copy.`
      : `${atRisk} of ${total} ${noun} can only be recovered from older offsite copies.`,
  };
}
