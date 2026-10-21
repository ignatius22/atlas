// Response shapes of dashboard/server.py. Keep in sync with that file.

export interface Container {
  name: string;
  id_short?: string;
  status: string;
  health: string;
  started?: string;
}

export interface SystemStatus {
  timestamp: string;
  host: string;
  os: string;
  disk: { total_gb: number; used_gb: number; free_gb: number; percent: number };
  containers: Container[];
  security: {
    private_keys_on_vps: number;
    zero_knowledge_intact: boolean;
    recipient_configured: boolean;
    recipient_masked: string;
  };
  offsite: { provider: string; bucket: string; configured: boolean };
  scheduler: { type: "systemd" | "cron" | "none"; active: boolean; rpo: string; drills_active?: boolean };
  apps?: Record<string, { database: boolean }>;
}

export interface Backup {
  filename: string;
  size_bytes: number;
  size_human: string;
  modified: string;
  modified_epoch?: number;
  sha256: string;
  sha256_short: string;
  has_age: boolean;
  age_size_bytes: number;
  synced?: boolean;
  contents?: { tables: number; rows: number } | null;
  // Files archives only: what the archive holds.
  files?: { files: number; bytes: number; sources: { kind: "volume" | "path"; name: string; files: number }[] } | null;
  drill?: RecordedDrill | null;
  metadata: Record<string, unknown>;
}

// Result of scripts/restore.sh --target=test, stored as <archive>.drill.json.
export interface RecordedDrill {
  passed: boolean;
  checked_at: number | null; // epoch seconds
  duration_s?: number;
  reason: string;
  tables_verified?: number;
  tables_expected?: number;
  rows_found?: number;
  files_found?: number;
  bytes_found?: number;
  image?: string;
}

// /api/files: per app, whether file backups are configured and the archives on disk.
export type FilesByApp = Record<string, { configured: boolean; every_hours?: number; archives: Backup[] }>;

export type BackupsByApp = Record<string, Backup[]>;

export interface OffsiteListing {
  configured: boolean;
  bucket?: string;
  total_objects?: number;
  objects: string[];
  error?: string;
}

export type ActionName = "backup" | "sync" | "restore-test";

export interface ActionResult {
  action: ActionName;
  app?: string;
  exit_code: number;
  output: string;
}
