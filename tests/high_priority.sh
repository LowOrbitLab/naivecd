#!/usr/bin/env bash
# Integration tests for transactional rollback, signal handling, and managed state persistence.
# shellcheck disable=SC2034,SC2329  # globals and mocks are consumed by sourced install.sh functions

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export NAIVECD_LIB_ONLY=1
export NAIVECD_TEST_ROOT="$TEST_ROOT"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/install.sh"

systemctl() {
    case "${1:-}" in
        is-active|is-enabled) return 0 ;;
        *) return 0 ;;
    esac
}

STATIC_ROOT="${TEST_ROOT}/var/www/cover"
mkdir -p \
    "$(dirname "$CADDY_BIN")" "$CADDY_DIR" "$CADDY_STATE_DIR" "$STATIC_ROOT" \
    "$(dirname "$SYSTEMD_UNIT")" "$(dirname "$CLIENT_CONFIG")"
printf 'old-bin' > "$CADDY_BIN"
printf 'old-unit' > "$SYSTEMD_UNIT"
printf 'old-config' > "$CADDYFILE"
printf 'old-cred' > "$CRED_FILE"
printf 'old-client' > "$CLIENT_CONFIG"
printf 'old-sing' > "$SINGBOX_CONFIG"
printf 'old-state' > "$STATE_FILE"
printf 'old-index' > "${STATIC_ROOT}/index.html"
chmod 0700 "$CADDY_DIR" "$CADDY_STATE_DIR" "$STATIC_ROOT" "${STATIC_ROOT}/index.html"

begin_transaction
printf 'new-bin' > "$CADDY_BIN"
printf 'new-config' > "$CADDYFILE"
printf 'new-index' > "${STATIC_ROOT}/index.html"
chmod 0755 "$CADDY_DIR" "$CADDY_STATE_DIR" "$STATIC_ROOT" "${STATIC_ROOT}/index.html"
rollback_transaction

[[ "$(<"$CADDY_BIN")" == "old-bin" ]]
[[ "$(<"$CADDYFILE")" == "old-config" ]]
[[ "$(<"${STATIC_ROOT}/index.html")" == "old-index" ]]
[[ "$(stat -c %a "$CADDY_DIR")" == "700" ]]
[[ "$(stat -c %a "$CADDY_STATE_DIR")" == "700" ]]
[[ "$(stat -c %a "$STATIC_ROOT")" == "700" ]]
[[ "$(stat -c %a "${STATIC_ROOT}/index.html")" == "700" ]]
[[ "$TRANSACTION_ACTIVE" == "0" ]]

# Verify sequential transactions in the same shell: committing a first transaction
# must not prevent a subsequent transaction from rolling back cleanly.
begin_transaction
printf 'committed-bin' > "$CADDY_BIN"
commit_transaction
[[ "$(<"$CADDY_BIN")" == "committed-bin" ]]

begin_transaction
printf 'aborted-second-tx' > "$CADDY_BIN"
rollback_transaction
[[ "$(<"$CADDY_BIN")" == "committed-bin" ]]
printf 'old-bin' > "$CADDY_BIN"

replaced_path="${TEST_ROOT}/replaced"
printf 'original' > "$replaced_path"
ORIGIN_TEST=""
BACKUP_TEST=""
record_resource_origin ORIGIN_TEST BACKUP_TEST "$replaced_path"
printf 'managed' > "$replaced_path"
restore_owned_resource "$replaced_path" "$ORIGIN_TEST" "$BACKUP_TEST" "test resource"
[[ "$(<"$replaced_path")" == "original" ]]

created_path="${TEST_ROOT}/created"
ORIGIN_CREATED=""
BACKUP_CREATED=""
record_resource_origin ORIGIN_CREATED BACKUP_CREATED "$created_path"
printf 'managed' > "$created_path"
restore_owned_resource "$created_path" "$ORIGIN_CREATED" "$BACKUP_CREATED" "created resource"
[[ ! -e "$created_path" ]]

