#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
LUA_FILE="${ROOT_DIR}/jammonitor.lua"
JS_FILE="${ROOT_DIR}/jammonitor.js"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT%/}"
TEST_DIR="$(mktemp -d "${TEST_TMP_ROOT}/jammonitor-luci-transactions.XXXXXX")"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT INT TERM

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok - %s\n' "$1" >&2
}

assert_contains() {
    _description="$1"
    _needle="$2"
    _file="$3"
    if grep -Fq -- "$_needle" "$_file"; then
        pass "$_description"
    else
        fail "$_description"
    fi
}

assert_regex() {
    _description="$1"
    _pattern="$2"
    _file="$3"
    if grep -Eq -- "$_pattern" "$_file"; then
        pass "$_description"
    else
        fail "$_description"
    fi
}

assert_count_at_least() {
    _description="$1"
    _needle="$2"
    _minimum="$3"
    _file="$4"
    _actual="$(grep -Fc -- "$_needle" "$_file" || true)"
    if [ "$_actual" -ge "$_minimum" ]; then
        pass "$_description"
    else
        fail "$_description (found $_actual, expected at least $_minimum)"
    fi
}

extract_block() {
    _start="$1"
    _stop="$2"
    _output="$3"
    awk -v start="$_start" -v stop="$_stop" '
        $0 ~ start { capture = 1 }
        capture && seen && $0 ~ stop { exit }
        capture { print; seen = 1 }
    ' "$LUA_FILE" > "$_output"
}

assert_order() {
    _description="$1"
    _file="$2"
    shift 2
    _previous=0
    _ok=1
    for _needle in "$@"; do
        _line="$(grep -nF -- "$_needle" "$_file" |
            awk -F: -v previous="$_previous" '$1 > previous { print $1; exit }')"
        if [ -z "$_line" ]; then
            _ok=0
            break
        fi
        _previous="$_line"
    done
    if [ "$_ok" -eq 1 ]; then
        pass "$_description"
    else
        fail "$_description"
    fi
}

WAN_POLICY="${TEST_DIR}/wan-policy.lua"
WAN_EDIT="${TEST_DIR}/wan-edit.lua"
WAN_ADVANCED="${TEST_DIR}/wan-advanced.lua"
WAN_IFACES="${TEST_DIR}/wan-ifaces.lua"
DHCP_SET="${TEST_DIR}/dhcp-set.lua"
DHCP_DELETE="${TEST_DIR}/dhcp-delete.lua"
STORAGE_FORMAT="${TEST_DIR}/storage-format.lua"
STORAGE_MOUNT="${TEST_DIR}/storage-mount.lua"
STORAGE_INIT="${TEST_DIR}/storage-init.lua"
BYPASS="${TEST_DIR}/bypass.lua"
SPEEDTEST="${TEST_DIR}/speedtest.lua"

extract_block '^function action_wan_policy_set[(][)]' \
    '^function action_wan_policy[(][)]' "$WAN_POLICY"
extract_block '^function action_wan_edit[(][)]' \
    '^function action_wan_advanced_set[(][)]' "$WAN_EDIT"
extract_block '^function action_wan_advanced_set[(][)]' \
    '^function action_wan_advanced[(][)]' "$WAN_ADVANCED"
extract_block '^function action_wan_ifaces_set[(][)]' \
    '^function action_wan_ifaces[(][)]' "$WAN_IFACES"
extract_block '^function action_set_reservation[(][)]' \
    '^function action_delete_reservation[(][)]' "$DHCP_SET"
extract_block '^function action_delete_reservation[(][)]' \
    '^function action_public_ip[(][)]' "$DHCP_DELETE"
extract_block '^function action_storage_format[(][)]' \
    '^function action_storage_mount[(][)]' "$STORAGE_FORMAT"
extract_block '^function action_storage_mount[(][)]' \
    '^function action_storage_init[(][)]' "$STORAGE_MOUNT"
extract_block '^function action_storage_init[(][)]' \
    '^function action_wifi_status[(][)]' "$STORAGE_INIT"
extract_block '^local function action_bypass_set_transactional[(][)]' \
    '^function action_bypass_set[(][)]' "$BYPASS"
