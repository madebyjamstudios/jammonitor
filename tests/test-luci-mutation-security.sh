#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUA_FILE="$ROOT_DIR/jammonitor.lua"
JS_FILE="$ROOT_DIR/jammonitor.js"
PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

assert_fixed() {
    description=$1
    needle=$2
    file=$3
    if grep -Fq -- "$needle" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_regex() {
    description=$1
    pattern=$2
    file=$3
    if grep -Eq -- "$pattern" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_absent() {
    description=$1
    pattern=$2
    file=$3
    if grep -Eq -- "$pattern" "$file"; then
        fail "$description"
    else
        pass "$description"
    fi
}

for route in \
    wan_policy_set wan_edit wan_advanced_set wan_ifaces_set bypass_set \
    storage_format storage_mount storage_init set_client_meta \
    set_reservation delete_reservation speedtest_start
do
    assert_regex \
        "$route is a LuCI post route" \
        "entry\\(.*\"$route\".*post\\(\"action_$route\"\\)" \
        "$LUA_FILE"
done

for route in wan_policy wan_advanced wan_ifaces bypass
do
    assert_regex \
        "$route remains a read-only call route" \
        "entry\\(.*\"$route\".*call\\(\"action_$route\"\\)" \
        "$LUA_FILE"
done

assert_absent \
    "Lua has no mixed request-method mutation branches" \
    'REQUEST_METHOD|method[[:space:]]*==[[:space:]]*"POST"|method[[:space:]]*~=[[:space:]]*"POST"' \
    "$LUA_FILE"
assert_fixed "JSON requests have a hard body cap" 'local MAX_JSON_BODY = 65536' "$LUA_FILE"
assert_fixed "WAN selection is derived server-side" 'local function eligible_wans(uci)' "$LUA_FILE"
assert_fixed "Base wan interface is eligible" 'name:match("^wan%d*$")' "$LUA_FILE"
assert_fixed "OMR IPv6 system interface is excluded" 'name == "omr6in4"' "$LUA_FILE"
assert_fixed "Inactive multipath off is not standalone WAN authority" \
    'section.multipath == "on" or section.multipath == "backup"' "$LUA_FILE"
assert_fixed "WAN policy requires the exact selected set" 'Policy must cover the exact selected WAN set' "$LUA_FILE"
assert_fixed "WAN policy requires exactly one master" 'Exactly one master WAN is required' "$LUA_FILE"
assert_fixed "Bypass enable is an exact boolean" 'type(data.enable) ~= "boolean"' "$LUA_FILE"
assert_fixed "Storage format requires exact confirmation" 'if params.confirm ~= "FORMAT" then' "$LUA_FILE"
assert_fixed "Client aliases reject controls" 'alias:find("%c")' "$LUA_FILE"
assert_fixed "Client device types use an allowlist" 'not VALID_DEVICE_TYPES[dtype]' "$LUA_FILE"
assert_fixed "Reservation hostnames use the bounded validator" 'local safe_name = validate_hostname(name or "")' "$LUA_FILE"
assert_fixed "Speed tests require a selected WAN" 'not selected_set[safe_iface]' "$LUA_FILE"
assert_fixed "Speed-test source addresses are revalidated" 'local bind_arg = validate_ip(source_ip) or validate_iface(l3_device)' "$LUA_FILE"
assert_fixed "Mutations use atomic directory locks" 'local function acquire_lock_dir(path, stale_seconds)' "$LUA_FILE"
assert_fixed "Mutation lock cleanup survives Lua errors" \
    'local called, first, second = pcall(operation)' "$LUA_FILE"
assert_fixed "Metadata read-modify-write is locked" 'local lock_path = "/tmp/jammonitor-client-meta.lock"' "$LUA_FILE"
assert_fixed "Atomic writes use unique temporary paths" '"%s.tmp.%d.%d.%d"' "$LUA_FILE"
assert_fixed "Speed tests use a global concurrency lease" \
    'local SPEEDTEST_LOCK = "/tmp/jammonitor_speedtest.lock"' "$LUA_FILE"
assert_fixed "Speed-test job IDs include process identity" \
    'job_iface, direction, os.time(), nixio.getpid(), speedtest_job_sequence' "$LUA_FILE"

assert_fixed "Frontend requires the LuCI environment token" 'typeof L.env.token !== '\''string'\''' "$JS_FILE"
assert_fixed "Frontend POSTs use same-origin credentials" 'credentials: '\''same-origin'\''' "$JS_FILE"
assert_fixed "Frontend checks HTTP status before JSON" 'if (!response.ok)' "$JS_FILE"
assert_fixed "Frontend has centralized JSON POSTs" 'function postJson(endpoint, payload)' "$JS_FILE"
assert_fixed "Frontend has centralized form POSTs" 'function postForm(endpoint, params)' "$JS_FILE"
assert_absent \
    "Frontend has no direct fetch to a mutator" \
    "fetch\\([^\\n]*(set_client_meta|set_reservation|delete_reservation|bypass_set|wan_edit|wan_policy_set|wan_advanced_set|wan_ifaces_set|storage_format|storage_mount|storage_init|speedtest_start)" \
    "$JS_FILE"
assert_fixed "WAN policy data-iface is HTML escaped" \
    'data-iface="'\'' + escapeHtml(iface.name)' "$JS_FILE"
assert_fixed "WAN selector values are HTML escaped" \
    'value="'\'' + escapeHtml(iface.name)' "$JS_FILE"
assert_fixed "WAN selector device text is HTML escaped" \
    'wan-iface-item-device">'\'' + escapeHtml(iface.device)' "$JS_FILE"
assert_fixed "WAN interface maps have no Object prototype" \
    'var wanPolicyModes = Object.create(null);' "$JS_FILE"
assert_fixed "Frontend client mutations are serialized" \
    'var sequence = operations.reduce(function(promise, operation)' "$JS_FILE"

assert_fixed "Watchdog projection includes process generation" \
    '"process_generation",' "$LUA_FILE"
assert_fixed "Watchdog projection includes process uptime" \
    '"process_uptime_seconds", "backend_state"' "$LUA_FILE"
assert_fixed "Process uptime is bound to a validated generation" \
    'not parsed.process_generation:match("^%d+:%d+$")' "$LUA_FILE"
assert_absent \
    "Watchdog projection does not overwrite cached uptime with a live PID lookup" \
    'projected\.process_uptime_seconds[[:space:]]*=[[:space:]]*tailscaled_process_uptime' \
    "$LUA_FILE"

if command -v node >/dev/null 2>&1; then
    if node --check "$JS_FILE"; then
        pass "jammonitor.js parses"
    else
        fail "jammonitor.js parses"
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
