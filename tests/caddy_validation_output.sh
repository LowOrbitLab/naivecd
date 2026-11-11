#!/usr/bin/env bash
# Tests for Caddyfile generation, OPSEC reverse-proxy headers, and validation output.
# shellcheck disable=SC2034,SC2329  # globals and mocks are consumed by sourced install.sh functions

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export NAIVECD_LIB_ONLY=1
export NAIVECD_TEST_ROOT="$TEST_ROOT"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/install.sh"

mkdir -p "$(dirname "$CADDY_BIN")" "$CADDY_DIR"
chown() { return 0; }
chgrp() { return 0; }

DOMAIN="proxy.example.com"
NAIVE_PORT=443
NAIVE_USER="testuser"
NAIVE_PASS="testpass"
COVER_MODE="static"
STATIC_ROOT="${TEST_ROOT}/var/www/cover"

cat > "$CADDY_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    fmt) exit 0 ;;
    validate)
        echo "INFO noisy validation log" >&2
        echo "Valid configuration"
        exit 0
        ;;
esac
EOF
chmod 0755 "$CADDY_BIN"

out_log="${TEST_ROOT}/caddyfile-out.log"
write_caddyfile >"$out_log" 2>&1
success_output="$(<"$out_log")"
[[ "$success_output" == *"Caddy configuration is valid"* ]]
[[ "$success_output" != *"noisy validation log"* ]]
[[ -s "$CADDYFILE" ]]
[[ "$STATE_DOMAIN" == "proxy.example.com" ]]
[[ "$STATE_NAIVE_PORT" == "443" ]]
[[ "$STATE_COVER_MODE" == "static" ]]
[[ -z "$STATE_MASK_SITE" ]]

# Verify reverse_proxy mode strips X-Forwarded-* headers so the proxy domain and
# probe client IP are never leaked to third-party cover origins.
COVER_MODE="proxy"
MASK_SITE="https://files.pythonhosted.org"
write_caddyfile >/dev/null 2>&1
caddyfile_body="$(<"$CADDYFILE")"
[[ "$caddyfile_body" == *"reverse_proxy https://files.pythonhosted.org"* ]]
[[ "$caddyfile_body" == *"header_up Host {upstream_hostport}"* ]]
[[ "$caddyfile_body" == *"header_up -X-Forwarded-For"* ]]
[[ "$caddyfile_body" == *"header_up -X-Forwarded-Host"* ]]
[[ "$caddyfile_body" == *"header_up -X-Forwarded-Proto"* ]]
[[ "$caddyfile_body" != *"X-Forwarded-Host {host}"* ]]
[[ "$STATE_COVER_MODE" == "proxy" ]]
[[ "$STATE_MASK_SITE" == "https://files.pythonhosted.org" ]]

printf 'original-config' > "$CADDYFILE"
cat > "$CADDY_BIN" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    fmt) exit 0 ;;
    validate)
        echo "synthetic validation failure" >&2
        exit 1
        ;;
esac
EOF
chmod 0755 "$CADDY_BIN"

if failure_output="$(write_caddyfile 2>&1)"; then
    echo "expected validation failure" >&2
    exit 1
fi
[[ "$failure_output" == *"synthetic validation failure"* ]]
[[ "$(<"$CADDYFILE")" == "original-config" ]]

printf 'caddy validation output tests passed\n'
