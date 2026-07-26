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

assert_absent() {
    _description="$1"
    _needle="$2"
    _file="$3"
    if grep -Fq -- "$_needle" "$_file"; then
        fail "$_description"
    else
        pass "$_description"
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
TAILSCALE_QUERY="${TEST_DIR}/tailscale-query.lua"
TAILSCALE_JOIN="${TEST_DIR}/tailscale-join.lua"
TAILSCALE_PROJECTION="${TEST_DIR}/tailscale-projection.lua"
TAILSCALE_GET="${TEST_DIR}/tailscale-get.lua"
TAILSCALE_CLIENTS="${TEST_DIR}/tailscale-clients.lua"
TAILSCALE_STATUS="${TEST_DIR}/tailscale-status.lua"
HISTORY_PARSE="${TEST_DIR}/history-parse.lua"
HISTORY="${TEST_DIR}/history.lua"
HISTORY_CLIENTS="${TEST_DIR}/history-clients.lua"
TRAFFIC_SUMMARY="${TEST_DIR}/traffic-summary.lua"

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
extract_block '^local function query_tailscale_status[(]include_peers[)]' \
    '^local function query_joined_tailscale_status[(]include_peers[)]' \
    "$TAILSCALE_QUERY"
extract_block '^local function query_joined_tailscale_status[(]include_peers[)]' \
    '^local function copy_string_list[(]values, limit[)]' "$TAILSCALE_JOIN"
extract_block '^local function live_tailscale_projection[(]' \
    '^local WATCHDOG_FIELDS = {' "$TAILSCALE_PROJECTION"
extract_block '^local function get_tailscale_projection[(]include_live_peers[)]' \
    '^-- System stats:' "$TAILSCALE_GET"
extract_block '^function action_clients[(][)]' \
    '^function action_tailscale_status[(][)]' "$TAILSCALE_CLIENTS"
extract_block '^function action_tailscale_status[(][)]' \
    '^-- Client metadata:' "$TAILSCALE_STATUS"
extract_block '^local HISTORY_MAX_TIMESTAMP = ' \
    '^-- Historical metrics download' "$HISTORY_PARSE"
extract_block '^function action_history[(][)]' \
    '^-- Per-client traffic' "$HISTORY"
extract_block '^function action_history_clients[(][)]' \
    '^-- Traffic summary' "$HISTORY_CLIENTS"
extract_block '^function action_traffic_summary[(][)]' \
    '^local function action_bypass_set_transactional[(][)]' "$TRAFFIC_SUMMARY"

# Every mutator that can conflict over UCI or persistent files must share the
# same lease for its mutation family. In particular, bypass and ordinary WAN
# edits cannot run under independent locks.
assert_contains "LuCI mutable runtime state has one private root" \
    'local LUCI_RUNTIME_DIRECTORY = "/var/run/jammonitor-luci"' "$LUA_FILE"
assert_contains "WAN mutation lock is a single shared constant" \
    'local WAN_MUTATION_LOCK = LUCI_RUNTIME_DIRECTORY .. "/wan.lock"' "$LUA_FILE"
assert_count_at_least "all four WAN writers plus bypass use the shared WAN lock" \
    'WAN_MUTATION_LOCK, 600' 5 "$LUA_FILE"
assert_contains "DHCP mutation lock is a single shared constant" \
    'local DHCP_MUTATION_LOCK = LUCI_RUNTIME_DIRECTORY .. "/dhcp.lock"' "$LUA_FILE"
assert_count_at_least "reservation create and delete share the DHCP lock" \
    'DHCP_MUTATION_LOCK, 120' 2 "$LUA_FILE"
assert_contains "storage mutation lock is a single shared constant" \
    'local STORAGE_LOCK = LUCI_RUNTIME_DIRECTORY .. "/storage.lock"' "$LUA_FILE"
assert_count_at_least "format, mount, and initialize share the storage lock" \
    'STORAGE_LOCK, 600' 3 "$LUA_FILE"

assert_order "locked operations release the lease after protected pcall" \
    "$LUA_FILE" \
    'local called, first, second = pcall(operation)' \
    'release_lock_dir(lock_path, lock_token)' \
    'if not called then'
assert_contains "live mutation owners are joined to exact process generation" \
    'lock_process_start_ticks(owner.pid) == owner.start_ticks' "$LUA_FILE"
assert_contains "lock release requires the original claim token" \
    'if not owner or owner.token ~= token then return false end' "$LUA_FILE"
assert_absent "wall-clock age never steals a live mutation lock" \
    'os.time() - tonumber(stat.mtime)' "$LUA_FILE"

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

assert_order "format neutralizes persistence and proves the destructive boundary" \
    "$STORAGE_FORMAT" \
    'local original_mount, mount_error = exact_mount_for_source(device)' \
    'clear_storage_mount_persistence()' \
    'unmount_exact("/mnt/data")' \
    'write_storage_mount_phase(bundle, "format_started")' \
    'storage_format_boundary_is_safe(current_identity)' \
    '"timeout 180 mkfs.ext4 -F -L "'

assert_contains "mount command uses the single hardened option contract" \
    '"timeout 30 mount -t ext4 -o " .. STORAGE_MOUNT_OPTIONS ..' "$LUA_FILE"
assert_contains "storage mount options forbid executable, device, and suid content" \
    '"rw,noatime,nosuid,nodev,noexec"' "$LUA_FILE"
assert_contains "mount verification proves exact source and ext4" \
    'mount.source == source and mount.fstype == "ext4"' "$LUA_FILE"
assert_contains "mount verification proves read-write state" \
    'mount.writable == true' "$LUA_FILE"
assert_order "mount lookup rejects duplicate target authority" \
    "$LUA_FILE" \
    'local function mounted_filesystem_at(path)' \
    'local count = 0' \
    'if target == path then' \
    'count = count + 1' \
    'if count > 1 then return nil, "ambiguous", count end' \
    'return found, "exact", 1'
assert_contains "restored mount is re-read for exact source" \
    'actual.source == mount.source and actual.fstype == mount.fstype' "$LUA_FILE"
assert_contains "restored mount is re-read for exact filesystem" \
    'normalized_storage_mount_options(actual.options) == options' "$LUA_FILE"

assert_order "fstab persistence is UUID-based, committed, then read back" \
    "$LUA_FILE" \
    'uci:delete("fstab", "jammonitor", "device")' \
    'uci:set("fstab", "jammonitor", "uuid", uuid)' \
    'uci:set("fstab", "jammonitor", "fstype", "ext4")' \
    'uci:commit("fstab")' \
    'local verify = require "luci.model.uci".cursor()' \
    'verify:get("fstab", "jammonitor", "uuid") == uuid'

assert_order "UUID persistence requires unique removable identity before and after commit" \
    "$LUA_FILE" \
    'local function persist_storage_mount(uuid, identity)' \
    'storage_uuid_has_exact_authority(uuid, identity)' \
    'uci:commit("fstab")' \
    'not storage_uuid_has_exact_authority(uuid, identity)' \
    'return sync_parent_directory(FSTAB_CONFIG)'
assert_contains "UUID enumeration has a hard deadline" \
    'checked_capture("timeout 10 block info")' "$LUA_FILE"
assert_contains "UUID enumeration requires exactly one match" \
    'return count == 1 and selected' "$LUA_FILE"

assert_contains "storage journal is persistent across reboot" \
    '"/etc/jammonitor_storage_mount_recovery.json"' "$LUA_FILE"
assert_contains "storage journal has a durable unresolved marker" \
    '"/etc/jammonitor_storage_mount_recovery_failed"' "$LUA_FILE"
assert_order "storage journal read requires root private single-link inode" \
    "$LUA_FILE" \
    'local function read_storage_mount_journal()' \
    'before.uid ~= 0' \
    'before.modedec ~= PRIVATE_FILE_MODE' \
    'read_bounded_regular_file('
assert_contains "storage journal rejects multiply-linked files" \
    'before.nlink ~= 1' "$LUA_FILE"
assert_contains "storage journal phases are operation-specific" \
    'STORAGE_MOUNT_OPERATION_PHASES[bundle.operation][bundle.phase]' "$LUA_FILE"
assert_contains "storage journal validates state transitions" \
    'storage_mount_phase_transition_is_valid(' "$LUA_FILE"
assert_contains "recovery preserves the interrupted phase" \
    'bundle, "restoring", interrupted_phase' "$LUA_FILE"
assert_contains "recovery claims only durably proven transaction mounts" \
    'local mount_ownership_proven =' "$LUA_FILE"
assert_contains "recovery leaves unresolved evidence on ambiguity" \
    '"Storage mount authority is ambiguous or unavailable"' "$LUA_FILE"
assert_contains "recovery restores the prior exact mount" \
    'not restore_mount(old_mount)' "$LUA_FILE"
assert_contains "recovery restores and verifies the prior fstab snapshot" \
    'not storage_fstab_matches_snapshot(bundle.fstab)' "$LUA_FILE"
assert_contains "recovery restores prior collector runtime" \
    'restore_collector_runtime({' "$LUA_FILE"
assert_order "mount writes WAL before service mount and fstab mutations" \
    "$STORAGE_MOUNT" \
    'write_storage_mount_journal(bundle)' \
    '"collector_stopping"' \
    'stop_collector_checked(collector)' \
    '"old_unmounting"' \
    'unmount_exact("/mnt/data")' \
    '"new_mounting"' \
    'mount_exact(device, "/mnt/data")' \
    '"fstab_writing"' \
    'persist_storage_mount(uuid, current_identity)'
assert_order "init writes WAL before fstab and collector mutations" \
    "$STORAGE_INIT" \
    'write_storage_mount_journal(bundle)' \
    '"fstab_writing"' \
    'persist_storage_mount(uuid, identity)' \
    '"collector_stopping"' \
    'stop_collector_checked(collector)' \
    '"collector_starting"' \
    'collector_service, "start", 30'
assert_contains "format refuses automatic rollback after mkfs may start" \
    'automatic old-data rollback is forbidden' "$LUA_FILE"
assert_contains "format retains an irreversible durable phase" \
    'format_started = true' "$LUA_FILE"
assert_contains "status surfaces exact mount ambiguity" \
    'mount_ambiguous = mount_state == "ambiguous"' "$LUA_FILE"
assert_contains "format endpoint retries pending recovery" \
    'recover_storage_mount_transaction_locked()' "$STORAGE_FORMAT"
assert_contains "mount endpoint retries pending recovery" \
    'recover_storage_mount_transaction_locked()' "$STORAGE_MOUNT"
assert_contains "init endpoint retries pending recovery" \
    'recover_storage_mount_transaction_locked()' "$STORAGE_INIT"
assert_contains "storage initialization requires removable ext4 rw mount" \
    'Verified removable ext4 storage is not mounted read-write' "$STORAGE_INIT"
assert_contains "storage initialization rejects unsafe persistent leaves" \
    'storage_data_directory_is_safe()' "$STORAGE_INIT"
assert_contains "storage data leaves must be root-owned regular single-links" \
    'leaf.type ~= "reg" or leaf.uid ~= 0 or' "$LUA_FILE"

# Time ranges cross from untrusted query strings into arithmetic and %d SQL
# interpolation. Accept only canonical bounded integers, then prove ordering
# and addition bounds before constructing any query.
assert_contains "history timestamps have an explicit safe upper bound" \
    'local HISTORY_MAX_TIMESTAMP = 4102444800' "$HISTORY_PARSE"
assert_order "history integer parsing rejects syntax and non-finite values" \
    "$HISTORY_PARSE" \
    'not raw:match("^%d+$")' \
    'local value = tonumber(raw)' \
    'value ~= value or value == math.huge' \
    'value ~= math.floor(value)' \
    'value < minimum or value > maximum'
assert_contains "invalid history input returns one generic bounded error" \
    'error = "invalid_time_range"' "$HISTORY_PARSE"
assert_order "custom history ranges validate both endpoints and strict order" \
    "$HISTORY" \
    'from_ts = parse_history_integer(' \
    'to_ts = parse_history_integer(' \
    'from_ts >= to_ts' \
    'local max_range = 720 * 3600' \
    'cutoff = from_ts'
assert_order "hours mode validates before timestamp arithmetic" \
    "$HISTORY" \
    'hours = parse_history_integer(hours_raw, 1, 720)' \
    'write_history_input_error(http, json)' \
    'cutoff = os.time() - (hours * 3600)'
assert_order "client history bounds start before adding its bucket duration" \
    "$HISTORY_CLIENTS" \
    'local max_duration =' \
    'HISTORY_MAX_TIMESTAMP - max_duration' \
    'end_ts = start_ts + 3600'
assert_order "traffic summary shares the bounded timestamp contract" \
    "$TRAFFIC_SUMMARY" \
    'local max_duration =' \
    'HISTORY_MAX_TIMESTAMP - max_duration' \
    'end_ts = start_ts + 3600'
assert_absent "history endpoints do not tonumber raw query timestamps directly" \
    'tonumber(http.formvalue(' "$HISTORY"
assert_absent "client history does not tonumber raw query timestamps directly" \
    'tonumber(http.formvalue(' "$HISTORY_CLIENTS"
assert_absent "traffic summary does not tonumber raw query timestamps directly" \
    'tonumber(http.formvalue(' "$TRAFFIC_SUMMARY"

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
assert_contains "bypass journal rename is a directory-durable boundary" \
    'if renamed then return sync_parent_directory(path) end' "$LUA_FILE"
assert_contains "bypass journal cleanup uses durable removal" \
    'local removed = durable_remove(BYPASS_BUNDLE) and' "$LUA_FILE"

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
assert_contains "speedtest jobs stay below private LuCI runtime state" \
    'local job_file = SPEEDTEST_JOB_PREFIX .. job_id .. ".json"' "$SPEEDTEST"
assert_contains "speedtest status reads use a bounded regular-file reader" \
    'local content = read_bounded_regular_file(job_file, 16384)' "$LUA_FILE"
assert_absent "speedtest no longer publishes jobs in attacker-writable tmp" \
    '/tmp/jammonitor_speedtest' "$LUA_FILE"
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

# Cached watchdog snapshots are an untrusted file boundary. Peer proof must
# have exact types and state combinations before LuCI can project connectivity.
assert_contains "watchdog validator recognizes invalid peer configuration" \
    '    invalid_configuration = true' "$LUA_FILE"
assert_contains "watchdog validator requires peer_configured boolean type" \
    '"service_running", "recoverable", "peer_configured"' "$LUA_FILE"
assert_contains "watchdog validator rejects unproven configured-peer connectivity" \
    'parsed.peer_reachable ~= true then' "$LUA_FILE"
assert_contains "watchdog validator binds unconfigured peers to null reachability" \
    'parsed.peer_state ~= "not_configured" or' "$LUA_FILE"
assert_contains "watchdog validator binds invalid peer configuration to false reachability" \
    'parsed.peer_state == "invalid_configuration") and' "$LUA_FILE"
assert_contains "LuCI live Tailscale projection emits schema 3" \
    '        schema = 3,' "$LUA_FILE"
assert_contains "watchdog validator accepts only persisted schemas 2 and 3" \
    '       (schema ~= 2 and schema ~= 3) or' "$LUA_FILE"
assert_contains "watchdog validator rejects string-typed schema values" \
    'if type(schema) ~= "number" or' "$LUA_FILE"
assert_contains "legacy schema 2 requires positive InEngine delivery evidence" \
    '       parsed.in_engine ~= true then' "$LUA_FILE"
assert_contains "legacy schema 2 requires exact InEngine boolean type" \
    'if type(parsed.in_engine) ~= "boolean" then return false end' "$LUA_FILE"
assert_contains "cached watchdog status is opened through a bounded regular-file reader" \
    'TAILSCALE_WATCHDOG_STATUS, 16384' "$LUA_FILE"
assert_contains "critical-peer config is classified with lstat" \
    'local stat = fs.lstat(TAILSCALE_CRITICAL_PEER)' "$LUA_FILE"
assert_contains "live supervisor state queries use a bounded tri-state helper" \
    'enabled = checked_init_state("/etc/init.d/tailscale", "enabled", 3)' \
    "$LUA_FILE"
assert_contains "live fallback treats malformed Health as unknown" \
    'state, reason = "running_degraded", "health_state_unknown"' "$LUA_FILE"
assert_contains "LocalAPI Health type is read from the pinned raw JSON file" \
    'raw_path .. " -t '\''@.Health'\'' 2>/dev/null"' "$TAILSCALE_QUERY"
assert_contains "LocalAPI raw JSON is removed after type inspection" \
    'fs.remove(raw_path)' "$TAILSCALE_QUERY"
assert_contains "live fallback accepts Health only as an exact JSON array" \
    'health_type == "array" and health_count ~= nil' "$TAILSCALE_PROJECTION"
assert_order "malformed Health cannot claim connected delivery" \
    "$TAILSCALE_PROJECTION" \
    'elseif not health_schema_valid then' \
    'state, reason = "running_degraded", "health_state_unknown"' \
    'connected, degraded = false, true'
assert_order "LocalAPI response is bracketed by exact daemon identity reads" \
    "$TAILSCALE_JOIN" \
    'local before_identity = observed_tailscaled_process_identity()' \
    'local status, health_type = query_tailscale_status(include_peers)' \
    'observed_tailscaled_process_identity()' \
    'same_tailscaled_process_identity(before_identity, after_identity)'
assert_contains "process joins reject dead-task state" \
    'state ~= "X" and state ~= "x" and' "$LUA_FILE"
assert_order "live projection reproves generation after supervisor reads" \
    "$TAILSCALE_PROJECTION" \
    'enabled = checked_init_state("/etc/init.d/tailscale", "enabled", 3)' \
    'running = checked_init_state(' \
    'local final_identity, final_uptime =' \
    'observed_tailscaled_process_identity()' \
    'same_tailscaled_process_identity(joined_identity, final_identity)'
assert_order "generation replacement fails live connectivity closed" \
    "$TAILSCALE_PROJECTION" \
    'elseif status ~= nil and process_join_state == "restarted" then' \
    'reason = "process_restarted"' \
    'connected = false' \
    'degraded = backend == "Running"'
assert_contains "generation replacement cannot publish inherited uptime" \
    'process_uptime_seconds = nil' "$LUA_FILE"
assert_order "unjoined LocalAPI response fields are cleared before projection" \
    "$TAILSCALE_PROJECTION" \
    'if process_join_state ~= "stable" then' \
    'ips = {}' \
    'control_online = nil' \
    'key_expiry = nil' \
    'tun_available = nil' \
    'health_schema_valid = false'
assert_order "non-running backend responses also require a stable process join" \
    "$TAILSCALE_PROJECTION" \
    'elseif status ~= nil and process_join_state == "restarted" then' \
    'reason = "process_restarted"' \
    'elseif status ~= nil and process_join_state ~= "stable" then' \
    'reason = "process_generation_unknown"' \
    'elseif backend == "Running" then'
assert_order "Tailscale status endpoint reproves immediately before publish" \
    "$TAILSCALE_STATUS" \
    'http.prepare_content("application/json")' \
    'live_projection_reprove_generation(result, identity)' \
    'http.write(json.stringify(result))'
assert_order "fresh watchdog cache carries its exact generation into reproof" \
    "$TAILSCALE_GET" \
    'watchdog_snapshot_is_valid(parsed)' \
    'if parsed.process_generation ~= nil then' \
    'generation = parsed.process_generation' \
    'executable = TAILSCALED_BINARY' \
    'return project_watchdog_snapshot(parsed), nil, expected_identity'
assert_contains "generation reproof applies to watchdog and live projections" \
    'if type(projected) ~= "table" or not expected_identity then' "$LUA_FILE"
assert_order "failed generation reproof clears every current delivery proof" \
    "$LUA_FILE" \
    'projected.healthy = false' \
    'projected.connected = false' \
    'projected.local_api_responsive = nil' \
    'projected.process_generation = nil' \
    'projected.process_uptime_seconds = nil' \
    'projected.tailscale_ips = {}' \
    'projected.tun_available = nil' \
    'projected.valid_response_streak = 0'
assert_order "failed generation reproof clears cached peer reachability" \
    "$LUA_FILE" \
    'if projected.peer_configured == true then' \
    'projected.peer_state = "unknown"' \
    'projected.peer_reachable = nil'
assert_order "client peer projection is bracketed by generation proofs" \
    "$TAILSCALE_CLIENTS" \
    'same_tailscaled_process_identity(' \
    'local peers = project_tailscale_peers(ts_live)' \
    'current_identity = observed_tailscaled_process_identity()' \
    'same_tailscaled_process_identity(' \
    'result.tailscale_peers = peers'
assert_order "client publication drops peers on a last-moment generation swap" \
    "$TAILSCALE_CLIENTS" \
    'if published_peer_identity then' \
    'local current_identity = observed_tailscaled_process_identity()' \
    'if not same_tailscaled_process_identity(' \
    'result.tailscale_peers = nil' \
    'if not live_projection_reprove_generation(' \
    'result.tailscale_peers = nil' \
    'http.write(json.stringify(result))'
assert_contains "connected snapshots require positive continuity provenance" \
    'if parsed.connected_since_at <= 0 or' "$LUA_FILE"
assert_contains "running-degraded snapshots require the exact semantic state" \
    'if parsed.status == "running_degraded" then' "$LUA_FILE"
assert_contains "Lua tailnet parser rejects non-IP IPv6 suffix syntax" \
    'candidate:find("[^0-9a-f:]")' "$LUA_FILE"
assert_contains "Lua IPv6 compression must replace at least one group" \
    'left_count + right_count < 8' "$LUA_FILE"
assert_contains "Lua IPv4 parser rejects ambiguous leading-zero octets" \
    'not part:match("^[1-9]%d?%d?$")' "$LUA_FILE"

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

# A long operation and a forward/backward wall-clock jump cannot invalidate a
# live PID/start-tick generation. This model binds the source assertions above
# to the target's /proc identity contract without sleeping for ten minutes.
mkdir "$LOCK_MODEL"
_model_start_ticks=424242
cat >"${LOCK_MODEL}/owner" <<EOF
schema=1
pid=$$
start_ticks=${_model_start_ticks}
token=$$:${_model_start_ticks}:1:1
EOF
touch -t 197001010000 "${LOCK_MODEL}/owner" "$LOCK_MODEL"
_model_owner_pid="$(sed -n 's/^pid=//p' "${LOCK_MODEL}/owner")"
_model_owner_start="$(sed -n 's/^start_ticks=//p' "${LOCK_MODEL}/owner")"
_model_proc_generation="${TEST_DIR}/proc-generation.${_model_owner_pid}"
printf '%s\n' "$_model_start_ticks" >"$_model_proc_generation"
_model_live_start="$(cat "$_model_proc_generation")"
if [ "$_model_live_start" = "$_model_owner_start" ]; then
    pass "dynamic old-mtime lock remains owned by its live process generation"
else
    fail "dynamic old-mtime lock remains owned by its live process generation"
fi
rm -f "${LOCK_MODEL}/owner"
rmdir "$LOCK_MODEL"

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

# Dynamic model 4: target mount authority counts every row. Multiple stacked
# rows can never collapse into the same result as zero rows.
mount_authority_model() {
    awk -v target="/mnt/data" '
        $2 == target { count += 1 }
        END {
            if (count == 0) print "none:0"
            else if (count == 1) print "exact:1"
            else print "ambiguous:" count
        }
    ' "$1"
}

MOUNTS_NONE="${TEST_DIR}/mounts-none"
MOUNTS_ONE="${TEST_DIR}/mounts-one"
MOUNTS_TWO="${TEST_DIR}/mounts-two"
MOUNTS_THREE="${TEST_DIR}/mounts-three"
printf '/dev/root / ext4 rw 0 0\n' > "$MOUNTS_NONE"
printf '/dev/sda1 /mnt/data ext4 rw,noatime 0 0\n' > "$MOUNTS_ONE"
printf '%s\n' \
    '/dev/sda1 /mnt/data ext4 rw,noatime 0 0' \
    '/dev/sdb1 /mnt/data ext4 rw,noatime 0 0' > "$MOUNTS_TWO"
printf '%s\n' \
    '/dev/sdc1 /mnt/data ext4 rw,noatime 0 0' \
    '/dev/root / ext4 rw 0 0' \
    '/dev/sda1 /mnt/data ext4 rw,noatime 0 0' \
    '/dev/sdb1 /mnt/data ext4 rw,noatime 0 0' > "$MOUNTS_THREE"
if [ "$(mount_authority_model "$MOUNTS_NONE")" = "none:0" ] &&
   [ "$(mount_authority_model "$MOUNTS_ONE")" = "exact:1" ] &&
   [ "$(mount_authority_model "$MOUNTS_TWO")" = "ambiguous:2" ] &&
   [ "$(mount_authority_model "$MOUNTS_THREE")" = "ambiguous:3" ]; then
    pass "dynamic exact-one target authority distinguishes zero one and duplicates"
else
    fail "dynamic exact-one target authority distinguishes zero one and duplicates"
fi

# A persisted UUID has authority only when one removable live identity owns it.
uuid_authority_model() {
    _uuid="$1"
    _expected_source="$2"
    _expected_identity="$3"
    _fixture="$4"
    awk -F'|' -v uuid="$_uuid" -v source="$_expected_source" \
        -v identity="$_expected_identity" '
        $2 == uuid {
            count += 1
            if ($1 == source && $3 == "removable" && $4 == identity) {
                selected = 1
            }
            if ($3 != "removable") bad = 1
        }
        END { exit(count == 1 && selected == 1 && bad != 1 ? 0 : 1) }
    ' "$_fixture"
}

UUID_ONE="${TEST_DIR}/uuid-one"
UUID_CLONE="${TEST_DIR}/uuid-clone"
UUID_WRONG_ID="${TEST_DIR}/uuid-wrong-id"
printf '/dev/sda1|UUID-A|removable|8:1\n' > "$UUID_ONE"
printf '%s\n' \
    '/dev/sda1|UUID-A|removable|8:1' \
    '/dev/sdb1|UUID-A|removable|8:17' > "$UUID_CLONE"
printf '/dev/sda1|UUID-A|removable|8:9\n' > "$UUID_WRONG_ID"
if uuid_authority_model UUID-A /dev/sda1 8:1 "$UUID_ONE" &&
   ! uuid_authority_model UUID-A /dev/sda1 8:1 "$UUID_CLONE" &&
   ! uuid_authority_model UUID-A /dev/sda1 8:1 "$UUID_WRONG_ID"; then
    pass "dynamic UUID authority rejects clones and identity replacement"
else
    fail "dynamic UUID authority rejects clones and identity replacement"
fi

# Dynamic model 5: simulate process death at each durable storage phase, then
# run the same conservative recovery rules in a fresh invocation.
WAL_MOUNT="${TEST_DIR}/wal-mount"
WAL_FSTAB="${TEST_DIR}/wal-fstab"
WAL_FSTAB_SNAPSHOT="${TEST_DIR}/wal-fstab.snapshot"
WAL_COLLECTOR="${TEST_DIR}/wal-collector"
WAL_JOURNAL="${TEST_DIR}/wal-journal"
WAL_MARKER="${TEST_DIR}/wal-marker"
WAL_OLD_MOUNT=old

wal_reset_model() {
    WAL_OLD_MOUNT="${1:-old}"
    printf '%s\n' "$WAL_OLD_MOUNT" > "$WAL_MOUNT"
    printf 'config mount old\n\toption uuid OLD\n' > "$WAL_FSTAB"
    cp "$WAL_FSTAB" "$WAL_FSTAB_SNAPSHOT"
    printf 'running\n' > "$WAL_COLLECTOR"
    printf 'prepared\n' > "$WAL_JOURNAL"
    rm -f "$WAL_MARKER"
}

wal_apply_mount_phase_model() {
    _phase="$1"
    printf '%s\n' "$_phase" > "$WAL_JOURNAL"
    case "$_phase" in
        prepared) ;;
        collector_stopped)
            printf 'stopped\n' > "$WAL_COLLECTOR" ;;
        old_unmounted|new_mounting)
            printf 'stopped\n' > "$WAL_COLLECTOR"
            printf 'none\n' > "$WAL_MOUNT" ;;
        new_mounted|fstab_writing)
            printf 'stopped\n' > "$WAL_COLLECTOR"
            printf 'new\n' > "$WAL_MOUNT" ;;
        fstab_persisted)
            printf 'stopped\n' > "$WAL_COLLECTOR"
            printf 'new\n' > "$WAL_MOUNT"
            printf 'config mount new\n\toption uuid NEW\n' > "$WAL_FSTAB" ;;
    esac
}

