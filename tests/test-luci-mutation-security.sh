#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUA_FILE="$ROOT_DIR/jammonitor.lua"
JS_FILE="$ROOT_DIR/jammonitor.js"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jammonitor-luci-security.XXXXXX")"
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

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

assert_order() {
    description=$1
    file=$2
    shift 2
    previous=0
    for needle in "$@"; do
        line="$(grep -nF -- "$needle" "$file" |
            awk -F: -v previous="$previous" '$1 > previous { print $1; exit }')"
        if [ -z "$line" ]; then
            fail "$description"
            return
        fi
        previous=$line
    done
    pass "$description"
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
assert_fixed "Mutations use atomic non-stealable directory locks" \
    'local function acquire_lock_dir(path, _stale_seconds)' "$LUA_FILE"
assert_fixed "Lock ownership includes exact process start ticks" \
    'lock_process_start_ticks(owner.pid) == owner.start_ticks' "$LUA_FILE"
assert_fixed "Lock cleanup requires its unguessable owner token" \
    'local function release_lock_dir(path, token)' "$LUA_FILE"
assert_absent "Wall-clock age cannot steal a live mutation lock" \
    'os.time() - tonumber(stat.mtime)' "$LUA_FILE"
assert_fixed "Mutation lock cleanup survives Lua errors" \
    'local called, first, second = pcall(operation)' "$LUA_FILE"
assert_fixed "Mutable LuCI state uses a root-only runtime directory" \
    'local LUCI_RUNTIME_DIRECTORY = "/var/run/jammonitor-luci"' "$LUA_FILE"
assert_fixed "nixio private file mode uses chmod-style digits" \
    'local PRIVATE_FILE_MODE = 600' "$LUA_FILE"
assert_absent "nixio modes are not misencoded as C permission bits" \
    'tonumber("600", 8)' "$LUA_FILE"
assert_fixed "Metadata read-modify-write is locked" \
    'local lock_path = LUCI_RUNTIME_DIRECTORY .. "/client-meta.lock"' "$LUA_FILE"
assert_fixed "Atomic writes create temporary inodes exclusively" \
    'nixio.open_flags("wronly", "creat", "excl")' "$LUA_FILE"
assert_fixed "Atomic writes fsync before publication" \
    'descriptor:sync(false)' "$LUA_FILE"
assert_fixed "Atomic writes verify the opened inode before rename" \
    'after.dev ~= opened.dev or after.ino ~= opened.ino' "$LUA_FILE"
assert_fixed "Atomic rename publication fsyncs its parent directory" \
    'if renamed then return sync_parent_directory(path) end' "$LUA_FILE"
assert_fixed "Persistent removals fsync their parent directory" \
    'local function durable_remove(path)' "$LUA_FILE"
assert_fixed "Captured command output has a kernel 64 KiB ceiling" \
    '(ulimit -f 128 || exit 125; ' "$LUA_FILE"
assert_fixed "History syslog reads seek directly to a bounded tail" \
    'read_bounded_regular_tail(path, max_bytes, 0)' "$LUA_FILE"
assert_fixed "History syslog authorization enforces a 64 KiB ceiling" \
    'max_bytes > 65536' "$LUA_FILE"
assert_fixed "History export classifies every source string before publication" \
    'local function history_string_contains_secret(value)' "$LUA_FILE"
assert_fixed "History export redaction uses a neutral replacement" \
    'return "[content removed]"' "$LUA_FILE"
assert_fixed "Raw JWT structure is detected without requiring a key label" \
    '"eyj[%w_%-]*%.[%w_%-]+%.[%w_%-]+"' "$LUA_FILE"
assert_fixed "History export has a response-wide secret detector" \
    'local function history_export_secret_detected(value, depth, budget)' \
    "$LUA_FILE"
assert_fixed "History export fails closed before serializing suspected bytes" \
    'error = "history_export_redaction_failed"' "$LUA_FILE"
assert_order "History detector precedes successful bundle serialization" \
    "$LUA_FILE" \
    'if history_export_secret_detected(bundle) then' \
    'error = "history_export_redaction_failed"' \
    'http.header("Content-Disposition"' \
    'http.write(json.stringify(bundle))'
