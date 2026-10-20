import type { ActionName, ActionResult, BackupsByApp, OffsiteListing, SystemStatus } from "./types";

const TOKEN_KEY = "atlas.dashboardToken";

export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(path, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new ApiError(`${path} returned ${res.status}`, res.status);
  return (await res.json()) as T;
}

export const api = {
  status: () => getJson<SystemStatus>("/api/status"),
  backups: () => getJson<BackupsByApp>("/api/backups"),
  offsite: () => getJson<OffsiteListing>("/api/offsite"),

  async action(action: ActionName, app: string): Promise<ActionResult> {
    const token = getToken();
    if (!token) throw new ApiError("Enter your dashboard token to run actions.", 401);
    const res = await fetch(`/api/actions/${action}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Atlas-Token": token },
      body: JSON.stringify({ app }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      if (res.status === 401) clearToken();
      throw new ApiError(body.error ?? `Request failed with ${res.status}`, res.status);
    }
    return body as ActionResult;
  },
};

// The token lives only for this browser tab; it never touches localStorage.
export function getToken(): string | null {
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

export function setToken(token: string) {
  try {
    sessionStorage.setItem(TOKEN_KEY, token.trim());
  } catch {
    /* storage unavailable: actions will ask again */
  }
}

export function clearToken() {
  try {
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}