extract_block '^function action_speedtest_start[(][)]' \
    '^function action_speedtest_status[(][)]' "$SPEEDTEST"

# Every mutator that can conflict over UCI or persistent files must share the
# same lease for its mutation family. In particular, bypass and ordinary WAN
# edits cannot run under independent locks.
assert_contains "WAN mutation lock is a single shared constant" \
    'local WAN_MUTATION_LOCK = "/tmp/jammonitor-wan.lock"' "$LUA_FILE"
assert_count_at_least "all four WAN writers plus bypass use the shared WAN lock" \
    'WAN_MUTATION_LOCK, 600' 5 "$LUA_FILE"
assert_contains "DHCP mutation lock is a single shared constant" \
    'local DHCP_MUTATION_LOCK = "/tmp/jammonitor-dhcp.lock"' "$LUA_FILE"
assert_count_at_least "reservation create and delete share the DHCP lock" \
    'DHCP_MUTATION_LOCK, 120' 2 "$LUA_FILE"
assert_contains "storage mutation lock is a single shared constant" \
    'local STORAGE_LOCK = "/tmp/jammonitor-storage.lock"' "$LUA_FILE"
assert_count_at_least "format, mount, and initialize share the storage lock" \
    'STORAGE_LOCK, 600' 3 "$LUA_FILE"

assert_order "locked operations release the lease after protected pcall" \
    "$LUA_FILE" \
    'local called, first, second = pcall(operation)' \
    'release_lock_dir(lock_path)' \
    'if not called then'

# UCI transactions must check commit, prove persisted values through a fresh
# cursor, and restore the exact configuration snapshot plus runtime service.
for _section in "$WAN_POLICY" "$WAN_EDIT"; do
    assert_contains "WAN transaction checks the network commit result" \
        'local committed = current:commit("network")' "$_section"
    assert_contains "WAN transaction reads back through a fresh cursor" \
        'local verify = require "luci.model.uci".cursor()' "$_section"
    assert_contains "WAN transaction restores its network snapshot on failure" \
        'restore_uci_snapshot("network", snapshot)' "$_section"
    assert_contains "WAN transaction verifies the runtime reload" \
        '"/etc/init.d/network", "reload", 60' "$_section"
done

assert_contains "advanced WAN transaction checks tracker commit" \
    'local tracker_committed = current:commit("omr-tracker")' "$WAN_ADVANCED"
assert_contains "advanced WAN transaction checks network commit" \
    'local network_committed = current:commit("network")' "$WAN_ADVANCED"
assert_contains "advanced WAN transaction reads back committed UCI" \
    'local verify = require "luci.model.uci".cursor()' "$WAN_ADVANCED"
assert_contains "advanced WAN rollback restores tracker snapshot" \
    'restore_uci_snapshot("omr-tracker", tracker_snapshot)' "$WAN_ADVANCED"
assert_contains "advanced WAN rollback restores network snapshot" \
    'restore_uci_snapshot("network", network_snapshot)' "$WAN_ADVANCED"
assert_contains "advanced WAN rollback restores live sysctl" \
    '"sysctl -w net.mptcp.stale_loss_cnt="' "$WAN_ADVANCED"

assert_order "WAN selection uses snapshot, atomic write, readback, then rollback" \
    "$WAN_IFACES" \
    'local snapshot = snapshot_file("/etc/jammonitor_wans")' \
    'if not atomic_write(' \
    '(fs.readfile("/etc/jammonitor_wans") or "") ~= content' \
    'restore_file_snapshot('

for _section in "$DHCP_SET" "$DHCP_DELETE"; do
    assert_contains "DHCP transaction checks commit result" \
        'current:commit("dhcp")' "$_section"
    assert_contains "DHCP transaction verifies through a fresh cursor" \
        'local verify = require "luci.model.uci".cursor()' "$_section"
    assert_contains "DHCP transaction has exact snapshot rollback" \
        'restore_dhcp_transaction(snapshot, was_running)' "$_section"
    assert_contains "DHCP transaction checks dnsmasq after commit" \
        'apply_dnsmasq_after_commit(was_running)' "$_section"
done

