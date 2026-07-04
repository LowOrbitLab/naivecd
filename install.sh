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
readonly PREBUILT_CADDY_URL="https://github.com/klzgrad/forwardproxy/releases/latest/download/caddy-forwardproxy-naive.tar.xz"
readonly CADDY_BIN="/usr/bin/caddy"
readonly CADDY_DIR="/etc/caddy"
readonly CADDYFILE="${CADDY_DIR}/Caddyfile"
readonly CRED_FILE="${CADDY_DIR}/credentials.txt"
readonly CLIENT_CONFIG="/root/naive-client-config.json"
readonly SINGBOX_CONFIG="/root/naive-singbox.json"
readonly SYSTEMD_UNIT="/etc/systemd/system/caddy.service"
readonly TMP_BUILD_DIR="/root/tmp"
readonly GO_INSTALL_DIR="/usr/local/go"

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

uninstall_caddy_naive() {
    local static_root_to_remove=""
    if [[ -s "$CADDYFILE" ]]; then
        static_root_to_remove="$(awk '/^[[:space:]]*root[[:space:]]+\*[[:space:]]/ {print $3; exit}' "$CADDYFILE")"
    fi
    static_root_to_remove="${static_root_to_remove:-$DEFAULT_STATIC_ROOT}"

    echo >&2
    warn "This will remove:" >&2
    echo "    - caddy.service" >&2
    echo "    - ${CADDY_BIN}" >&2
    echo "    - ${CADDY_DIR}/" >&2
    echo "    - generated client configs" >&2
    echo "    - ${static_root_to_remove}" >&2
    echo >&2
warn "Not managed by this script (yours to handle):" >&2
    echo "    - DNS records / firewall rules (never touched by this script)" >&2
    echo >&2

    local go_managed="no"
    if [[ -x "${GO_INSTALL_DIR}/bin/go" ]]; then
        warn "Found Go toolchain at ${GO_INSTALL_DIR}"
        echo "    (installed during source build if NAIVE_CADDY_INSTALL=build was used)" >&2
        if confirm "Remove Go too" default-no; then
            go_managed="yes"
        fi
    fi
    confirm "Continue uninstall" default-no || die "Aborted by user."

    if systemctl list-unit-files caddy.service >/dev/null 2>&1; then
        log "Stopping and disabling caddy.service..."
        systemctl stop caddy 2>/dev/null || true
        systemctl disable caddy >/dev/null 2>&1 || true
    fi

    log "Removing Caddy service, binary, and generated configs..."
    rm -f "$SYSTEMD_UNIT"
    rm -f "$CADDY_BIN"
    rm -rf "$CADDY_DIR"
    rm -f "$CLIENT_CONFIG" "$SINGBOX_CONFIG"
    systemctl daemon-reload
    systemctl reset-failed caddy.service >/dev/null 2>&1 || true

if [[ -d "$static_root_to_remove" ]]; then
        rm -rf "$static_root_to_remove"
        ok "Removed ${static_root_to_remove}"
    fi

    if [[ "$go_managed" == "yes" && -d "${GO_INSTALL_DIR}" ]]; then
        rm -rf "${GO_INSTALL_DIR}"
        ok "Removed ${GO_INSTALL_DIR}"
    fi

    ok "Uninstall complete."
}

handle_existing_caddy() {
    # Returns mode via stdout: "rebuild" | "reconfigure" | "reuse" | "uninstall" | "fresh"
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

    local has_caddyfile=0
    [[ -s "$CADDYFILE" ]] && has_caddyfile=1

    echo "" >&2
    echo "Choose action:" >&2
    echo "  1) Reinstall NaiveProxy" >&2
    echo "  2) Reconfigure" >&2
    if [[ "$has_caddyfile" -eq 1 ]]; then
        echo "  3) Show client config" >&2
        echo "  4) Uninstall" >&2
        echo "  5) Exit" >&2
    else
        echo "  3) Uninstall" >&2
        echo "  4) Exit" >&2
        echo "     (Show client config is unavailable: ${CADDYFILE} missing or empty)" >&2
    fi
    echo "" >&2

    local choice prompt
    if [[ "$has_caddyfile" -eq 1 ]]; then
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
                if [[ "$has_caddyfile" -eq 1 ]]; then
                    echo "reuse"
                    return 0
                else
                    echo "uninstall"
                    return 0
                fi
                ;;
            4)
                if [[ "$has_caddyfile" -eq 1 ]]; then
                    echo "uninstall"
                    return 0
                else
                    die "Exited by user choice."
                fi
                ;;
            5)
                if [[ "$has_caddyfile" -eq 1 ]]; then
                    die "Exited by user choice."
                else
                    echo "Invalid choice." >&2
                fi
                ;;
            *) echo "Invalid choice." >&2 ;;
        esac
    done
}

