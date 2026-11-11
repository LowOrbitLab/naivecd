#!/usr/bin/env bash
# Lifecycle tests for client configs, reconfigure defaults, cover cleanup,
# backup pruning, crash-loop detection, and uninstall behavior.
# shellcheck disable=SC2034,SC2329

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

TEST_TTY="${TEST_ROOT}/fake-tty"
printf '\n' > "$TEST_TTY"

export NAIVECD_LIB_ONLY=1
export NAIVECD_TEST_ROOT="$TEST_ROOT"
export NAIVECD_TEST_TTY="$TEST_TTY"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/install.sh"

chown() { return 0; }
chgrp() { return 0; }

# Client configs and credentials: mode 0600, valid JSON, no sing-box tls.utls.
DOMAIN="cdn.example.com"
NAIVE_PORT=443
NAIVE_USER="userAbc123"
NAIVE_PASS="passXyz789"
COVER_MODE="static"
STATIC_ROOT="${TEST_ROOT}/var/www/naive-cover"

save_credentials_file
write_client_config
write_singbox_config

[[ "$(stat -c %a "$CRED_FILE")" == "600" ]]
[[ "$(stat -c %a "$CLIENT_CONFIG")" == "600" ]]
[[ "$(stat -c %a "$SINGBOX_CONFIG")" == "600" ]]

if command -v jq >/dev/null 2>&1; then
    jq -e '.listen == "socks://127.0.0.1:10808"' "$CLIENT_CONFIG" >/dev/null
    jq -e '.proxy == "https://userAbc123:passXyz789@cdn.example.com:443"' "$CLIENT_CONFIG" >/dev/null
    jq -e '.outbounds[0].type == "naive"' "$SINGBOX_CONFIG" >/dev/null
    jq -e '.outbounds[0].server == "cdn.example.com" and .outbounds[0].server_port == 443' "$SINGBOX_CONFIG" >/dev/null
    jq -e '.outbounds[0].tls.enabled == true and .outbounds[0].tls.server_name == "cdn.example.com"' "$SINGBOX_CONFIG" >/dev/null
    # sing-box naive outbound explicitly rejects tls.utls; ensure it is absent.
    jq -e '.outbounds[0].tls | has("utls") | not' "$SINGBOX_CONFIG" >/dev/null
else
    [[ "$(<"$SINGBOX_CONFIG")" != *'"utls"'* ]]
fi

NAIVE_USER=""
NAIVE_PASS=""
load_existing_credentials
[[ "$NAIVE_USER" == "userAbc123" && "$NAIVE_PASS" == "passXyz789" ]]

# Reconfigure defaults fall back to CRED_FILE comments when upgrading from
# older state files and prefer STATE_* values when present.
STATE_DOMAIN=""
STATE_NAIVE_PORT=""
STATE_COVER_MODE=""
STATE_STATIC_ROOT=""
STATE_MASK_SITE=""
MODE="reconfigure"
unset NAIVE_DOMAIN NAIVE_PORT NAIVE_COVER_MODE NAIVE_STATIC_ROOT NAIVE_MASK_SITE
DOMAIN=""
NAIVE_PORT=""
COVER_MODE=""
STATIC_ROOT=""
gather_inputs >/dev/null 2>&1
[[ "$DOMAIN" == "cdn.example.com" ]]
[[ "$NAIVE_PORT" == "443" ]]
[[ "$COVER_MODE" == "static" ]]
[[ "$STATIC_ROOT" == "$(realpath -m -- "${TEST_ROOT}/var/www/naive-cover")" ]]

STATE_DOMAIN="reconf.example.com"
STATE_NAIVE_PORT="8443"
STATE_COVER_MODE="proxy"
STATE_MASK_SITE="https://mirror.example.org"
DOMAIN=""
NAIVE_PORT=""
COVER_MODE=""
MASK_SITE=""
gather_inputs >/dev/null 2>&1
[[ "$DOMAIN" == "reconf.example.com" ]]
[[ "$NAIVE_PORT" == "8443" ]]
[[ "$COVER_MODE" == "proxy" ]]
[[ "$MASK_SITE" == "https://mirror.example.org" ]]