# Empty DNS is a real clear mutation. It must still mark the transaction
# changed, commit, and prove an empty readback list.
assert_order "empty DNS deletion still flows through commit and readback" \
    "$WAN_EDIT" \
    'current:delete("network", iface, "dns")' \
    'changed = true' \
    'local committed = current:commit("network")' \
    'local actual_dns = verify:get_list("network", iface, "dns") or {}' \
    'if #actual_dns ~= #data.dns then'

# Storage authority is partition-scoped, removable, revalidated under the
# shared lock, and never inferred from a caller-controlled /dev path alone.
assert_contains "storage accepts only sd partitions, never whole disks" \
    'device:match("^/dev/(sd[a-z])(%d+)$")' "$LUA_FILE"
assert_contains "storage requires the kernel removable bit" \
    'if removable ~= "1" then return nil end' "$LUA_FILE"
for _section in "$STORAGE_FORMAT" "$STORAGE_MOUNT"; do
    assert_contains "destructive storage identity is revalidated under lock" \
        'local current_identity = storage_partition_identity(device)' "$_section"
    assert_contains "storage revalidation excludes a system disk" \
        'storage_partition_is_system(current_identity)' "$_section"
done

assert_order "format proves exact source is unmounted before mkfs" \
    "$STORAGE_FORMAT" \
    'local original_mount, mount_error = exact_mount_for_source(device)' \
    'checked_call("timeout 30 umount " .. device)' \
    'exact_mount_for_source(device) ~= nil' \
    '"timeout 180 mkfs.ext4 -F -L "'

assert_contains "mount command requests exact ext4 read-write semantics" \
    '"timeout 30 mount -t ext4 -o rw " .. source .. " " .. target' "$LUA_FILE"
assert_contains "mount verification proves exact source and ext4" \
    'mount.source == source and mount.fstype == "ext4"' "$LUA_FILE"
assert_contains "mount verification proves read-write state" \
    'mount.writable == true' "$LUA_FILE"
assert_contains "restored mount is re-read for exact source" \
    'actual ~= nil and actual.source == mount.source' "$LUA_FILE"
assert_contains "restored mount is re-read for exact filesystem" \
    'actual.fstype == mount.fstype and' "$LUA_FILE"

assert_order "fstab persistence is UUID-based, committed, then read back" \
    "$LUA_FILE" \
    'uci:delete("fstab", "jammonitor", "device")' \
    'uci:set("fstab", "jammonitor", "uuid", uuid)' \
    'uci:set("fstab", "jammonitor", "fstype", "ext4")' \
    'uci:commit("fstab")' \
    'local verify = require "luci.model.uci".cursor()' \
    'verify:get("fstab", "jammonitor", "uuid") == uuid'

assert_contains "mount rollback restores the prior exact mount" \
    'rollback_ok = restore_mount(old_mount) and rollback_ok' "$STORAGE_MOUNT"
assert_contains "mount rollback restores the prior fstab snapshot" \
    'restore_uci_snapshot("fstab", fstab_snapshot)' "$STORAGE_MOUNT"
assert_contains "mount rollback restores prior collector runtime" \
    'restore_collector_runtime(collector)' "$STORAGE_MOUNT"
assert_contains "storage initialization requires removable ext4 rw mount" \
    'Verified removable ext4 storage is not mounted read-write' "$STORAGE_INIT"

# The bypass recovery bundle is a versioned write-ahead record. Every
# interrupted phase is recovered before a new request, and the active flag is
# the final mutation after an active bundle has been durably written.
assert_contains "bypass bundle carries a schema version" \
    'schema = 1' "$LUA_FILE"
for _phase in prepared network_off services_stopped active restoring restored; do
    assert_contains "bypass validates the ${_phase} recovery phase" \
        "bundle.phase ~= \"${_phase}\"" "$LUA_FILE"
done
assert_order "bypass recovers an incomplete bundle before new mutation" \
    "$BYPASS" \
    'if bundle and (not flag_exists or bundle.phase ~= "active") then' \
    'restore_bypass_bundle(bundle)' \
    'if data.enable and flag_exists then' \
    'bundle, selection_error = capture_bypass_bundle(uci, selected)'