wal_apply_init_phase_model() {
    _phase="$1"
    printf '%s\n' "$_phase" > "$WAL_JOURNAL"
    printf 'config mount new\n\toption uuid NEW\n' > "$WAL_FSTAB"
    case "$_phase" in
        fstab_persisted) ;;
        collector_stopped)
            printf 'stopped\n' > "$WAL_COLLECTOR" ;;
        collector_started)
            printf 'running-new-generation\n' > "$WAL_COLLECTOR" ;;
    esac
}

wal_recover_model() {
    _operation="$1"
    _phase="$2"
    _mount="$(sed -n '1p' "$WAL_MOUNT")"
    case "$_operation:$_phase" in
        format:format_started)
            printf 'unresolved\n' > "$WAL_MARKER"
            return 1
            ;;
        format:format_verified)
            [ "$_mount" = "none" ] || {
                printf 'unresolved\n' > "$WAL_MARKER"
                return 1
            }
            rm -f "$WAL_MARKER" "$WAL_JOURNAL"
            return 0
            ;;
    esac
    case "$_mount" in
        ambiguous|unavailable)
            printf 'unresolved\n' > "$WAL_MARKER"
            return 1
            ;;
        old)
            [ "$WAL_OLD_MOUNT" = "old" ] || {
                printf 'unresolved\n' > "$WAL_MARKER"
                return 1
            }
            ;;
        new)
            case "$_operation:$_phase" in
                mount:new_mounted|mount:fstab_writing|mount:fstab_persisted)
                    printf 'none\n' > "$WAL_MOUNT"
                    ;;
                *)
                    printf 'unresolved\n' > "$WAL_MARKER"
                    return 1
                    ;;
            esac
            ;;
        none) ;;
        *)
            printf 'unresolved\n' > "$WAL_MARKER"
            return 1
            ;;
    esac
    cp "$WAL_FSTAB_SNAPSHOT" "$WAL_FSTAB"
    printf '%s\n' "$WAL_OLD_MOUNT" > "$WAL_MOUNT"
    printf 'running\n' > "$WAL_COLLECTOR"
    rm -f "$WAL_MARKER" "$WAL_JOURNAL"
}

