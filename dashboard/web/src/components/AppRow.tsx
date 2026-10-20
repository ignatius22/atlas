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
  chain: AppChain;
  backups: Backup[];
  now: number;
  busy?: ActionName;
  onAction: (action: ActionName, app: string) => void;
}

export function AppRow({ chain, backups, now, busy, onAction }: Props) {
  const [open, setOpen] = useState(false);
  const historyId = useId();
  const recent = [...backups].sort((a, b) => backupTime(b) - backupTime(a)).slice(0, 8);

  return (
    <article className={`app-row health-${chain.health}`}>
      <header className="app-head">
        <div className="app-title">
          <h3>{chain.app}</h3>
          <span className="health-tag">{HEALTH_TEXT[chain.health]}</span>
        </div>
        <p className="app-summary">{chain.summary}</p>
      </header>

      <ChainTrack links={chain.links} />

      <div className="app-actions">
        <button type="button" disabled={!!busy} onClick={() => onAction("backup", chain.app)}>
          {busy === "backup" ? "Backing up…" : "Back up now"}
        </button>
        <button type="button" disabled={!!busy} onClick={() => onAction("sync", chain.app)}>
          {busy === "sync" ? "Uploading…" : "Upload offsite"}
        </button>
        <button
          type="button"
          className="primary"
          disabled={!!busy || !chain.newest}
          onClick={() => onAction("restore-test", chain.app)}
        >
          {busy === "restore-test" ? "Running drill…" : "Run restore drill"}
        </button>
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
            <caption className="visually-hidden">Recent backups for {chain.app}</caption>
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