# Verify SIGTERM before begin_transaction exits cleanly without false rollback warnings.
pre_tx_log="${TEST_ROOT}/pre-tx.log"
if NAIVECD_LIB_ONLY=1 NAIVECD_TEST_ROOT="$TEST_ROOT" PROJECT_ROOT="$PROJECT_ROOT" bash -c '
    source "$PROJECT_ROOT/install.sh"
    kill -TERM $$
' >"$pre_tx_log" 2>&1; then
    pre_tx_status=0
else
    pre_tx_status=$?
fi
[[ "$pre_tx_status" == "143" ]]
[[ "$(<"$pre_tx_log")" != *"Rolling back"* ]]

# Verify SIGTERM during an active transaction exits 143 and restores the snapshot.
if NAIVECD_LIB_ONLY=1 NAIVECD_TEST_ROOT="$TEST_ROOT" PROJECT_ROOT="$PROJECT_ROOT" STATIC_ROOT="$STATIC_ROOT" bash -c '
    source "$PROJECT_ROOT/install.sh"
    systemctl() {
        case "${1:-}" in
            is-active|is-enabled) return 0 ;;
            *) return 0 ;;
        esac
    }
    begin_transaction
    printf interrupted > "$CADDY_BIN"
    kill -TERM $$
'; then
    signal_status=0
else
    signal_status=$?
fi
[[ "$signal_status" == "143" ]]
[[ "$(<"$CADDY_BIN")" == "old-bin" ]]

# Verify non-zero exit during an active transaction triggers EXIT rollback and preserves exit status.
if NAIVECD_LIB_ONLY=1 NAIVECD_TEST_ROOT="$TEST_ROOT" PROJECT_ROOT="$PROJECT_ROOT" STATIC_ROOT="$STATIC_ROOT" bash -c '
    source "$PROJECT_ROOT/install.sh"
    systemctl() { return 0; }
    begin_transaction
    printf failed > "$CADDY_BIN"
    exit 7
'; then
    failure_status=0
else
    failure_status=$?
fi
[[ "$failure_status" == "7" ]]
[[ "$(<"$CADDY_BIN")" == "old-bin" ]]

ORIGIN_CADDY_BIN="replaced"
ORIGINAL_CADDY_BIN_BACKUP="${TEST_ROOT}/original-caddy"
STATE_DOMAIN="edge.example.com"
STATE_NAIVE_PORT="8443"
STATE_COVER_MODE="proxy"
STATE_MASK_SITE="https://files.pythonhosted.org"
STATE_CADDY_DIR_METADATA="0:0:700"
STATE_CADDY_STATE_DIR_METADATA="0:0:750"
STATE_STATIC_ROOT_METADATA="0:0:700"
STATE_STATIC_INDEX_METADATA="0:0:600"
ORIGINAL_SERVICE_STATE_CAPTURED=1
ORIGINAL_SERVICE_ACTIVE=1
ORIGINAL_SERVICE_ENABLED=1
chown() { return 0; }
write_managed_state
reset_managed_state
load_managed_state
[[ "$ORIGIN_CADDY_BIN" == "replaced" ]]
[[ "$ORIGINAL_CADDY_BIN_BACKUP" == "${TEST_ROOT}/original-caddy" ]]
[[ "$STATE_DOMAIN" == "edge.example.com" ]]
[[ "$STATE_NAIVE_PORT" == "8443" ]]
[[ "$STATE_COVER_MODE" == "proxy" ]]
[[ "$STATE_MASK_SITE" == "https://files.pythonhosted.org" ]]
[[ "$STATE_CADDY_STATE_DIR_METADATA" == "0:0:750" ]]
[[ "$STATE_STATIC_INDEX_METADATA" == "0:0:600" ]]
[[ "$ORIGINAL_SERVICE_ACTIVE" == "1" ]]

printf 'high-priority integration tests passed\n'