_mount_recovery_ok=1
for _phase in prepared collector_stopped old_unmounted new_mounting \
    new_mounted fstab_writing fstab_persisted
do
    wal_reset_model old
    wal_apply_mount_phase_model "$_phase"
    wal_recover_model mount "$_phase" || _mount_recovery_ok=0
    [ "$(sed -n '1p' "$WAL_MOUNT")" = "old" ] ||
        _mount_recovery_ok=0
    [ "$(sed -n '1p' "$WAL_COLLECTOR")" = "running" ] ||
        _mount_recovery_ok=0
    cmp -s "$WAL_FSTAB" "$WAL_FSTAB_SNAPSHOT" ||
        _mount_recovery_ok=0
    [ ! -e "$WAL_JOURNAL" ] && [ ! -e "$WAL_MARKER" ] ||
        _mount_recovery_ok=0
done
if [ "$_mount_recovery_ok" -eq 1 ]; then
    pass "dynamic mount WAL restores exact pre-state after every proven phase"
else
    fail "dynamic mount WAL restores exact pre-state after every proven phase"
fi

_init_recovery_ok=1
for _phase in fstab_persisted collector_stopped collector_started; do
    wal_reset_model old
    wal_apply_init_phase_model "$_phase"
    wal_recover_model init "$_phase" || _init_recovery_ok=0
    [ "$(sed -n '1p' "$WAL_MOUNT")" = "old" ] ||
        _init_recovery_ok=0
    [ "$(sed -n '1p' "$WAL_COLLECTOR")" = "running" ] ||
        _init_recovery_ok=0
    cmp -s "$WAL_FSTAB" "$WAL_FSTAB_SNAPSHOT" ||
        _init_recovery_ok=0
