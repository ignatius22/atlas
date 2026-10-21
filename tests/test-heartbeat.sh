#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — Heartbeat (External Watchdog) Tests
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
HB="${ATLAS_ROOT}/scripts/lib/heartbeat.py"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
CATCHER_PID=""
cleanup() {
  [ -n "${CATCHER_PID}" ] && kill "${CATCHER_PID}" 2> /dev/null || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

printf "\n\033[1m=== Heartbeat Report & Delivery Tests ===\033[0m\n"

# A tiny HTTP receiver that records path, signature and body of each POST.
cat > "${WORK}/catcher.py" << 'PY'
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sys.argv[2], "a") as fh:
            fh.write(json.dumps({"path": self.path, "sig": self.headers.get("X-Atlas-Signature"), "raw": body.decode()}) + "\n")
        self.send_response(200); self.end_headers()
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY
python3 "${WORK}/catcher.py" "${WORK}" "${WORK}/hits.jsonl" > "${WORK}/port" &
CATCHER_PID=$!
for _ in $(seq 50); do [ -s "${WORK}/port" ] && break; sleep 0.1; done
PORT="$(head -n 1 "${WORK}/port")"
URL="http://127.0.0.1:${PORT}/ping/check-1"

BK="${WORK}/backups"
mkdir -p "${BK}/good" "${BK}/bad"
NOW="$(date +%s)"
printf 'SECRET-ROW-DATA' | gzip > "${BK}/good/good-20261021T000000Z.sql.gz"
touch "${BK}/good/good-20261021T000000Z.sql.gz.synced"
printf '{"table_count": 3, "total_rows": 42}' > "${BK}/good/good-20261021T000000Z.sql.gz.manifest.json"
printf '{"passed": true, "checked_at": %s}' "${NOW}" > "${BK}/good/good-20261021T000000Z.sql.gz.drill.json"

# 1. Healthy server -> success URL, status ok
ATLAS_BACKUP_DIR="${BK}/good-only" python3 -I "${HB}" report > /dev/null
mkdir -p "${WORK}/only-good" && cp -a "${BK}/good" "${WORK}/only-good/"
ATLAS_BACKUP_DIR="${WORK}/only-good" ATLAS_HEARTBEAT_URL="${URL}" python3 -I "${HB}" send --event backup --exit-code 0 > /dev/null
if python3 -I - "${WORK}/hits.jsonl" << 'PY'
import json, sys
hits = [json.loads(l) for l in open(sys.argv[1])]
h = hits[-1]
body = json.loads(h["raw"])
assert h["path"] == "/ping/check-1", h["path"]
assert body["status"] == "ok" and body["problems"] == [], body
app = body["apps"][0]
assert app["app"] == "good" and app["database"]["tables"] == 3 and app["database"]["rows"] == 42
assert app["database"]["offsite_confirmed"] is True and app["database"]["drill"]["passed"] is True
PY
then
  pass "Healthy server sends status ok to the success URL with per-app backup, offsite and drill state"
else
  fail "Healthy heartbeat"
fi

# 2. Problems -> /fail URL with reasons and the run's exit code
printf 'x' | gzip > "${BK}/bad/bad-20261021T000000Z.sql.gz"
touch -d "@$((NOW - 10 * 3600))" "${BK}/bad/bad-20261021T000000Z.sql.gz"
printf '{"passed": false, "checked_at": %s, "reason": "public.users has 1 rows, expected 2"}' "${NOW}" > "${BK}/bad/bad-20261021T000000Z.sql.gz.drill.json"
ATLAS_BACKUP_DIR="${BK}" ATLAS_HEARTBEAT_URL="${URL}" python3 -I "${HB}" send --event backup --exit-code 1 > /dev/null
if python3 -I - "${WORK}/hits.jsonl" << 'PY'
import json, sys
h = [json.loads(l) for l in open(sys.argv[1])][-1]
body = json.loads(h["raw"])
assert h["path"] == "/ping/check-1/fail", h["path"]
p = " | ".join(body["problems"])
assert body["status"] == "fail"
assert "backup exited with code 1" in p and "bad: newest backup is 10 h old" in p, p
assert "bad: no copy confirmed offsite" in p and "bad: last restore drill failed" in p, p
PY
then
  pass "Problems go to the /fail URL with the exit code and each reason (late, not offsite, drill failed)"
else
  fail "Failure heartbeat routing or reasons"
fi

# 3. Signature is a valid HMAC of the exact body; no backup contents leak
ATLAS_BACKUP_DIR="${WORK}/only-good" ATLAS_HEARTBEAT_URL="${URL}" ATLAS_HEARTBEAT_SECRET="s3cret" python3 -I "${HB}" send > /dev/null
if python3 -I - "${WORK}/hits.jsonl" << 'PY'
import hashlib, hmac, json, sys
h = [json.loads(l) for l in open(sys.argv[1])][-1]
expected = "sha256=" + hmac.new(b"s3cret", h["raw"].encode(), hashlib.sha256).hexdigest()
assert h["sig"] == expected, (h["sig"], expected)
assert "SECRET-ROW-DATA" not in h["raw"]
PY
then
  pass "X-Atlas-Signature is a valid HMAC-SHA256 of the body, and no backup contents are sent"
else
  fail "Heartbeat signature or data leakage"
fi

# 4. Unreachable watchdog never fails the caller; unset URL is a no-op
if ATLAS_BACKUP_DIR="${BK}" ATLAS_HEARTBEAT_URL="http://127.0.0.1:9/none" python3 -I "${HB}" send --exit-code 0 > "${WORK}/out" 2>&1 \
  && grep -q "not delivered" "${WORK}/out" \
  && ATLAS_BACKUP_DIR="${BK}" ATLAS_HEARTBEAT_URL="" python3 -I "${HB}" send > "${WORK}/out2" && grep -q "not set; skipped" "${WORK}/out2"; then
  pass "An unreachable or unset watchdog never fails the backup or drill"
else
  fail "Heartbeat failure isolation"
fi

# 5. Only configured apps are reported: an old folder is ignored, a configured app with no backups is a problem
printf 'apps:\n  good: {database: {type: postgres, container: x}}\n  newapp: {database: {type: postgres, container: y}}\n  nodb: {name: static site}\n' > "${WORK}/apps.yml"
if ATLAS_BACKUP_DIR="${BK}" ATLAS_CONFIG_FILE="${WORK}/apps.yml" python3 -I "${HB}" report | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
names = [a["app"] for a in r["apps"]]
assert names == ["good", "newapp"], names
assert r["problems"] == ["newapp: configured but has no backups yet"], r["problems"]
'; then
  pass "Reports only configured apps: old backup folders are ignored, a configured app with no backups is flagged"
else
  fail "Configured-apps filtering"
fi

# 6. A mistyped URL is explained, not sent
if ATLAS_BACKUP_DIR="${BK}" ATLAS_HEARTBEAT_URL="https://https://hc-ping.com/abc" python3 -I "${HB}" send > "${WORK}/out3" 2>&1 \
  && grep -q "looks wrong" "${WORK}/out3"; then
  pass "A doubled https:// in the URL is caught with a clear message"
else
  fail "Malformed URL: $(cat "${WORK}/out3")"
fi

printf "\n\033[1mHeartbeat Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