# Static cover site lifecycle: initial write, unmodified regeneration, user
# edit preservation, and cleanup when changing root or switching to proxy mode.
COVER_MODE="static"
DOMAIN="first.example.com"
NAIVE_PORT=443
STATIC_ROOT="${TEST_ROOT}/var/www/cover-a"
MANAGED_STATIC_ROOT_CREATED=0
MANAGED_STATIC_INDEX=0
STATE_STATIC_ROOT=""
STATE_STATIC_INDEX_SHA256=""

write_static_cover_site >/dev/null 2>&1
[[ -f "${STATIC_ROOT}/index.html" ]]
[[ "$MANAGED_STATIC_ROOT_CREATED" == "1" ]]
[[ "$MANAGED_STATIC_INDEX" == "1" ]]
[[ "$(<"${STATIC_ROOT}/index.html")" == *"https://first.example.com"* ]]

# Unmodified page regenerates when DOMAIN/NAIVE_PORT changes.
DOMAIN="second.example.com"
NAIVE_PORT=8443
write_static_cover_site >/dev/null 2>&1
[[ "$(<"${STATIC_ROOT}/index.html")" == *"https://second.example.com:8443"* ]]

# Switching STATIC_ROOT cleans up the old unmodified managed directory.
old_root="$STATIC_ROOT"
STATIC_ROOT="${TEST_ROOT}/var/www/cover-b"
write_static_cover_site >/dev/null 2>&1
[[ ! -d "$old_root" ]]
[[ -f "${STATIC_ROOT}/index.html" ]]

# User-modified index.html is preserved across reconfigure and proxy switch.
printf '<html>custom cover</html>\n' > "${STATIC_ROOT}/index.html"
DOMAIN="third.example.com"
write_static_cover_site >/dev/null 2>&1
[[ "$(<"${STATIC_ROOT}/index.html")" == "<html>custom cover</html>" ]]

COVER_MODE="proxy"
write_static_cover_site >/dev/null 2>&1
[[ -f "${TEST_ROOT}/var/www/cover-b/index.html" ]]

# Fresh unmodified static root IS cleaned up when switching to proxy mode.
COVER_MODE="static"
STATIC_ROOT="${TEST_ROOT}/var/www/cover-c"
write_static_cover_site >/dev/null 2>&1
[[ -f "${STATIC_ROOT}/index.html" ]]
COVER_MODE="proxy"
write_static_cover_site >/dev/null 2>&1
[[ ! -d "${TEST_ROOT}/var/www/cover-c" ]]
[[ -z "$STATE_STATIC_ROOT" ]]

# Backup session pruning keeps newest 5 plus referenced originals.
rm -rf -- "$BACKUP_ROOT"
mkdir -p "$BACKUP_ROOT"
for s in 20260101-000001 20260102-000001 20260103-000001 20260104-000001 \
         20260105-000001 20260106-000001 20260107-000001 20260108-000001; do
    mkdir -p "${BACKUP_ROOT}/${s}"
done
BACKUP_SESSION_DIR=""
ORIGINAL_CADDYFILE_BACKUP="${BACKUP_ROOT}/20260101-000001/originals/etc/caddy/Caddyfile"
prune_backup_sessions >/dev/null 2>&1
[[ -d "${BACKUP_ROOT}/20260101-000001" ]]
[[ ! -d "${BACKUP_ROOT}/20260102-000001" ]]
[[ ! -d "${BACKUP_ROOT}/20260103-000001" ]]
[[ -d "${BACKUP_ROOT}/20260104-000001" ]]
[[ -d "${BACKUP_ROOT}/20260108-000001" ]]

# wait_for_caddy_active detects systemd auto-restart crash loops immediately.
systemctl() {
    case "${1:-}" in
        is-active|is-failed) return 1 ;;
        show)
            printf 'SubState=auto-restart\nExecMainStatus=1\n'
            return 0
            ;;
        *) return 0 ;;
    esac
}
journalctl() { printf 'synthetic caddy crash log\n'; return 0; }
start_sec=$SECONDS
if crash_out="$(wait_for_caddy_active 2>&1)"; then
    echo "expected wait_for_caddy_active to fail on crash loop" >&2
    exit 1