assert_order "bypass persists write-ahead phases before the active flag" \
    "$BYPASS" \
    'if not write_bypass_bundle(bundle) then' \
    'local applied = apply_bypass_network(bundle, true)' \
    'bundle.phase = "network_off"' \
    'bundle.phase = "services_stopped"' \
    'bundle.phase = "active"' \
    'not write_bypass_bundle(bundle)' \
    'not atomic_write(BYPASS_FLAG, bundle.primary .. "\n", PRIVATE_FILE_MODE)' \
    'not bypass_state_is_active(bundle)'

assert_contains "bypass restores original service enablement explicitly" \
    'spec.path, want_enabled and "enable" or "disable", 30' "$LUA_FILE"
assert_contains "bypass restores original running state explicitly" \
    'spec.path, want_running and "start" or "stop", 30' "$LUA_FILE"
assert_contains "bypass proves both restored service dimensions" \
    'service_state_matches(' "$LUA_FILE"

# Speed-test worker output must not publish a transport success when curl
# failed, must use atomic rename for every status, and must have both curl and
# observer deadlines.
assert_order "speedtest records curl status before parsing transport output" \
    "$SPEEDTEST" \
    'RESULT=$(' \
    'CURL_RC=$?' \
    'if [ "$CURL_RC" -eq 0 ]'
assert_order "speedtest status writes are temp-file plus atomic rename" \
    "$SPEEDTEST" \
    '_status_tmp="${JOB_FILE}.tmp.$$"' \
    'printf ' \
    'chmod 600 "$_status_tmp"' \
    'mv -f "$_status_tmp" "$JOB_FILE"'
assert_contains "speedtest curl has an explicit maximum time" \
    'curl -4 -L --max-time %d' "$SPEEDTEST"
assert_contains "speedtest publishes a bounded observer deadline" \
    'local deadline_at = started_at + timeout_s + 15' "$SPEEDTEST"
assert_contains "speedtest transport error publishes curl exit status" \
    '\"curl_exit\":$CURL_RC' "$SPEEDTEST"

# The watchdog producer, LuCI projection, and UI are one status contract. A
# missing LocalAPI socket must remain a precise fault through every layer.
assert_contains "watchdog validator accepts the socket-missing state" \
    '    socket_missing = true,' "$LUA_FILE"
assert_contains "UI presents the socket-missing watchdog state" \
    '            socket_missing: {' "$JS_FILE"
assert_contains "socket-missing state has an exact operator-facing title" \
    "                title: _('Local API socket missing')," "$JS_FILE"
assert_contains "UI presents the matching LocalAPI reason code" \
    '            localapi_socket_missing: {' "$JS_FILE"
assert_count_at_least "state and reason share the exact socket diagnosis" \
    "detail: _('The Tailscale process exists, but its expected local API socket is missing.')" \
    2 "$JS_FILE"

# Dynamic model 1: the mkdir primitive admits exactly one simultaneous owner,
# and operation failure releases the lease so a successor can proceed.
LOCK_MODEL="${TEST_DIR}/lock-model"
LOCK_RESULTS="${TEST_DIR}/lock-results"
LOCK_BARRIER="${TEST_DIR}/lock-barrier"
: > "$LOCK_RESULTS"

lock_worker() {
    _id="$1"
    : > "${LOCK_BARRIER}.ready.${_id}"
    while [ ! -e "$LOCK_BARRIER" ]; do sleep 0.01; done
    if mkdir "$LOCK_MODEL" 2>/dev/null; then
        printf 'owner %s\n' "$_id" >> "$LOCK_RESULTS"
        sleep 0.3
        rmdir "$LOCK_MODEL"
    else
        printf 'blocked %s\n' "$_id" >> "$LOCK_RESULTS"
    fi
}

_worker=1
while [ "$_worker" -le 12 ]; do
    lock_worker "$_worker" &
    _worker=$((_worker + 1))
done
_attempt=0
while [ "$(find "$TEST_DIR" -name 'lock-barrier.ready.*' | wc -l | tr -d ' ')" -lt 12 ]; do
    _attempt=$((_attempt + 1))
    [ "$_attempt" -lt 200 ] || break
    sleep 0.01
