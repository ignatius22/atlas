#!/usr/bin/env bash
# ==============================================================================
# Atlas Test Suite — one-line installer (get.sh)
# ==============================================================================
# Installs into a temporary directory from this checkout, without root, systemd
# changes or package installs, and checks the result and re-run behaviour.
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
GET="${ATLAS_ROOT}/get.sh"

PASSED=0
FAILED=0
pass() { printf "  \033[32m✓ PASS\033[0m: %s\n" "$1"; PASSED=$((PASSED + 1)); }
fail() { printf "  \033[31m✗ FAIL\033[0m: %s\n" "$1"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
DIR="${WORK}/opt/atlas"
KEY="age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

run_get() {
  ATLAS_SOURCE_DIR="${ATLAS_ROOT}" ATLAS_ALLOW_NONROOT=1 \
    ATLAS_SYSTEMD_DIR="${WORK}/systemd" ATLAS_BIN_LINK="${WORK}/bin/atlas" NO_COLOR=1 \
    bash "${GET}" --yes --dir="${DIR}" --no-deps --no-start --no-first-run --no-discover "$@"
}
env_value() { sed -n "s/^$1=//p" "${DIR}/.env"; }

printf "\n\033[1m=== One-line Installer (get.sh) Tests ===\033[0m\n"

# 1. Fresh install
if run_get > "${WORK}/out1" 2>&1; then
  pass "Fresh install completes without root, systemd or package installs"
else
  fail "Fresh install: $(tail -n 5 "${WORK}/out1")"
fi

if [ -x "${DIR}/bin/atlas" ] && [ -L "${WORK}/bin/atlas" ] && [ -f "${WORK}/systemd/atlas-drill.timer" ]; then
  pass "Code, atlas command and systemd units are installed"
else
  fail "Installed files missing"
fi

mode="$(stat -c '%a' "${DIR}/.env" 2> /dev/null || echo none)"
token="$(env_value ATLAS_DASHBOARD_TOKEN)"
if [ "${mode}" = "600" ] && [[ "${token}" =~ ^[0-9a-f]{64}$ ]]; then
  pass ".env is private (600) with a generated 64-character dashboard token"
else
  fail ".env mode ${mode}, token '${token}'"
fi

if [ -z "$(env_value ATLAS_AGE_RECIPIENT)" ] && [ -z "$(env_value ATLAS_DISCORD_WEBHOOK)" ] \
  && grep -q "re-run with --age-recipient" "${WORK}/out1" && grep -q "Offsite storage" "${WORK}/out1"; then
  pass "No placeholder secrets: unset values stay empty and the summary lists what is left to do"
else
  fail "Placeholders or summary: $(grep -E '^ATLAS_(AGE|DISCORD)' "${DIR}/.env")"
fi

# 2. Re-run with a key: token kept, key set, user edits kept
printf 'ATLAS_S3_BUCKET=my-bucket\nMY_SETTING=keep-me\n' >> "${DIR}/.env"
mkdir -p "${DIR}/config" && printf 'apps:\n  mine: {name: Mine}\n' > "${DIR}/config/apps.yml"
if run_get --age-recipient="${KEY}" > "${WORK}/out2" 2>&1 \
  && [ "$(env_value ATLAS_DASHBOARD_TOKEN)" = "${token}" ] \
  && [ "$(env_value ATLAS_AGE_RECIPIENT)" = "${KEY}" ] \
  && [ "$(env_value MY_SETTING)" = "keep-me" ] && [ "$(env_value ATLAS_S3_BUCKET | tail -n 1)" = "my-bucket" ] \
  && grep -q "mine" "${DIR}/config/apps.yml" && grep -q "1 app(s) configured" "${WORK}/out2"; then
  pass "Re-running upgrades in place: keeps the token, your settings and apps.yml, and sets the key"
else
  fail "Re-run: $(tail -n 8 "${WORK}/out2")"
fi

# 3. A placeholder token from the old template is replaced
sed -i 's/^ATLAS_DASHBOARD_TOKEN=.*/ATLAS_DASHBOARD_TOKEN=generate_a_secure_random_64_char_hex_token_here/' "${DIR}/.env"
run_get > /dev/null 2>&1 || true
if [[ "$(env_value ATLAS_DASHBOARD_TOKEN)" =~ ^[0-9a-f]{64}$ ]]; then
  pass "A placeholder dashboard token is replaced with a real one"
else
  fail "Placeholder token kept"
fi

# 4. Bad input and safety
if ! run_get --age-recipient="AGE-SECRET-KEY-1ABC" > "${WORK}/out4" 2>&1 && grep -q "Never pass the private key" "${WORK}/out4"; then
  pass "Refuses a private key passed as --age-recipient"
else
  fail "Private key accepted as recipient"
fi

if ! grep -rqs "AGE-SECRET-KEY-" "${DIR}/.env" "${DIR}/config"; then
  pass "No private key is written anywhere on the server"
else
  fail "Private key found on disk"
fi

if [ "$(grep -v '^[[:space:]]*$' "${GET}" | tail -n 1)" = 'main "$@"' ] \
  && head -n "$(($(wc -l < "${GET}") / 2))" "${GET}" | ATLAS_INSTALL_DIR="${WORK}/half" bash > /dev/null 2>&1; [ ! -e "${WORK}/half" ]; then
  pass "A download cut off halfway runs nothing"
else
  fail "Truncated script had side effects"
fi

printf "\n\033[1mInstaller Tests Summary: %d passed, %d failed\033[0m\n" "${PASSED}" "${FAILED}"
if [ "${FAILED}" -gt 0 ]; then exit 1; fi
exit 0
