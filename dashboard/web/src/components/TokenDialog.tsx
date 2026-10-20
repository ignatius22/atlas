import { useEffect, useRef, useState } from "react";

interface Props {
  open: boolean;
  error?: string;
  onSubmit: (token: string) => void;
  onCancel: () => void;
}

export function TokenDialog({ open, error, onSubmit, onCancel }: Props) {
  const ref = useRef<HTMLDialogElement>(null);
  const [value, setValue] = useState("");

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  return (
    <dialog ref={ref} className="token-dialog" onCancel={onCancel} aria-labelledby="token-title">
      <form
        method="dialog"
        onSubmit={(e) => {
          e.preventDefault();
          if (value.trim()) {
            onSubmit(value);
            setValue("");
          }
        }}
      >
        <h2 id="token-title">Unlock actions</h2>
        <p>
          Backups, uploads and restore drills need the dashboard token. It is the{" "}
          <code>ATLAS_DASHBOARD_TOKEN</code> value in your server's <code>.env</code> and is kept only
          until you close this tab.
        </p>
        <label htmlFor="token-input">Dashboard token</label>
        <input
          id="token-input"
          type="password"
          autoComplete="off"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          autoFocus
        />
        {error && <p className="field-error">{error}</p>}
        <div className="dialog-actions">
          <button type="button" onClick={onCancel}>
            Cancel
          </button>
          <button type="submit" className="primary" disabled={!value.trim()}>
            Unlock
          </button>
        </div>
      </form>
    </dialog>
  );
}
