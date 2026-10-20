import type { ChainLink } from "../chain";

const STATE_TEXT: Record<ChainLink["state"], string> = {
  ok: "done",
  warn: "needs attention",
  broken: "broken",
  unknown: "not checked",
};

// The signature element: a backup's chain of custody, link by link.
// A connector is drawn broken when the link it leads into is broken.
export function ChainTrack({ links }: { links: ChainLink[] }) {
  return (
    <ol className="chain" aria-label="Chain of custody">
      {links.map((link, i) => (
        <li key={link.key} className={`chain-link is-${link.state}`}>
          {i > 0 && <span className="chain-connector" aria-hidden="true" />}
          <span className="chain-node" aria-hidden="true" />
          <span className="chain-label">{link.label}</span>
          <span className="chain-detail">{link.detail}</span>
          <span className="visually-hidden">: {STATE_TEXT[link.state]}</span>
        </li>
      ))}
    </ol>
  );
}