done
if [ "$_init_recovery_ok" -eq 1 ]; then
    pass "dynamic init WAL restores fstab mount and prior collector state"
else
    fail "dynamic init WAL restores fstab mount and prior collector state"
fi

# A prepared/new_mounting intent does not prove ownership of a mount that may
# have appeared after reboot from the prior fstab. It must remain unresolved.
_intent_race_ok=1
for _phase in prepared new_mounting; do
    wal_reset_model none
    printf 'new\n' > "$WAL_MOUNT"
    printf '%s\n' "$_phase" > "$WAL_JOURNAL"
    wal_recover_model mount "$_phase" && _intent_race_ok=0
    [ "$(sed -n '1p' "$WAL_MOUNT")" = "new" ] ||
        _intent_race_ok=0
    [ -e "$WAL_JOURNAL" ] && [ -e "$WAL_MARKER" ] ||
        _intent_race_ok=0
done
if [ "$_intent_race_ok" -eq 1 ]; then
    pass "dynamic prepared and armed intent never claims reboot-mounted storage"
else
    fail "dynamic prepared and armed intent never claims reboot-mounted storage"
fi

wal_reset_model old
wal_apply_mount_phase_model new_mounted
printf 'ambiguous\n' > "$WAL_MOUNT"
if ! wal_recover_model mount new_mounted &&
   [ "$(sed -n '1p' "$WAL_MOUNT")" = "ambiguous" ] &&
   [ -e "$WAL_JOURNAL" ] && [ -e "$WAL_MARKER" ]; then
    pass "dynamic ambiguous recovery keeps journal and unresolved marker"
