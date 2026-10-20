# Atlas Dashboard

The dashboard answers one question: **could every app on this server be recovered right now?**

Each app is shown as a chain of custody. A backup has to be dumped, checksummed, encrypted, confirmed in offsite storage and restore-tested before Atlas calls it recoverable. A broken link shows exactly where recovery is at risk.

## How it fits together

| Part | Path | Role |
| --- | --- | --- |
| API server | `dashboard/server.py` | Python standard library only. Binds to `127.0.0.1:8888`, serves the API and the built app. |
| React app | `dashboard/web` | Vite + React + TypeScript source. |
| Build output | `dashboard/dist` | Committed, so the VPS never needs Node.js. CI fails if it is out of date. |

Read-only endpoints (`/api/status`, `/api/backups`, `/api/offsite`) need no token. Actions (`/api/actions/backup`, `sync`, `restore-test`) require the `X-Atlas-Token` header, which the app asks for once per browser tab.

## Running it on the server

```bash
# ATLAS_DASHBOARD_TOKEN must be set in /opt/atlas/.env
sudo systemctl enable --now atlas-dashboard.service

# From your laptop, tunnel to the localhost-only port
ssh -L 8888:127.0.0.1:8888 you@your-server
# then open http://localhost:8888
```

## Developing the UI

```bash
cd dashboard/web
npm ci
npm run dev          # http://localhost:5173, proxies /api to ATLAS_API_URL (default http://127.0.0.1:8888)
npm test             # chain-of-custody logic
npm run build        # writes dashboard/dist — commit the result
```

Point the dev server at a remote API through an SSH tunnel: `ATLAS_API_URL=http://127.0.0.1:8888 npm run dev`.
