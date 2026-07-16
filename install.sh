#!/usr/bin/env bash
# NaiveProxy + Caddy auto-setup for Debian/Ubuntu VPS.
# Repository: https://github.com/LowOrbitLab/naivecd

set -euo pipefail
umask 077

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
    err "Failed at line $line (exit $code). Last command: ${BASH_COMMAND}"
    exit "$code"
}
trap 'on_err $LINENO' ERR

TMP_DIRS=()

register_tmp() {
    [[ -n "$1" ]] && TMP_DIRS+=("$1")
}

cleanup_tmp() {
    local d
    [[ ${#TMP_DIRS[@]} -eq 0 ]] && return 0
    for d in "${TMP_DIRS[@]}"; do
        if [[ "${PRESERVE_TRANSACTION_DIR:-0}" == "1" && "$d" == "${TRANSACTION_DIR:-}" ]]; then
            continue
        fi
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d" || true
    done
}

handle_exit() {
    local code=$?
    trap - EXIT ERR INT TERM
    set +e
    if [[ "${TRANSACTION_ACTIVE:-0}" == "1" ]]; then
        rollback_transaction
    fi
    cleanup_tmp
    exit "$code"
}

handle_signal() {
    local signal="$1" code="$2"
    warn "Received ${signal}; aborting safely."
    exit "$code"
}

trap handle_exit EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

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

readonly DEFAULT_MASK_SITE="https://www.lovense.com"
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
readonly STATE_FORMAT_VERSION="2"
readonly STATE_ABSENT="__NAIVECD_ABSENT__"
readonly CADDY_USER="caddy"
readonly CADDY_GROUP="caddy"
readonly CADDY_STATE_DIR="/var/lib/caddy"

STATE_LOADED=0
NAIVECD_STATE_VERSION=0
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
STATE_CADDY_BIN_SHA256=""
STATE_SYSTEMD_UNIT_SHA256=""
STATE_CADDYFILE_SHA256=""
STATE_CRED_FILE_SHA256=""
STATE_CLIENT_CONFIG_SHA256=""
STATE_SINGBOX_CONFIG_SHA256=""
STATE_CADDY_BIN_ORIGINAL=""
STATE_SYSTEMD_UNIT_ORIGINAL=""
STATE_CADDYFILE_ORIGINAL=""
STATE_CRED_FILE_ORIGINAL=""
STATE_CLIENT_CONFIG_ORIGINAL=""
STATE_SINGBOX_CONFIG_ORIGINAL=""
STATE_ORIGINAL_SERVICE_ACTIVE=""
STATE_ORIGINAL_SERVICE_ENABLED=""
BACKUP_SESSION_DIR=""
BACKUP_QUIET=0
LAST_BACKUP_PATH=""
TRANSACTION_ACTIVE=0
TRANSACTION_DIR=""
PRESERVE_TRANSACTION_DIR=0
TXN_SERVICE_ACTIVE=0
TXN_SERVICE_ENABLED=0
TXN_CADDY_DIR_EXISTED=0
TXN_CADDY_DIR_UID=""
TXN_CADDY_DIR_GID=""
TXN_CADDY_DIR_MODE=""
TXN_STATIC_ROOT_EXISTED=0
TXN_STATIC_BASE_EXISTED=0
TXN_STATIC_BASE=""
declare -A TXN_PATHS=()
declare -A TXN_EXISTED=()
declare -A TXN_SNAPSHOTS=()

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
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) ok "Detected ${PRETTY_NAME:-$ID}" ;;
        *) die "Unsupported OS: ${ID:-unknown} (supported: debian, ubuntu)" ;;
    esac
}

