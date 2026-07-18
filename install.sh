#!/usr/bin/env bash
# NaiveProxy + Caddy auto-setup for Debian/Ubuntu VPS.
# Repository: https://github.com/LowOrbitLab/naivecd

# -E (errtrace) makes functions inherit the ERR trap so on_err reports the
# real failing line; without it, failures inside functions skip on_err entirely.
set -Eeuo pipefail

#─────────────────────────────────────────────────────────────────────────────
# Helpers
#─────────────────────────────────────────────────────────────────────────────

readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[0;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_BOLD=$'\033[1m'
readonly C_RST=$'\033[0m'

log()   { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RST" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RST" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RST" "$*"; }
err()   { printf '%s[x]%s %s\n' "$C_RED"    "$C_RST" "$*" >&2; }
die()   { err "$*"; exit 1; }

on_err() {
    local code=$? line=${1:-?}
    trap - ERR
    # Command substitutions inherit the ERR trap (set -E) but run in subshells
    # where diagnostics would duplicate the parent's and rollback is pointless:
    # exit quietly and let the parent handle (or guard) the failure.
    if (( BASH_SUBSHELL > 0 )); then
        exit "$code"
    fi
    err "Failed at line $line (exit $code). Last command: ${BASH_COMMAND}"
    rollback_transaction || true
    exit "$code"
}
trap 'on_err $LINENO' ERR

TMP_PATHS=()

register_tmp() {
    if [[ -n "${1:-}" ]]; then
        TMP_PATHS+=("$1")
    fi
}

cleanup_tmp() {
    local p
    [[ ${#TMP_PATHS[@]} -eq 0 ]] && return 0
    for p in "${TMP_PATHS[@]}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf -- "$p" || true
    done
}

on_exit() {
    local code=$?
    trap - ERR
    if (( TRANSACTION_ACTIVE == 1 && TRANSACTION_COMMITTED == 0 )); then
        rollback_transaction || true
    fi
    cleanup_tmp
    return "$code"
}
trap on_exit EXIT

on_signal() {
    local code="$1" signal="$2"
    trap - ERR INT TERM
    warn "Received ${signal}; rolling back the current installation."
    rollback_transaction || true
    exit "$code"
}
trap 'on_signal 130 INT' INT
trap 'on_signal 143 TERM' TERM

confirm() {
    # confirm "Question" [default-yes|default-no]
    local prompt="$1" default="${2:-default-no}" reply
    local hint="[y/N]"
    [[ "$default" == "default-yes" ]] && hint="[Y/n]"
    while true; do
        read -r -p "$(printf '%s? %s ' "$prompt" "$hint")" reply </dev/tty || return 1
        reply="${reply:-}"
        if [[ -z "$reply" ]]; then
            [[ "$default" == "default-yes" ]] && return 0 || return 1
        fi
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO)   return 1 ;;
            *) echo "Please answer y or n." >&2 ;;
        esac
    done
}

prompt_value() {
    # prompt_value "Question" [default]
    local prompt="$1" default="${2:-}" reply
    local suffix=""
    [[ -n "$default" ]] && suffix=" [$default]"
    while true; do
        read -r -p "$(printf '%s%s: ' "$prompt" "$suffix")" reply </dev/tty || return 1
        reply="${reply:-$default}"
        if [[ -n "$reply" ]]; then
            printf '%s' "$reply"
            return 0
        fi
        echo "Value required, please enter." >&2
    done
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

#─────────────────────────────────────────────────────────────────────────────
# Constants
#─────────────────────────────────────────────────────────────────────────────

readonly DEFAULT_MASK_SITE="https://files.pythonhosted.org/"
readonly DEFAULT_STATIC_ROOT="/var/www/naive-cover"
readonly DEFAULT_NAIVE_PORT="443"
readonly PREBUILT_CADDY_TAG="v2.11.2-naive"
readonly PREBUILT_CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/download/${PREBUILT_CADDY_TAG}/caddy-forwardproxy-naive.tar.xz"
readonly PREBUILT_CADDY_SHA256="19eccb7321dd877a5fb4a3dba6ef1b745185188b616c96cc6201f1a1fc0380a8"
readonly CADDY_CORE_VERSION="v2.11.2"
readonly GO_VERSION="go1.26.4"
readonly GO_LINUX_AMD64_SHA256="1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f"
readonly GO_LINUX_ARM64_SHA256="ef758ae7c6cf9267c9c0ef080b8965f453d89ab2d25d9eb22de4405925238768"
readonly XCADDY_MODULE="github.com/caddyserver/xcaddy/cmd/xcaddy@v0.4.6"
readonly FORWARDPROXY_MODULE="github.com/klzgrad/forwardproxy@v2.11.2-naive"
readonly CADDY_BIN="/usr/bin/caddy"
readonly CADDY_DIR="/etc/caddy"
readonly CADDYFILE="${CADDY_DIR}/Caddyfile"
readonly CRED_FILE="${CADDY_DIR}/credentials.txt"
readonly CLIENT_CONFIG="/root/naive-client-config.json"
readonly SINGBOX_CONFIG="/root/naive-singbox.json"
readonly SYSTEMD_UNIT="/etc/systemd/system/caddy.service"
readonly TMP_BUILD_DIR="/root/tmp"
readonly GO_INSTALL_DIR="/usr/local/go"
readonly STATE_FILE="${CADDY_DIR}/naivecd-managed.env"
readonly BACKUP_ROOT="/root/naivecd-backups"
readonly CADDY_USER="caddy"
readonly CADDY_GROUP="caddy"
readonly CADDY_STATE_DIR="/var/lib/caddy"

STATE_LOADED=0
NAIVECD_MANAGED=0
MANAGED_CADDY_DIR_CREATED=0
MANAGED_CADDY_BIN=0
MANAGED_SYSTEMD_UNIT=0
MANAGED_CADDYFILE=0
MANAGED_CRED_FILE=0
MANAGED_CLIENT_CONFIG=0
MANAGED_SINGBOX_CONFIG=0
MANAGED_STATIC_ROOT_CREATED=0
MANAGED_STATIC_INDEX=0
MANAGED_GO=0
MANAGED_CADDY_USER_CREATED=0
MANAGED_CADDY_GROUP_CREATED=0
STATE_STATIC_ROOT=""
STATE_STATIC_INDEX_SHA256=""
BACKUP_SESSION_DIR=""
BACKUP_QUIET=0
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
TRANSACTION_DIR=""
TRANSACTION_SERVICE_ACTIVE=0
TRANSACTION_SERVICE_ENABLED=0
TRANSACTION_PATHS=()
TRANSACTION_PATH_EXISTED=()
TRANSACTION_METADATA_PATHS=()
TRANSACTION_METADATA_VALUES=()
TRANSACTION_CADDY_DIR_EXISTED=0
TRANSACTION_CADDY_STATE_DIR_EXISTED=0
TRANSACTION_STATIC_ROOT_EXISTED=0
TRANSACTION_CREATED_CADDY_USER=0
TRANSACTION_CREATED_CADDY_GROUP=0
TRANSACTION_INSTALLED_GO=0

ORIGIN_CADDY_BIN=""
ORIGIN_SYSTEMD_UNIT=""
ORIGIN_CADDYFILE=""
ORIGIN_CRED_FILE=""
ORIGIN_CLIENT_CONFIG=""
ORIGIN_SINGBOX_CONFIG=""
ORIGINAL_CADDY_BIN_BACKUP=""
ORIGINAL_SYSTEMD_UNIT_BACKUP=""
ORIGINAL_CADDYFILE_BACKUP=""
ORIGINAL_CRED_FILE_BACKUP=""
ORIGINAL_CLIENT_CONFIG_BACKUP=""
ORIGINAL_SINGBOX_CONFIG_BACKUP=""
STATE_CADDY_DIR_METADATA=""
STATE_CADDY_STATE_DIR_METADATA=""
STATE_STATIC_ROOT_METADATA=""
STATE_STATIC_INDEX_METADATA=""
ORIGINAL_SERVICE_STATE_CAPTURED=0
ORIGINAL_SERVICE_ACTIVE=0
ORIGINAL_SERVICE_ENABLED=0
SYSTEMD_UNIT_CHANGED=1

#─────────────────────────────────────────────────────────────────────────────
# Preflight
#─────────────────────────────────────────────────────────────────────────────

check_root() {
    [[ $EUID -eq 0 ]] || die "Run as root (try: sudo bash $0)"
}

detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *) die "Unsupported architecture: $m (supported: x86_64, aarch64)" ;;
    esac
}

detect_os() {
    [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; this script supports Debian/Ubuntu only."
    # Source os-release in subshells so its variables (ID, NAME, VERSION, ...)
    # do not leak into this script's namespace.
    local os_id os_pretty
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}" || true)"
    # shellcheck disable=SC1091
    os_pretty="$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" || true)"
    case "$os_id" in
        debian|ubuntu) ok "Detected ${os_pretty:-$os_id}" ;;
        *) die "Unsupported OS: ${os_id:-unknown} (supported: debian, ubuntu)" ;;
    esac
}

has_caddy_unit() {
    # systemd < 246 exits 0 from `list-unit-files <pattern>` even when nothing
    # matches, so check the output instead of the exit code.
    [[ -f "$SYSTEMD_UNIT" ]] && return 0
    [[ "$(systemctl list-unit-files caddy.service 2>/dev/null)" == *"caddy.service"* ]]
}

get_external_ip() {
    # Try multiple endpoints; first one wins. Force IPv4 so a v6-preferring
    # host does not return an address the A-record check cannot use.
    local ip url
    for url in https://api.ipify.org https://ifconfig.me https://ipinfo.io/ip; do
        ip="$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

get_external_ipv6() {
    local ip url
    for url in https://api6.ipify.org https://ifconfig.me; do
        ip="$(curl -6 -fsS --max-time 5 "$url" 2>/dev/null || true)"
        if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

resolve_records() {
    # resolve_records A|AAAA <domain> — prints matching records, one per line.
    # Falls back from 1.1.1.1 to the system resolver; prints nothing on failure
    # instead of letting a dig error abort the script.
    local rrtype="$1" domain="$2" out filter
    case "$rrtype" in
        A)    filter='^[0-9.]+$' ;;
        AAAA) filter='^[0-9a-fA-F:]+$' ;;
        *)    return 1 ;;
    esac
    out="$(dig +short "$rrtype" "$domain" @1.1.1.1 2>/dev/null)" || out=""
    if [[ -z "$out" ]]; then
        out="$(dig +short "$rrtype" "$domain" 2>/dev/null)" || out=""
    fi
    printf '%s\n' "$out" | grep -E "$filter" || true
}

