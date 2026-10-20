import { useCallback, useMemo, useRef, useState } from "react";
import { api, ApiError, clearToken, getToken, setToken } from "./api";
import { ago, buildChain, verdict, type DrillResult } from "./chain";
import type { ActionName, SystemStatus } from "./types";
import { useDashboard, useNow } from "./useDashboard";
import { AppRow } from "./components/AppRow";
import { ActivityLog, type LogEntry } from "./components/ActivityLog";
import { DatabasesPanel, ServerPanel } from "./components/ServerPanel";
import { TokenDialog } from "./components/TokenDialog";

type Pending = { action: ActionName; app: string };

export default function App() {
  const data = useDashboard();
  const now = useNow(15_000);
  const [drills, setDrills] = useState<Record<string, DrillResult>>({});
  const [busy, setBusy] = useState<Record<string, ActionName>>({});
  const [log, setLog] = useState<LogEntry[]>([]);
  const [unlocked, setUnlocked] = useState(() => !!getToken());
  const [pending, setPending] = useState<Pending | null>(null);
  const [tokenError, setTokenError] = useState<string>();
  const nextId = useRef(1);

  const chains = useMemo(() => {
    const backups = data.backups ?? {};
    // Worst first, so the app that needs attention is at the top.
    const rank = { unprotected: 0, "no-backups": 1, "at-risk": 2, recoverable: 3 } as const;
    return Object.keys(backups)
      .map((app) => buildChain(app, backups[app], drills[app], now))
      .sort((a, b) => rank[a.health] - rank[b.health] || a.app.localeCompare(b.app));
  }, [data.backups, drills, now]);

  const run = useCallback(
    async (action: ActionName, app: string) => {
      const id = nextId.current++;
      setBusy((b) => ({ ...b, [app]: action }));
      setLog((l) => [{ id, action, app, startedAt: Date.now(), state: "running" as const }, ...l].slice(0, 20));
      try {
        const res = await api.action(action, app);
        const ok = res.exit_code === 0;
        setLog((l) => l.map((e) => (e.id === id ? { ...e, state: ok ? "succeeded" : "failed", output: res.output } : e)));
        if (action === "restore-test") setDrills((d) => ({ ...d, [app]: { passed: ok, at: Date.now() } }));
        await data.refresh();
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        setLog((l) => l.map((e) => (e.id === id ? { ...e, state: "failed", output: message } : e)));
        if (err instanceof ApiError && err.status === 401) {
          setUnlocked(false);
          setTokenError("That token was not accepted. Check ATLAS_DASHBOARD_TOKEN on the server.");
          setPending({ action, app });
        }
      } finally {
        setBusy((b) => {
          const next = { ...b };
          delete next[app];
          return next;
        });
      }
    },
    [data],
  );

  const requestAction = (action: ActionName, app: string) => {
    if (!getToken()) {
      setTokenError(undefined);
      setPending({ action, app });
      return;
    }
    void run(action, app);
  };

  const v = verdict(chains);

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="wordmark">Atlas</span>
          {data.status && <span className="host">{data.status.host}</span>}
        </div>
        <div className="topbar-actions">
          <span className="updated" aria-live="polite">
            {data.updatedAt ? `Updated ${ago(data.updatedAt, now)}` : "Connecting…"}
          </span>
          <button type="button" onClick={() => void data.refresh()}>
            Refresh
          </button>
          {unlocked ? (
            <button
              type="button"
              onClick={() => {
                clearToken();
                setUnlocked(false);
              }}
            >
              Lock actions
            </button>
          ) : (
            <button type="button" onClick={() => setPending({ action: "backup", app: "" })}>
              Unlock actions
            </button>
          )}
        </div>
      </header>

      <main>
        {data.error && !data.status ? (
          <section className="verdict" data-tone="bad">
            <h1>Can't reach the Atlas API.</h1>
            <p className="verdict-sub">
              {data.error}. Check that <code>atlas-dashboard</code> is running on this server, then refresh.
            </p>
          </section>
        ) : data.loading ? (
          <section className="verdict">
            <h1 className="loading">Checking your backups…</h1>
          </section>
        ) : (
          <>
            <section className="verdict" data-tone={v.tone}>
              <h1>{v.text}</h1>
              {data.status && <Facts status={data.status} />}
              {data.error && <p className="stale">Showing the last good data. Latest refresh failed: {data.error}</p>}
            </section>

            <section className="apps" aria-labelledby="apps-heading">
              <h2 id="apps-heading" className="section-title">
                Apps
              </h2>
              {chains.length === 0 ? (
                <p className="empty">
                  No apps found. Register them in <code>config/apps.yml</code> and run your first backup with{" "}
                  <code>atlas backup create --all</code>.
                </p>
              ) : (
                chains.map((c) => (
                  <AppRow
                    key={c.app}
                    chain={c}
                    backups={data.backups?.[c.app] ?? []}
                    now={now}
                    busy={busy[c.app]}
                    onAction={requestAction}
                  />
                ))
              )}
            </section>

            {data.status && (
              <div className="panels">
                <DatabasesPanel status={data.status} />
                <ServerPanel status={data.status} offsite={data.offsite} />
              </div>
            )}

            <ActivityLog entries={log} />
          </>
        )}
      </main>

      <TokenDialog
        open={pending !== null}
        error={tokenError}
        onCancel={() => setPending(null)}
        onSubmit={(token) => {
          setToken(token);
          setUnlocked(true);
          const p = pending;
          setPending(null);
          if (p && p.app) void run(p.action, p.app);
        }}
      />
    </div>
  );
}

function Facts({ status }: { status: SystemStatus }) {
  const schedule = status.scheduler.active
    ? `Every 6 hours (${status.scheduler.type === "systemd" ? "systemd timer" : "cron"})`
    : "Not scheduled";
  return (
    <dl className="verdict-facts">
      <div>
        <dt>Backups run</dt>
        <dd className={status.scheduler.active ? "" : "tone-bad"}>{schedule}</dd>
      </div>
      <div>
        <dt>Offsite storage</dt>
        <dd className={status.offsite.configured ? "" : "tone-bad"}>
          {status.offsite.configured ? `${status.offsite.provider}, ${status.offsite.bucket}` : "Not configured"}
        </dd>
      </div>
      <div>
        <dt>Encryption key</dt>
        <dd className={status.security.recipient_configured ? "" : "tone-bad"}>
          {status.security.recipient_configured ? status.security.recipient_masked : "Not configured"}
        </dd>
      </div>
    </dl>
  );
}
