#!/usr/bin/env bash
# shellcheck disable=SC2034  # many globals here are consumed by sourced install.sh functions

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_SCRIPT="${TEST_ROOT}/install-test.sh"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

# 将所有系统路径改写到临时目录，避免测试影响真实系统。
sed \
    -e "s|readonly CADDY_BIN=.*|readonly CADDY_BIN=\"${TEST_ROOT}/usr/bin/caddy\"|" \
    -e "s|readonly CADDY_DIR=.*|readonly CADDY_DIR=\"${TEST_ROOT}/etc/caddy\"|" \
    -e "s|readonly CLIENT_CONFIG=.*|readonly CLIENT_CONFIG=\"${TEST_ROOT}/root/naive-client-config.json\"|" \
    -e "s|readonly SINGBOX_CONFIG=.*|readonly SINGBOX_CONFIG=\"${TEST_ROOT}/root/naive-singbox.json\"|" \
    -e "s|readonly SYSTEMD_UNIT=.*|readonly SYSTEMD_UNIT=\"${TEST_ROOT}/etc/systemd/system/caddy.service\"|" \
    -e "s|readonly TMP_BUILD_DIR=.*|readonly TMP_BUILD_DIR=\"${TEST_ROOT}/root/tmp\"|" \
    -e "s|readonly GO_INSTALL_DIR=.*|readonly GO_INSTALL_DIR=\"${TEST_ROOT}/usr/local/go\"|" \
    -e "s|readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT=\"${TEST_ROOT}/root/backups\"|" \
    -e "s|readonly CADDY_STATE_DIR=.*|readonly CADDY_STATE_DIR=\"${TEST_ROOT}/var/lib/caddy\"|" \
    "$PROJECT_ROOT/install.sh" > "$TEST_SCRIPT"

export NAIVECD_LIB_ONLY=1
# shellcheck disable=SC1090
source "$TEST_SCRIPT"

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

# 验证 TERM 会退出进程，并在退出前恢复事务快照。
if NAIVECD_LIB_ONLY=1 TEST_SCRIPT="$TEST_SCRIPT" STATIC_ROOT="$STATIC_ROOT" bash -c '
    source "$TEST_SCRIPT"
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

# 验证普通失败退出同样触发 EXIT 回滚，并保留原退出码。
if NAIVECD_LIB_ONLY=1 TEST_SCRIPT="$TEST_SCRIPT" STATIC_ROOT="$STATIC_ROOT" bash -c '
    source "$TEST_SCRIPT"
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
[[ "$STATE_CADDY_STATE_DIR_METADATA" == "0:0:750" ]]
[[ "$STATE_STATIC_INDEX_METADATA" == "0:0:600" ]]
[[ "$ORIGINAL_SERVICE_ACTIVE" == "1" ]]

printf 'high-priority integration tests passed\n'
