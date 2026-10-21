import { useId, useState } from "react";
import { ago, backupTime, type AppChain } from "../chain";
import type { ActionName, Backup } from "../types";
import { ChainTrack } from "./ChainTrack";

const HEALTH_TEXT: Record<AppChain["health"], string> = {
  recoverable: "Recoverable",
  "at-risk": "At risk",
  "drill-failed": "Restore failed",
  unprotected: "Unprotected",
  "no-backups": "No backups",
};

interface Props {
  app: string;
  primary: AppChain; // the weaker of the database and files chains
  db?: AppChain;
  files?: AppChain;
  backups: Backup[];
  now: number;
  busy?: ActionName;
  onAction: (action: ActionName, app: string) => void;
}

function FilesSources({ chain }: { chain: AppChain }) {
  const sources = chain.newest?.files?.sources;
  if (!sources || sources.length === 0) return null;
  return (
    <p className="chain-sources">
      {sources
        .map((s) => `${s.kind === "volume" ? `volume ${s.name}` : s.name} (${s.files.toLocaleString("en-US")} files)`)
        .join(", ")}
    </p>
  );
}

export function AppRow({ app, primary, db, files, backups, now, busy, onAction }: Props) {
  const [open, setOpen] = useState(false);
  const historyId = useId();
  const recent = [...backups].sort((a, b) => backupTime(b) - backupTime(a)).slice(0, 8);
  const both = !!db && !!files;
  const chain = db ?? primary;

  return (
    <article className={`app-row health-${primary.health}`}>
      <header className="app-head">
        <div className="app-title">
          <h3>{app}</h3>
          <span className="health-tag">{HEALTH_TEXT[primary.health]}</span>
        </div>
        <p className="app-summary">
          {both && primary.kind === "files" ? "Files: " : ""}
          {primary.summary}
        </p>
      </header>

      {db && (
        <section className="chain-group" aria-label="Database backups">
          {both && <h4 className="chain-title">Database</h4>}
          <ChainTrack links={db.links} />
        </section>
      )}

      {files && (
        <section className="chain-group" aria-label="Files and volumes backups">
          <h4 className="chain-title">Files and volumes</h4>
          <ChainTrack links={files.links} />
          <FilesSources chain={files} />
        </section>
      )}

      <div className="app-actions">
        <button type="button" disabled={!!busy} onClick={() => onAction("backup", app)}>
          {busy === "backup" ? "Backing up…" : "Back up now"}
        </button>
        <button type="button" disabled={!!busy} onClick={() => onAction("sync", app)}>
          {busy === "sync" ? "Uploading…" : "Upload offsite"}
        </button>
        {db && (
          <button
            type="button"
            className="primary"
            disabled={!!busy || !chain.newest}
            onClick={() => onAction("restore-test", app)}
          >
            {busy === "restore-test" ? "Running drill…" : "Run restore drill"}
          </button>
        )}
        {recent.length > 0 && (
          <button
            type="button"
            className="link"
            aria-expanded={open}
            aria-controls={historyId}
            onClick={() => setOpen((o) => !o)}
          >
            {open ? "Hide backups" : `Show ${recent.length} recent backup${recent.length === 1 ? "" : "s"}`}
          </button>
        )}
      </div>

      {open && (
        <div className="history" id={historyId}>
          <table>
            <caption className="visually-hidden">Recent database backups for {app}</caption>
            <thead>
              <tr>
                <th scope="col">Taken</th>
                <th scope="col">Size</th>
                <th scope="col">Checksum</th>
                <th scope="col">Encrypted</th>
                <th scope="col">Offsite</th>
                <th scope="col">Restore test</th>
              </tr>
            </thead>
            <tbody>
              {recent.map((b) => (
                <tr key={b.filename}>
                  <td title={b.filename}>{ago(backupTime(b), now)}</td>
                  <td>{b.size_human}</td>
                  <td>
                    <code title={b.sha256}>{b.sha256 ? b.sha256.slice(0, 12) : "missing"}</code>
                  </td>
                  <td>{b.has_age ? "Yes" : "No"}</td>
                  <td>{b.synced ? "Confirmed" : "Local only"}</td>
                  <td className={b.drill ? (b.drill.passed ? "tone-ok" : "tone-bad") : undefined} title={b.drill?.reason || undefined}>
                    {b.drill ? (b.drill.passed ? "Passed" : "Failed") : "Not tested"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </article>
  );
}