fi
elapsed=$(( SECONDS - start_sec ))
(( elapsed < 10 ))
[[ "$crash_out" == *"crash-looping (exit status 1)"* ]]
unset -f systemctl journalctl

# Uninstall reclaims CADDY_STATE_DIR ownership before userdel/groupdel and
# restarts a pre-existing vendor caddy.service even when /etc/systemd/system/caddy.service
# was newly created as an override.
reset_managed_state
mkdir -p "$CADDY_DIR" "$CADDY_STATE_DIR" "$(dirname "$CADDY_BIN")" "$(dirname "$SYSTEMD_UNIT")"
chmod 0750 "$CADDY_STATE_DIR"
printf '# Managed by naivecd.\n' > "$SYSTEMD_UNIT"
printf '# Managed by naivecd.\n' > "$CADDYFILE"
printf '# Managed by naivecd.\n' > "$CRED_FILE"
orig_bin="${BACKUP_ROOT}/vendor-orig/usr/bin/caddy"
mkdir -p "$(dirname "$orig_bin")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$orig_bin"
chmod 0755 "$orig_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CADDY_BIN"
chmod 0755 "$CADDY_BIN"

NAIVECD_MANAGED=1
MANAGED_CADDY_BIN=1
MANAGED_SYSTEMD_UNIT=1
MANAGED_CADDYFILE=1
MANAGED_CRED_FILE=1
MANAGED_CADDY_USER_CREATED=1
MANAGED_CADDY_GROUP_CREATED=1
ORIGIN_CADDY_BIN="replaced"
ORIGINAL_CADDY_BIN_BACKUP="$orig_bin"
ORIGIN_SYSTEMD_UNIT="created"
ORIGIN_CADDYFILE="created"
ORIGIN_CRED_FILE="created"
ORIGINAL_SERVICE_STATE_CAPTURED=1
ORIGINAL_SERVICE_ENABLED=1
ORIGINAL_SERVICE_ACTIVE=1
write_managed_state

events_log="${TEST_ROOT}/uninstall-events.log"
: > "$events_log"
chown() {
    printf 'chown:%s\n' "$*" >> "$events_log"
    return 0
}
id() { return 0; }
getent() { return 0; }
userdel() {
    printf 'userdel:%s:mode=%s\n' "$1" "$(stat -c %a "$CADDY_STATE_DIR")" >> "$events_log"
    return 0
}
groupdel() {
    printf 'groupdel:%s\n' "$1" >> "$events_log"
    return 0
}
systemctl() {
    printf 'systemctl:%s\n' "$*" >> "$events_log"
    if [[ "${1:-}" == "list-unit-files" ]]; then
        printf 'caddy.service disabled enabled\n1 unit files listed.\n'
    fi
    return 0
}
printf 'y\n' > "$TEST_TTY"

uninstall_caddy_naive >/dev/null 2>&1

events="$(<"$events_log")"
# Ownership reclaim (-Rh root:root) and chmod 700 must happen BEFORE userdel.
[[ "$events" == *"chown:-Rh root:root -- ${CADDY_STATE_DIR}"* ]]
[[ "$events" == *"userdel:caddy:mode=700"* ]]
chown_line="$(grep -n "chown:-Rh root:root -- ${CADDY_STATE_DIR}" "$events_log" | head -n1 | cut -d: -f1)"
userdel_line="$(grep -n "userdel:caddy:mode=700" "$events_log" | head -n1 | cut -d: -f1)"
(( chown_line < userdel_line ))

# Vendor unit must be re-enabled and restarted after removing our /etc override.
[[ ! -e "$SYSTEMD_UNIT" ]]
[[ -x "$CADDY_BIN" ]]
[[ "$events" == *"systemctl:enable caddy"* ]]
[[ "$events" == *"systemctl:start caddy"* ]]

printf 'lifecycle and config tests passed\n'
