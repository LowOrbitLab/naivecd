#!/usr/bin/env bash
# Unit tests for pure library functions in install.sh (no root, no network).
#
# Assertions are single-quoted strings passed to `eval` in check(), so
# SC2016 (no expansion in single quotes) is intentional. Globals set here are
# consumed by sourced install.sh functions (SC2034), and mock overrides are
# invoked indirectly by those functions (SC2329).
# shellcheck disable=SC2016,SC2034,SC2329
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export NAIVECD_LIB_ONLY=1
export NAIVECD_TEST_ROOT="$TEST_ROOT"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/install.sh"

mkdir -p "$(dirname "$CRED_FILE")"

fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

# load_existing_credentials round-trips the values written by save_credentials_file.
printf "NAIVE_USER='abc123XYZ'\nNAIVE_PASS='pass456QRS'\n" > "$CRED_FILE"
NAIVE_USER=""; NAIVE_PASS=""
load_existing_credentials
check "load_existing_credentials parses quoted"      '[[ "$NAIVE_USER" == "abc123XYZ" && "$NAIVE_PASS" == "pass456QRS" ]]'
printf "NAIVE_USER=''\nNAIVE_PASS='x'\n" > "$CRED_FILE"
check "load_existing_credentials rejects empty user" '! load_existing_credentials'

# validate_naive_port bounds and octal-safe parsing.
NAIVE_PORT=443;   check "port 443 valid"          'validate_naive_port'
NAIVE_PORT=0443;  check "port 0443 normalized"    'validate_naive_port && [[ "$NAIVE_PORT" == "443" ]]'
NAIVE_PORT=80;    check "port 80 rejected"        '! (validate_naive_port) 2>/dev/null'
NAIVE_PORT=0;     check "port 0 rejected"         '! (validate_naive_port) 2>/dev/null'
NAIVE_PORT=70000; check "port 70000 rejected"     '! (validate_naive_port) 2>/dev/null'
NAIVE_PORT=abc;   check "port abc rejected"       '! (validate_naive_port) 2>/dev/null'

# validate_mask_site normalization and validation.
MASK_SITE="https://files.pythonhosted.org"
check "mask site clean URL valid"        'validate_mask_site && [[ "$MASK_SITE" == "https://files.pythonhosted.org" ]]'
MASK_SITE="https://example.com:8443/sub/path?x=1"
check "mask site strips trailing path"   'validate_mask_site >/dev/null 2>&1 && [[ "$MASK_SITE" == "https://example.com:8443" ]]'
MASK_SITE="https://user:pass@example.com"
check "mask site rejects credentials"    '! (validate_mask_site) 2>/dev/null'
MASK_SITE="ftp://example.com"
check "mask site rejects non-http"       '! (validate_mask_site) 2>/dev/null'
MASK_SITE="https://example.com:70000"
check "mask site rejects bad port"       '! (validate_mask_site) 2>/dev/null'

# validate_static_root path restrictions.
STATIC_ROOT="/var/www/naive-cover"
check "static root /var/www valid"       'validate_static_root && [[ "$STATIC_ROOT" == "/var/www/naive-cover" ]]'
STATIC_ROOT="/srv/cover-site"
check "static root /srv valid"           'validate_static_root && [[ "$STATIC_ROOT" == "/srv/cover-site" ]]'
STATIC_ROOT="/etc/caddy"
check "static root /etc/caddy rejected"  '! (validate_static_root) 2>/dev/null'
STATIC_ROOT="/root/cover"
check "static root /root rejected"       '! (validate_static_root) 2>/dev/null'
STATIC_ROOT="/var/www/../etc/passwd"
check "static root traversal rejected"   '! (validate_static_root) 2>/dev/null'
STATIC_ROOT="relative/path"
check "static root relative rejected"    '! (validate_static_root) 2>/dev/null'