parse_existing_caddyfile() {
    # Populates DOMAIN, COVER_MODE, MASK_SITE/STATIC_ROOT, NAIVE_USER, NAIVE_PASS
    # from the existing Caddyfile. Expects a format this script writes.
    local f="$CADDYFILE"
    [[ -s "$f" ]] || die "Cannot reuse: ${f} missing or empty"

    DOMAIN="$(awk '/^:443,/ {sub(/^:443,[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit}' "$f")"
    MASK_SITE="$(awk '/^[[:space:]]*reverse_proxy[[:space:]]/ {print $2; exit}' "$f")"
    STATIC_ROOT="$(awk '/^[[:space:]]*root[[:space:]]+\*[[:space:]]/ {print $3; exit}' "$f")"

    if [[ -n "$MASK_SITE" ]]; then
        COVER_MODE="proxy"
    elif [[ -n "$STATIC_ROOT" ]]; then
        COVER_MODE="static"
    else
        die "Failed to parse cover mode from ${f} (expected 'reverse_proxy <url>' or 'root * <path>')"
    fi

    local creds_line
    creds_line="$(awk '/^[[:space:]]*basic_auth[[:space:]]/ {print $2, $3; exit}' "$f")"
    NAIVE_USER="${creds_line%% *}"
    NAIVE_PASS="${creds_line##* }"

    [[ -n "$DOMAIN"     ]] || die "Failed to parse domain from ${f} (expected ':443, <domain>' line)"
    [[ -n "$NAIVE_USER" && -n "$NAIVE_PASS" && "$NAIVE_USER" != "$NAIVE_PASS" ]] \
        || die "Failed to parse credentials from ${f} (expected 'basic_auth <user> <pass>' line)"
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

install_go() {
    local latest tarball url
    log "Resolving latest stable Go version..."
    latest="$(curl -fsS --max-time 10 https://go.dev/VERSION?m=text | head -n1)"
    [[ "$latest" =~ ^go[0-9] ]] || die "Could not resolve latest Go version (got: '$latest')"

    if [[ -x "${GO_INSTALL_DIR}/bin/go" ]]; then
        local current
        current="$("${GO_INSTALL_DIR}/bin/go" version | awk '{print $3}')"
        if [[ "$current" == "$latest" ]]; then
            ok "Go ${latest} already installed"
            export PATH="${GO_INSTALL_DIR}/bin:$PATH"
            return 0
        fi
        log "Replacing existing Go ${current} with ${latest}"
    fi

    tarball="${latest}.linux-${ARCH}.tar.gz"
    url="https://go.dev/dl/${tarball}"
    log "Downloading $url"
    wget -q --show-progress -O "/tmp/${tarball}" "$url"

    rm -rf "${GO_INSTALL_DIR}"
    tar -C /usr/local -xzf "/tmp/${tarball}"
    rm -f "/tmp/${tarball}"

    export PATH="${GO_INSTALL_DIR}/bin:$PATH"
    ok "Installed $(go version)"
}

verify_caddy_forwardproxy() {
    local bin="$1"
    [[ -x "$bin" ]] || return 1
    "$bin" list-modules 2>/dev/null | grep -Fxq 'http.handlers.forward_proxy'
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

    log "Downloading prebuilt Caddy with NaiveProxy support..."
    local download_dir archive extracted_bin
    mkdir -p "$TMP_BUILD_DIR"
    download_dir="$(mktemp -d -p "$TMP_BUILD_DIR" caddy-prebuilt.XXXXXX)"
    archive="${download_dir}/caddy-forwardproxy-naive.tar.xz"

    if ! wget -q -O "$archive" "$PREBUILT_CADDY_URL"; then
        warn "Prebuilt Caddy download failed; falling back to source build."
        rm -rf "$download_dir"
        return 1
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

    log "Installing xcaddy..."
    go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

    log "Building Caddy with klzgrad/forwardproxy@naive (this takes a few minutes)..."
    local build_dir
    build_dir="$(mktemp -d -p "$TMP_BUILD_DIR" caddy-build.XXXXXX)"
    pushd "$build_dir" >/dev/null
    "${GOPATH}/bin/xcaddy" build \
        --with github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive
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
    install -m 0755 "$BUILT_CADDY_BIN" "$CADDY_BIN"
    rm -f "$BUILT_CADDY_BIN"
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
    mkdir -p "$STATIC_ROOT"
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
        ok "Default index.html written"
    else
        ok "Existing index.html preserved"
    fi
}

write_caddyfile() {
    log "Writing ${CADDYFILE}..."
    mkdir -p "$CADDY_DIR"
    cat > "$CADDYFILE" <<EOF
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
    chmod 600 "$CADDYFILE"
    ok "Caddyfile written"
}


write_systemd_unit() {
    log "Writing ${SYSTEMD_UNIT}..."
    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=Caddy with NaiveProxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=root
Group=root
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
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
    cat > "$CRED_FILE" <<EOF
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
    chmod 600 "$CRED_FILE"
}

write_client_config() {
    cat > "$CLIENT_CONFIG" <<EOF
{
  "listen": "socks://127.0.0.1:10808",
  "proxy": "https://${NAIVE_USER}:${NAIVE_PASS}@${DOMAIN}"
}
EOF
    chmod 600 "$CLIENT_CONFIG"
}

write_singbox_config() {
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
    chmod 600 "$SINGBOX_CONFIG"
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

    if [[ "$MODE" == "uninstall" ]]; then
        uninstall_caddy_naive
        exit 0
    fi

    install_dependencies

    if [[ "$MODE" == "reuse" ]]; then
        parse_existing_caddyfile
        log "Reusing existing Caddyfile:"
        log "Domain      : $DOMAIN"
        log "Cover mode  : $COVER_MODE"
        if [[ "$COVER_MODE" == "static" ]]; then
            log "Static root : $STATIC_ROOT"
        else
            log "Cover site  : $MASK_SITE"
        fi
        log "User/pass   : preserved from existing config"
    else
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
        check_dns "$DOMAIN"
    fi

    check_ports

    if [[ "$MODE" == "rebuild" || "$MODE" == "fresh" ]]; then
        prepare_caddy_binary
        install_caddy_binary
    fi

    if [[ "$MODE" != "reuse" ]]; then
        generate_credentials
        write_static_cover_site
        write_caddyfile
    fi

    write_systemd_unit
    start_caddy
    wait_for_caddy_active

    save_credentials_file
    write_client_config
    write_singbox_config
    print_summary
}

main "$@"