check_dns() {
    local domain="$1" external_ip resolved_ips resolved_v6
    log "Checking DNS for $domain..."
    require_cmd dig

    if ! external_ip="$(get_external_ip)"; then
        warn "Could not detect this server's external IP — skipping DNS check."
        return 0
    fi
    log "Server external IP: $external_ip"

    resolved_ips="$(resolve_records A "$domain")"
    if [[ -z "$resolved_ips" ]]; then
        warn "Domain $domain has no A-record (or DNS not yet propagated / resolver unreachable)."
        confirm "Continue anyway (ACME will fail until DNS resolves)" default-no \
            || die "Aborted by user. Configure DNS A-record first."
        return 0
    fi

    # Match against the full A-record set: round-robin / multi-A setups must include this server's IP.
    if printf '%s\n' "$resolved_ips" | grep -Fxq "$external_ip"; then
        ok "DNS check passed: $domain → $external_ip"
    else
        warn "DNS mismatch: $domain resolves to [$(printf '%s' "$resolved_ips" | tr '\n' ' ')], server IP is $external_ip"
        warn "Possible causes: A-record not updated yet; Cloudflare orange-cloud (must be grey)."
        confirm "Continue anyway" default-no \
            || die "Aborted by user. Fix DNS A-record first."
    fi

    # A stray AAAA record can break ACME even when the A record is correct,
    # because Let's Encrypt prefers IPv6 when both exist. Warn-only: v6
    # detection from this host is best-effort.
    resolved_v6="$(resolve_records AAAA "$domain")"
    if [[ -n "$resolved_v6" ]]; then
        local external_ip6=""
        external_ip6="$(get_external_ipv6 || true)"
        if [[ -n "$external_ip6" ]] && printf '%s\n' "${resolved_v6,,}" | grep -Fxq "${external_ip6,,}"; then
            ok "AAAA check passed: $domain → $external_ip6"
        else
            warn "Domain $domain has AAAA record(s) [$(printf '%s' "$resolved_v6" | tr '\n' ' ')] that could not be confirmed to point at this server."
            warn "If IPv6 is misconfigured, ACME validation (which may prefer IPv6) can fail; remove the AAAA record if in doubt."
        fi
    fi
}

check_firewall() {
    # Warn-only: a host firewall blocking 80/NAIVE_PORT turns into confusing
    # ACME timeouts later, so surface it before any changes are made.
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n1 | grep -q 'Status: active'; then
        warn "ufw is active. Make sure TCP ports 80 and ${NAIVE_PORT} are allowed, e.g.:"
        warn "  ufw allow 80/tcp && ufw allow ${NAIVE_PORT}/tcp"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        warn "firewalld is running. Make sure TCP ports 80 and ${NAIVE_PORT} are open."
    fi
    return 0
}

check_ports() {
    local port busy_pid busy_proc ports=(80 "$NAIVE_PORT")
    require_cmd ss
    for port in "${ports[@]}"; do
        busy_pid="$(ss -tlnpH "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
        if [[ -n "$busy_pid" ]]; then
            busy_proc="$(ps -p "$busy_pid" -o comm= 2>/dev/null || echo unknown)"
            warn "Port :$port is occupied by PID $busy_pid ($busy_proc)"
            if [[ "$busy_proc" == "caddy" ]]; then
                log "It's a previous Caddy process — will be replaced by systemd unit."
                continue
            fi
            die "Port :$port is busy. Stop $busy_proc (PID $busy_pid) manually and retry."
        fi
    done

    # Caddy also binds UDP :NAIVE_PORT for HTTP/3 (QUIC); a conflict there is
    # not fatal (TCP still serves), so warn instead of dying.
    local udp_pid udp_proc
    udp_pid="$(ss -ulnpH "sport = :${NAIVE_PORT}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
    if [[ -n "$udp_pid" ]]; then
        udp_proc="$(ps -p "$udp_pid" -o comm= 2>/dev/null || echo unknown)"
        if [[ "$udp_proc" != "caddy" ]]; then
            warn "UDP :${NAIVE_PORT} is in use by ${udp_proc} (PID ${udp_pid}); HTTP/3 (QUIC) may be unavailable."
        fi
    fi
    ok "Ports 80 and ${NAIVE_PORT} are available"
}

reset_managed_state() {
    STATE_LOADED=0
    NAIVECD_MANAGED=0
    MANAGED_CADDY_DIR_CREATED=0
    MANAGED_CADDY_BIN=0
    MANAGED_SYSTEMD_UNIT=0
    MANAGED_CADDYFILE=0
    MANAGED_CRED_FILE=0
    MANAGED_CLIENT_CONFIG=0
    MANAGED_SINGBOX_CONFIG=0
    MANAGED_STATIC_ROOT_CREATED=0
    MANAGED_STATIC_INDEX=0
    MANAGED_GO=0
    MANAGED_CADDY_USER_CREATED=0
    MANAGED_CADDY_GROUP_CREATED=0
    STATE_STATIC_ROOT=""
    STATE_STATIC_INDEX_SHA256=""
    ORIGIN_CADDY_BIN=""
    ORIGIN_SYSTEMD_UNIT=""
    ORIGIN_CADDYFILE=""
    ORIGIN_CRED_FILE=""
    ORIGIN_CLIENT_CONFIG=""
    ORIGIN_SINGBOX_CONFIG=""
    ORIGINAL_CADDY_BIN_BACKUP=""
    ORIGINAL_SYSTEMD_UNIT_BACKUP=""
    ORIGINAL_CADDYFILE_BACKUP=""
    ORIGINAL_CRED_FILE_BACKUP=""
    ORIGINAL_CLIENT_CONFIG_BACKUP=""
    ORIGINAL_SINGBOX_CONFIG_BACKUP=""
    STATE_CADDY_DIR_METADATA=""
    STATE_CADDY_STATE_DIR_METADATA=""
    STATE_STATIC_ROOT_METADATA=""
    STATE_STATIC_INDEX_METADATA=""
    ORIGINAL_SERVICE_STATE_CAPTURED=0
    ORIGINAL_SERVICE_ACTIVE=0
    ORIGINAL_SERVICE_ENABLED=0
}

