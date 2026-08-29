#!/usr/bin/env bash
# ==============================================================================
# Atlas V1 — Comprehensive Test Suite & DR Chaos Engine
# ==============================================================================
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_DIR="$(cd "${TEST_DIR}/.." && pwd)"

echo "=============================================================================="
echo "🧪 RUNNING ATLAS V1 TEST SUITE & DR CHAOS DRILL"
echo "=============================================================================="

# Test 1: Configuration Validation
echo "--> [UNIT] Test 1: Validating atlas.example.yml schema..."
python3 "${ATLAS_DIR}/scripts/lib/yaml_parser.py" "${ATLAS_DIR}/atlas.example.yml" validate
echo "✓ Schema validation passed."

# Test 2: Unsafe Input & Injection Rejection
echo "--> [UNIT] Test 2: Verifying rejection of unsafe container injection..."
TMP_CONF="$(mktemp)"
cat << 'TMP' > "${TMP_CONF}"
applications:
  "bad;injection":
    database:
      container: "test;rm -rf /"
TMP
if python3 "${ATLAS_DIR}/scripts/lib/yaml_parser.py" "${TMP_CONF}" validate 2>/dev/null; then
  echo "FAIL: Unsafe container name was not rejected!"
  rm -f "${TMP_CONF}"
  exit 1
fi
rm -f "${TMP_CONF}"
echo "✓ Unsafe container names successfully blocked."

# Test 3: Age Key Generation
echo "--> [UNIT] Test 3: Generating Age keypair via CLI..."
"${ATLAS_DIR}/bin/atlas" crypto gen-key >/dev/null
echo "✓ Crypto keypair generation passed."

# Test 4: Full Chaos DR Drill (Postgres -> Dump -> Compress -> Encrypt -> Wipe -> Decrypt -> Restore)
echo "--> [CHAOS DR] Test 4: Executing End-to-End PostgreSQL Backup, Encryption, and Ephemeral Recovery..."

PG_TEST_CONTAINER="atlas_chaos_pg_$$"
PG_VERSION="${PG_VERSION:-16}"

docker run -d --name "${PG_TEST_CONTAINER}" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=chaos_secret \
  -e POSTGRES_DB=chaos_db \
  "postgres:${PG_VERSION}-alpine" >/dev/null

# Robust poll loop waiting until postgres is fully ready and accepting connections
for i in {1..30}; do
  if docker exec "${PG_TEST_CONTAINER}" psql -U postgres -d chaos_db -c "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Seed test database inside container using stdin redirection
docker exec -i "${PG_TEST_CONTAINER}" psql -U postgres -d chaos_db << 'SQL'
CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100), created_at TIMESTAMP DEFAULT NOW());
INSERT INTO users (name) VALUES ('Alice'), ('Bob'), ('Charlie'), ('David');
CREATE TABLE orders (id SERIAL PRIMARY KEY, user_id INT, amount NUMERIC);
INSERT INTO orders (user_id, amount) VALUES (1, 99.50), (2, 149.00), (3, 20.00);
SQL

# Generate test config
CHAOS_CONF="$(mktemp)"
cat << TMP > "${CHAOS_CONF}"
version: "1"
settings:
  backup_dir: "/tmp/atlas_test_backups"
  storage_provider: "local-mock"
applications:
  chaos-app:
    name: "Chaos Test App"
    directory: "/tmp"
    database:
      type: "postgres"
      container: "${PG_TEST_CONTAINER}"
      backup: true
      user: "postgres"
      database: "chaos_db"
TMP

# Generate test Age keys
TEST_KEYPAIR="$(age-keygen)"
TEST_PUB_KEY="$(echo "${TEST_KEYPAIR}" | grep 'public key:' | awk '{print $NF}')"
TEST_PRIV_KEY="$(echo "${TEST_KEYPAIR}" | grep -v '^#' | grep -v '^$')"

KEY_FILE="$(mktemp)"
echo "${TEST_PRIV_KEY}" > "${KEY_FILE}"
chmod 600 "${KEY_FILE}"

export ATLAS_AGE_RECIPIENT="${TEST_PUB_KEY}"
export ATLAS_OFFSITE_PROVIDER="local-mock"
export ATLAS_CONFIG_FILE="${CHAOS_CONF}"
export ATLAS_BACKUP_DIR="/tmp/atlas_test_backups"

# 1. Backup
"${ATLAS_DIR}/bin/atlas" backup create chaos-app --config="${CHAOS_CONF}"

# 2. Encrypt & Off-site sync
"${ATLAS_DIR}/bin/atlas" backup sync chaos-app --config="${CHAOS_CONF}"

# 3. Destroy source database
docker rm -f "${PG_TEST_CONTAINER}" >/dev/null

# 4. Ephemeral DR Restore Drill
"${ATLAS_DIR}/bin/atlas" restore test chaos-app --config="${CHAOS_CONF}" --key-file="${KEY_FILE}"

# Cleanup
rm -rf "/tmp/atlas_test_backups" "/tmp/atlas_mock_s3" "${CHAOS_CONF}" "${KEY_FILE}"
echo "✓ End-to-End Disaster Recovery Drill PASSED!"

echo "=============================================================================="
echo "🎉 ALL TESTS & DR VERIFICATIONS PASSED SUCCESSFULLY!"
echo "=============================================================================="