else
    fail "dynamic ambiguous recovery keeps journal and unresolved marker"
fi

wal_reset_model old
printf 'stopped\n' > "$WAL_COLLECTOR"
printf 'none\n' > "$WAL_MOUNT"
printf 'format_started\n' > "$WAL_JOURNAL"
printf 'config mount cleared\n' > "$WAL_FSTAB"
if ! wal_recover_model format format_started &&
   [ "$(sed -n '1p' "$WAL_MOUNT")" = "none" ] &&
   [ "$(sed -n '1p' "$WAL_COLLECTOR")" = "stopped" ] &&
   [ -e "$WAL_JOURNAL" ] && [ -e "$WAL_MARKER" ]; then
    pass "dynamic format_started evidence forbids old-data rollback"
else
    fail "dynamic format_started evidence forbids old-data rollback"
fi

format_boundary_model() {
    _identity="$1"
    _source_mounts="$2"
    _target_mounts="$3"
    [ "$_identity" = "same" ] &&
        [ "$_source_mounts" -eq 0 ] &&
        [ "$_target_mounts" -eq 0 ]
}
if format_boundary_model same 0 0 &&
   ! format_boundary_model changed 0 0 &&
   ! format_boundary_model same 1 1 &&
   ! format_boundary_model same 0 1; then
    pass "dynamic format boundary suppresses mkfs after remount or identity swap"
