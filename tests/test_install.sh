#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"

# 加载函数但不执行安装入口。
# shellcheck source=../install.sh
source "${REPO_DIR}/install.sh"

TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "$TEST_TMP"' EXIT

assert_eq() {
    local expected="$1" actual="$2" message="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf '测试失败：%s（期望=%s，实际=%s）\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

write_minimal_state() {
    local path="$1"
    cat > "$path" <<EOF
NAIVECD_STATE_VERSION=${STATE_FORMAT_VERSION}
NAIVECD_MANAGED=1
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
STATE_STATIC_ROOT=
STATE_STATIC_INDEX_SHA256=
STATE_CADDY_BIN_SHA256=
STATE_SYSTEMD_UNIT_SHA256=
STATE_CADDYFILE_SHA256=
STATE_CRED_FILE_SHA256=
STATE_CLIENT_CONFIG_SHA256=
STATE_SINGBOX_CONFIG_SHA256=
STATE_CADDY_BIN_ORIGINAL=
STATE_SYSTEMD_UNIT_ORIGINAL=
STATE_CADDYFILE_ORIGINAL=
STATE_CRED_FILE_ORIGINAL=
STATE_CLIENT_CONFIG_ORIGINAL=
STATE_SINGBOX_CONFIG_ORIGINAL=
STATE_ORIGINAL_SERVICE_ACTIVE=0
STATE_ORIGINAL_SERVICE_ENABLED=0
EOF
    chmod 0600 "$path"
}

test_valid_state_loads() {
    local state="${TEST_TMP}/valid.env"
    write_minimal_state "$state"
    load_managed_state "$state"
    assert_eq "1" "$STATE_LOADED" "可信状态文件应成功加载"
}

test_invalid_state_fails_closed() {
    local state="${TEST_TMP}/invalid.env"
    printf 'MANAGED_CADDY_BIN=1\n' > "$state"
    chmod 0600 "$state"
    load_managed_state "$state"
    assert_eq "0" "$STATE_LOADED" "无效状态文件不应加载"
    assert_eq "0" "$MANAGED_CADDY_BIN" "无效状态中的删除标志必须被清零"
}

test_writable_state_is_rejected() {
    local state="${TEST_TMP}/writable.env"
    write_minimal_state "$state"
    chmod 0666 "$state"
    load_managed_state "$state"
    assert_eq "0" "$STATE_LOADED" "可被组或其他用户写入的状态文件必须被拒绝"
}

test_complete_managed_resource_state_loads() {
    local state="${TEST_TMP}/managed-resource.env"
    write_minimal_state "$state"
    sed -i \
        -e 's/^MANAGED_CLIENT_CONFIG=0$/MANAGED_CLIENT_CONFIG=1/' \
        -e 's/^STATE_CLIENT_CONFIG_SHA256=$/STATE_CLIENT_CONFIG_SHA256=0000000000000000000000000000000000000000000000000000000000000000/' \
        -e "s/^STATE_CLIENT_CONFIG_ORIGINAL=$/STATE_CLIENT_CONFIG_ORIGINAL=${STATE_ABSENT}/" \
        "$state"
    load_managed_state "$state"
    assert_eq "1" "$STATE_LOADED" "摘要和原始记录完整的托管资源应成功加载"
    assert_eq "1" "$MANAGED_CLIENT_CONFIG" "托管资源标志应被保留"
}

test_symlink_component_is_detected() {
    mkdir -p "${TEST_TMP}/real"
    ln -s "${TEST_TMP}/real" "${TEST_TMP}/link"
    path_has_symlink_component "${TEST_TMP}/link/site" \
        || { printf '测试失败：未检测到静态路径中的符号链接\n' >&2; exit 1; }
}

test_transaction_snapshot_restores_file() {
    local target="${TEST_TMP}/target" snapshot_dir="${TEST_TMP}/transaction"
    printf 'original\n' > "$target"
    TRANSACTION_DIR="$snapshot_dir"
    mkdir -p "${TRANSACTION_DIR}/files"
    TXN_PATHS=()
    TXN_EXISTED=()
    TXN_SNAPSHOTS=()
    transaction_snapshot_path sample "$target"
    printf 'changed\n' > "$target"
    transaction_restore_path sample
    assert_eq "original" "$(tr -d '\r\n' < "$target")" "事务快照应恢复原文件"
}

test_transaction_snapshot_removes_new_file() {
    local target="${TEST_TMP}/new-target" snapshot_dir="${TEST_TMP}/new-transaction"
    TRANSACTION_DIR="$snapshot_dir"
    mkdir -p "${TRANSACTION_DIR}/files"
    TXN_PATHS=()
    TXN_EXISTED=()
    TXN_SNAPSHOTS=()
    transaction_snapshot_path sample_new "$target"
    printf 'created\n' > "$target"
    transaction_restore_path sample_new
    [[ ! -e "$target" ]] \
        || { printf '测试失败：事务回滚未删除新建文件\n' >&2; exit 1; }
}

test_managed_checksum_rejects_modified_file() {
    local target="${TEST_TMP}/managed" checksum
    printf 'managed\n' > "$target"
    checksum="$(file_sha256 "$target")"
    managed_resource_matches "$target" "$checksum" \
        || { printf '测试失败：原始托管文件摘要未匹配\n' >&2; exit 1; }
    printf 'modified\n' > "$target"
    if managed_resource_matches "$target" "$checksum"; then
        printf '测试失败：修改后的托管文件仍被判定为可删除\n' >&2
        exit 1
    fi
}

test_term_exits_instead_of_continuing() {
    local output code
    set +e
    output="$(bash -c 'source "$1"; kill -TERM $$; echo CONTINUED' _ "${REPO_DIR}/install.sh" 2>&1)"
    code=$?
    set -e
    assert_eq "143" "$code" "TERM 应以 143 退出"
    [[ "$output" != *CONTINUED* ]] \
        || { printf '测试失败：TERM 后脚本仍继续执行\n' >&2; exit 1; }
}

test_stdin_entry_guard_handles_unset_bash_source() {
    local output
    output="$(printf '%s\n' \
        'set -u' \
        'if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then echo ENTRY_OK; fi' \
        | bash)"
    assert_eq "ENTRY_OK" "$output" "管道执行时入口保护必须兼容未定义的 BASH_SOURCE"
}

test_valid_state_loads
test_invalid_state_fails_closed
test_writable_state_is_rejected
test_complete_managed_resource_state_loads
test_symlink_component_is_detected
test_transaction_snapshot_restores_file
test_transaction_snapshot_removes_new_file
test_managed_checksum_rejects_modified_file
test_term_exits_instead_of_continuing
test_stdin_entry_guard_handles_unset_bash_source

printf '全部安全边界测试通过。\n'
