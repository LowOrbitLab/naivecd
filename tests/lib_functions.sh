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

# Rewrite the readonly CRED_FILE path so the tests can seed it, mirroring the
# other harnesses in this directory.
LIB="${TEST_ROOT}/install-lib.sh"
sed -e "s|readonly CRED_FILE=.*|readonly CRED_FILE=\"${TEST_ROOT}/cred\"|" \
    "$PROJECT_ROOT/install.sh" > "$LIB"

export NAIVECD_LIB_ONLY=1
# shellcheck disable=SC1090
source "$LIB"

fail=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; fail=1; fi; }

# load_existing_credentials round-trips the values written by save_credentials_file.
printf "NAIVE_USER='abc123XYZ'\nNAIVE_PASS='pass456QRS'\n" > "$CRED_FILE"
NAIVE_USER=""; NAIVE_PASS=""
load_existing_credentials
check "load_existing_credentials parses quoted"      '[[ "$NAIVE_USER" == "abc123XYZ" && "$NAIVE_PASS" == "pass456QRS" ]]'
printf "NAIVE_USER=''\nNAIVE_PASS='x'\n" > "$CRED_FILE"
check "load_existing_credentials rejects empty user" '! load_existing_credentials'

# validate_naive_port bounds.
NAIVE_PORT=443;   check "port 443 valid"    'validate_naive_port'
NAIVE_PORT=80;    check "port 80 rejected"  '! (validate_naive_port) 2>/dev/null'
NAIVE_PORT=70000; check "port 70000 reject" '! (validate_naive_port) 2>/dev/null'
NAIVE_PORT=abc;   check "port abc reject"   '! (validate_naive_port) 2>/dev/null'

# resolve_records must swallow dig failures (returns empty, rc 0) so an
# unreachable 1.1.1.1 cannot abort the installer under set -e.
dig() { return 1; }
check "resolve_records tolerates dig failure" 'out="$(resolve_records A example.com)"; [[ -z "$out" ]]'
unset -f dig

# has_caddy_unit keys off output text, not the exit code (systemd < 246 quirk).
systemctl() { printf '0 unit files listed.\n'; return 0; }
check "has_caddy_unit false when unit absent" '! has_caddy_unit'
unset -f systemctl

if (( fail )); then echo "library function tests FAILED"; exit 1; fi
printf 'library function tests passed\n'