get_external_ip() {
    # Try multiple endpoints; first one wins.
    local ip
    for url in https://api.ipify.org https://ifconfig.me https://ipinfo.io/ip; do
        ip="$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)"
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

check_dns() {
    local domain="$1" external_ip resolved_ips
    log "Checking DNS for $domain..."

    if ! external_ip="$(get_external_ip)"; then
        warn "Could not detect this server's external IP — skipping DNS check."
        return 0
    fi
    log "Server external IP: $external_ip"

    require_cmd dig
    resolved_ips="$(dig +short A "$domain" @1.1.1.1)"
    if [[ -z "$resolved_ips" ]]; then
        warn "Domain $domain has no A-record (or DNS not yet propagated)."
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
    ok "Ports 80 and ${NAIVE_PORT} are available"
}

reset_managed_state() {
    STATE_LOADED=0
    NAIVECD_STATE_VERSION=0
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
    STATE_CADDY_BIN_SHA256=""
    STATE_SYSTEMD_UNIT_SHA256=""
    STATE_CADDYFILE_SHA256=""
    STATE_CRED_FILE_SHA256=""
    STATE_CLIENT_CONFIG_SHA256=""
    STATE_SINGBOX_CONFIG_SHA256=""
    STATE_CADDY_BIN_ORIGINAL=""
    STATE_SYSTEMD_UNIT_ORIGINAL=""
    STATE_CADDYFILE_ORIGINAL=""
    STATE_CRED_FILE_ORIGINAL=""
    STATE_CLIENT_CONFIG_ORIGINAL=""
    STATE_SINGBOX_CONFIG_ORIGINAL=""
    STATE_ORIGINAL_SERVICE_ACTIVE=""
    STATE_ORIGINAL_SERVICE_ENABLED=""
}

state_flag_is_valid() {
    [[ "$1" == "0" || "$1" == "1" ]]
}

state_hash_is_valid() {
    [[ -z "$1" || "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

state_original_ref_is_valid() {
    local ref="$1"
    [[ -z "$ref" ]] && return 0
    [[ "$ref" == "$STATE_ABSENT" ]] && return 0
    [[ "$ref" == "${BACKUP_ROOT}/"* ]] || return 1
    [[ "$ref" != *[[:space:]]* && "$ref" != *'/../'* && "$ref" != */.. ]] || return 1
}

state_file_is_trusted() {
    local path="$1" owner mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    owner="$(stat -c '%u' -- "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' -- "$path" 2>/dev/null)" || return 1
    [[ "$owner" == "$EUID" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

load_managed_state() {
    reset_managed_state
    local state_path="${1:-$STATE_FILE}"
    [[ -r "$state_path" ]] || return 0

    if ! state_file_is_trusted "$state_path"; then
        warn "Ignoring untrusted managed-state file: ${state_path}"
        return 0
    fi

    local key value
    while IFS='=' read -r key value; do
        [[ -n "$key" && "$key" != \#* ]] || continue
        case "$key" in
            NAIVECD_STATE_VERSION|NAIVECD_MANAGED|MANAGED_CADDY_DIR_CREATED|MANAGED_CADDY_BIN|MANAGED_SYSTEMD_UNIT|\
            MANAGED_CADDYFILE|MANAGED_CRED_FILE|MANAGED_CLIENT_CONFIG|MANAGED_SINGBOX_CONFIG|\
            MANAGED_STATIC_ROOT_CREATED|MANAGED_STATIC_INDEX|MANAGED_GO|\
            MANAGED_CADDY_USER_CREATED|MANAGED_CADDY_GROUP_CREATED|STATE_STATIC_ROOT|\
            STATE_STATIC_INDEX_SHA256|STATE_CADDY_BIN_SHA256|STATE_SYSTEMD_UNIT_SHA256|\
            STATE_CADDYFILE_SHA256|STATE_CRED_FILE_SHA256|STATE_CLIENT_CONFIG_SHA256|\
            STATE_SINGBOX_CONFIG_SHA256|STATE_CADDY_BIN_ORIGINAL|STATE_SYSTEMD_UNIT_ORIGINAL|\
            STATE_CADDYFILE_ORIGINAL|STATE_CRED_FILE_ORIGINAL|STATE_CLIENT_CONFIG_ORIGINAL|\
            STATE_SINGBOX_CONFIG_ORIGINAL|STATE_ORIGINAL_SERVICE_ACTIVE|STATE_ORIGINAL_SERVICE_ENABLED)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$state_path"

    if [[ "$NAIVECD_MANAGED" != "1" || "$NAIVECD_STATE_VERSION" != "$STATE_FORMAT_VERSION" ]]; then
        warn "Ignoring invalid or unsupported managed-state file: ${state_path}"
        reset_managed_state
        return 0
    fi

    local flag hash original
    for flag in \
        MANAGED_CADDY_DIR_CREATED MANAGED_CADDY_BIN MANAGED_SYSTEMD_UNIT MANAGED_CADDYFILE \
        MANAGED_CRED_FILE MANAGED_CLIENT_CONFIG MANAGED_SINGBOX_CONFIG MANAGED_STATIC_ROOT_CREATED \
        MANAGED_STATIC_INDEX MANAGED_GO MANAGED_CADDY_USER_CREATED MANAGED_CADDY_GROUP_CREATED; do
        if ! state_flag_is_valid "${!flag}"; then
            warn "Ignoring managed-state file with invalid flag ${flag}: ${state_path}"
            reset_managed_state
            return 0
        fi
    done

    for flag in STATE_ORIGINAL_SERVICE_ACTIVE STATE_ORIGINAL_SERVICE_ENABLED; do
        if ! state_flag_is_valid "${!flag}"; then
            warn "Ignoring managed-state file with invalid service state ${flag}: ${state_path}"
            reset_managed_state
            return 0
        fi
    done

    for hash in \
        STATE_STATIC_INDEX_SHA256 STATE_CADDY_BIN_SHA256 STATE_SYSTEMD_UNIT_SHA256 \
        STATE_CADDYFILE_SHA256 STATE_CRED_FILE_SHA256 STATE_CLIENT_CONFIG_SHA256 \
        STATE_SINGBOX_CONFIG_SHA256; do
        if ! state_hash_is_valid "${!hash}"; then
            warn "Ignoring managed-state file with invalid checksum ${hash}: ${state_path}"
            reset_managed_state
            return 0
        fi
    done

    for original in \
        STATE_CADDY_BIN_ORIGINAL STATE_SYSTEMD_UNIT_ORIGINAL STATE_CADDYFILE_ORIGINAL \
        STATE_CRED_FILE_ORIGINAL STATE_CLIENT_CONFIG_ORIGINAL STATE_SINGBOX_CONFIG_ORIGINAL; do
        if ! state_original_ref_is_valid "${!original}"; then
            warn "Ignoring managed-state file with invalid backup reference ${original}: ${state_path}"
            reset_managed_state
            return 0
        fi
    done

    local resource_spec managed_var hash_var original_var
    for resource_spec in \
        'MANAGED_CADDY_BIN:STATE_CADDY_BIN_SHA256:STATE_CADDY_BIN_ORIGINAL' \
        'MANAGED_SYSTEMD_UNIT:STATE_SYSTEMD_UNIT_SHA256:STATE_SYSTEMD_UNIT_ORIGINAL' \
        'MANAGED_CADDYFILE:STATE_CADDYFILE_SHA256:STATE_CADDYFILE_ORIGINAL' \
        'MANAGED_CRED_FILE:STATE_CRED_FILE_SHA256:STATE_CRED_FILE_ORIGINAL' \
        'MANAGED_CLIENT_CONFIG:STATE_CLIENT_CONFIG_SHA256:STATE_CLIENT_CONFIG_ORIGINAL' \
        'MANAGED_SINGBOX_CONFIG:STATE_SINGBOX_CONFIG_SHA256:STATE_SINGBOX_CONFIG_ORIGINAL'; do
        IFS=':' read -r managed_var hash_var original_var <<< "$resource_spec"
        if [[ "${!managed_var}" == "1" && ( -z "${!hash_var}" || -z "${!original_var}" ) ]]; then
            warn "Ignoring incomplete managed-state resource ${managed_var}: ${state_path}"
            reset_managed_state
            return 0
        fi
    done

    if [[ -n "$STATE_STATIC_ROOT" ]]; then
        [[ "$STATE_STATIC_ROOT" == /var/www/* || "$STATE_STATIC_ROOT" == /srv/* ]] || {
            warn "Ignoring managed-state file with unsafe static root: ${state_path}"
            reset_managed_state
            return 0
        }
        [[ "$STATE_STATIC_ROOT" != *[[:space:]]* && "$STATE_STATIC_ROOT" != *'/../'* ]] || {
            warn "Ignoring managed-state file with malformed static root: ${state_path}"
            reset_managed_state
            return 0
        }
    fi

    STATE_LOADED=1
}

write_managed_state() {
    mkdir -p "$CADDY_DIR"
    local tmp="${STATE_FILE}.tmp"
    {
        printf '# Managed by naivecd. This file records resources created by the installer.\n'
        printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'NAIVECD_STATE_VERSION=%s\n' "$STATE_FORMAT_VERSION"
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
        printf 'STATE_CADDY_BIN_SHA256=%s\n' "${STATE_CADDY_BIN_SHA256:-}"
        printf 'STATE_SYSTEMD_UNIT_SHA256=%s\n' "${STATE_SYSTEMD_UNIT_SHA256:-}"
        printf 'STATE_CADDYFILE_SHA256=%s\n' "${STATE_CADDYFILE_SHA256:-}"
        printf 'STATE_CRED_FILE_SHA256=%s\n' "${STATE_CRED_FILE_SHA256:-}"
        printf 'STATE_CLIENT_CONFIG_SHA256=%s\n' "${STATE_CLIENT_CONFIG_SHA256:-}"
        printf 'STATE_SINGBOX_CONFIG_SHA256=%s\n' "${STATE_SINGBOX_CONFIG_SHA256:-}"
        printf 'STATE_CADDY_BIN_ORIGINAL=%s\n' "${STATE_CADDY_BIN_ORIGINAL:-}"
        printf 'STATE_SYSTEMD_UNIT_ORIGINAL=%s\n' "${STATE_SYSTEMD_UNIT_ORIGINAL:-}"
        printf 'STATE_CADDYFILE_ORIGINAL=%s\n' "${STATE_CADDYFILE_ORIGINAL:-}"
        printf 'STATE_CRED_FILE_ORIGINAL=%s\n' "${STATE_CRED_FILE_ORIGINAL:-}"
        printf 'STATE_CLIENT_CONFIG_ORIGINAL=%s\n' "${STATE_CLIENT_CONFIG_ORIGINAL:-}"
        printf 'STATE_SINGBOX_CONFIG_ORIGINAL=%s\n' "${STATE_SINGBOX_CONFIG_ORIGINAL:-}"
        printf 'STATE_ORIGINAL_SERVICE_ACTIVE=%s\n' "${STATE_ORIGINAL_SERVICE_ACTIVE:-0}"
        printf 'STATE_ORIGINAL_SERVICE_ENABLED=%s\n' "${STATE_ORIGINAL_SERVICE_ENABLED:-0}"
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
    LAST_BACKUP_PATH=""
    [[ -e "$path" || -L "$path" ]] || return 0

    ensure_backup_dir
    rel="${path#/}"
    dest="${BACKUP_SESSION_DIR}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp -a -- "$path" "$dest"
    LAST_BACKUP_PATH="$dest"
    if [[ "$BACKUP_QUIET" != "1" ]]; then
        ok "Backed up ${path} (${reason}) to ${dest}"
    fi
}

backup_and_record_original() {
    local path="$1" state_var="$2" reason="$3"
    local expected_sha256="${4:-}" managed_flag="${5:-0}" label="${6:-$path}"
    local original="${!state_var}"

    if [[ "$managed_flag" == "1" && ( -e "$path" || -L "$path" ) ]] \
        && ! managed_resource_matches "$path" "$expected_sha256"; then
        warn "Managed ${label} changed outside naivecd: ${path}"
        confirm "Replace it and preserve the current file as the new uninstall restore point" default-no \
            || die "Aborted to preserve modified ${label}: ${path}"
        backup_path "$path" "preserving modified ${label} before replacement"
        [[ -n "$LAST_BACKUP_PATH" ]] || die "Failed to preserve modified ${label}: ${path}"
        printf -v "$state_var" '%s' "$LAST_BACKUP_PATH"
        return 0
    fi

    backup_path "$path" "$reason"
    [[ -n "$original" ]] && return 0

    if [[ -n "$LAST_BACKUP_PATH" ]]; then
        printf -v "$state_var" '%s' "$LAST_BACKUP_PATH"
    else
        printf -v "$state_var" '%s' "$STATE_ABSENT"
    fi
}

record_original_service_state() {
    [[ -n "$STATE_ORIGINAL_SERVICE_ACTIVE" && -n "$STATE_ORIGINAL_SERVICE_ENABLED" ]] && return 0

    if systemctl is-active --quiet caddy 2>/dev/null; then
        STATE_ORIGINAL_SERVICE_ACTIVE=1
    else
        STATE_ORIGINAL_SERVICE_ACTIVE=0
    fi

    if systemctl is-enabled --quiet caddy 2>/dev/null; then
        STATE_ORIGINAL_SERVICE_ENABLED=1
    else
        STATE_ORIGINAL_SERVICE_ENABLED=0
    fi
}

managed_resource_matches() {
    local path="$1" expected_sha256="$2"
    [[ -f "$path" && ! -L "$path" && -n "$expected_sha256" ]] || return 1
    [[ "$(file_sha256 "$path")" == "$expected_sha256" ]]
}

managed_resource_can_change() {
    local path="$1" expected_sha256="$2" original_ref="$3" marker_required="${4:-0}"

    if [[ "$original_ref" != "$STATE_ABSENT" && ( ! -e "$original_ref" && ! -L "$original_ref" ) ]]; then
        return 1
    fi

    [[ -e "$path" || -L "$path" ]] || return 0
    [[ "$marker_required" != "1" ]] || file_has_naivecd_marker "$path" || return 1
    managed_resource_matches "$path" "$expected_sha256"
}

restore_or_remove_managed_resource() {
    local path="$1" expected_sha256="$2" original_ref="$3" label="$4"

    if [[ ! -e "$path" && ! -L "$path" ]]; then
        if [[ "$original_ref" == "$STATE_ABSENT" ]]; then
            return 0
        fi
        if ! state_original_ref_is_valid "$original_ref" || [[ ! -e "$original_ref" && ! -L "$original_ref" ]]; then
            warn "Cannot restore missing ${label}; original backup is unavailable: ${original_ref:-<missing>}"
            return 1
        fi
        mkdir -p "$(dirname "$path")"
        cp -a -- "$original_ref" "$path"
        ok "Restored original ${label}: ${path}"
        return 0
    fi

    if ! managed_resource_matches "$path" "$expected_sha256"; then
        warn "Preserving ${path}; current ${label} does not match the managed checksum."
        return 1
    fi

    if [[ "$original_ref" == "$STATE_ABSENT" ]]; then
        remove_managed_file "$path"
        return 0
    fi

    if ! state_original_ref_is_valid "$original_ref" || [[ ! -e "$original_ref" && ! -L "$original_ref" ]]; then
        warn "Preserving ${path}; original backup is unavailable: ${original_ref:-<missing>}"
        return 1
    fi

    backup_path "$path" "before restoring original ${label}"
    rm -f -- "$path"
    mkdir -p "$(dirname "$path")"
    cp -a -- "$original_ref" "$path"
    ok "Restored original ${label}: ${path}"
}

transaction_snapshot_path() {
    local label="$1" path="$2" snapshot
    snapshot="${TRANSACTION_DIR}/files/${label}"
    TXN_PATHS["$label"]="$path"
    TXN_SNAPSHOTS["$label"]="$snapshot"
    if [[ -e "$path" || -L "$path" ]]; then
        TXN_EXISTED["$label"]=1
        cp -a -- "$path" "$snapshot"
    else
        TXN_EXISTED["$label"]=0
    fi
}

transaction_restore_path() {
    local label="$1" path snapshot
    path="${TXN_PATHS[$label]}"
    snapshot="${TXN_SNAPSHOTS[$label]}"
    if [[ -d "$path" && ! -L "$path" ]]; then
        warn "Rollback cannot replace unexpected directory at file path: $path"
        return 1
    fi
    rm -f -- "$path"
    if [[ "${TXN_EXISTED[$label]}" == "1" ]]; then
        mkdir -p "$(dirname "$path")"
        cp -a -- "$snapshot" "$path"
    fi
}

begin_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "0" ]] || die "Internal error: transaction already active"
    mkdir -p "$TMP_BUILD_DIR"
    TRANSACTION_DIR="$(mktemp -d -p "$TMP_BUILD_DIR" naivecd-transaction.XXXXXX)"
    register_tmp "$TRANSACTION_DIR"
    mkdir -p "${TRANSACTION_DIR}/files"
    TXN_PATHS=()
    TXN_EXISTED=()
    TXN_SNAPSHOTS=()

    transaction_snapshot_path caddy_bin "$CADDY_BIN"
    transaction_snapshot_path caddyfile "$CADDYFILE"
    transaction_snapshot_path systemd_unit "$SYSTEMD_UNIT"
    transaction_snapshot_path credentials "$CRED_FILE"
    transaction_snapshot_path client_config "$CLIENT_CONFIG"
    transaction_snapshot_path singbox_config "$SINGBOX_CONFIG"
    transaction_snapshot_path managed_state "$STATE_FILE"

    TXN_CADDY_DIR_EXISTED=0
    if [[ -d "$CADDY_DIR" && ! -L "$CADDY_DIR" ]]; then
        TXN_CADDY_DIR_EXISTED=1
        TXN_CADDY_DIR_UID="$(stat -c '%u' -- "$CADDY_DIR")"
        TXN_CADDY_DIR_GID="$(stat -c '%g' -- "$CADDY_DIR")"
        TXN_CADDY_DIR_MODE="$(stat -c '%a' -- "$CADDY_DIR")"
    fi

    TXN_STATIC_ROOT_EXISTED=0
    TXN_STATIC_BASE_EXISTED=0
    TXN_STATIC_BASE=""
    if [[ "$COVER_MODE" == "static" ]]; then
        transaction_snapshot_path static_index "${STATIC_ROOT}/index.html"
        [[ -d "$STATIC_ROOT" ]] && TXN_STATIC_ROOT_EXISTED=1
        if [[ "$STATIC_ROOT" == /var/www/* ]]; then
            TXN_STATIC_BASE="/var/www"
        else
            TXN_STATIC_BASE="/srv"
        fi
        [[ -d "$TXN_STATIC_BASE" ]] && TXN_STATIC_BASE_EXISTED=1
    fi

    systemctl is-active --quiet caddy 2>/dev/null && TXN_SERVICE_ACTIVE=1 || TXN_SERVICE_ACTIVE=0
    systemctl is-enabled --quiet caddy 2>/dev/null && TXN_SERVICE_ENABLED=1 || TXN_SERVICE_ENABLED=0
    TRANSACTION_ACTIVE=1
    log "Installation transaction started; failures will restore the previous state."
}

rollback_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "1" ]] || return 0
    TRANSACTION_ACTIVE=0
    local rollback_failed=0 label
    warn "Rolling back incomplete installation..."

    systemctl stop caddy 2>/dev/null || true
    for label in caddy_bin caddyfile systemd_unit credentials client_config singbox_config managed_state; do
        transaction_restore_path "$label" || rollback_failed=1
    done
    if [[ -n "${TXN_PATHS[static_index]:-}" ]]; then
        transaction_restore_path static_index || rollback_failed=1
    fi

    if [[ "$TXN_STATIC_ROOT_EXISTED" == "0" && -n "${STATIC_ROOT:-}" && -d "$STATIC_ROOT" ]]; then
        rmdir "$STATIC_ROOT" 2>/dev/null || true
    fi
    if [[ "$TXN_STATIC_BASE_EXISTED" == "0" && -n "$TXN_STATIC_BASE" && -d "$TXN_STATIC_BASE" ]]; then
        rmdir "$TXN_STATIC_BASE" 2>/dev/null || true
    fi

    if [[ "$TXN_CADDY_DIR_EXISTED" == "1" && -d "$CADDY_DIR" ]]; then
        chown "${TXN_CADDY_DIR_UID}:${TXN_CADDY_DIR_GID}" "$CADDY_DIR" || rollback_failed=1
        chmod "$TXN_CADDY_DIR_MODE" "$CADDY_DIR" || rollback_failed=1
    elif [[ "$TXN_CADDY_DIR_EXISTED" == "0" && -d "$CADDY_DIR" ]]; then
        rmdir "$CADDY_DIR" 2>/dev/null || true
    fi

    systemctl daemon-reload 2>/dev/null || rollback_failed=1
    if [[ "$TXN_SERVICE_ENABLED" == "1" ]] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        systemctl enable caddy >/dev/null 2>&1 || rollback_failed=1
    else
        systemctl disable caddy >/dev/null 2>&1 || true
    fi
    if [[ "$TXN_SERVICE_ACTIVE" == "1" ]] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        systemctl start caddy || rollback_failed=1
    else
        systemctl stop caddy 2>/dev/null || true
    fi

    if (( rollback_failed == 0 )); then
        ok "Previous installation state restored."
    else
        PRESERVE_TRANSACTION_DIR=1
        err "Rollback was incomplete. Inspect ${TRANSACTION_DIR} and system logs before retrying."
    fi
}

commit_transaction() {
    [[ "$TRANSACTION_ACTIVE" == "1" ]] || die "Internal error: no active transaction to commit"
    TRANSACTION_ACTIVE=0
    if [[ "$TRANSACTION_DIR" == "${TMP_BUILD_DIR}/naivecd-transaction."* ]]; then
        rm -rf -- "$TRANSACTION_DIR"
    fi
    TRANSACTION_DIR=""
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

    [[ "$STATE_LOADED" == "1" ]] \
        || die "Cannot uninstall safely: managed-state is missing, invalid, or from an unsupported format. Preserve resources and inspect ${STATE_FILE} manually."

    local static_root_to_review="${STATE_STATIC_ROOT:-}"
    local runtime_safe=1 runtime_managed=0 uninstall_incomplete=0 runtime_restore_ok=1

    if [[ "$MANAGED_CADDY_BIN" == "1" ]]; then
        runtime_managed=1
        managed_resource_can_change "$CADDY_BIN" "$STATE_CADDY_BIN_SHA256" "$STATE_CADDY_BIN_ORIGINAL" \
            || runtime_safe=0
    fi
    if [[ "$MANAGED_SYSTEMD_UNIT" == "1" ]]; then
        runtime_managed=1
        managed_resource_can_change "$SYSTEMD_UNIT" "$STATE_SYSTEMD_UNIT_SHA256" "$STATE_SYSTEMD_UNIT_ORIGINAL" 1 \
            || runtime_safe=0
    fi
    if [[ "$MANAGED_CADDYFILE" == "1" ]]; then
        runtime_managed=1
        managed_resource_can_change "$CADDYFILE" "$STATE_CADDYFILE_SHA256" "$STATE_CADDYFILE_ORIGINAL" 1 \
            || runtime_safe=0
    fi

    echo >&2
    warn "Uninstall restores pre-existing resources and removes only unchanged naivecd-managed files." >&2
    echo >&2

    local any=0
    warn "Restore or remove when unchanged:" >&2
    if (( runtime_managed == 1 )); then
        printf '  %-10s %s\n' "runtime" "Caddy binary, unit, and Caddyfile as one safety bundle" >&2
        any=1
        if (( runtime_safe == 0 )); then
            warn "The Caddy runtime bundle has changed or lost an original backup; it will be preserved." >&2
        fi
    fi
    [[ "$MANAGED_CRED_FILE" == "1" ]] && { printf '  %-10s %s\n' "config" "$CRED_FILE" >&2; any=1; }
    [[ "$MANAGED_CLIENT_CONFIG" == "1" ]] && { printf '  %-10s %s\n' "client" "$CLIENT_CONFIG" >&2; any=1; }
    [[ "$MANAGED_SINGBOX_CONFIG" == "1" ]] && { printf '  %-10s %s\n' "client" "$SINGBOX_CONFIG" >&2; any=1; }
    [[ -e "$STATE_FILE" ]] && { printf '  %-10s %s\n' "state" "$STATE_FILE" >&2; any=1; }
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

    echo >&2
    warn "Keep:" >&2
    printf '  %-10s %s\n' "data" "$CADDY_STATE_DIR" >&2
    printf '  %-10s %s\n' "custom" "modified or unverifiable Caddy/static/client files" >&2
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

    if (( runtime_managed == 1 && runtime_safe == 1 )) && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        log "Stopping and disabling caddy.service..."
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy >/dev/null 2>&1 || true
    elif (( runtime_managed == 1 )); then
        warn "Preserving the running Caddy service because the runtime bundle is not safe to restore."
        uninstall_incomplete=1
    fi

    log "Restoring or removing managed resources..."
    if (( runtime_managed == 1 && runtime_safe == 1 )); then
        if [[ "$MANAGED_CADDY_BIN" == "1" ]]; then
            restore_or_remove_managed_resource "$CADDY_BIN" "$STATE_CADDY_BIN_SHA256" "$STATE_CADDY_BIN_ORIGINAL" "Caddy binary" \
                || runtime_restore_ok=0
        fi
        if [[ "$MANAGED_CADDYFILE" == "1" ]]; then
            restore_or_remove_managed_resource "$CADDYFILE" "$STATE_CADDYFILE_SHA256" "$STATE_CADDYFILE_ORIGINAL" "Caddyfile" \
                || runtime_restore_ok=0
        fi
        if [[ "$MANAGED_SYSTEMD_UNIT" == "1" ]]; then
            restore_or_remove_managed_resource "$SYSTEMD_UNIT" "$STATE_SYSTEMD_UNIT_SHA256" "$STATE_SYSTEMD_UNIT_ORIGINAL" "systemd unit" \
                || runtime_restore_ok=0
        fi
        (( runtime_restore_ok == 1 )) || uninstall_incomplete=1
    fi

    if [[ "$MANAGED_CRED_FILE" == "1" ]]; then
        if managed_resource_can_change "$CRED_FILE" "$STATE_CRED_FILE_SHA256" "$STATE_CRED_FILE_ORIGINAL" 1; then
            restore_or_remove_managed_resource "$CRED_FILE" "$STATE_CRED_FILE_SHA256" "$STATE_CRED_FILE_ORIGINAL" "credentials file" \
                || uninstall_incomplete=1
        else
            warn "Preserving ${CRED_FILE}; it changed or its original backup is unavailable."
            uninstall_incomplete=1
        fi
    fi
    if [[ "$MANAGED_CLIENT_CONFIG" == "1" ]]; then
        if managed_resource_can_change "$CLIENT_CONFIG" "$STATE_CLIENT_CONFIG_SHA256" "$STATE_CLIENT_CONFIG_ORIGINAL"; then
            restore_or_remove_managed_resource "$CLIENT_CONFIG" "$STATE_CLIENT_CONFIG_SHA256" "$STATE_CLIENT_CONFIG_ORIGINAL" "Naive client config" \
                || uninstall_incomplete=1
        else
            warn "Preserving ${CLIENT_CONFIG}; it changed or its original backup is unavailable."
            uninstall_incomplete=1
        fi
    fi
    if [[ "$MANAGED_SINGBOX_CONFIG" == "1" ]]; then
        if managed_resource_can_change "$SINGBOX_CONFIG" "$STATE_SINGBOX_CONFIG_SHA256" "$STATE_SINGBOX_CONFIG_ORIGINAL"; then
            restore_or_remove_managed_resource "$SINGBOX_CONFIG" "$STATE_SINGBOX_CONFIG_SHA256" "$STATE_SINGBOX_CONFIG_ORIGINAL" "sing-box config" \
                || uninstall_incomplete=1
        else
            warn "Preserving ${SINGBOX_CONFIG}; it changed or its original backup is unavailable."
            uninstall_incomplete=1
        fi
    fi

    if [[ "$MANAGED_STATIC_INDEX" == "1" && -n "$static_root_to_review" ]]; then
        local static_index="${static_root_to_review}/index.html"
        if [[ -e "$static_index" || -L "$static_index" ]]; then
            if managed_resource_matches "$static_index" "$STATE_STATIC_INDEX_SHA256"; then
                remove_managed_file "$static_index"
            else
                warn "Preserving ${static_index}; it has been modified or lacks a managed checksum."
                uninstall_incomplete=1
            fi
        fi
    fi

    if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" && -n "$static_root_to_review" && -d "$static_root_to_review" ]]; then
        if rmdir "$static_root_to_review" 2>/dev/null; then
            ok "Removed empty managed static root ${static_root_to_review}"
        else
            warn "Preserving ${static_root_to_review}; it is not empty."
            uninstall_incomplete=1
        fi
    fi

    if (( runtime_managed == 1 && runtime_safe == 1 && runtime_restore_ok == 1 )); then
        systemctl daemon-reload
        if [[ "$STATE_ORIGINAL_SERVICE_ENABLED" == "1" ]] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
            systemctl enable caddy >/dev/null 2>&1 || uninstall_incomplete=1
        else
            systemctl disable caddy >/dev/null 2>&1 || true
        fi
        if [[ "$STATE_ORIGINAL_SERVICE_ACTIVE" == "1" ]] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
            systemctl start caddy || uninstall_incomplete=1
        else
            systemctl stop caddy 2>/dev/null || true
        fi
        systemctl reset-failed caddy.service >/dev/null 2>&1 || true
    fi

    if (( uninstall_incomplete == 0 )); then
        remove_managed_file "$STATE_FILE"
    else
        warn "Preserving ${STATE_FILE}; unresolved managed resources still require manual review."
    fi

    if (( uninstall_incomplete == 0 )) && [[ "$MANAGED_CADDY_DIR_CREATED" == "1" && -d "$CADDY_DIR" ]]; then
        if rmdir "$CADDY_DIR" 2>/dev/null; then
            ok "Removed empty managed Caddy config directory ${CADDY_DIR}"
        else
            warn "Preserving ${CADDY_DIR}; it is not empty."
        fi
    fi

    if [[ "$MANAGED_GO" == "1" && -d "${GO_INSTALL_DIR}" ]]; then
        warn "Preserving managed Go toolchain at ${GO_INSTALL_DIR}; remove it manually if it is no longer needed."
    fi

    if (( uninstall_incomplete == 0 )); then
        ok "Uninstall complete."
    else
        warn "Uninstall completed partially; modified or unverifiable resources were preserved."
    fi
    log "Backup saved to: ${BACKUP_SESSION_DIR}"
}

handle_existing_caddy() {
    # Returns mode via stdout: "rebuild" | "reconfigure" | "show" | "uninstall" | "fresh"
    if [[ ! -x "$CADDY_BIN" ]] && ! systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        echo "fresh"
        return 0
    fi

    local service_status="not installed"
    if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
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
    echo "  2) Reconfigure" >&2
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
        read -r -p "$prompt" choice </dev/tty
        case "$choice" in
            1) echo "rebuild";     return 0 ;;
            2) echo "reconfigure"; return 0 ;;
            3)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    echo "show"
                    return 0
                else
                    echo "uninstall"
                    return 0
                fi
                ;;
            4)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    echo "uninstall"
                    return 0
                else
                    die "Exited by user choice."
                fi
                ;;
            5)
                if [[ "$has_saved_config" -eq 1 ]]; then
                    die "Exited by user choice."
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
    path_has_symlink_component "$STATIC_ROOT" \
        && die "Static site root must not contain symbolic-link components: $STATIC_ROOT"
    STATIC_ROOT="$(realpath -m -- "$STATIC_ROOT")"
    [[ "$STATIC_ROOT" == /var/www/* || "$STATIC_ROOT" == /srv/* ]] \
        || die "Static site root must resolve under /var/www/ or /srv/: $STATIC_ROOT"

    local base parent
    if [[ "$STATIC_ROOT" == /var/www/* ]]; then
        base="/var/www"
    else
        base="/srv"
    fi
    parent="$(dirname "$STATIC_ROOT")"
    if [[ "$parent" != "$base" && ! -d "$parent" ]]; then
        die "Static site parent directory must already exist so its ownership can be verified: $parent"
    fi
}

path_has_symlink_component() {
    local path="$1" current="" part
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        current="${current}/${part}"
        [[ -L "$current" ]] && return 0
    done
    return 1
}

assert_secure_static_directories() {
    local path="$1" current="" part owner mode
    local -a parts=()
    IFS='/' read -r -a parts <<< "${path#/}"
    for part in "${parts[@]}"; do
        [[ -n "$part" ]] || continue
        current="${current}/${part}"
        [[ -e "$current" ]] || continue
        [[ -d "$current" && ! -L "$current" ]] \
            || die "Static site path component must be a real directory: $current"
        owner="$(stat -c '%u' -- "$current")"
        mode="$(stat -c '%a' -- "$current")"
        [[ "$owner" == "0" ]] \
            || die "Static site path component must be owned by root: $current"
        (( (8#$mode & 0022) == 0 )) \
            || die "Static site path component must not be group/other writable: $current (mode $mode)"
    done
}

validate_static_root_runtime_security() {
    local index="${STATIC_ROOT}/index.html" owner mode unsafe_entry unsafe_mount
    require_cmd runuser
    require_cmd find
    require_cmd mountpoint
    path_has_symlink_component "$STATIC_ROOT" \
        && die "Static site root gained a symbolic-link component: $STATIC_ROOT"
    assert_secure_static_directories "$STATIC_ROOT"

    unsafe_entry="$(find -P "$STATIC_ROOT" -xdev \
        \( -type l -o \( -type d ! -user root \) -o \( -type d -perm /022 \) \
        -o \( ! -type d ! -type f \) \) -print -quit)"
    [[ -z "$unsafe_entry" ]] \
        || die "Static site tree contains a symlink, special file, or writable/non-root directory: $unsafe_entry"
    unsafe_mount="$(find -P "$STATIC_ROOT" -xdev -mindepth 1 -type d \
        -exec mountpoint -q -- {} \; -print -quit)"
    [[ -z "$unsafe_mount" ]] \
        || die "Static site tree contains a nested mount point that could escape the intended root: $unsafe_mount"

    if [[ -e "$index" || -L "$index" ]]; then
        [[ ! -L "$index" ]] || die "Refusing symbolic-link static index: $index"
        [[ -f "$index" ]] || die "Static index must be a regular file: $index"
        owner="$(stat -c '%u' -- "$index")"
        mode="$(stat -c '%a' -- "$index")"
        [[ "$owner" == "0" ]] || die "Existing static index must be owned by root: $index"
        (( (8#$mode & 0022) == 0 )) \
            || die "Existing static index must not be group/other writable: $index (mode $mode)"
    fi

    runuser -u "$CADDY_USER" -- test -x "$STATIC_ROOT" \
        || die "Caddy user cannot traverse static root: $STATIC_ROOT"
    if [[ -f "$index" ]]; then
        runuser -u "$CADDY_USER" -- test -r "$index" \
            || die "Caddy user cannot read existing static index: $index"
    fi
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
    apt-get update -qq
    apt-get install -y -qq "${missing[@]}" >/dev/null
    ok "apt dependencies installed"
}

ensure_caddy_account() {
    log "Preparing dedicated Caddy runtime account..."
    if ! getent group "$CADDY_GROUP" >/dev/null 2>&1; then
        groupadd --system "$CADDY_GROUP"
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

    tar -C /usr/local -xzf "$tarball_path"
    rm -rf "$download_dir"

    export PATH="${GO_INSTALL_DIR}/bin:$PATH"
    MANAGED_GO=1
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
    if systemctl is-active --quiet caddy 2>/dev/null; then
        log "Stopping running caddy.service before binary swap..."
        systemctl stop caddy
    fi
    backup_and_record_original "$CADDY_BIN" STATE_CADDY_BIN_ORIGINAL "before Caddy binary replacement" \
        "$STATE_CADDY_BIN_SHA256" "$MANAGED_CADDY_BIN" "Caddy binary"
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    require_installed_caddy_forwardproxy \
        "continue after installing Caddy" \
        "Retry reinstall/source build with a Naive-capable Caddy."
    rm -f "$BUILT_CADDY_BIN"
    MANAGED_CADDY_BIN=1
    STATE_CADDY_BIN_SHA256="$(file_sha256 "$CADDY_BIN")"
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

generate_credentials() {
    log "Generating credentials..."
    NAIVE_USER="$(random_alnum)"
    NAIVE_PASS="$(random_alnum)"
    [[ ${#NAIVE_USER} -eq 16 && ${#NAIVE_PASS} -eq 16 ]] \
        || die "Failed to generate credentials"
    ok "Credentials generated"
}

write_static_cover_site() {
    [[ "$COVER_MODE" == "static" ]] || return 0
    local public_origin="https://${DOMAIN}" base index tmp
    log "Preparing local static cover site at ${STATIC_ROOT}..."
    if [[ "$NAIVE_PORT" != "443" ]]; then
        public_origin="https://${DOMAIN}:${NAIVE_PORT}"
    fi
    if [[ -n "$STATE_STATIC_ROOT" && "$STATE_STATIC_ROOT" != "$STATIC_ROOT" ]]; then
        MANAGED_STATIC_ROOT_CREATED=0
        MANAGED_STATIC_INDEX=0
        STATE_STATIC_INDEX_SHA256=""
    fi
    if [[ ! -d "$STATIC_ROOT" ]]; then
        MANAGED_STATIC_ROOT_CREATED=1
    fi
    if [[ "$STATIC_ROOT" == /var/www/* ]]; then
        base="/var/www"
    else
        base="/srv"
    fi
    if [[ ! -d "$base" ]]; then
        install -d -o root -g root -m 0755 "$base"
    fi
    assert_secure_static_directories "$(dirname "$STATIC_ROOT")"
    if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" ]]; then
        install -d -o root -g "$CADDY_GROUP" -m 0750 "$STATIC_ROOT"
    fi
    validate_static_root_runtime_security

    index="${STATIC_ROOT}/index.html"
    if [[ ! -e "$index" && ! -L "$index" ]]; then
        tmp="$(mktemp "${STATIC_ROOT}/.index.html.XXXXXX")"
        cat > "$tmp" <<EOF
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
        chown "root:$CADDY_GROUP" "$tmp"
        chmod 0640 "$tmp"
        mv -- "$tmp" "$index"
        MANAGED_STATIC_INDEX=1
        STATE_STATIC_ROOT="$STATIC_ROOT"
        STATE_STATIC_INDEX_SHA256="$(file_sha256 "$index")"
        ok "Default index.html written"
    else
        STATE_STATIC_ROOT="$STATIC_ROOT"
        ok "Existing index.html preserved"
    fi
    validate_static_root_runtime_security
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    local tmp
    if [[ ! -d "$CADDY_DIR" ]]; then
        MANAGED_CADDY_DIR_CREATED=1
    fi
    mkdir -p "$CADDY_DIR"
    chgrp "$CADDY_GROUP" "$CADDY_DIR"
    chmod u+rwx,g+rx "$CADDY_DIR"
    tmp="$(mktemp "${CADDYFILE}.XXXXXX")"
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
    chown "root:$CADDY_GROUP" "$tmp"
    chmod 0640 "$tmp"
    if ! "$CADDY_BIN" validate --config "$tmp"; then
        rm -f -- "$tmp"
        die "Generated Caddyfile failed validation; existing ${CADDYFILE} was left unchanged."
    fi
    backup_and_record_original "$CADDYFILE" STATE_CADDYFILE_ORIGINAL "before Caddyfile replacement" \
        "$STATE_CADDYFILE_SHA256" "$MANAGED_CADDYFILE" "Caddyfile"
    mv "$tmp" "$CADDYFILE"
    MANAGED_CADDYFILE=1
    STATE_CADDYFILE_SHA256="$(file_sha256 "$CADDYFILE")"
    ok "Caddyfile written"
}


write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    backup_and_record_original "$SYSTEMD_UNIT" STATE_SYSTEMD_UNIT_ORIGINAL "before systemd unit replacement" \
        "$STATE_SYSTEMD_UNIT_SHA256" "$MANAGED_SYSTEMD_UNIT" "systemd unit"
    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy
# Managed by naivecd. The installer may replace this unit during reconfiguration.
After=network.target network-online.target
Requires=network-online.target

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
    chown root:root "$SYSTEMD_UNIT"
    chmod 0644 "$SYSTEMD_UNIT"
    MANAGED_SYSTEMD_UNIT=1
    STATE_SYSTEMD_UNIT_SHA256="$(file_sha256 "$SYSTEMD_UNIT")"
    systemctl daemon-reload
    ok "systemd unit written"
}

start_caddy() {
    log "Enabling and starting caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    if ! systemctl restart caddy; then
        err "caddy.service failed to restart. Last 50 log lines:"
        journalctl -u caddy -n 50 --no-pager >&2
        die "Aborting. Inspect logs above (often: invalid config, ACME error, port conflict, DNS misconfig)."
    fi
}

wait_for_caddy_active() {
    log "Waiting for Caddy to become active and obtain TLS certificate..."
    local i=0
    while (( i < 60 )); do
        if systemctl is-active --quiet caddy; then
            # Systemd reports active even before ACME finishes — probe TLS to confirm
            # cert issued. Drop -f so HTTP 4xx/5xx from the mask reverse_proxy still
            # counts as a successful TLS handshake.
            if curl -sS --max-time 5 -o /dev/null "https://${DOMAIN}:${NAIVE_PORT}" 2>/dev/null; then
                ok "Caddy is active and TLS endpoint responding"
                return 0
            fi
        elif systemctl is-failed --quiet caddy; then
            err "caddy.service failed. Last 50 log lines:"
            journalctl -u caddy -n 50 --no-pager >&2
            die "Aborting. Inspect logs above (often: ACME error, port conflict, DNS misconfig)."
        fi
        sleep 2
        # Pre-increment: returns the NEW value (never 0 here), so it can't trip
        # `set -e` on iteration 1 the way `((i++))` would (post-increment returns
        # the OLD value 0 → exit 1 → script dies silently before cert arrives).
        ((++i))
    done
    warn "Caddy did not respond on https://${DOMAIN}:${NAIVE_PORT} within 120s."
    warn "Recent logs:"
    journalctl -u caddy -n 30 --no-pager >&2
    confirm "Continue anyway (cert may still be issuing)" default-no \
        || die "Aborted. Run 'journalctl -u caddy -f' to debug."
}

#─────────────────────────────────────────────────────────────────────────────
# Output
#─────────────────────────────────────────────────────────────────────────────

save_credentials_file() {
    backup_and_record_original "$CRED_FILE" STATE_CRED_FILE_ORIGINAL "before credentials replacement" \
        "$STATE_CRED_FILE_SHA256" "$MANAGED_CRED_FILE" "credentials file"
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
    STATE_CRED_FILE_SHA256="$(file_sha256 "$CRED_FILE")"
}

write_client_config() {
    backup_and_record_original "$CLIENT_CONFIG" STATE_CLIENT_CONFIG_ORIGINAL "before client config replacement" \
        "$STATE_CLIENT_CONFIG_SHA256" "$MANAGED_CLIENT_CONFIG" "Naive client config"
    cat > "$CLIENT_CONFIG" <<EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:${NAIVE_PORT}"
}
EOF
    chown root:root "$CLIENT_CONFIG"
    chmod 600 "$CLIENT_CONFIG"
    MANAGED_CLIENT_CONFIG=1
    STATE_CLIENT_CONFIG_SHA256="$(file_sha256 "$CLIENT_CONFIG")"
}

write_singbox_config() {
    backup_and_record_original "$SINGBOX_CONFIG" STATE_SINGBOX_CONFIG_ORIGINAL "before sing-box config replacement" \
        "$STATE_SINGBOX_CONFIG_SHA256" "$MANAGED_SINGBOX_CONFIG" "sing-box config"
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
    STATE_SINGBOX_CONFIG_SHA256="$(file_sha256 "$SINGBOX_CONFIG")"
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
    ARCH="$(detect_arch)"
    ok "Architecture: $ARCH"

    if [[ -x "$CADDY_BIN" ]] || systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        MODE="$(handle_existing_caddy)"
    else
        log "Install NaiveProxy with Caddy on this server."
        confirm "Continue" default-no || die "Aborted by user."
        MODE="fresh"
    fi
    log "Install mode: $MODE"

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
    record_original_service_state

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

    ensure_caddy_account
    check_ports

    if [[ "$MODE" == "rebuild" || "$MODE" == "fresh" ]]; then
        prepare_caddy_binary
    fi

    begin_transaction

    if [[ "$MODE" == "rebuild" || "$MODE" == "fresh" ]]; then
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

    print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
