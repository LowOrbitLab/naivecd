#!/usr/bin/env bash
# NaiveProxy + Caddy auto-setup for Debian/Ubuntu VPS.
# Repository: https://github.com/LowOrbitLab/naivecd

set -euo pipefail

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
    local port busy_pid busy_proc
    require_cmd ss
    for port in 80 443; do
        busy_pid="$(ss -tlnpH "sport = :${port}" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -n1 || true)"
        if [[ -n "$busy_pid" ]]; then
            busy_proc="$(ps -p "$busy_pid" -o comm= 2>/dev/null || echo unknown)"
            warn "Port :$port is occupied by PID $busy_pid ($busy_proc)"
            if [[ "$busy_proc" == "caddy" ]]; then
                log "It's a previous Caddy process — will be replaced by systemd unit."
                continue
            fi
            confirm "Stop process $busy_proc (PID $busy_pid) and continue" default-no \
                || die "Aborted by user. Free port :$port manually and retry."
            kill "$busy_pid" 2>/dev/null || true
            sleep 2
            kill -9 "$busy_pid" 2>/dev/null || true
        fi
    done
    ok "Ports 80 and 443 are available"
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
            STATE_STATIC_INDEX_SHA256)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$STATE_FILE"

    [[ "$NAIVECD_MANAGED" == "1" ]] && STATE_LOADED=1
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
    warn "This will remove only managed resources:" >&2
    if [[ "$unit_managed" == "1" && -e "$SYSTEMD_UNIT" ]]; then
        echo "  Service:" >&2
        echo "    - ${SYSTEMD_UNIT}" >&2
        any=1
    fi
    if [[ "$MANAGED_CADDY_BIN" == "1" && -e "$CADDY_BIN" ]]; then
        echo "  Binary:" >&2
        echo "    - ${CADDY_BIN}" >&2
        any=1
    fi
    if [[ "$caddyfile_managed" == "1" || "$cred_managed" == "1" || -e "$STATE_FILE" ]]; then
        echo "  Config:" >&2
        if [[ "$caddyfile_managed" == "1" && -e "$CADDYFILE" ]]; then
            echo "    - ${CADDYFILE}" >&2
            any=1
        fi
        if [[ "$cred_managed" == "1" && -e "$CRED_FILE" ]]; then
            echo "    - ${CRED_FILE}" >&2
            any=1
        fi
        if [[ -e "$STATE_FILE" ]]; then
            echo "    - ${STATE_FILE}" >&2
            any=1
        fi
    fi
    if [[ "$MANAGED_CLIENT_CONFIG" == "1" || "$MANAGED_SINGBOX_CONFIG" == "1" ]]; then
        echo "  Client configs:" >&2
        if [[ "$MANAGED_CLIENT_CONFIG" == "1" && -e "$CLIENT_CONFIG" ]]; then
            echo "    - ${CLIENT_CONFIG}" >&2
            any=1
        fi
        if [[ "$MANAGED_SINGBOX_CONFIG" == "1" && -e "$SINGBOX_CONFIG" ]]; then
            echo "    - ${SINGBOX_CONFIG}" >&2
            any=1
        fi
    fi
    if [[ "$MANAGED_STATIC_INDEX" == "1" || "$MANAGED_STATIC_ROOT_CREATED" == "1" ]]; then
        echo "  Static cover:" >&2
        if [[ "$MANAGED_STATIC_INDEX" == "1" && -n "$static_root_to_review" ]]; then
            echo "    - ${static_root_to_review}/index.html, if unchanged from the installer placeholder" >&2
            any=1
        fi
        if [[ "$MANAGED_STATIC_ROOT_CREATED" == "1" && -n "$static_root_to_review" ]]; then
            echo "    - ${static_root_to_review}/, only if empty after the managed placeholder is removed" >&2
            any=1
        fi
    fi
    if [[ "$MANAGED_CADDY_DIR_CREATED" == "1" ]]; then
        echo "  Directories:" >&2
        echo "    - ${CADDY_DIR}/, only if empty after managed files are removed" >&2
        any=1
    fi

    echo >&2
    warn "Preserved by default:" >&2
    echo "    - unmarked Caddy files and custom/static site content" >&2
    echo "    - Caddy TLS state and certificates under ${CADDY_STATE_DIR}" >&2
    echo "    - Go toolchains, DNS records, and firewall rules" >&2
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

    if [[ "$unit_managed" == "1" ]] && systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        log "Stopping and disabling caddy.service..."
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy >/dev/null 2>&1 || true
    elif systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        warn "Preserving caddy.service because it is not marked as managed by naivecd."
    fi

    log "Removing managed resources..."
    [[ "$unit_managed" == "1" ]] && remove_managed_file "$SYSTEMD_UNIT"
    [[ "$MANAGED_CADDY_BIN" == "1" ]] && remove_managed_file "$CADDY_BIN"
    [[ "$caddyfile_managed" == "1" ]] && remove_managed_file "$CADDYFILE"
    [[ "$cred_managed" == "1" ]] && remove_managed_file "$CRED_FILE"
    [[ "$MANAGED_CLIENT_CONFIG" == "1" ]] && remove_managed_file "$CLIENT_CONFIG"
    [[ "$MANAGED_SINGBOX_CONFIG" == "1" ]] && remove_managed_file "$SINGBOX_CONFIG"

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
    fi

    if [[ "$MANAGED_GO" == "1" && -d "${GO_INSTALL_DIR}" ]]; then
        warn "Preserving managed Go toolchain at ${GO_INSTALL_DIR}; remove it manually if it is no longer needed."
    fi

    ok "Uninstall complete."
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
    [[ "$STATIC_ROOT" == /var/www/* || "$STATIC_ROOT" == /srv/* ]] \
        || die "Static site root must be under /var/www/ or /srv/: $STATIC_ROOT"
    [[ "$STATIC_ROOT" != *[[:space:]]* ]] \
        || die "Static site root must not contain whitespace: $STATIC_ROOT"
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
    backup_path "$CADDY_BIN" "before Caddy binary replacement"
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    require_installed_caddy_forwardproxy \
        "continue after installing Caddy" \
        "Retry reinstall/source build with a Naive-capable Caddy."
    rm -f "$BUILT_CADDY_BIN"
    MANAGED_CADDY_BIN=1
    ok "Installed: $($CADDY_BIN version | head -n1)"
}

generate_credentials() {
    log "Generating credentials..."
    NAIVE_USER="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    NAIVE_PASS="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    [[ ${#NAIVE_USER} -eq 16 && ${#NAIVE_PASS} -eq 16 ]] \
        || die "Failed to generate credentials"
    ok "Credentials generated"
}

write_static_cover_site() {
    [[ "$COVER_MODE" == "static" ]] || return 0
    log "Preparing local static cover site at ${STATIC_ROOT}..."
    if [[ -n "$STATE_STATIC_ROOT" && "$STATE_STATIC_ROOT" != "$STATIC_ROOT" ]]; then
        MANAGED_STATIC_ROOT_CREATED=0
        MANAGED_STATIC_INDEX=0
        STATE_STATIC_INDEX_SHA256=""
    fi
    if [[ ! -d "$STATIC_ROOT" ]]; then
        MANAGED_STATIC_ROOT_CREATED=1
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
    if [[ ! -e "${STATIC_ROOT}/index.html" ]]; then
        cat > "${STATIC_ROOT}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
  <style>
    body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #1f2933; background: #f7f7f5; }
    main { max-width: 760px; margin: 12vh auto; padding: 0 24px; }
    h1 { font-size: clamp(2rem, 5vw, 4rem); margin-bottom: 0.25em; }
    p { font-size: 1.1rem; line-height: 1.65; color: #52606d; }
  </style>
</head>
<body>
  <main>
    <h1>${DOMAIN}</h1>
    <p>This site is being set up. Please check back later.</p>
  </main>
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
            chgrp "$CADDY_GROUP" "${STATIC_ROOT}/index.html"
            chmod g+r "${STATIC_ROOT}/index.html"
        fi
        STATE_STATIC_ROOT="$STATIC_ROOT"
        ok "Existing index.html preserved"
    fi
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    if [[ ! -d "$CADDY_DIR" ]]; then
        MANAGED_CADDY_DIR_CREATED=1
    fi
    mkdir -p "$CADDY_DIR"
    chgrp "$CADDY_GROUP" "$CADDY_DIR"
    chmod u+rwx,g+rx "$CADDY_DIR"
    backup_path "$CADDYFILE" "before Caddyfile replacement"
    cat > "$CADDYFILE" <<EOF
# Managed by naivecd. The installer may replace this file during reconfiguration.
:443, ${DOMAIN}
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
        cat >> "$CADDYFILE" <<EOF
  root * ${STATIC_ROOT}
  file_server
EOF
    else
        cat >> "$CADDYFILE" <<EOF
  reverse_proxy ${MASK_SITE} {
    header_up Host {upstream_hostport}
    header_up X-Forwarded-Host {host}
  }
EOF
    fi
    cat >> "$CADDYFILE" <<EOF
}
EOF
    chown "root:$CADDY_GROUP" "$CADDYFILE"
    chmod 0640 "$CADDYFILE"
    MANAGED_CADDYFILE=1
    ok "Caddyfile written"
}


write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    backup_path "$SYSTEMD_UNIT" "before systemd unit replacement"
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
    systemctl daemon-reload
    ok "systemd unit written"
}

start_caddy() {
    log "Enabling and starting caddy.service..."
    systemctl enable caddy >/dev/null 2>&1
    systemctl restart caddy
}

wait_for_caddy_active() {
    log "Waiting for Caddy to become active and obtain TLS certificate..."
    local i=0
    while (( i < 60 )); do
        if systemctl is-active --quiet caddy; then
            # Systemd reports active even before ACME finishes — probe TLS to confirm
            # cert issued. Drop -f so HTTP 4xx/5xx from the mask reverse_proxy still
            # counts as a successful TLS handshake.
            if curl -sS --max-time 5 -o /dev/null "https://${DOMAIN}" 2>/dev/null; then
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
    warn "Caddy did not respond on https://${DOMAIN} within 120s."
    warn "Recent logs:"
    journalctl -u caddy -n 30 --no-pager >&2
    confirm "Continue anyway (cert may still be issuing)" default-no \
        || die "Aborted. Run 'journalctl -u caddy -f' to debug."
}

#─────────────────────────────────────────────────────────────────────────────
# Output
#─────────────────────────────────────────────────────────────────────────────

save_credentials_file() {
    backup_path "$CRED_FILE" "before credentials replacement"
    cat > "$CRED_FILE" <<EOF
# Managed by naivecd. This file contains generated NaiveProxy credentials.
# NaiveProxy credentials — generated $(date -Iseconds)
# Domain:     ${DOMAIN}
# Cover mode: ${COVER_MODE}
EOF
    if [[ "$COVER_MODE" == "static" ]]; then
        printf '# Static root: %s\n' "$STATIC_ROOT" >> "$CRED_FILE"
    else
        printf '# Mask site:   %s\n' "$MASK_SITE" >> "$CRED_FILE"
    fi
    cat >> "$CRED_FILE" <<EOF
NAIVE_USER='${NAIVE_USER}'
NAIVE_PASS='${NAIVE_PASS}'
NAIVE_URL='naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy'
EOF
    chown root:root "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    MANAGED_CRED_FILE=1
}

write_client_config() {
    backup_path "$CLIENT_CONFIG" "before client config replacement"
    cat > "$CLIENT_CONFIG" <<EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}"
}
EOF
    chown root:root "$CLIENT_CONFIG"
    chmod 600 "$CLIENT_CONFIG"
    MANAGED_CLIENT_CONFIG=1
}

write_singbox_config() {
    backup_path "$SINGBOX_CONFIG" "before sing-box config replacement"
    cat > "$SINGBOX_CONFIG" <<EOF
{
  "outbounds": [
    {
      "type": "naive",
      "tag": "NaiveProxy",
      "server": "${DOMAIN}",
      "server_port": 443,
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
    local uri="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}:443?padding=1#NaiveProxy"

    echo
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    printf '%s  NaiveProxy is up at https://%s%s\n' "$C_BOLD" "$DOMAIN" "$C_RST"
    printf '%s════════════════════════════════════════════════════════════════════%s\n' "$C_BOLD" "$C_RST"
    echo

    printf '%sCredentials%s\n' "$C_BOLD" "$C_RST"
    printf '  user: %s\n' "$NAIVE_USER"
    printf '  pass: %s\n' "$NAIVE_PASS"
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

    gather_inputs
    echo
    log "NaiveProxy setup summary:"
    log "Domain      : $DOMAIN"
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
        install_caddy_binary
    fi

    generate_credentials
    write_static_cover_site
    write_caddyfile

    write_systemd_unit
    write_managed_state
    start_caddy
    wait_for_caddy_active

    save_credentials_file
    write_client_config
    write_singbox_config
    write_managed_state
    print_summary
}

main "$@"