load_managed_state() {
    reset_managed_state
    [[ -r "$STATE_FILE" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        [[ -n "$key" && "$key" != \#* ]] || continue
        case "$key" in
            NAIVECD_MANAGED|MANAGED_CADDY_DIR_CREATED|MANAGED_CADDY_BIN|MANAGED_SYSTEMD_UNIT|\
            MANAGED_CADDYFILE|MANAGED_CRED_FILE|MANAGED_CLIENT_CONFIG|MANAGED_SINGBOX_CONFIG|\
            MANAGED_STATIC_ROOT_CREATED|MANAGED_STATIC_INDEX|MANAGED_GO|\
            MANAGED_CADDY_USER_CREATED|MANAGED_CADDY_GROUP_CREATED|STATE_STATIC_ROOT|\
            STATE_STATIC_INDEX_SHA256|ORIGIN_CADDY_BIN|ORIGIN_SYSTEMD_UNIT|ORIGIN_CADDYFILE|\
            ORIGIN_CRED_FILE|ORIGIN_CLIENT_CONFIG|ORIGIN_SINGBOX_CONFIG|\
            ORIGINAL_CADDY_BIN_BACKUP|ORIGINAL_SYSTEMD_UNIT_BACKUP|ORIGINAL_CADDYFILE_BACKUP|\
            ORIGINAL_CRED_FILE_BACKUP|ORIGINAL_CLIENT_CONFIG_BACKUP|ORIGINAL_SINGBOX_CONFIG_BACKUP|\
            STATE_CADDY_DIR_METADATA|STATE_CADDY_STATE_DIR_METADATA|STATE_STATIC_ROOT_METADATA|STATE_STATIC_INDEX_METADATA|\
            ORIGINAL_SERVICE_STATE_CAPTURED|ORIGINAL_SERVICE_ACTIVE|ORIGINAL_SERVICE_ENABLED)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$STATE_FILE"

    if [[ "$NAIVECD_MANAGED" == "1" ]]; then
        STATE_LOADED=1
        # 兼容旧状态文件：旧版本只记录“由 naivecd 管理”，无法恢复安装前原件。
        if [[ -z "$ORIGIN_CADDY_BIN" && "$MANAGED_CADDY_BIN" == "1" ]]; then ORIGIN_CADDY_BIN="created"; fi
        if [[ -z "$ORIGIN_SYSTEMD_UNIT" && "$MANAGED_SYSTEMD_UNIT" == "1" ]]; then ORIGIN_SYSTEMD_UNIT="created"; fi
        if [[ -z "$ORIGIN_CADDYFILE" && "$MANAGED_CADDYFILE" == "1" ]]; then ORIGIN_CADDYFILE="created"; fi
        if [[ -z "$ORIGIN_CRED_FILE" && "$MANAGED_CRED_FILE" == "1" ]]; then ORIGIN_CRED_FILE="created"; fi
        if [[ -z "$ORIGIN_CLIENT_CONFIG" && "$MANAGED_CLIENT_CONFIG" == "1" ]]; then ORIGIN_CLIENT_CONFIG="created"; fi
        if [[ -z "$ORIGIN_SINGBOX_CONFIG" && "$MANAGED_SINGBOX_CONFIG" == "1" ]]; then ORIGIN_SINGBOX_CONFIG="created"; fi
    fi
}

write_managed_state() {
    mkdir -p "$CADDY_DIR"
    local tmp="${STATE_FILE}.tmp"
    {
        printf '# Managed by naivecd. This file records resources created by the installer.\n'
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'NAIVECD_MANAGED=1\n'
        printf 'MANAGED_CADDY_DIR_CREATED=%s\n' "$MANAGED_CADDY_DIR_CREATED"
        printf 'MANAGED_CADDY_BIN=%s\n' "$MANAGED_CADDY_BIN"
        printf 'MANAGED_SYSTEMD_UNIT=%s\n' "$MANAGED_SYSTEMD_UNIT"
        printf 'MANAGED_CADDYFILE=%s\n' "$MANAGED_CADDYFILE"
        printf 'MANAGED_CRED_FILE=%s\n' "$MANAGED_CRED_FILE"
        printf 'MANAGED_CLIENT_CONFIG=%s\n' "$MANAGED_CLIENT_CONFIG"
        printf 'MANAGED_SINGBOX_CONFIG=%s\n' "$MANAGED_SINGBOX_CONFIG"
        printf 'MANAGED_STATIC_ROOT_CREATED=%s\n' "$MANAGED_STATIC_ROOT_CREATED"
        printf 'MANAGED_STATIC_INDEX=%s\n' "$MANAGED_STATIC_INDEX"
        printf 'MANAGED_GO=%s\n' "$MANAGED_GO"
        printf 'MANAGED_CADDY_USER_CREATED=%s\n' "$MANAGED_CADDY_USER_CREATED"
        printf 'MANAGED_CADDY_GROUP_CREATED=%s\n' "$MANAGED_CADDY_GROUP_CREATED"
        printf 'STATE_STATIC_ROOT=%s\n' "${STATE_STATIC_ROOT:-}"
        printf 'STATE_STATIC_INDEX_SHA256=%s\n' "${STATE_STATIC_INDEX_SHA256:-}"
        printf 'ORIGIN_CADDY_BIN=%s\n' "$ORIGIN_CADDY_BIN"
        printf 'ORIGIN_SYSTEMD_UNIT=%s\n' "$ORIGIN_SYSTEMD_UNIT"
        printf 'ORIGIN_CADDYFILE=%s\n' "$ORIGIN_CADDYFILE"
        printf 'ORIGIN_CRED_FILE=%s\n' "$ORIGIN_CRED_FILE"
        printf 'ORIGIN_CLIENT_CONFIG=%s\n' "$ORIGIN_CLIENT_CONFIG"
        printf 'ORIGIN_SINGBOX_CONFIG=%s\n' "$ORIGIN_SINGBOX_CONFIG"
        printf 'ORIGINAL_CADDY_BIN_BACKUP=%s\n' "$ORIGINAL_CADDY_BIN_BACKUP"
        printf 'ORIGINAL_SYSTEMD_UNIT_BACKUP=%s\n' "$ORIGINAL_SYSTEMD_UNIT_BACKUP"
        printf 'ORIGINAL_CADDYFILE_BACKUP=%s\n' "$ORIGINAL_CADDYFILE_BACKUP"
        printf 'ORIGINAL_CRED_FILE_BACKUP=%s\n' "$ORIGINAL_CRED_FILE_BACKUP"
        printf 'ORIGINAL_CLIENT_CONFIG_BACKUP=%s\n' "$ORIGINAL_CLIENT_CONFIG_BACKUP"
        printf 'ORIGINAL_SINGBOX_CONFIG_BACKUP=%s\n' "$ORIGINAL_SINGBOX_CONFIG_BACKUP"
        printf 'STATE_CADDY_DIR_METADATA=%s\n' "$STATE_CADDY_DIR_METADATA"
        printf 'STATE_CADDY_STATE_DIR_METADATA=%s\n' "$STATE_CADDY_STATE_DIR_METADATA"
        printf 'STATE_STATIC_ROOT_METADATA=%s\n' "$STATE_STATIC_ROOT_METADATA"
        printf 'STATE_STATIC_INDEX_METADATA=%s\n' "$STATE_STATIC_INDEX_METADATA"
        printf 'ORIGINAL_SERVICE_STATE_CAPTURED=%s\n' "$ORIGINAL_SERVICE_STATE_CAPTURED"
        printf 'ORIGINAL_SERVICE_ACTIVE=%s\n' "$ORIGINAL_SERVICE_ACTIVE"
        printf 'ORIGINAL_SERVICE_ENABLED=%s\n' "$ORIGINAL_SERVICE_ENABLED"
    } > "$tmp"
    chown root:root "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

file_sha256() {
    sha256sum "$1" | awk '{print $1}'
}

verify_sha256() {
    local file="$1" expected="$2" label="${3:-$1}"
    require_cmd sha256sum
    [[ -f "$file" ]] || die "Cannot verify SHA256; file not found: ${file}"

    if printf '%s  %s\n' "$expected" "$file" | sha256sum -c --strict --status -; then
        ok "Verified SHA256 for ${label}"
        return 0
    fi

    err "SHA256 verification failed for ${label}"
    return 1
}

ensure_backup_dir() {
    if [[ -z "$BACKUP_SESSION_DIR" ]]; then
        BACKUP_SESSION_DIR="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)"
        mkdir -p "$BACKUP_SESSION_DIR"
        chmod 0700 "$BACKUP_ROOT" "$BACKUP_SESSION_DIR"
    fi
}

backup_path() {
    local path="$1" reason="${2:-backup}" rel dest
    [[ -e "$path" || -L "$path" ]] || return 0

    ensure_backup_dir
    rel="${path#/}"
    dest="${BACKUP_SESSION_DIR}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    if [[ "$BACKUP_QUIET" != "1" ]]; then
        ok "Backed up ${path} (${reason}) to ${dest}"
    fi
}

prune_backup_sessions() {
    # Each (re)install session copies the ~40MB Caddy binary into a new
    # timestamped directory; without pruning, /root/naivecd-backups grows
    # unbounded. Keep the newest sessions plus any session that still holds
    # "originals" referenced by the managed state (needed for uninstall).
    local keep=5
    [[ -d "$BACKUP_ROOT" ]] || return 0
    local -a sessions=()
    local name
    while IFS= read -r name; do
        sessions+=("$name")
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
    (( ${#sessions[@]} > keep )) || return 0
    local -a referenced=(
        "$ORIGINAL_CADDY_BIN_BACKUP" "$ORIGINAL_SYSTEMD_UNIT_BACKUP"
        "$ORIGINAL_CADDYFILE_BACKUP" "$ORIGINAL_CRED_FILE_BACKUP"
        "$ORIGINAL_CLIENT_CONFIG_BACKUP" "$ORIGINAL_SINGBOX_CONFIG_BACKUP"
    )
    local i dir ref skip pruned=0
    for ((i=keep; i<${#sessions[@]}; i++)); do
        dir="${BACKUP_ROOT}/${sessions[$i]}"
        [[ -n "$BACKUP_SESSION_DIR" && "$dir" == "$BACKUP_SESSION_DIR" ]] && continue
        skip=0
        for ref in "${referenced[@]}"; do
            if [[ -n "$ref" && "$ref" == "$dir"/* ]]; then
                skip=1
                break
            fi
        done
        (( skip == 1 )) && continue
        rm -rf -- "$dir"
        ((++pruned))
    done
    if (( pruned > 0 )); then
        log "Pruned ${pruned} old backup session(s) under ${BACKUP_ROOT} (kept newest ${keep} plus referenced originals)."
    fi
    return 0
}

path_metadata() {
    stat -c '%u:%g:%a' -- "$1"
}

restore_metadata() {
    local path="$1" metadata="$2" uid gid mode
    [[ -n "$metadata" && -e "$path" ]] || return 0
    IFS=: read -r uid gid mode <<< "$metadata"
    chown "$uid:$gid" -- "$path"
    chmod "$mode" -- "$path"
}

record_resource_origin() {
    local origin_var="$1" backup_var="$2" path="$3" origin rel original_dest
    origin="${!origin_var:-}"
    [[ -z "$origin" ]] || return 0
    if [[ -e "$path" || -L "$path" ]]; then
        ensure_backup_dir
        rel="${path#/}"
        original_dest="${BACKUP_SESSION_DIR}/originals/${rel}"
        mkdir -p "$(dirname "$original_dest")"
        cp -a -- "$path" "$original_dest"
        ok "Saved original resource before naivecd ownership: ${original_dest}"
        printf -v "$origin_var" '%s' "replaced"
        printf -v "$backup_var" '%s' "$original_dest"
    else
        printf -v "$origin_var" '%s' "created"
    fi
}

snapshot_transaction_path() {
    local path="$1" rel
    TRANSACTION_PATHS+=("$path")
    if [[ -e "$path" || -L "$path" ]]; then
        TRANSACTION_PATH_EXISTED+=(1)
        rel="${path#/}"
        mkdir -p "${TRANSACTION_DIR}/files/$(dirname "$rel")"
        cp -a -- "$path" "${TRANSACTION_DIR}/files/${rel}"
    else
        TRANSACTION_PATH_EXISTED+=(0)
    fi
}

snapshot_transaction_metadata() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    TRANSACTION_METADATA_PATHS+=("$path")
    TRANSACTION_METADATA_VALUES+=("$(path_metadata "$path")")
}

begin_transaction() {
    (( TRANSACTION_ACTIVE == 0 )) || return 0
    ensure_backup_dir
    TRANSACTION_DIR="${BACKUP_SESSION_DIR}/transaction"
    mkdir -p "$TRANSACTION_DIR/files"
    chmod 0700 "$TRANSACTION_DIR"
    systemctl is-active --quiet caddy 2>/dev/null && TRANSACTION_SERVICE_ACTIVE=1 || true
    systemctl is-enabled --quiet caddy 2>/dev/null && TRANSACTION_SERVICE_ENABLED=1 || true
    if [[ "$ORIGINAL_SERVICE_STATE_CAPTURED" != "1" ]]; then
        ORIGINAL_SERVICE_STATE_CAPTURED=1
        ORIGINAL_SERVICE_ACTIVE="$TRANSACTION_SERVICE_ACTIVE"
        ORIGINAL_SERVICE_ENABLED="$TRANSACTION_SERVICE_ENABLED"
    fi
    [[ -d "$CADDY_DIR" ]] && TRANSACTION_CADDY_DIR_EXISTED=1
    [[ -d "$CADDY_STATE_DIR" ]] && TRANSACTION_CADDY_STATE_DIR_EXISTED=1
    [[ -n "${STATIC_ROOT:-}" && -d "$STATIC_ROOT" ]] && TRANSACTION_STATIC_ROOT_EXISTED=1
    local path static_index=""
    [[ -n "${STATIC_ROOT:-}" ]] && static_index="${STATIC_ROOT}/index.html"
    for path in "$CADDY_BIN" "$SYSTEMD_UNIT" "$CADDYFILE" "$CRED_FILE" \
        "$CLIENT_CONFIG" "$SINGBOX_CONFIG" "$STATE_FILE"; do
        snapshot_transaction_path "$path"
    done
    [[ -n "$static_index" ]] && snapshot_transaction_path "$static_index"
    snapshot_transaction_metadata "$CADDY_DIR"
    snapshot_transaction_metadata "$CADDY_STATE_DIR"
    [[ -n "${STATIC_ROOT:-}" ]] && snapshot_transaction_metadata "$STATIC_ROOT"
    if [[ -n "$STATE_STATIC_ROOT" && "$STATE_STATIC_ROOT" != "${STATIC_ROOT:-}" ]]; then
        snapshot_transaction_metadata "$STATE_STATIC_ROOT"
        snapshot_transaction_metadata "${STATE_STATIC_ROOT}/index.html"
    fi
    TRANSACTION_ACTIVE=1
    log "Installation transaction started; failures will restore the previous state."
}

restore_owned_resource() {
    local path="$1" origin="$2" original_backup="$3" label="$4"
    case "$origin" in
        created)
            remove_managed_file "$path"
            ;;
        replaced)
            if [[ -e "$original_backup" || -L "$original_backup" ]]; then
                backup_path "$path" "before restoring original ${label}"
                rm -rf -- "$path"
                mkdir -p "$(dirname "$path")"
                cp -a -- "$original_backup" "$path"
                ok "Restored original ${label}: ${path}"
            else
                warn "Cannot restore original ${label}; backup is missing: ${original_backup}"
            fi
            ;;
        *)
            remove_managed_file "$path"
            ;;
    esac
}

rollback_transaction() {
    (( TRANSACTION_ACTIVE == 1 && TRANSACTION_COMMITTED == 0 )) || return 0
    set +e
    warn "Restoring files and service state from the transaction snapshot..."
    systemctl stop caddy >/dev/null 2>&1 || true
    local i path rel
    for ((i=${#TRANSACTION_PATHS[@]}-1; i>=0; i--)); do
        path="${TRANSACTION_PATHS[$i]}"
        if [[ "${TRANSACTION_PATH_EXISTED[$i]}" == "1" ]]; then
            rel="${path#/}"
            rm -rf -- "$path"
            mkdir -p "$(dirname "$path")"
            cp -a -- "${TRANSACTION_DIR}/files/${rel}" "$path"
        else
            rm -rf -- "$path"
        fi
    done
    for ((i=0; i<${#TRANSACTION_METADATA_PATHS[@]}; i++)); do
        restore_metadata "${TRANSACTION_METADATA_PATHS[$i]}" "${TRANSACTION_METADATA_VALUES[$i]}"
    done
    (( TRANSACTION_STATIC_ROOT_EXISTED == 0 )) && [[ -n "${STATIC_ROOT:-}" ]] && rmdir "$STATIC_ROOT" 2>/dev/null || true
    (( TRANSACTION_CADDY_DIR_EXISTED == 0 )) && rmdir "$CADDY_DIR" 2>/dev/null || true
    (( TRANSACTION_CADDY_STATE_DIR_EXISTED == 0 )) && rm -rf -- "$CADDY_STATE_DIR"
    (( TRANSACTION_INSTALLED_GO == 1 )) && rm -rf -- "$GO_INSTALL_DIR"
    (( TRANSACTION_CREATED_CADDY_USER == 1 )) && userdel "$CADDY_USER" >/dev/null 2>&1 || true
    (( TRANSACTION_CREATED_CADDY_GROUP == 1 )) && groupdel "$CADDY_GROUP" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    if (( TRANSACTION_SERVICE_ENABLED == 1 )); then
        systemctl enable caddy >/dev/null 2>&1 || true
    else
        systemctl disable caddy >/dev/null 2>&1 || true
    fi
    (( TRANSACTION_SERVICE_ACTIVE == 1 )) && systemctl start caddy >/dev/null 2>&1 || true
    TRANSACTION_ACTIVE=0
    warn "Rollback complete. Snapshot retained at ${TRANSACTION_DIR}."
    set -e
}

commit_transaction() {
    TRANSACTION_COMMITTED=1
    TRANSACTION_ACTIVE=0
    rm -rf -- "$TRANSACTION_DIR"
    ok "Installation transaction committed."
}

file_has_naivecd_marker() {
    local path="$1"
    [[ -r "$path" ]] && grep -Fq "Managed by naivecd" "$path"
}

remove_managed_file() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    backup_path "$path" "before uninstall"
    rm -f -- "$path"
    ok "Removed ${path}"
}

uninstall_caddy_naive() {
    load_managed_state

    local unit_managed=0 caddyfile_managed=0 cred_managed=0 static_root_to_review=""
    # State alone is not enough for text files that users may have replaced after
    # installation. Require the current file to still carry the naivecd marker
    # before stopping/removing it; otherwise preserve it as user-managed data.
    file_has_naivecd_marker "$SYSTEMD_UNIT" && unit_managed=1
    file_has_naivecd_marker "$CADDYFILE" && caddyfile_managed=1
    file_has_naivecd_marker "$CRED_FILE" && cred_managed=1

    static_root_to_review="${STATE_STATIC_ROOT:-}"
    if [[ -z "$static_root_to_review" && "$caddyfile_managed" == "1" && -s "$CADDYFILE" ]]; then
        static_root_to_review="$(awk '/^[[:space:]]*root[[:space:]]+\*[[:space:]]/ {print $3; exit}' "$CADDYFILE")"
    fi

    echo >&2
    warn "Uninstall uses naivecd managed-state markers and preserves unmarked assets." >&2
    if [[ "$STATE_LOADED" != "1" ]]; then
        warn "No managed-state file was found; only files with a naivecd marker can be removed safely." >&2
    fi
    echo >&2

    local any=0
    warn "Remove:" >&2
    if [[ "$unit_managed" == "1" && -e "$SYSTEMD_UNIT" ]]; then
        printf '  %-10s %s\n' "service" "$SYSTEMD_UNIT" >&2
        any=1
    fi
    if [[ "$MANAGED_CADDY_BIN" == "1" && -e "$CADDY_BIN" ]]; then
        printf '  %-10s %s\n' "binary" "$CADDY_BIN" >&2
        any=1
    fi
    if [[ "$caddyfile_managed" == "1" && -e "$CADDYFILE" ]]; then
        printf '  %-10s %s\n' "config" "$CADDYFILE" >&2
        any=1
    fi
    if [[ "$cred_managed" == "1" && -e "$CRED_FILE" ]]; then
        printf '  %-10s %s\n' "config" "$CRED_FILE" >&2
        any=1
    fi
    if [[ -e "$STATE_FILE" ]]; then
        printf '  %-10s %s\n' "state" "$STATE_FILE" >&2
        any=1
    fi
    if [[ "$MANAGED_CLIENT_CONFIG" == "1" && -e "$CLIENT_CONFIG" ]]; then
        printf '  %-10s %s\n' "client" "$CLIENT_CONFIG" >&2
        any=1
    fi
    if [[ "$MANAGED_SINGBOX_CONFIG" == "1" && -e "$SINGBOX_CONFIG" ]]; then
        printf '  %-10s %s\n' "client" "$SINGBOX_CONFIG" >&2
        any=1
    fi
    if [[ "$MANAGED_STATIC_INDEX" == "1" && -n "$static_root_to_review" ]]; then
        printf '  %-10s %s    %s\n' "static" "${static_root_to_review}/index.html" "if unchanged" >&2
        any=1
    fi
    if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" && -n "$static_root_to_review" ]]; then
        printf '  %-10s %s\n' "empty-dir" "$static_root_to_review" >&2
        any=1
    fi
    if [[ "$MANAGED_CADDY_DIR_CREATED" == "1" ]]; then
        printf '  %-10s %s\n' "empty-dir" "$CADDY_DIR" >&2
        any=1
    fi
    if [[ "$MANAGED_CADDY_USER_CREATED" == "1" ]] && id -u "$CADDY_USER" >/dev/null 2>&1; then
        printf '  %-10s %s\n' "user" "$CADDY_USER" >&2
        any=1
    fi
    if [[ "$MANAGED_CADDY_GROUP_CREATED" == "1" ]] && getent group "$CADDY_GROUP" >/dev/null 2>&1; then
        printf '  %-10s %s\n' "group" "$CADDY_GROUP" >&2
        any=1
    fi

    echo >&2
    warn "Keep:" >&2
    printf '  %-10s %s\n' "data" "$CADDY_STATE_DIR" >&2
    printf '  %-10s %s\n' "custom" "unmarked Caddy/static files" >&2
    printf '  %-10s %s\n' "system" "Go toolchains, DNS records, firewall rules" >&2
    if (( any == 0 )); then
        echo >&2
        warn "No managed resources were found to remove." >&2
        return 0
    fi

    echo >&2
    confirm "Continue uninstall" default-no || die "Aborted by user."

    BACKUP_QUIET=1
    ensure_backup_dir
    log "Backup directory: ${BACKUP_SESSION_DIR}"

    if [[ "$unit_managed" == "1" ]] && has_caddy_unit; then
        log "Stopping and disabling caddy.service..."
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy >/dev/null 2>&1 || true
    elif has_caddy_unit; then
        warn "Preserving caddy.service because it is not marked as managed by naivecd."
    fi

    log "Removing managed resources..."
    [[ "$unit_managed" == "1" ]] && restore_owned_resource "$SYSTEMD_UNIT" "$ORIGIN_SYSTEMD_UNIT" "$ORIGINAL_SYSTEMD_UNIT_BACKUP" "systemd unit"
    if [[ "$MANAGED_CADDY_BIN" == "1" ]]; then
        systemctl stop caddy 2>/dev/null || true
        restore_owned_resource "$CADDY_BIN" "$ORIGIN_CADDY_BIN" "$ORIGINAL_CADDY_BIN_BACKUP" "Caddy binary"
    fi
    [[ "$caddyfile_managed" == "1" ]] && restore_owned_resource "$CADDYFILE" "$ORIGIN_CADDYFILE" "$ORIGINAL_CADDYFILE_BACKUP" "Caddyfile"
    [[ "$cred_managed" == "1" ]] && restore_owned_resource "$CRED_FILE" "$ORIGIN_CRED_FILE" "$ORIGINAL_CRED_FILE_BACKUP" "credentials file"
    [[ "$MANAGED_CLIENT_CONFIG" == "1" ]] && restore_owned_resource "$CLIENT_CONFIG" "$ORIGIN_CLIENT_CONFIG" "$ORIGINAL_CLIENT_CONFIG_BACKUP" "Naive client config"
    [[ "$MANAGED_SINGBOX_CONFIG" == "1" ]] && restore_owned_resource "$SINGBOX_CONFIG" "$ORIGIN_SINGBOX_CONFIG" "$ORIGINAL_SINGBOX_CONFIG_BACKUP" "sing-box config"

    if [[ "$MANAGED_STATIC_INDEX" == "1" && -n "$static_root_to_review" ]]; then
        local static_index="${static_root_to_review}/index.html"
        if [[ -f "$static_index" ]]; then
            if [[ -n "$STATE_STATIC_INDEX_SHA256" && "$(file_sha256 "$static_index")" == "$STATE_STATIC_INDEX_SHA256" ]]; then
                remove_managed_file "$static_index"
            else
                warn "Preserving ${static_index}; it has been modified or lacks a managed checksum."
            fi
        fi
    fi

    if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" && -n "$static_root_to_review" && -d "$static_root_to_review" ]]; then
        if rmdir "$static_root_to_review" 2>/dev/null; then
            ok "Removed empty managed static root ${static_root_to_review}"
        else
            warn "Preserving ${static_root_to_review}; it is not empty."
        fi
    fi

    if [[ "$MANAGED_STATIC_ROOT_CREATED" != "1" && -n "$static_root_to_review" ]]; then
        restore_metadata "$static_root_to_review" "$STATE_STATIC_ROOT_METADATA"
        if [[ "$MANAGED_STATIC_INDEX" != "1" ]]; then
            restore_metadata "${static_root_to_review}/index.html" "$STATE_STATIC_INDEX_METADATA"
        fi
    fi

    if [[ "$MANAGED_CADDY_DIR_CREATED" != "1" ]]; then
        restore_metadata "$CADDY_DIR" "$STATE_CADDY_DIR_METADATA"
    fi
    restore_metadata "$CADDY_STATE_DIR" "$STATE_CADDY_STATE_DIR_METADATA"

    remove_managed_file "$STATE_FILE"

    if [[ "$MANAGED_CADDY_DIR_CREATED" == "1" && -d "$CADDY_DIR" ]]; then
        if rmdir "$CADDY_DIR" 2>/dev/null; then
            ok "Removed empty managed Caddy config directory ${CADDY_DIR}"
        else
            warn "Preserving ${CADDY_DIR}; it is not empty."
        fi
    fi

    if [[ "$unit_managed" == "1" ]]; then
        systemctl daemon-reload
        systemctl reset-failed caddy.service >/dev/null 2>&1 || true
        if [[ "$ORIGINAL_SERVICE_ENABLED" == "1" && "$ORIGIN_SYSTEMD_UNIT" == "replaced" ]]; then
            systemctl enable caddy >/dev/null 2>&1 || warn "Could not re-enable the original caddy.service."
        fi
        if [[ "$ORIGINAL_SERVICE_ACTIVE" == "1" && "$ORIGIN_SYSTEMD_UNIT" == "replaced" ]]; then
            systemctl start caddy >/dev/null 2>&1 || warn "Could not restart the original caddy.service."
        fi
    fi

    # Remove the runtime account only when this installer created it; the
    # user goes first so the group is no longer its primary group.
    if [[ "$MANAGED_CADDY_USER_CREATED" == "1" ]] && id -u "$CADDY_USER" >/dev/null 2>&1; then
        if userdel "$CADDY_USER" >/dev/null 2>&1; then
            ok "Removed system user ${CADDY_USER}"
        else
            warn "Could not remove system user ${CADDY_USER} (still in use?); remove it manually if desired."
        fi
    fi
    if [[ "$MANAGED_CADDY_GROUP_CREATED" == "1" ]] && getent group "$CADDY_GROUP" >/dev/null 2>&1; then
        if groupdel "$CADDY_GROUP" >/dev/null 2>&1; then
            ok "Removed system group ${CADDY_GROUP}"
        else
            warn "Could not remove system group ${CADDY_GROUP} (still in use?); remove it manually if desired."
        fi
    fi

    if [[ "$MANAGED_GO" == "1" && -d "${GO_INSTALL_DIR}" ]]; then
        warn "Preserving managed Go toolchain at ${GO_INSTALL_DIR}; remove it manually if it is no longer needed."
    fi

    ok "Uninstall complete."
    log "Backup saved to: ${BACKUP_SESSION_DIR}"
}

handle_existing_caddy() {
    # Interactive menu for an existing installation. Sets the global MODE to
    # one of: rebuild | reconfigure | show | uninstall (or exits).
    local service_status="not installed"
    if has_caddy_unit; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            service_status="active"
        else
            service_status="inactive"
        fi
    fi

    if [[ -x "$CADDY_BIN" ]]; then
        warn "Existing Caddy installation detected (service: ${service_status})." >&2
    else
        warn "Existing caddy.service detected (service: ${service_status})." >&2
    fi

    local has_saved_config=0
    [[ -s "$CRED_FILE" || -s "$CLIENT_CONFIG" || -s "$SINGBOX_CONFIG" ]] && has_saved_config=1

    echo "" >&2
    echo "Choose action:" >&2
    echo "  1) Reinstall NaiveProxy" >&2
    echo "  2) Reconfigure (keeps existing credentials)" >&2
    if [[ "$has_saved_config" -eq 1 ]]; then
        echo "  3) Show client config" >&2
        echo "  4) Uninstall" >&2
        echo "  5) Exit" >&2
    else
        echo "  3) Uninstall" >&2
        echo "  4) Exit" >&2
        echo "     (Show client config is unavailable: no saved config files were found)" >&2
    fi
    echo "" >&2

    local choice prompt
    if [[ "$has_saved_config" -eq 1 ]]; then
        prompt="Enter choice [1-5]: "
    else
        prompt="Enter choice [1-4]: "
    fi

    while true; do
        read -r -p "$prompt" choice </dev/tty \
            || die "No input available; run the installer in an interactive terminal."
        case "$choice" in
            1) MODE="rebuild";     return 0 ;;
            2) MODE="reconfigure"; return 0 ;;
            3)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    MODE="show"
                else
                    MODE="uninstall"
                fi
                return 0
                ;;
            4)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    MODE="uninstall"
                    return 0
                else
                    log "Exited by user choice."
                    exit 0
                fi
                ;;
            5)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    log "Exited by user choice."
                    exit 0
                else
                    echo "Invalid choice." >&2
                fi
                ;;
            *) echo "Invalid choice." >&2 ;;
        esac
    done
}

#─────────────────────────────────────────────────────────────────────────────
# Inputs
#─────────────────────────────────────────────────────────────────────────────

normalize_cover_mode() {
    local mode="${1,,}"
    case "$mode" in
        1|static|local) echo "static" ;;
        2|proxy|reverse-proxy|reverse_proxy) echo "proxy" ;;
        *) return 1 ;;
    esac
}

choose_cover_mode() {
    local choice mode
    echo "Choose cover mode:" >&2
    echo "  1) Local static site (served from ${DEFAULT_STATIC_ROOT})" >&2
    echo "  2) Reverse proxy a cover site" >&2
    while true; do
        read -r -p "Enter 1 or 2 [1]: " choice </dev/tty || return 1
        choice="${choice:-1}"
        if mode="$(normalize_cover_mode "$choice")"; then
            printf '%s' "$mode"
            return 0
        fi
        echo "Please enter 1 or 2." >&2
    done
}

validate_mask_site() {
    # Caddy's reverse_proxy upstream accepts only scheme://host[:port] — no path,
    # query, fragment, whitespace, or trailing slash. Strip anything past the host[:port].
    local mask_clean
    mask_clean="$(printf '%s' "$MASK_SITE" | sed -E 's|^(https?://[^[:space:]/?#]+).*$|\1|')"
    [[ "$mask_clean" =~ ^https?://[^[:space:]/?#]+$ ]] || die "Mask site must start with http:// or https:// and contain a host: $MASK_SITE"
    if [[ "$mask_clean" != "$MASK_SITE" ]]; then
        log "Stripped path/slash from mask site: $MASK_SITE → $mask_clean"
        MASK_SITE="$mask_clean"
    fi
}

validate_static_root() {
    command -v realpath >/dev/null 2>&1 || die "Missing required command: realpath"
    [[ "$STATIC_ROOT" == /* ]] \
        || die "Static site root must be an absolute path: $STATIC_ROOT"
    [[ "$STATIC_ROOT" != *[[:space:]]* ]] \
        || die "Static site root must not contain whitespace: $STATIC_ROOT"
    STATIC_ROOT="$(realpath -m -- "$STATIC_ROOT")"
    [[ "$STATIC_ROOT" == /var/www/* || "$STATIC_ROOT" == /srv/* ]] \
        || die "Static site root must resolve under /var/www/ or /srv/: $STATIC_ROOT"
}

validate_naive_port() {
    [[ "$NAIVE_PORT" =~ ^[0-9]+$ ]] \
        || die "Invalid NAIVE_PORT: $NAIVE_PORT (expected an integer port)"
    (( NAIVE_PORT >= 1 && NAIVE_PORT <= 65535 )) \
        || die "Invalid NAIVE_PORT: $NAIVE_PORT (expected 1-65535)"
    [[ "$NAIVE_PORT" != "80" ]] \
        || die "NAIVE_PORT must not be 80 because port 80 is reserved for ACME HTTP validation"
}

gather_inputs() {
    # Populates globals: DOMAIN, COVER_MODE, MASK_SITE or STATIC_ROOT
    if [[ -n "${NAIVE_DOMAIN:-}" ]]; then
        DOMAIN="$NAIVE_DOMAIN"
        log "Domain from env: $DOMAIN"
    else
        DOMAIN="$(prompt_value 'Domain for NaiveProxy (DNS-only, points to this server)')"
    fi

    [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
        || die "Invalid domain: '$DOMAIN' (expected something like proxy.example.com — no scheme, no port, no path)"

    if [[ -n "${NAIVE_PORT:-}" ]]; then
        log "NaiveProxy HTTPS port from env: $NAIVE_PORT"
    else
        NAIVE_PORT="$(prompt_value 'NaiveProxy HTTPS port' "$DEFAULT_NAIVE_PORT")"
    fi
    validate_naive_port

    if [[ -n "${NAIVE_COVER_MODE:-}" ]]; then
        COVER_MODE="$(normalize_cover_mode "$NAIVE_COVER_MODE")" \
            || die "Invalid NAIVE_COVER_MODE: $NAIVE_COVER_MODE (expected static or proxy)"
        log "Cover mode from env: $COVER_MODE"
    else
        COVER_MODE="$(choose_cover_mode)"
    fi

    case "$COVER_MODE" in
        static)
            if [[ -n "${NAIVE_STATIC_ROOT:-}" ]]; then
                STATIC_ROOT="$NAIVE_STATIC_ROOT"
                log "Static site root from env: $STATIC_ROOT"
            else
                STATIC_ROOT="$(prompt_value 'Static site root' "$DEFAULT_STATIC_ROOT")"
            fi
            validate_static_root
            ;;
        proxy)
            if [[ -n "${NAIVE_MASK_SITE:-}" ]]; then
                MASK_SITE="$NAIVE_MASK_SITE"
                log "Mask site from env: $MASK_SITE"
            else
                MASK_SITE="$(prompt_value 'Cover site URL to reverse proxy' "$DEFAULT_MASK_SITE")"
            fi
            validate_mask_site
            ;;
    esac
}

#─────────────────────────────────────────────────────────────────────────────
# Install steps
#─────────────────────────────────────────────────────────────────────────────

install_dependencies() {
    local pkgs=(curl wget ca-certificates dnsutils iproute2 procps openssl tar xz-utils qrencode)
    local missing=()
    for pkg in "${pkgs[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$'; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        ok "apt dependencies already installed (skipping)"
        return 0
    fi
    log "Installing apt dependencies (${missing[*]})..."
    export DEBIAN_FRONTEND=noninteractive
    # Fresh VPSes often have unattended-upgrades holding the dpkg lock; wait
    # for it instead of failing immediately.
    apt-get -o DPkg::Lock::Timeout=60 update -qq
    apt-get -o DPkg::Lock::Timeout=60 install -y -qq "${missing[@]}" >/dev/null
    ok "apt dependencies installed"
}

ensure_caddy_account() {
    log "Preparing dedicated Caddy runtime account..."
    if [[ -d "$CADDY_STATE_DIR" && -z "$STATE_CADDY_STATE_DIR_METADATA" ]]; then
        STATE_CADDY_STATE_DIR_METADATA="$(path_metadata "$CADDY_STATE_DIR")"
    fi
    if ! getent group "$CADDY_GROUP" >/dev/null 2>&1; then
        groupadd --system "$CADDY_GROUP"
        TRANSACTION_CREATED_CADDY_GROUP=1
        MANAGED_CADDY_GROUP_CREATED=1
        ok "Created system group: ${CADDY_GROUP}"
    else
        ok "System group exists: ${CADDY_GROUP}"
    fi

    if ! id -u "$CADDY_USER" >/dev/null 2>&1; then
        local nologin="/usr/sbin/nologin"
        [[ -x /sbin/nologin ]] && nologin="/sbin/nologin"
        useradd --system \
            --gid "$CADDY_GROUP" \
            --home-dir "$CADDY_STATE_DIR" \
            --shell "$nologin" \
            --comment "Caddy web server" \
            "$CADDY_USER"
        TRANSACTION_CREATED_CADDY_USER=1
        MANAGED_CADDY_USER_CREATED=1
        ok "Created system user: ${CADDY_USER}"
    else
        if ! id -nG "$CADDY_USER" | tr ' ' '\n' | grep -Fxq "$CADDY_GROUP"; then
            usermod -a -G "$CADDY_GROUP" "$CADDY_USER"
            ok "Added ${CADDY_USER} to group ${CADDY_GROUP}"
        else
            ok "System user exists: ${CADDY_USER}"
        fi
    fi

    mkdir -p "$CADDY_STATE_DIR"
    chown "$CADDY_USER:$CADDY_GROUP" "$CADDY_STATE_DIR"
    chmod 0750 "$CADDY_STATE_DIR"
    ok "Caddy state directory ready: ${CADDY_STATE_DIR}"
}

install_go() {
    if [[ -x "${GO_INSTALL_DIR}/bin/go" ]]; then
        local current
        current="$("${GO_INSTALL_DIR}/bin/go" version)"
        if [[ "$current" == *" ${GO_VERSION} "* ]]; then
            ok "Using existing Go installation: ${current}"
        else
            warn "Using existing Go installation: ${current}; the installer will not replace ${GO_INSTALL_DIR} automatically."
        fi
        export PATH="${GO_INSTALL_DIR}/bin:$PATH"
        return 0
    fi

    if [[ -d "$GO_INSTALL_DIR" ]]; then
        die "${GO_INSTALL_DIR} exists but ${GO_INSTALL_DIR}/bin/go is not executable. Repair or remove it manually before source build."
    fi

    local go_bin
    if go_bin="$(type -P go)" && [[ -n "$go_bin" ]]; then
        local current
        current="$(go version)"
        if [[ "$current" == *" ${GO_VERSION} "* ]]; then
            ok "Using existing Go installation from ${go_bin}: ${current}"
        else
            warn "Using existing Go installation from ${go_bin}: ${current}; the installer will not install pinned ${GO_VERSION} automatically."
        fi
        return 0
    fi

    local checksum download_dir tarball tarball_path url
    case "$ARCH" in
        amd64) checksum="$GO_LINUX_AMD64_SHA256" ;;
        arm64) checksum="$GO_LINUX_ARM64_SHA256" ;;
        *) die "Unsupported Go architecture: ${ARCH}" ;;
    esac

    mkdir -p "$TMP_BUILD_DIR"
    download_dir="$(mktemp -d -p "$TMP_BUILD_DIR" go-download.XXXXXX)"
    register_tmp "$download_dir"
    tarball="${GO_VERSION}.linux-${ARCH}.tar.gz"
    tarball_path="${download_dir}/${tarball}"
    url="https://go.dev/dl/${tarball}"
    log "Downloading $url"
    if ! wget -q --show-progress -O "$tarball_path" "$url"; then
        rm -rf "$download_dir"
        die "Failed to download ${url}"
    fi

    if ! verify_sha256 "$tarball_path" "$checksum" "Go ${GO_VERSION} ${ARCH} tarball"; then
        rm -rf "$download_dir"
        die "Refusing to extract Go tarball after checksum failure."
    fi

    # Mark before extracting: an interrupted tar would otherwise leave a
    # partial /usr/local/go that neither rollback nor a rerun can handle.
    MANAGED_GO=1
    TRANSACTION_INSTALLED_GO=1
    tar -C /usr/local -xzf "$tarball_path"
    rm -rf "$download_dir"

    export PATH="${GO_INSTALL_DIR}/bin:$PATH"
    ok "Installed $(go version)"
}

verify_caddy_forwardproxy() {
    local bin="$1"
    [[ -x "$bin" ]] || return 1
    "$bin" list-modules 2>/dev/null | grep -Fxq 'http.handlers.forward_proxy'
}

require_installed_caddy_forwardproxy() {
    local action="$1"
    local advice="$2"

    [[ -e "$CADDY_BIN" ]] \
        || die "${CADDY_BIN} is missing; cannot ${action}. ${advice}"
    [[ -x "$CADDY_BIN" && ! -d "$CADDY_BIN" ]] \
        || die "${CADDY_BIN} is not executable; cannot ${action}. ${advice}"
    verify_caddy_forwardproxy "$CADDY_BIN" \
        || die "${CADDY_BIN} is missing required module http.handlers.forward_proxy; cannot ${action}. ${advice}"

    ok "Verified Caddy forward_proxy module in ${CADDY_BIN}"
}

download_prebuilt_caddy() {
    if [[ "${NAIVE_CADDY_INSTALL:-auto}" == "build" ]]; then
        log "Source build forced by NAIVE_CADDY_INSTALL=build"
        return 1
    fi

    if [[ "$ARCH" != "amd64" ]]; then
        warn "Prebuilt Caddy binary is only used on amd64; falling back to source build."
        return 1
    fi

    log "Downloading prebuilt Caddy ${PREBUILT_CADDY_TAG} with NaiveProxy support..."
    local download_dir archive extracted_bin
    mkdir -p "$TMP_BUILD_DIR"
    download_dir="$(mktemp -d -p "$TMP_BUILD_DIR" caddy-prebuilt.XXXXXX)"
    register_tmp "$download_dir"
    archive="${download_dir}/caddy-forwardproxy-naive.tar.xz"

    if ! wget -q -O "$archive" "$PREBUILT_CADDY_URL"; then
        warn "Prebuilt Caddy download failed; falling back to source build."
        rm -rf "$download_dir"
        return 1
    fi

    if ! verify_sha256 "$archive" "$PREBUILT_CADDY_SHA256" "prebuilt Caddy archive"; then
        rm -rf "$download_dir"
        die "Refusing to extract prebuilt Caddy archive after checksum failure."
    fi

    if ! tar -C "$download_dir" -xJf "$archive"; then
        warn "Failed to extract prebuilt Caddy; falling back to source build."
        rm -rf "$download_dir"
        return 1
    fi

    extracted_bin="$(find "$download_dir" -type f -name caddy -perm /111 | head -n1)"
    if [[ -z "$extracted_bin" ]] || ! verify_caddy_forwardproxy "$extracted_bin"; then
        warn "Downloaded Caddy does not include http.handlers.forward_proxy; falling back to source build."
        rm -rf "$download_dir"
        return 1
    fi

    BUILT_CADDY_BIN="${TMP_BUILD_DIR}/caddy.new"
    install -m 0755 "$extracted_bin" "$BUILT_CADDY_BIN"
    rm -rf "$download_dir"
    ok "Downloaded prebuilt Caddy: $($BUILT_CADDY_BIN version | head -n1)"
    return 0
}

build_caddy() {
    log "Preparing build environment..."
    mkdir -p "$TMP_BUILD_DIR"
    export TMPDIR="$TMP_BUILD_DIR"
    export GOPATH="${GOPATH:-/root/go}"
    export PATH="${GOPATH}/bin:${GO_INSTALL_DIR}/bin:$PATH"

    log "Installing ${XCADDY_MODULE}..."
    go install "$XCADDY_MODULE"

    log "Building Caddy ${CADDY_CORE_VERSION} with ${FORWARDPROXY_MODULE} (this takes a few minutes)..."
    local build_dir
    build_dir="$(mktemp -d -p "$TMP_BUILD_DIR" caddy-build.XXXXXX)"
    register_tmp "$build_dir"
    pushd "$build_dir" >/dev/null
    "${GOPATH}/bin/xcaddy" build "$CADDY_CORE_VERSION" \
        --with "github.com/caddyserver/forwardproxy=${FORWARDPROXY_MODULE}"
    [[ -x ./caddy ]] || die "xcaddy build failed: ./caddy not produced"
    verify_caddy_forwardproxy ./caddy || die "built Caddy is missing http.handlers.forward_proxy"
    BUILT_CADDY_BIN="${TMP_BUILD_DIR}/caddy.new"
    install -m 0755 ./caddy "$BUILT_CADDY_BIN"
    popd >/dev/null
    rm -rf "$build_dir"
    ok "Caddy built: $BUILT_CADDY_BIN"
}

prepare_caddy_binary() {
    if download_prebuilt_caddy; then
        return 0
    fi

    install_go
    build_caddy
}

install_caddy_binary() {
    log "Installing Caddy binary to ${CADDY_BIN}..."
    record_resource_origin ORIGIN_CADDY_BIN ORIGINAL_CADDY_BIN_BACKUP "$CADDY_BIN"
    if systemctl is-active --quiet caddy 2>/dev/null; then
        log "Stopping running caddy.service before binary swap..."
        systemctl stop caddy
    fi
    backup_path "$CADDY_BIN" "before Caddy binary replacement"
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    require_installed_caddy_forwardproxy \
        "continue after installing Caddy" \
        "Retry reinstall/source build with a Naive-capable Caddy."
    rm -f "$BUILT_CADDY_BIN"
    MANAGED_CADDY_BIN=1
    ok "Installed: $($CADDY_BIN version | head -n1)"
}

random_alnum() {
    local value
    while true; do
        value="$(openssl rand -base64 96 | tr -dc 'A-Za-z0-9')"
        if (( ${#value} >= 16 )); then
            printf '%s' "${value:0:16}"
            return 0
        fi
    done
}

load_existing_credentials() {
    # Parses NAIVE_USER / NAIVE_PASS back out of the credentials file without
    # sourcing it. Returns non-zero when absent or not cleanly parseable.
    [[ -r "$CRED_FILE" ]] || return 1
    local user pass
    user="$(awk -F"'" '/^NAIVE_USER=/{print $2; exit}' "$CRED_FILE")" || return 1
    pass="$(awk -F"'" '/^NAIVE_PASS=/{print $2; exit}' "$CRED_FILE")" || return 1
    [[ "$user" =~ ^[A-Za-z0-9]+$ && "$pass" =~ ^[A-Za-z0-9]+$ ]] || return 1
    NAIVE_USER="$user"
    NAIVE_PASS="$pass"
}

generate_credentials() {
    # Reconfigure keeps the existing credentials so deployed clients survive
    # a settings change; a reinstall still rotates them.
    if [[ "${MODE:-}" == "reconfigure" ]] && load_existing_credentials; then
        ok "Reusing existing credentials from ${CRED_FILE}"
        return 0
    fi
    log "Generating credentials..."
    NAIVE_USER="$(random_alnum)"
    NAIVE_PASS="$(random_alnum)"
    [[ ${#NAIVE_USER} -eq 16 && ${#NAIVE_PASS} -eq 16 ]] \
        || die "Failed to generate credentials"
    ok "Credentials generated"
}

write_static_cover_site() {
    [[ "$COVER_MODE" == "static" ]] || return 0
    local public_origin="https://${DOMAIN}"
    log "Preparing local static cover site at ${STATIC_ROOT}..."
    if [[ "$NAIVE_PORT" != "443" ]]; then
        public_origin="https://${DOMAIN}:${NAIVE_PORT}"
    fi
    if [[ -n "$STATE_STATIC_ROOT" && "$STATE_STATIC_ROOT" != "$STATIC_ROOT" ]]; then
        restore_metadata "$STATE_STATIC_ROOT" "$STATE_STATIC_ROOT_METADATA"
        if [[ "$MANAGED_STATIC_INDEX" != "1" ]]; then
            restore_metadata "${STATE_STATIC_ROOT}/index.html" "$STATE_STATIC_INDEX_METADATA"
        elif [[ -f "${STATE_STATIC_ROOT}/index.html" ]]; then
            warn "Cover page from the previous install remains at ${STATE_STATIC_ROOT}/index.html; remove it manually if unneeded."
        fi
        MANAGED_STATIC_ROOT_CREATED=0
        MANAGED_STATIC_INDEX=0
        STATE_STATIC_INDEX_SHA256=""
        STATE_STATIC_ROOT_METADATA=""
        STATE_STATIC_INDEX_METADATA=""
    fi
    if [[ ! -d "$STATIC_ROOT" ]]; then
        MANAGED_STATIC_ROOT_CREATED=1
    elif [[ -z "$STATE_STATIC_ROOT_METADATA" ]]; then
        STATE_STATIC_ROOT_METADATA="$(path_metadata "$STATIC_ROOT")"
    fi
    mkdir -p "$STATIC_ROOT"
    # Caddy now runs as the dedicated caddy user. Grant group traversal on the
    # selected static root so an existing root-owned cover directory remains
    # serviceable without making Caddy run as root again.
    chgrp "$CADDY_GROUP" "$STATIC_ROOT"
    chmod g+rx "$STATIC_ROOT"
    if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" ]]; then
        chmod 0755 "$STATIC_ROOT"
    fi
    # If the existing page is one we generated and the user never touched it
    # (checksum matches the managed state), regenerate it so the embedded
    # origin follows a domain/port change. User-modified pages are preserved.
    local regen_managed=0
    if [[ -f "${STATIC_ROOT}/index.html" && "$MANAGED_STATIC_INDEX" == "1" && -n "$STATE_STATIC_INDEX_SHA256" ]] \
        && [[ "$(file_sha256 "${STATIC_ROOT}/index.html")" == "$STATE_STATIC_INDEX_SHA256" ]]; then
        regen_managed=1
        log "Managed cover page is unmodified; regenerating it for the current settings."
    fi
    if [[ ! -e "${STATIC_ROOT}/index.html" || "$regen_managed" == "1" ]]; then
        cat > "${STATIC_ROOT}/index.html" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Global Edge Content Delivery Network. Fast, secure, and reliable static asset hosting.">
    <meta name="robots" content="noindex, nofollow">
    <title>Static Edge | Global CDN Service</title>
    <style>
        :root {
            --bg-color: #fafafa;
            --text-main: #171717;
            --text-muted: #737373;
            --border-color: #e5e5e5;
            --code-bg: #1a1a1a;
            --code-text: #e5e5e5;
            --code-keyword: #ff7b72;
            --code-string: #a5d6ff;
            --code-comment: #8b949e;
            --font-stack: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Segoe UI Symbol";
        }

        @media (prefers-color-scheme: dark) {
            :root {
                --bg-color: #0f1115;
                --text-main: #f5f5f5;
                --text-muted: #a3a3a3;
                --border-color: #262a33;
                --code-bg: #171a21;
                --code-text: #e6edf3;
                --code-keyword: #ff7b72;
                --code-string: #a5d6ff;
                --code-comment: #8b949e;
            }
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: var(--font-stack);
            background-color: var(--bg-color);
            color: var(--text-main);
            line-height: 1.6;
            display: flex;
            flex-direction: column;
            min-height: 100vh;
        }

        .container {
            width: 100%;
            max-width: 800px;
            margin: 0 auto;
            padding: 0 24px;
            flex-grow: 1;
            display: flex;
            flex-direction: column;
            justify-content: center;
        }

        header {
            text-align: left;
            padding: 60px 0 40px;
            border-bottom: 1px solid var(--border-color);
        }

        h1 {
            font-size: 2.5rem;
            font-weight: 700;
            letter-spacing: -0.03em;
            margin-bottom: 12px;
        }

        .subtitle {
            font-size: 1.125rem;
            color: var(--text-muted);
            max-width: 600px;
        }

        main {
            padding: 40px 0;
        }

        .code-block {
            background-color: var(--code-bg);
            color: var(--code-text);
            padding: 20px;
            border-radius: 8px;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
            font-size: 0.875rem;
            overflow-x: auto;
            margin-bottom: 40px;
        }

        .code-block .keyword { color: var(--code-keyword); }
        .code-block .string { color: var(--code-string); }
        .code-block .comment { color: var(--code-comment); }

        .features {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 32px;
        }

        .feature-item h3 {
            font-size: 1rem;
            font-weight: 600;
            margin-bottom: 8px;
        }

        .feature-item p {
            font-size: 0.9375rem;
            color: var(--text-muted);
        }

        footer {
            padding: 32px 0;
            border-top: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 0.875rem;
            color: var(--text-muted);
        }

        .footer-links span {
            color: var(--text-muted);
            margin-left: 16px;
        }

        @media (max-width: 720px) {
            .container {
                min-height: auto;
                justify-content: flex-start;
                padding: 0 20px;
            }

            header {
                padding: 44px 0 32px;
            }

            h1 {
                font-size: 2rem;
            }

            .subtitle {
                font-size: 1rem;
            }

            main {
                padding: 32px 0;
            }

            .code-block {
                padding: 16px;
                font-size: 0.8125rem;
                margin-bottom: 32px;
            }

            .features {
                grid-template-columns: 1fr;
                gap: 24px;
            }

            footer {
                flex-direction: column;
                gap: 16px;
                text-align: center;
            }

            .footer-links {
                display: flex;
                flex-wrap: wrap;
                justify-content: center;
                gap: 8px 16px;
            }

            .footer-links span {
                margin-left: 0;
            }
        }

        @media (max-width: 420px) {
            .container {
                padding: 0 16px;
            }

            h1 {
                font-size: 1.75rem;
            }

            .code-block {
                margin-left: -4px;
                margin-right: -4px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Static Edge</h1>
            <p class="subtitle">Distributed static resource routing and delivery network. Providing low-latency asset serving for enterprise applications.</p>
        </header>

        <main>
            <div class="code-block">
                <span class="comment">// Standard Endpoint Access Example</span><br><br>
                <span class="keyword">const</span> endpoint = <span class="string">'${public_origin}/v2/static'</span>;<br>
                <span class="keyword">const</span> region = <span class="string">'auto'</span>; <span class="comment">// Automatically routes to nearest PoP</span><br><br>
                <span class="keyword">export default function</span> resolveAsset(id) {<br>
                &nbsp;&nbsp;<span class="keyword">return</span> \`\${endpoint}/\${id}?region=\${region}\`;<br>
                }
            </div>

            <div class="features">
                <div class="feature-item">
                    <h3>Global Edge Network</h3>
                    <p>Distributed edge routing helps serve static resources from regional infrastructure.</p>
                </div>
                <div class="feature-item">
                    <h3>Managed Asset Cache</h3>
                    <p>Static assets are cached and refreshed through standard operational workflows.</p>
                </div>
                <div class="feature-item">
                    <h3>Secure Delivery</h3>
                    <p>Modern transport security is used for serving public object payloads.</p>
                </div>
            </div>
        </main>

        <footer>
            <div class="copyright">
                &copy; <script>document.write(new Date().getFullYear())</script> Static Edge Infrastructure.
            </div>
            <div class="footer-links">
                <span>Documentation</span>
                <span>API Reference</span>
                <span>Terms of Service</span>
            </div>
        </footer>
    </div>
</body>
</html>
EOF
        chmod 0644 "${STATIC_ROOT}/index.html"
        chgrp "$CADDY_GROUP" "${STATIC_ROOT}/index.html"
        MANAGED_STATIC_INDEX=1
        STATE_STATIC_ROOT="$STATIC_ROOT"
        STATE_STATIC_INDEX_SHA256="$(file_sha256 "${STATIC_ROOT}/index.html")"
        ok "Default index.html written"
    else
        if [[ -f "${STATIC_ROOT}/index.html" ]]; then
            if [[ -z "$STATE_STATIC_INDEX_METADATA" ]]; then
                STATE_STATIC_INDEX_METADATA="$(path_metadata "${STATIC_ROOT}/index.html")"
            fi
            chgrp "$CADDY_GROUP" "${STATIC_ROOT}/index.html"
            chmod g+r "${STATIC_ROOT}/index.html"
        fi
        STATE_STATIC_ROOT="$STATIC_ROOT"
        ok "Existing index.html preserved"
    fi
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    local tmp validation_log
    if [[ ! -d "$CADDY_DIR" ]]; then
        MANAGED_CADDY_DIR_CREATED=1
    elif [[ -z "$STATE_CADDY_DIR_METADATA" ]]; then
        STATE_CADDY_DIR_METADATA="$(path_metadata "$CADDY_DIR")"
    fi
    mkdir -p "$CADDY_DIR"
    chgrp "$CADDY_GROUP" "$CADDY_DIR"
    chmod u+rwx,g+rx "$CADDY_DIR"
    tmp="$(mktemp "${CADDYFILE}.XXXXXX")"
    register_tmp "$tmp"
    cat > "$tmp" <<EOF
# Managed by naivecd. The installer may replace this file during reconfiguration.
:${NAIVE_PORT}, ${DOMAIN}:${NAIVE_PORT}
tls naive@${DOMAIN}

route {
  forward_proxy {
    basic_auth ${NAIVE_USER} ${NAIVE_PASS}
    hide_ip
    hide_via
    probe_resistance
  }

EOF
    if [[ "$COVER_MODE" == "static" ]]; then
        cat >> "$tmp" <<EOF
  root * ${STATIC_ROOT}
  file_server
EOF
    else
        cat >> "$tmp" <<EOF
  reverse_proxy ${MASK_SITE} {
    header_up Host {upstream_hostport}
    header_up X-Forwarded-Host {host}
  }
EOF
    fi
    cat >> "$tmp" <<EOF
}
EOF
    validation_log="$(mktemp "${CADDYFILE}.validate.XXXXXX")"
    register_tmp "$validation_log"
    if ! "$CADDY_BIN" fmt --overwrite "$tmp" >"$validation_log" 2>&1; then
        err "Failed to format generated Caddyfile:"
        sed 's/^/    /' "$validation_log" >&2
        rm -f -- "$tmp" "$validation_log"
        die "Generated Caddyfile could not be formatted; existing ${CADDYFILE} was left unchanged."
    fi
    if ! "$CADDY_BIN" validate --config "$tmp" >"$validation_log" 2>&1; then
        err "Generated Caddyfile validation output:"
        sed 's/^/    /' "$validation_log" >&2
        rm -f -- "$tmp" "$validation_log"
        die "Generated Caddyfile failed validation; existing ${CADDYFILE} was left unchanged."
    fi
    rm -f -- "$validation_log"
    chown "root:$CADDY_GROUP" "$tmp"
    chmod 0640 "$tmp"
    ok "Caddy configuration is valid"
    record_resource_origin ORIGIN_CADDYFILE ORIGINAL_CADDYFILE_BACKUP "$CADDYFILE"
    backup_path "$CADDYFILE" "before Caddyfile replacement"
    mv "$tmp" "$CADDYFILE"
    MANAGED_CADDYFILE=1
    ok "Caddyfile written"
}


write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    local tmp
    tmp="$(mktemp "${SYSTEMD_UNIT}.XXXXXX")"
    register_tmp "$tmp"
    cat > "$tmp" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy
# Managed by naivecd. The installer may replace this unit during reconfiguration.
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy
Environment=XDG_DATA_HOME=/var/lib/caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ProtectClock=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadWritePaths=/var/lib/caddy
StateDirectory=caddy
RuntimeDirectory=caddy
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    if [[ -f "$SYSTEMD_UNIT" ]] && cmp -s -- "$tmp" "$SYSTEMD_UNIT"; then
        rm -f -- "$tmp"
        SYSTEMD_UNIT_CHANGED=0
        MANAGED_SYSTEMD_UNIT=1
        ok "systemd unit already up to date"
        return 0
    fi
    record_resource_origin ORIGIN_SYSTEMD_UNIT ORIGINAL_SYSTEMD_UNIT_BACKUP "$SYSTEMD_UNIT"
    backup_path "$SYSTEMD_UNIT" "before systemd unit replacement"
    mv -- "$tmp" "$SYSTEMD_UNIT"
    MANAGED_SYSTEMD_UNIT=1
    SYSTEMD_UNIT_CHANGED=1
    systemctl daemon-reload
    ok "systemd unit written"
}

start_caddy() {
    systemctl enable caddy >/dev/null 2>&1 \
        || warn "Could not enable caddy.service; run 'systemctl enable caddy' manually."
    # On reconfigure with an unchanged unit only the Caddyfile differs, so a
    # graceful reload keeps existing connections alive. Anything else (new
    # binary, changed unit) needs a real restart.
    if [[ "${MODE:-}" == "reconfigure" && "$SYSTEMD_UNIT_CHANGED" == "0" ]] \
        && systemctl is-active --quiet caddy 2>/dev/null; then
        log "Reloading caddy.service with the new configuration..."
        if systemctl reload caddy 2>/dev/null; then
            ok "caddy.service reloaded"
            return 0
        fi
        warn "Graceful reload failed; falling back to restart."
    fi
    log "Enabling and starting caddy.service..."
    if ! systemctl restart caddy; then
        err "caddy.service failed to restart. Last 50 log lines:"
        journalctl -u caddy -n 50 --no-pager >&2
        die "Aborting. Inspect logs above (often: invalid config, ACME error, port conflict, DNS misconfig)."
    fi
}

wait_for_caddy_active() {
    log "Waiting for Caddy to become active and obtain TLS certificate..."
    local deadline=$(( SECONDS + 180 ))
    while (( SECONDS < deadline )); do
        if systemctl is-active --quiet caddy; then
            # Systemd reports active even before ACME finishes — probe TLS to confirm
            # cert issued. --resolve pins the domain to 127.0.0.1 so the probe hits
            # this server even while public DNS is still propagating. Drop -f so
            # HTTP 4xx/5xx from the mask reverse_proxy still counts as a successful
            # TLS handshake.
            if curl -sS --max-time 5 --resolve "${DOMAIN}:${NAIVE_PORT}:127.0.0.1" \
                -o /dev/null "https://${DOMAIN}:${NAIVE_PORT}" 2>/dev/null; then
                ok "Caddy is active and TLS endpoint responding"
                return 0
            fi
        elif systemctl is-failed --quiet caddy; then
            err "caddy.service failed. Last 50 log lines:"
            journalctl -u caddy -n 50 --no-pager >&2
            die "Aborting. Inspect logs above (often: ACME error, port conflict, DNS misconfig)."
        fi
        sleep 2
    done
    warn "Caddy did not serve a valid TLS response on :${NAIVE_PORT} within 180s."
    warn "Recent logs:"
    journalctl -u caddy -n 30 --no-pager >&2
    confirm "Continue anyway (cert may still be issuing)" default-no \
        || die "Aborted. Run 'journalctl -u caddy -f' to debug."
}

#─────────────────────────────────────────────────────────────────────────────
# Output
#─────────────────────────────────────────────────────────────────────────────

save_credentials_file() {
    record_resource_origin ORIGIN_CRED_FILE ORIGINAL_CRED_FILE_BACKUP "$CRED_FILE"
    backup_path "$CRED_FILE" "before credentials replacement"
    cat > "$CRED_FILE" <<EOF
# Managed by naivecd. This file contains generated NaiveProxy credentials.
# NaiveProxy credentials — generated $(date -Iseconds)
# Domain:     ${DOMAIN}
# Cover mode: ${COVER_MODE}
# Port:       ${NAIVE_PORT}
EOF
    if [[ "$COVER_MODE" == "static" ]]; then
        printf '# Static root: %s\n' "$STATIC_ROOT" >> "$CRED_FILE"
    else
        printf '# Mask site:   %s\n' "$MASK_SITE" >> "$CRED_FILE"
    fi
    cat >> "$CRED_FILE" <<EOF
NAIVE_USER='${NAIVE_USER}'
NAIVE_PASS='${NAIVE_PASS}'
NAIVE_URL='naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${NAIVE_PORT}?padding=1#NaiveProxy'
EOF
    chown root:root "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    MANAGED_CRED_FILE=1
}

write_client_config() {
    record_resource_origin ORIGIN_CLIENT_CONFIG ORIGINAL_CLIENT_CONFIG_BACKUP "$CLIENT_CONFIG"
    backup_path "$CLIENT_CONFIG" "before client config replacement"
    cat > "$CLIENT_CONFIG" <<EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${NAIVE_PORT}"
}
EOF
    chown root:root "$CLIENT_CONFIG"
    chmod 600 "$CLIENT_CONFIG"
    MANAGED_CLIENT_CONFIG=1
}

write_singbox_config() {
    record_resource_origin ORIGIN_SINGBOX_CONFIG ORIGINAL_SINGBOX_CONFIG_BACKUP "$SINGBOX_CONFIG"
    backup_path "$SINGBOX_CONFIG" "before sing-box config replacement"
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "outbounds": [
    {
      "type": "naive",
      "tag": "NaiveProxy",
      "server": "${DOMAIN}",
      "server_port": ${NAIVE_PORT},
      "username": "${NAIVE_USER}",
      "password": "${NAIVE_PASS}",
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    }
  ]
}
EOF
    chown root:root "$SINGBOX_CONFIG"
    chmod 600 "$SINGBOX_CONFIG"
    MANAGED_SINGBOX_CONFIG=1
}

show_existing_client_config() {
    local found=0

    echo
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    printf '%s  Saved NaiveProxy client configuration%s\n' "$C_BOLD" "$C_RST"
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    echo

    if [[ -r "$CRED_FILE" ]]; then
        printf '%sCredentials%s (%s):\n' "$C_BOLD" "$C_RST" "$CRED_FILE"
        sed 's/^/    /' "$CRED_FILE"
        echo
        found=1
    else
        warn "Credentials file not found: ${CRED_FILE}"
    fi

    if [[ -r "$CLIENT_CONFIG" ]]; then
        printf '%sNaive CLI config%s (%s):\n' "$C_BOLD" "$C_RST" "$CLIENT_CONFIG"
        sed 's/^/    /' "$CLIENT_CONFIG"
        echo
        found=1
    else
        warn "Naive CLI config not found: ${CLIENT_CONFIG}"
    fi

    if [[ -r "$SINGBOX_CONFIG" ]]; then
        printf '%ssing-box config%s (%s):\n' "$C_BOLD" "$C_RST" "$SINGBOX_CONFIG"
        sed 's/^/    /' "$SINGBOX_CONFIG"
        echo
        found=1
    else
        warn "sing-box config not found: ${SINGBOX_CONFIG}"
    fi

    if (( found == 0 )); then
        warn "No saved client configuration or credentials were found."
    else
        ok "Read-only display complete. No files, services, ports, or credentials were changed."
    fi
}

print_summary() {
    local uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${NAIVE_PORT}?padding=1#NaiveProxy"

    echo
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    printf '%s  NaiveProxy is up at https://%s:%s%s\n' "$C_BOLD" "$DOMAIN" "$NAIVE_PORT" "$C_RST"
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    echo

    printf '%sCredentials%s\n' "$C_BOLD" "$C_RST"
    printf '  user: %s\n' "$NAIVE_USER"
    printf '  pass: %s\n' "$NAIVE_PASS"
    printf '  port: %s\n' "$NAIVE_PORT"
    printf '  saved to: %s\n' "$CRED_FILE"
    echo

    printf '%sCover site%s\n' "$C_BOLD" "$C_RST"
    printf '  mode: %s\n' "$COVER_MODE"
    if [[ "$COVER_MODE" == "static" ]]; then
        printf '  static root: %s\n' "$STATIC_ROOT"
        printf '  edit: %s/index.html\n' "$STATIC_ROOT"
    else
        printf '  reverse proxy: %s\n' "$MASK_SITE"
    fi
    echo

    printf '%sClient config (klzgrad/naive CLI)%s\n' "$C_BOLD" "$C_RST"
    printf '  saved to: %s\n' "$CLIENT_CONFIG"
    printf '  download CLI binary for your OS: https://github.com/klzgrad/naiveproxy/releases\n'
    printf '  run: ./naive %s\n' "$(basename "$CLIENT_CONFIG")"
    echo
    printf '  contents:\n'
    sed 's/^/    /' "$CLIENT_CONFIG"
    echo

    printf '%sURI for SagerNet-family Android clients%s (Exclave, NekoBox, sing-box-for-android via plugin)\n' "$C_BOLD" "$C_RST"
    printf '  %s\n' "$uri"
    echo
    printf '  QR (scan in Exclave → Add → From QR Code):\n'
    echo
    qrencode -t UTF8 -m 2 "$uri" | sed 's/^/    /'
    echo

    printf '%ssing-box config%s (for Karing / sing-box-for-android — import as profile):\n' "$C_BOLD" "$C_RST"
    printf '  saved to: %s\n' "$SINGBOX_CONFIG"
    printf '  contents:\n'
    sed 's/^/    /' "$SINGBOX_CONFIG"
    echo

    printf '%sFinal check%s — from your client (after launching naive CLI):\n' "$C_BOLD" "$C_RST"
    printf '  curl --socks5-hostname 127.0.0.1:10808 https://ifconfig.me\n'
    printf '  expected output: %s (this server)\n' "$(get_external_ip 2>/dev/null || echo "<this-server-IP>")"
    echo
    printf '%sService status%s — manage with:\n' "$C_BOLD" "$C_RST"
    printf '  systemctl status caddy\n'
    printf '  journalctl -u caddy -f\n'
    echo
}

#─────────────────────────────────────────────────────────────────────────────
# Main
#─────────────────────────────────────────────────────────────────────────────

main() {
    check_root
    detect_os
    ARCH="$(detect_arch)" || exit 1
    ok "Architecture: $ARCH"

    if [[ -x "$CADDY_BIN" ]] || has_caddy_unit; then
        handle_existing_caddy
        log "Install mode: $MODE"
    else
        MODE="fresh"
        log "Install mode: fresh (NaiveProxy with Caddy on this server)"
    fi

    if [[ "$MODE" == "show" ]]; then
        show_existing_client_config
        exit 0
    fi

    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_caddy_naive
        exit 0
    fi

    if [[ "$MODE" == "reconfigure" ]]; then
        require_installed_caddy_forwardproxy \
            "reconfigure" \
            "Choose Reinstall NaiveProxy, or rerun with NAIVE_CADDY_INSTALL=build to source-build a Naive-capable Caddy."
    fi

    load_managed_state

    gather_inputs
    echo
    log "NaiveProxy setup summary:"
    log "Domain      : $DOMAIN"
    log "Port        : $NAIVE_PORT"
    log "Cover mode  : $COVER_MODE"
    if [[ "$COVER_MODE" == "static" ]]; then
        log "Static root : $STATIC_ROOT"
    else
        log "Cover site  : $MASK_SITE"
    fi
    echo
    confirm "Proceed" default-yes || die "Aborted by user."

    install_dependencies
    check_dns "$DOMAIN"
    check_firewall

    begin_transaction
    ensure_caddy_account
    check_ports

    if [[ "$MODE" == "rebuild" || "$MODE" == "fresh" ]]; then
        prepare_caddy_binary
        install_caddy_binary
    fi

    generate_credentials
    write_static_cover_site
    write_caddyfile

    write_systemd_unit
    save_credentials_file
    write_client_config
    write_singbox_config
    write_managed_state
    start_caddy
    wait_for_caddy_active
    commit_transaction
    prune_backup_sessions

    print_summary
}

if [[ "${NAIVECD_LIB_ONLY:-0}" != "1" ]]; then
    main "$@"
fi