else
    fail "dynamic format boundary suppresses mkfs after remount or identity swap"
fi

storage_phase_model() {
    case "$1:$2" in
        mount:prepared|mount:new_mounting|mount:new_mounted|\
        mount:fstab_writing|mount:fstab_persisted|\
        init:prepared|init:fstab_writing|init:fstab_persisted|\
        init:collector_started|\
        format:prepared|format:fstab_writing|format:fstab_persisted|\
        format:format_arming|format:format_started|format:format_verified)
            return 0 ;;
        *) return 1 ;;
    esac
}
if storage_phase_model mount new_mounted &&
   storage_phase_model init collector_started &&
   storage_phase_model format format_started &&
   ! storage_phase_model mount format_started &&
   ! storage_phase_model format new_mounted &&
   ! storage_phase_model init old_unmounted; then
    pass "dynamic journal state machine rejects cross-operation phases"
else
    fail "dynamic journal state machine rejects cross-operation phases"
fi

# Dynamic model 6: adversarial LocalAPI fixtures preserve the semantic
# distinction that Lua tables erase for empty JSON arrays and objects. The
# source contracts above bind this model to jsonfilter's exact type result.
HEALTH_ARRAY_FIXTURE='{"BackendState":"Running","Health":[]}'
HEALTH_OBJECT_FIXTURE='{"BackendState":"Running","Health":{}}'
fixture_health_type() {
    node -e '
        const value = JSON.parse(process.argv[1]).Health;
        process.stdout.write(Array.isArray(value) ? "array" :
            (value !== null && typeof value === "object" ? "object" :
            typeof value));
    ' "$1"
}
if [ "$(fixture_health_type "$HEALTH_ARRAY_FIXTURE")" = "array" ] &&
   [ "$(fixture_health_type "$HEALTH_OBJECT_FIXTURE")" = "object" ]; then
    pass "adversarial Health fixtures distinguish empty array from object"
