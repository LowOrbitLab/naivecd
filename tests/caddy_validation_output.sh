#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_SCRIPT="${TEST_ROOT}/install-test.sh"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

sed \
    -e "s|readonly CADDY_BIN=.*|readonly CADDY_BIN=\"${TEST_ROOT}/usr/bin/caddy\"|" \
    -e "s|readonly CADDY_DIR=.*|readonly CADDY_DIR=\"${TEST_ROOT}/etc/caddy\"|" \
    -e "s|readonly BACKUP_ROOT=.*|readonly BACKUP_ROOT=\"${TEST_ROOT}/backups\"|" \
    "$PROJECT_ROOT/install.sh" > "$TEST_SCRIPT"

export NAIVECD_LIB_ONLY=1
# shellcheck disable=SC1090
source "$TEST_SCRIPT"

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

success_output="$(write_caddyfile 2>&1)"
[[ "$success_output" == *"Caddy configuration is valid"* ]]
[[ "$success_output" != *"noisy validation log"* ]]
[[ -s "$CADDYFILE" ]]

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
