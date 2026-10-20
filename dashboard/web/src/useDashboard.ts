import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { BackupsByApp, OffsiteListing, SystemStatus } from "./types";

const REFRESH_MS = 30_000;

export interface DashboardData {
  status?: SystemStatus;
  backups?: BackupsByApp;
  offsite?: OffsiteListing;
  error?: string;
  loading: boolean;
  updatedAt?: number;
  refresh: () => Promise<void>;
}

export function useDashboard(): DashboardData {
  const [status, setStatus] = useState<SystemStatus>();
  const [backups, setBackups] = useState<BackupsByApp>();
  const [offsite, setOffsite] = useState<OffsiteListing>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [updatedAt, setUpdatedAt] = useState<number>();
  const inFlight = useRef(false);

  const refresh = useCallback(async () => {
    if (inFlight.current) return;
    inFlight.current = true;
    try {
      // Status and backups drive the page; offsite listing is slower and optional.
      const [s, b] = await Promise.all([api.status(), api.backups()]);
      setStatus(s);
      setBackups(b);
      setError(undefined);
      setUpdatedAt(Date.now());
      api.offsite().then(setOffsite).catch(() => setOffsite(undefined));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      inFlight.current = false;
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const id = window.setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, REFRESH_MS);
    return () => window.clearInterval(id);
  }, [refresh]);

  return { status, backups, offsite, error, loading, updatedAt, refresh };
}

// Re-render once a minute so "x min ago" labels stay honest.
export function useNow(intervalMs = 60_000): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}