assert_fixed "Speed tests use a global concurrency lease" \
    'local SPEEDTEST_LOCK = LUCI_RUNTIME_DIRECTORY .. "/speedtest.lock"' "$LUA_FILE"
assert_fixed "Speed-test status reads are regular and bounded" \
    'local content = read_bounded_regular_file(job_file, 16384)' "$LUA_FILE"
assert_absent "Speed-test jobs never use attacker-writable tmp" \
    '/tmp/jammonitor_speedtest' "$LUA_FILE"
assert_fixed "Speed-test job IDs include process identity" \
    'job_iface, direction, os.time(), nixio.getpid(), speedtest_job_sequence' "$LUA_FILE"
assert_fixed "Diagnostic generation has a hard external deadline" \
    '"timeout -s TERM -k 2 90 " .. worker_file' "$LUA_FILE"
assert_fixed "Diagnostic outputs have a kernel file-size ceiling" \
    'ulimit -f 2048 || exit 1' "$LUA_FILE"
assert_fixed "Volatile diagnostic reads require root-owned regular files" \
    'bounded_root_volatile_file() {' "$LUA_FILE"
assert_fixed "Volatile diagnostic reads have byte and time caps" \
    'bs=4096 count=16 2>/dev/null' "$LUA_FILE"
assert_absent "Diagnostics never wildcard-cat attacker-controlled tmp paths" \
    'cat /tmp/openmptcprouter_' "$LUA_FILE"
assert_fixed "Diagnostic archives are bounded before download" \
    'before.size < 1 or before.size > 32 * 1024 * 1024' "$LUA_FILE"
assert_absent "Diagnostics never clobber a fixed tmp archive" \
    '/tmp/jammonitor-diag.tar.gz' "$LUA_FILE"
assert_fixed "Every diagnostic text file crosses centralized redaction" \
    'redact_all_diagnostics || exit 1' "$LUA_FILE"
assert_fixed "Post-redaction secret detection fails archive generation closed" \
    'if diagnostic_secret_detected; then' "$LUA_FILE"
assert_fixed "Tailscale authentication URLs are explicitly redacted" \
    'login\.tailscale\.com/a/[A-Za-z0-9_-]+' "$LUA_FILE"
assert_fixed "Tailscale key prefixes are explicitly redacted" \
    'tskey-(auth|client|api|scoped)-' "$LUA_FILE"
assert_absent "Diagnostics never archive or echo suspected leak content" \
    'JWT_LEAKS|TOKEN_LEAKS|PASS_LEAKS|KEY_LEAKS' "$LUA_FILE"

REDACTION_FUNCTIONS="${TEST_DIR}/redaction-functions.sh"
awk '
    /^(redact_sensitive|diagnostic_secret_detected)[(][)] [{]$/ {
        copying = 1
    }
    copying { print }
    copying && /^}$/ { copying = 0; found++ }
    END { if (found != 2) exit 1 }
' "$LUA_FILE" >"$REDACTION_FUNCTIONS"
# shellcheck disable=SC1090
. "$REDACTION_FUNCTIONS"

REDACTION_DIR="${TEST_DIR}/redaction"
mkdir -p "$REDACTION_DIR"
cat >"${REDACTION_DIR}/injected.txt" <<'EOF'
AuthURL: https://login.tailscale.com/a/AuthCodeSentinel123
auth-key=tskey-auth-k-authsentinel123
Authorization: Bearer bearer.sentinel.value
option password 'router-password-sentinel'
{"client_secret":"oauth-secret-sentinel"}
machinekey:machinekeysentinel123
client_secret="quoted secret with spaces sentinel"
password: "colon secret with spaces and tail sentinel"
token=first-multi-sentinel password="second multi secret sentinel"
EOF
redact_sensitive <"${REDACTION_DIR}/injected.txt" \
    >"${REDACTION_DIR}/safe.txt"