else
    fail "adversarial Health fixtures distinguish empty array from object"
fi

fixture_generation_join() {
    _health_type="$1"
    _before="$2"
    _after="$3"
    _after_aux="$4"
    _before_publish="$5"
    if [ -z "$_before" ] ||
       [ "$_before" != "$_after" ] ||
       [ "$_after" != "$_after_aux" ] ||
       [ "$_after_aux" != "$_before_publish" ]; then
        printf 'healthy=false;connected=false;generation=null;uptime=null\n'
        return
    fi
    if [ "$_health_type" != "array" ]; then
        printf 'healthy=false;connected=false;generation=%s;uptime=10\n' \
            "$_before"
        return
    fi
    printf 'healthy=true;connected=true;generation=%s;uptime=10\n' "$_before"
}

GENERATION_A='4242:10000:/usr/sbin/tailscaled'
GENERATION_B='4243:20000:/usr/sbin/tailscaled'
_healthy_join="$(fixture_generation_join array \
    "$GENERATION_A" "$GENERATION_A" "$GENERATION_A" "$GENERATION_A")"
_health_object_join="$(fixture_generation_join object \
    "$GENERATION_A" "$GENERATION_A" "$GENERATION_A" "$GENERATION_A")"
_status_swap_join="$(fixture_generation_join array \
    "$GENERATION_A" "$GENERATION_B" "$GENERATION_B" "$GENERATION_B")"
