import type { ActionName } from "../types";

export interface LogEntry {
  id: number;
  action: ActionName;
  app: string;
  startedAt: number;
  state: "running" | "succeeded" | "failed";
  output?: string;
}

const VERB: Record<ActionName, string> = {
  backup: "Backup",
  sync: "Offsite upload",
  "restore-test": "Test restore",
};

const RESULT: Record<LogEntry["state"], string> = {
  running: "running",
  succeeded: "succeeded",
  failed: "failed",
};

export function ActivityLog({ entries }: { entries: LogEntry[] }) {
  if (entries.length === 0) return null;
  return (
    <section className="panel activity" aria-labelledby="activity-heading" aria-live="polite">
      <h2 id="activity-heading">Actions run from this page</h2>
      <ol>
        {entries.map((e) => (
          <li key={e.id} className={`log-${e.state}`}>
            <details open={e.state === "failed"}>
              <summary>
                <span className="log-title">
                  {VERB[e.action]} for {e.app} {RESULT[e.state]}
                </span>
                <time dateTime={new Date(e.startedAt).toISOString()}>
                  {new Date(e.startedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
                </time>
              </summary>
              <pre>{e.output || (e.state === "running" ? "Waiting for the server…" : "No output.")}</pre>
            </details>
          </li>
        ))}
      </ol>
    </section>
  );
}