if grep -Eq \
    'AuthCodeSentinel|authsentinel|bearer\.sentinel|router-password-sentinel|oauth-secret-sentinel|machinekeysentinel|quoted secret|colon secret|multi-sentinel|multi secret' \
    "${REDACTION_DIR}/safe.txt"; then
    fail "Injected log and status secrets survive centralized redaction"
else
    pass "Injected AuthURL, key, bearer, config, JSON, and machine secrets are redacted"
fi
if ! grep -Eq \
    '<REDACTED>|<TAILSCALE_KEY_REDACTED>' \
    "${REDACTION_DIR}/safe.txt"; then
    fail "Centralized redaction does not leave explicit safe placeholders"
else
    pass "Centralized redaction leaves explicit safe placeholders"
fi
rm -f "${REDACTION_DIR}/injected.txt"
DIAGDIR="$REDACTION_DIR"
if diagnostic_secret_detected; then
    fail "Post-redaction detector rejects a clean sanitized diagnostic"
else
    pass "Post-redaction detector accepts sanitized diagnostics"
fi
printf '%s\n' \
    'AuthURL: https://login.tailscale.com/a/StillSecret123' \
    >"${REDACTION_DIR}/raw.txt"
DETECTOR_OUTPUT="${TEST_DIR}/detector-output"
if diagnostic_secret_detected >"$DETECTOR_OUTPUT" 2>&1; then
    if [ -s "$DETECTOR_OUTPUT" ]; then
        fail "Secret detector echoes the suspected secret content"
    else
        pass "Secret detector fails closed without echoing suspected content"
    fi
else
    fail "Post-redaction detector misses an injected Tailscale AuthURL"
fi

# The history exporter uses this literal marker table in both its source
# sanitizer and its final response-wide detector. Exercise representative
# quoted and unquoted secret forms against the exact checked-in table.
HISTORY_MARKERS="${TEST_DIR}/history-markers"
awk '
    /^local HISTORY_EXPORT_SECRET_MARKERS = [{]$/ { capture = 1; next }
    capture && /^}/ { exit }
    capture {
        line = $0
        while (match(line, /"[^"]+"/)) {
            print substr(line, RSTART + 1, RLENGTH - 2)
            line = substr(line, RSTART + RLENGTH)
        }
    }
' "$LUA_FILE" >"$HISTORY_MARKERS"

history_marker_detects() {
    _history_fixture="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r _history_marker; do
        case "$_history_fixture" in
            *"$_history_marker"*) return 0 ;;
        esac
    done <"$HISTORY_MARKERS"
    return 1
}

_history_marker_ok=1
while IFS= read -r _history_fixture; do
    history_marker_detects "$_history_fixture" || _history_marker_ok=0
done <<'EOF'
password="quoted-password-sentinel"
password=unquoted-password-sentinel
AuthURL: https://login.tailscale.com/a/AuthCodeSentinel
auth-key=tskey-auth-k-historysentinel
Authorization: Bearer header.payload.signature
jwt=eyJhbGciOiJIUzI1NiJ9.payload.signature
nodekey:nodekey-historysentinel
machinekey:machinekey-historysentinel
privkey:privkey-historysentinel
private_key="private-key-historysentinel"
EOF
if [ "$_history_marker_ok" -eq 1 ]; then
    pass "History policy detects quoted, unquoted, AuthURL, Tailscale, bearer, JWT, and key fixtures"
else
    fail "History policy detects quoted, unquoted, AuthURL, Tailscale, bearer, JWT, and key fixtures"
fi

if printf '%s\n' \
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJoaXN0b3J5In0.signature' |
    grep -Eq '^[Ee][Yy][Jj][[:alnum:]_-]*[.][[:alnum:]_-]+[.][[:alnum:]_-]+$'; then
    pass "History policy adversarial fixture covers an unlabeled raw JWT"
else
    fail "History policy adversarial fixture covers an unlabeled raw JWT"
fi

assert_fixed "History source sanitizer invokes the shared classifier" \
    'if history_string_contains_secret(value) then' "$LUA_FILE"
assert_fixed "History post-redaction detector invokes the shared classifier" \
    'return history_string_contains_secret(value)' "$LUA_FILE"

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