# detect_os version enforcement.
os_file="${TEST_ROOT}/os-release"
export NAIVECD_TEST_OS_RELEASE="$os_file"
printf 'ID=debian\nVERSION_ID="12"\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n' > "$os_file"
check "detect_os accepts Debian 12"      '(detect_os) >/dev/null 2>&1'
printf 'ID=debian\nVERSION_ID="11"\nPRETTY_NAME="Debian GNU/Linux 11 (bullseye)"\n' > "$os_file"
check "detect_os rejects Debian 11"      '! (detect_os) 2>/dev/null'
printf 'ID=debian\nPRETTY_NAME="Debian GNU/Linux trixie/sid"\n' > "$os_file"
check "detect_os accepts Debian sid"     '(detect_os) >/dev/null 2>&1'
printf 'ID=ubuntu\nVERSION_ID="22.04"\nPRETTY_NAME="Ubuntu 22.04 LTS"\n' > "$os_file"
check "detect_os accepts Ubuntu 22.04"   '(detect_os) >/dev/null 2>&1'
printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04 LTS"\n' > "$os_file"
check "detect_os accepts Ubuntu 24.04"   '(detect_os) >/dev/null 2>&1'
printf 'ID=ubuntu\nVERSION_ID="20.04"\nPRETTY_NAME="Ubuntu 20.04 LTS"\n' > "$os_file"
check "detect_os rejects Ubuntu 20.04"   '! (detect_os) 2>/dev/null'
printf 'ID=fedora\nVERSION_ID="40"\n' > "$os_file"
check "detect_os rejects Fedora"         '! (detect_os) 2>/dev/null'
unset NAIVECD_TEST_OS_RELEASE

# go_version_at_least checks against MIN_GO_MAJOR.MIN_GO_MINOR (1.26).
check "go1.26.0 satisfies >= 1.26"       'go_version_at_least "go version go1.26.0 linux/amd64"'
check "go1.26.11 satisfies >= 1.26"      'go_version_at_least "go version go1.26.11 linux/arm64"'
check "go1.27rc1 satisfies >= 1.26"      'go_version_at_least "go version go1.27rc1 linux/amd64"'
check "go1.25.9 rejected for >= 1.26"    '! go_version_at_least "go version go1.25.9 linux/amd64"'
check "go1.22.4 rejected for >= 1.26"    '! go_version_at_least "go version go1.22.4 linux/amd64"'

# canonical_ipv6 normalizes expanded and compressed representations.
check "canonical_ipv6 matches expanded and compressed" \
    '[[ "$(canonical_ipv6 "2001:0DB8:0000:0000:0000:0000:0000:0001")" == "$(canonical_ipv6 "2001:db8::1")" ]]'

# resolve_records must swallow dig failures (returns empty, rc 0) so an
# unreachable 1.1.1.1 cannot abort the installer under set -e.
dig() { return 1; }
check "resolve_records tolerates dig failure" 'out="$(resolve_records A example.com)"; [[ -z "$out" ]]'
unset -f dig

# has_caddy_unit keys off output text, not the exit code (systemd < 246 quirk).
systemctl() { printf '0 unit files listed.\n'; return 0; }
check "has_caddy_unit false when unit absent" '! has_caddy_unit'
systemctl() { printf 'caddy.service enabled enabled\n1 unit files listed.\n'; return 0; }
check "has_caddy_unit true when unit listed"  'has_caddy_unit'
unset -f systemctl

# check_ports rejects occupied TCP ports even when ss omits pid=...
NAIVE_PORT=443
ss() {
    if [[ "$1" == "-tlnpH" && "$2" == "sport = :443" ]]; then
        printf 'LISTEN 0 4096 *:443 *:*\n'
    fi
    return 0
}
check "check_ports rejects pid-less listener" '! (check_ports) 2>/dev/null'
ss() {
    if [[ "$1" == "-tlnpH" && "$2" == "sport = :443" ]]; then
        printf 'LISTEN 0 4096 *:443 *:* users:(("caddy",pid=4242,fd=7))\n'
    fi
    return 0
}
ps() { printf 'caddy\n'; return 0; }
check "check_ports permits existing caddy listener" '(check_ports) >/dev/null 2>&1'
unset -f ss ps

# verify_caddy_forwardproxy must not fail under pipefail when list-modules prints
# lots of trailing output after http.handlers.forward_proxy.
fake_caddy="${TEST_ROOT}/fake-caddy"
cat > "$fake_caddy" <<'EOF'
#!/usr/bin/env bash
echo "http.handlers.forward_proxy"
for i in $(seq 1 5000); do
    echo "http.handlers.extra_module_${i}"
done
EOF
chmod 0755 "$fake_caddy"
check "verify_caddy_forwardproxy avoids SIGPIPE under pipefail" \
    '(set -euo pipefail; verify_caddy_forwardproxy "$fake_caddy")'

if (( fail )); then echo "library function tests FAILED"; exit 1; fi
printf 'library function tests passed\n'