done
: > "$LOCK_BARRIER"
wait
if [ "$(grep -c '^owner ' "$LOCK_RESULTS")" -eq 1 ] &&
   [ "$(grep -c '^blocked ' "$LOCK_RESULTS")" -eq 11 ]; then
    pass "dynamic mkdir-lock race admits one mutation owner"
else
    fail "dynamic mkdir-lock race admits one mutation owner"
fi

mkdir "$LOCK_MODEL"
(
    false
) || true
rmdir "$LOCK_MODEL"
if mkdir "$LOCK_MODEL"; then
    rmdir "$LOCK_MODEL"
    pass "dynamic failed-operation cleanup admits a successor"
else
    fail "dynamic failed-operation cleanup admits a successor"
fi

# Dynamic model 2: a failed pre-rename status write preserves the prior state,
# and racing complete writers can only publish one whole record.
STATUS_MODEL="${TEST_DIR}/status-model"
printf 'state:previous\n' > "$STATUS_MODEL"
status_write() {
    _value="$1"
    _fail_before_rename="${2:-0}"
    _tmp="${STATUS_MODEL}.tmp.$$.$_value"
    printf 'state:%s\n' "$_value" > "$_tmp"
    if [ "$_fail_before_rename" -eq 1 ]; then
        rm -f "$_tmp"
        return 1
    fi
    mv -f "$_tmp" "$STATUS_MODEL"
}

status_write failed 1 || true
if [ "$(cat "$STATUS_MODEL")" = "state:previous" ]; then
    pass "dynamic pre-rename failure preserves prior status"
else
    fail "dynamic pre-rename failure preserves prior status"
fi

_writer=1
while [ "$_writer" -le 20 ]; do
    status_write "$_writer" 0 &
    _writer=$((_writer + 1))
done
wait
if grep -Eq '^state:([1-9]|1[0-9]|20)$' "$STATUS_MODEL" &&
   ! find "$TEST_DIR" -name 'status-model.tmp.*' -print -quit | grep -q .; then
    pass "dynamic racing status writers publish one complete atomic record"
else
    fail "dynamic racing status writers publish one complete atomic record"
fi

# Dynamic model 3: checked commit/readback/runtime failures restore the exact
# pre-transaction bytes. This is the fault matrix the source contracts above
# require for UCI-backed operations.
CONFIG_MODEL="${TEST_DIR}/config-model"
SNAPSHOT_MODEL="${TEST_DIR}/config-model.snapshot"
printf 'mode=master\ndns=1.1.1.1\n' > "$CONFIG_MODEL"
cp "$CONFIG_MODEL" "$SNAPSHOT_MODEL"

transaction_model() {
    _failure="$1"
    _staged="${CONFIG_MODEL}.staged.$$"
    printf 'mode=backup\ndns=\n' > "$_staged"
    if [ "$_failure" = "commit" ]; then
        rm -f "$_staged"
        cp "$SNAPSHOT_MODEL" "$CONFIG_MODEL"
        return 1
    fi
    mv -f "$_staged" "$CONFIG_MODEL"
    if [ "$_failure" = "readback" ]; then
        printf 'mode=corrupt\ndns=\n' > "$CONFIG_MODEL"
    fi
    if [ "$_failure" = "readback" ] ||
       [ "$_failure" = "runtime" ]; then
        cp "$SNAPSHOT_MODEL" "$CONFIG_MODEL"
        return 1
    fi
    return 0
}

_matrix_ok=1
for _failure in commit readback runtime; do
    cp "$SNAPSHOT_MODEL" "$CONFIG_MODEL"
    transaction_model "$_failure" && _matrix_ok=0
    cmp -s "$CONFIG_MODEL" "$SNAPSHOT_MODEL" || _matrix_ok=0
done
if [ "$_matrix_ok" -eq 1 ]; then
    pass "dynamic transaction fault matrix restores exact pre-change bytes"
else
    fail "dynamic transaction fault matrix restores exact pre-change bytes"
fi

printf '1..%s\n' "$((PASS_COUNT + FAIL_COUNT))"
[ "$FAIL_COUNT" -eq 0 ]