_aux_swap_join="$(fixture_generation_join array \
    "$GENERATION_A" "$GENERATION_A" "$GENERATION_B" "$GENERATION_B")"
_publish_swap_join="$(fixture_generation_join array \
    "$GENERATION_A" "$GENERATION_A" "$GENERATION_A" "$GENERATION_B")"

case "$_healthy_join" in
    healthy=true\;connected=true\;generation="$GENERATION_A"\;uptime=10)
        pass "stable exact PID start-ticks executable fixture may be healthy" ;;
    *) fail "stable exact PID start-ticks executable fixture may be healthy" ;;
esac
case "$_health_object_join" in
    healthy=false\;connected=false\;generation="$GENERATION_A"\;uptime=10)
        pass "Health object fails closed without erasing proven process identity" ;;
    *) fail "Health object fails closed without erasing proven process identity" ;;
esac
for _fixture_result in \
    "$_status_swap_join" \
    "$_aux_swap_join" \
    "$_publish_swap_join"
do
    case "$_fixture_result" in
        'healthy=false;connected=false;generation=null;uptime=null') ;;
        *)
            fail "generation and Health adversarial fixtures fail closed"
            _fixture_result=
            break
            ;;
    esac
done
if [ -n "${_fixture_result:-}" ]; then
    pass "generation and Health adversarial fixtures fail closed"
fi

fixture_cached_reproof() {
    _cached_generation="$1"
    _current_generation="$2"
    if [ -z "$_current_generation" ] ||
       [ "$_cached_generation" != "$_current_generation" ]; then
        printf 'healthy=false;connected=false;generation=null;uptime=null\n'
        return
    fi
    printf 'healthy=true;connected=true;generation=%s;uptime=10\n' \
        "$_cached_generation"
}

_cached_stable="$(fixture_cached_reproof "$GENERATION_A" "$GENERATION_A")"
_cached_swap="$(fixture_cached_reproof "$GENERATION_A" "$GENERATION_B")"
_cached_missing="$(fixture_cached_reproof "$GENERATION_A" "")"
case "$_cached_stable" in
    healthy=true\;connected=true\;generation="$GENERATION_A"\;uptime=10) ;;
    *) fail "fresh cached generation fixtures fail closed"; _cached_swap= ;;
esac
for _fixture_result in "$_cached_swap" "$_cached_missing"; do
    case "$_fixture_result" in
        'healthy=false;connected=false;generation=null;uptime=null') ;;
        *)
            fail "fresh cached generation fixtures fail closed"
            _cached_swap=
            break
            ;;
    esac
done
if [ -n "${_cached_swap:-}" ]; then
    pass "fresh cached generation fixtures fail closed"
fi

# Adversarial model for the exact lexical, finite, integer, and range contract
# asserted above. This keeps hostile query strings in the regression matrix on
# hosts that do not ship the router's Lua runtime.
history_integer_model() {
    _raw="$1"
    _minimum="$2"
    _maximum="$3"
    [ -n "$_raw" ] && [ "${#_raw}" -le 16 ] || return 1
    case "$_raw" in
        *[!0-9]*) return 1 ;;
    esac
    awk -v value="$_raw" -v minimum="$_minimum" -v maximum="$_maximum" '
        BEGIN {
            numeric = value + 0
            exit !(numeric == numeric && numeric >= minimum &&
                   numeric <= maximum && numeric == int(numeric))
        }
    '
}

_time_adversarial_ok=1
for _raw in \
    nan NaN inf Infinity -1 +1 1.0 1e3 0x10 \
    4102444801 9999999999999999 abc
do
    if history_integer_model "$_raw" 0 4102444800; then
        _time_adversarial_ok=0
    fi
done
for _raw in 0 1 1720000000 4102444800; do
    history_integer_model "$_raw" 0 4102444800 ||
        _time_adversarial_ok=0
done
if [ "$_time_adversarial_ok" -eq 1 ]; then
    pass "adversarial history integers reject NaN infinity signs fractions exponents and huge values"
else
    fail "adversarial history integers reject NaN infinity signs fractions exponents and huge values"
fi

_time_order_ok=1
for _pair in '10 10' '11 10' '4102444800 4102444800'; do
    set -- $_pair
    if history_integer_model "$1" 0 4102444800 &&
       history_integer_model "$2" 0 4102444800 &&
       [ "$1" -lt "$2" ]; then
        _time_order_ok=0
    fi
done
if history_integer_model 10 0 4102444800 &&
   history_integer_model 11 0 4102444800 &&
   [ 10 -lt 11 ]; then
    :
else
    _time_order_ok=0
fi
if [ "$_time_order_ok" -eq 1 ]; then
    pass "adversarial history ranges reject equal and reversed endpoints"
else
    fail "adversarial history ranges reject equal and reversed endpoints"
fi

printf '1..%s\n' "$((PASS_COUNT + FAIL_COUNT))"
[ "$FAIL_COUNT" -eq 0 ]
