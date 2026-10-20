import type { OffsiteListing, SystemStatus } from "../types";

export function ServerPanel({ status, offsite }: { status: SystemStatus; offsite?: OffsiteListing }) {
  const disk = status.disk;
  const diskTone = disk.percent >= 90 ? "bad" : disk.percent >= 75 ? "warn" : "ok";
  const keys = status.security.private_keys_on_vps;

  return (
    <section className="panel" aria-labelledby="server-heading">
      <h2 id="server-heading">This server</h2>

      <div className="meter-block">
        <div className="meter-label">
          <span>Backup disk</span>
          <span>
            {disk.free_gb} GB free of {disk.total_gb} GB
          </span>
        </div>
        <div
          className={`meter tone-${diskTone}`}
          role="meter"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={disk.percent}
          aria-label="Backup disk used"
        >
          <span style={{ width: `${Math.min(100, disk.percent)}%` }} />
        </div>
      </div>

      <dl className="facts">
        <div>
          <dt>Private keys on this server</dt>
          <dd className={keys === 0 ? "tone-ok" : "tone-bad"}>
            {keys === 0 ? "None found" : `${keys} file${keys === 1 ? "" : "s"} contain a private key`}
          </dd>
        </div>
        <div>
          <dt>Offsite objects</dt>
          <dd>
            {offsite === undefined
              ? "Checking…"
              : offsite.error
                ? <span className="tone-bad">{offsite.error}</span>
                : `${offsite.total_objects ?? offsite.objects.length} in ${offsite.bucket ?? status.offsite.bucket}`}
          </dd>
        </div>
        <div>
          <dt>Operating system</dt>
          <dd>{status.os}</dd>
        </div>
      </dl>
      {keys > 0 && (
        <p className="note tone-bad">
          Move private keys off this server. Anyone who breaks in could decrypt every offsite backup.
        </p>
      )}
    </section>
  );
}

export function DatabasesPanel({ status }: { status: SystemStatus }) {
  return (
    <section className="panel" aria-labelledby="db-heading">
      <h2 id="db-heading">Database containers</h2>
      {status.containers.length === 0 ? (
        <p className="empty">No database containers registered. Add apps to config/apps.yml.</p>
      ) : (
        <ul className="containers">
          {status.containers.map((c) => {
            const up = c.status === "running";
            const healthy = up && (c.health === "healthy" || c.health === "n/a");
            return (
              <li key={c.name}>
                <span className={`dot ${healthy ? "tone-ok" : up ? "tone-warn" : "tone-bad"}`} aria-hidden="true" />
                <span className="container-name">{c.name}</span>
                <span className="container-state">
                  {up ? (c.health === "n/a" ? "Running" : `Running, ${c.health}`) : "Not running"}
                </span>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
