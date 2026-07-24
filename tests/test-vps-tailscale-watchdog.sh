#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WATCHDOG="${REPO_DIR}/vps/jammonitor-tailscale-watchdog"
SERVICE_UNIT="${REPO_DIR}/vps/jammonitor-tailscale-watchdog.service"
TIMER_UNIT="${REPO_DIR}/vps/jammonitor-tailscale-watchdog.timer"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jammonitor-vps-watchdog-test.XXXXXX")"
SOCKET_COUNTER=0

cleanup() {
    rm -f "${TMPDIR:-/tmp}/jmvps-watchdog-sock.$$."*
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

MOCK_BIN="${TEST_ROOT}/bin"
mkdir -p "$MOCK_BIN"

cat >"${MOCK_BIN}/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_ARGS_FILE}"
[ "${1:-}" = "--socket=${MOCK_EXPECTED_SOCKET}" ] || exit 91

if [ "${2:-}" = "ping" ]; then
    [ "${3:-}" = "--c=1" ] || exit 92
    [ "${4:-}" = "--timeout=3s" ] || exit 93
    [ "${5:-}" = "--until-direct=false" ] || exit 94
    [ "${6:-}" = "--" ] || exit 95
    [ -n "${7:-}" ] && [ "$#" -eq 7 ] || exit 96
    [ "${MOCK_PEER_MODE:-reachable}" = "reachable" ]
    exit
fi

[ "${2:-}" = "status" ] || exit 92
[ "${3:-}" = "--json" ] || exit 93
[ "${4:-}" = "--peers=false" ] || exit 94
[ "$#" -eq 4 ] || exit 95

case "${MOCK_TAILSCALE_MODE:-running}" in
    running)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":true,"TailscaleIPs":["100.70.186.127"]},"Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    running_warning)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":true,"TailscaleIPs":["100.70.186.127"]},"Health":["sentinel-health-secret"],"AuthURL":"sentinel-auth-url"}'
        ;;
    control_offline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":false,"InEngine":true,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    tun_off)
        printf '%s\n' '{"BackendState":"Running","TUN":false,"Self":{"Online":true,"InEngine":true,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    engine_off)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":false,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    no_address)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":true,"TailscaleIPs":[]},"Health":[]}'
        ;;
    invalid_address)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":true,"TailscaleIPs":["100.64.not-an-ip"]},"Health":[]}'
        ;;
    running_bad_schema)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"InEngine":true,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    needs_login)
        printf '%s\n' '{"BackendState":"NeedsLogin","Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    needs_machine_auth)
        printf '%s\n' '{"BackendState":"NeedsMachineAuth","Health":[]}'
        ;;
    stopped)
        printf '%s\n' '{"BackendState":"Stopped","Health":[]}'
        ;;
    unknown)
        printf '%s\n' '{"BackendState":"FutureState","Health":[]}'
        ;;
    malformed)
        printf '%s\n' 'not-json sentinel-auth-url'
        ;;
    health_bad_schema)
        printf '%s\n' '{"BackendState":"Running","Health":"sentinel-health-secret"}'
        ;;
    command_error)
        printf '%s\n' 'sentinel-command-error sentinel-auth-url' >&2
        exit 1
        ;;
    timeout)
        exit 88
        ;;
    timeout_137)
        exit 87
        ;;
    timeout_143)
        exit 86
        ;;
    block)
        fifo="${MOCK_CASE_DIR}/block-fifo"
        [ -p "$fifo" ] || mkfifo "$fifo"
        printf '%s\n' "$$" >"${MOCK_CASE_DIR}/blocked-child-pid"
        read -r ignored <"$fifo"
        ;;
    *)
        exit 89
        ;;
esac
EOF

cat >"${MOCK_BIN}/jq" <<'EOF'
#!/bin/sh
mode="${1:-}"
query="${2:-}"
file="${3:-}"
[ "$mode" = "-e" ] || [ "$mode" = "-r" ] || exit 2
[ -f "$file" ] || exit 2
raw="$(cat "$file")"

case "$query" in
    *'.BackendState | type == "string"'*)
        case "$raw" in
            not-json*|*'"Health":"'* ) exit 1 ;;
            *'"BackendState":"'* ) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *'.TUN | type == "boolean"'*)
        case "$raw" in
            *'"BackendState":"Running"'*'"Online":'*'"InEngine":'*'"TailscaleIPs":['*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *'any(.Self.TailscaleIPs[];'*)
        case "$raw" in
            *'"TailscaleIPs":["100.70.186.127"]'*|\
            *'"TailscaleIPs":["fd7a:115c:a1e0:'*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    '.TUN')
        case "$raw" in *'"TUN":true'*) printf 'true\n' ;; *) printf 'false\n' ;; esac
        ;;
    '.Self.Online')
        case "$raw" in *'"Online":true'*) printf 'true\n' ;; *) printf 'false\n' ;; esac
        ;;
    '.Self.InEngine')
        case "$raw" in *'"InEngine":true'*) printf 'true\n' ;; *) printf 'false\n' ;; esac
        ;;
    '(.Health // []) | length')
        case "$raw" in
            *'"Health":[]'*) printf '0\n' ;;
            *'"Health":['*) printf '1\n' ;;
            *) exit 1 ;;
        esac
        ;;
    '.BackendState')
        value="${raw#*\"BackendState\":\"}"
        [ "$value" != "$raw" ] || exit 1
        printf '%s\n' "${value%%\"*}"
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat >"${MOCK_BIN}/timeout" <<'EOF'
#!/bin/sh
[ "${1:-}" = "--signal=TERM" ] || exit 96
[ "${2:-}" = "--kill-after=2" ] || exit 97
shift 3
"$@" &
child=$!
terminate_child() {
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
}
trap 'terminate_child; exit 143' HUP INT TERM
wait "$child"
rc=$?
trap - HUP INT TERM
[ "$rc" -eq 88 ] && exit 124
[ "$rc" -eq 87 ] && exit 137
[ "$rc" -eq 86 ] && exit 143
exit "$rc"
EOF

cat >"${MOCK_BIN}/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_SYSTEMCTL_ARGS_FILE}"
case "${1:-}" in
    show)
        [ "${2:-}" = "--property=ActiveState" ] || exit 98
        [ "${3:-}" = "--property=UnitFileState" ] || exit 98
        [ "${4:-}" = "--property=NRestarts" ] || exit 98
        [ "${5:-}" = "--property=ExecMainStartTimestampMonotonic" ] || exit 98
        [ "${6:-}" = "tailscaled.service" ] || exit 99
        [ "${MOCK_SERVICE_STATE:-active}" != "query_error" ] || exit 4
        printf 'ActiveState=%s\n' "${MOCK_SERVICE_STATE:-active}"
        printf 'UnitFileState=%s\n' "${MOCK_UNIT_FILE_STATE:-enabled}"
        printf 'NRestarts=%s\n' "${MOCK_NRESTARTS:-0}"
        printf 'ExecMainStartTimestampMonotonic=%s\n' \
            "${MOCK_PROCESS_START_USEC:-100000000}"
        ;;
    restart)
        [ "${2:-}" = "tailscaled.service" ] || exit 99
        printf '%s\n' restart >>"${MOCK_ACTIONS_FILE}"
        exit "${MOCK_RESTART_RC:-0}"
        ;;
    *)
        exit 90
        ;;
esac
EOF

cat >"${MOCK_BIN}/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOG_FILE}"
EOF

cat >"${MOCK_BIN}/flock" <<'EOF'
#!/usr/bin/env python3
import fcntl
import sys

if sys.argv[1:] != ["-n", "9"]:
    raise SystemExit(2)
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
EOF

chmod 0755 "${MOCK_BIN}/tailscale" "${MOCK_BIN}/jq" \
    "${MOCK_BIN}/timeout" "${MOCK_BIN}/systemctl" "${MOCK_BIN}/logger" \
    "${MOCK_BIN}/flock"

PASS_COUNT=0

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

create_unix_socket() {
    _socket_path="$1"
    rm -f "$_socket_path"
    python3 - "$_socket_path" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
sock.close()
PY
}

new_case() {
    CASE_NAME="$1"
    CASE_DIR="${TEST_ROOT}/${CASE_NAME}"
    STATE_DIR="${CASE_DIR}/state"
    ACTIONS_FILE="${CASE_DIR}/actions"
    LOG_FILE="${CASE_DIR}/log"
    CLI_ARGS_FILE="${CASE_DIR}/cli-args"
    SYSTEMCTL_ARGS_FILE="${CASE_DIR}/systemctl-args"
    SOCKET_COUNTER=$((SOCKET_COUNTER + 1))
    SOCKET_PATH="${TMPDIR:-/tmp}/jmvps-watchdog-sock.$$.${SOCKET_COUNTER}"
    CRITICAL_PEER_PATH="${CASE_DIR}/critical-peer"
    mkdir -p "$STATE_DIR"
    : >"$ACTIONS_FILE"
    : >"$LOG_FILE"
    : >"$CLI_ARGS_FILE"
    : >"$SYSTEMCTL_ARGS_FILE"
    create_unix_socket "$SOCKET_PATH"
}

run_once() {
    _mode="$1"
    _service_rc="$2"
    _mono="$3"
    _epoch="$4"
    case "$_service_rc" in
        0) _service_state="active" ;;
        3) _service_state="inactive" ;;
        4) _service_state="query_error" ;;
        5) _service_state="activating" ;;
        *) _service_state="query_error" ;;
    esac
    env \
        MOCK_TAILSCALE_MODE="$_mode" \
        MOCK_PEER_MODE="${PEER_MODE_VALUE:-reachable}" \
        MOCK_EXPECTED_SOCKET="$SOCKET_PATH" \
        MOCK_SERVICE_STATE="$_service_state" \
        MOCK_UNIT_FILE_STATE="${UNIT_FILE_STATE_VALUE:-enabled}" \
        MOCK_NRESTARTS="${NRESTARTS_VALUE:-0}" \
        MOCK_PROCESS_START_USEC="${PROCESS_START_USEC_VALUE:-100000000}" \
        MOCK_RESTART_RC="${RESTART_RC_VALUE:-0}" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_ARGS_FILE="$CLI_ARGS_FILE" \
        MOCK_SYSTEMCTL_ARGS_FILE="$SYSTEMCTL_ARGS_FILE" \
        MOCK_CASE_DIR="$CASE_DIR" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_SOCKET="$SOCKET_PATH" \
        WATCHDOG_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        WATCHDOG_SYSTEMCTL_CMD="${MOCK_BIN}/systemctl" \
        WATCHDOG_TIMEOUT_CMD="${MOCK_BIN}/timeout" \
        WATCHDOG_JQ_CMD="${MOCK_BIN}/jq" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_STATUS_TIMEOUT=1 \
        WATCHDOG_PEER_TIMEOUT=1 \
        WATCHDOG_RESTART_TIMEOUT=1 \
        WATCHDOG_FAILURE_THRESHOLD="${THRESHOLD_VALUE:-3}" \
        WATCHDOG_VALID_STREAK_REQUIRED="${STREAK_VALUE:-5}" \
        WATCHDOG_BOOT_GRACE="${BOOT_GRACE_VALUE:-0}" \
        WATCHDOG_MAINTENANCE_MAX_FUTURE=3600 \
        WATCHDOG_NOW_MONO="$_mono" \
        WATCHDOG_NOW_EPOCH="$_epoch" \
        /bin/dash "$WATCHDOG" --once
}

start_blocking_watchdog() {
    env \
        MOCK_TAILSCALE_MODE=block \
        MOCK_PEER_MODE=reachable \
        MOCK_EXPECTED_SOCKET="$SOCKET_PATH" \
        MOCK_SERVICE_STATE=active \
        MOCK_UNIT_FILE_STATE=enabled \
        MOCK_NRESTARTS=0 \
        MOCK_PROCESS_START_USEC=100000000 \
        MOCK_RESTART_RC=0 \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_ARGS_FILE="$CLI_ARGS_FILE" \
        MOCK_SYSTEMCTL_ARGS_FILE="$SYSTEMCTL_ARGS_FILE" \
        MOCK_CASE_DIR="$CASE_DIR" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_SOCKET="$SOCKET_PATH" \
        WATCHDOG_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        WATCHDOG_SYSTEMCTL_CMD="${MOCK_BIN}/systemctl" \
        WATCHDOG_TIMEOUT_CMD="${MOCK_BIN}/timeout" \
        WATCHDOG_JQ_CMD="${MOCK_BIN}/jq" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_STATUS_TIMEOUT=30 \
        WATCHDOG_PEER_TIMEOUT=1 \
        WATCHDOG_RESTART_TIMEOUT=1 \
        WATCHDOG_FAILURE_THRESHOLD=3 \
        WATCHDOG_VALID_STREAK_REQUIRED=5 \
        WATCHDOG_BOOT_GRACE=0 \
        WATCHDOG_MAINTENANCE_MAX_FUTURE=3600 \
        WATCHDOG_NOW_MONO=1600 \
        WATCHDOG_NOW_EPOCH=2400 \
        /bin/dash "$WATCHDOG" --once &
    BLOCKING_WATCHDOG_PID=$!
}

wait_for_file() {
    _path="$1"
    _attempt=0
    while [ ! -e "$_path" ] && [ "$_attempt" -lt 100 ]; do
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    [ -e "$_path" ] || fail "timed out waiting for ${_path}"
}

assert_json() {
    _fragment="$1"
    grep -Fq "$_fragment" "${STATE_DIR}/status.json" ||
        fail "${CASE_NAME}: missing JSON fragment ${_fragment}"
}

assert_no_action() {
    [ ! -s "$ACTIONS_FILE" ] ||
        fail "${CASE_NAME}: unexpected tailscaled restart"
}

action_count() {
    wc -l <"$ACTIONS_FILE" | tr -d ' '
}

file_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

file_inode() {
    stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

sh -n "$WATCHDOG"
dash -n "$WATCHDOG"
sh -n "${REPO_DIR}/vps/install-tailscale-watchdog.sh"
dash -n "${REPO_DIR}/vps/install-tailscale-watchdog.sh"

new_case running
run_once running 0 200 1000
assert_json '"status":"running"'
assert_json '"localapi_valid":true'
assert_json '"healthy":true'
assert_json '"connected":true'
assert_json '"degraded":false'
assert_json '"control_online":true'
assert_json '"tun_available":true'
assert_json '"in_engine":true'
assert_json '"tailnet_ip_present":true'
assert_json '"health_warning":false'
assert_json '"connectivity_uptime_seconds":0'
assert_json '"supervisor_restart_count":0'
assert_json '"process_started_monotonic_usec":100000000'
assert_json '"process_uptime_seconds":100'
assert_no_action
[ "$(file_mode "$STATE_DIR")" = "700" ] || fail "runtime directory is not private"
[ "$(file_mode "${STATE_DIR}/status.json")" = "600" ] || fail "status file is not private"
[ "$(file_mode "${STATE_DIR}/memory")" = "600" ] || fail "memory file is not private"
! grep -R -q 'sentinel-' "$STATE_DIR" "$LOG_FILE" ||
    fail "raw LocalAPI data leaked"
grep -Fq -- "--socket=${SOCKET_PATH} status --json --peers=false" \
    "$CLI_ARGS_FILE" || fail "bounded LocalAPI arguments changed"
pass "healthy LocalAPI response publishes only private allowlisted state"

new_case process_generation
run_once running 0 200 1000
NRESTARTS_VALUE=1
PROCESS_START_USEC_VALUE=195000000
run_once running 0 205 1005
unset NRESTARTS_VALUE PROCESS_START_USEC_VALUE
assert_json '"supervisor_restart_count":1'
assert_json '"process_started_monotonic_usec":195000000'
assert_json '"process_uptime_seconds":10'
assert_json '"connectivity_uptime_seconds":0'
assert_json '"recovery_count":0'
assert_no_action
pass "process generation exposes crashes and resets connected uptime"

new_case needs_login
_i=1
while [ "$_i" -le 8 ]; do
    run_once needs_login 0 "$((200 + _i))" "$((1000 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"needs_login"'
assert_json '"reason":"operator_reauthorization_required"'
assert_json '"localapi_valid":true'
assert_json '"recovery_count":0'
assert_no_action
! grep -R -q 'sentinel-' "$STATE_DIR" "$LOG_FILE" ||
    fail "NeedsLogin leaked an AuthURL"
pass "NeedsLogin remains an operator condition without restart"

new_case needs_machine_auth
_i=1
while [ "$_i" -le 5 ]; do
    run_once needs_machine_auth 0 "$((300 + _i))" "$((1100 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"needs_machine_auth"'
assert_json '"recovery_count":0'
assert_no_action
pass "NeedsMachineAuth never authorizes recovery"

new_case health_warning
_i=1
while [ "$_i" -le 5 ]; do
    run_once running_warning 0 "$((400 + _i))" "$((1200 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"running_warning"'
assert_json '"health_warning":true'
assert_json '"healthy":false'
assert_json '"connected":true'
assert_json '"degraded":true'
assert_no_action
! grep -R -q 'sentinel-health-secret' "$STATE_DIR" "$LOG_FILE" ||
    fail "health text leaked"
pass "health warnings are redacted and never restart the daemon"

new_case control_offline
_i=1
while [ "$_i" -le 5 ]; do
    run_once control_offline 0 "$((500 + _i))" "$((1300 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"running_degraded"'
assert_json '"reason":"control_offline"'
assert_json '"healthy":false'
assert_json '"connected":true'
assert_json '"degraded":true'
assert_json '"control_online":false'
assert_json '"connectivity_uptime_seconds":4'
assert_no_action
pass "control-plane loss degrades health without erasing connected uptime"

for _delivery_mode in no_address invalid_address tun_off engine_off; do
    new_case "delivery-${_delivery_mode}"
    run_once "$_delivery_mode" 0 550 1350
    assert_json '"status":"running_degraded"'
    assert_json '"healthy":false'
    assert_json '"connected":false'
    assert_json '"degraded":true'
    assert_json '"connectivity_uptime_seconds":null'
    assert_no_action
done
pass "connected requires Running, tailnet address, TUN, and InEngine"

new_case critical-peer
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
run_once running 0 560 1360
assert_json '"peer_configured":true'
assert_json '"peer_state":"reachable"'
assert_json '"peer_reachable":true'
assert_json '"connected":true'
PEER_MODE_VALUE=unreachable
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 0 "$((560 + _i))" "$((1360 + _i))"
    _i=$((_i + 1))
done
unset PEER_MODE_VALUE
assert_json '"status":"running_degraded"'
assert_json '"reason":"critical_peer_unreachable"'
assert_json '"healthy":false'
assert_json '"connected":false'
assert_json '"degraded":true'
assert_json '"peer_reachable":false'
assert_no_action
pass "configured critical-peer reachability is required for connected"

new_case schema_errors
for _mode in malformed running_bad_schema health_bad_schema unknown; do
    _i=1
    while [ "$_i" -le 4 ]; do
        run_once "$_mode" 0 "$((600 + _i))" "$((1400 + _i))"
        _i=$((_i + 1))
    done
done
assert_json '"status":"unknown_backend"'
assert_json '"localapi_valid":false'
assert_json '"recovery_count":0'
assert_no_action
! grep -R -q 'sentinel-' "$STATE_DIR" "$LOG_FILE" ||
    fail "schema error leaked raw status"
pass "malformed and future schemas fail closed without restart"

new_case command_error
_i=1
while [ "$_i" -le 6 ]; do
    run_once command_error 0 "$((700 + _i))" "$((1500 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"command_error"'
assert_json '"recovery_count":0'
assert_no_action
! grep -R -q 'sentinel-' "$STATE_DIR" "$LOG_FILE" ||
    fail "command stderr leaked"
pass "generic LocalAPI command failures never trigger recovery"

new_case socket-missing
rm -f "$SOCKET_PATH"
_i=1
while [ "$_i" -le 7 ]; do
    run_once running 0 "$((750 + _i))" "$((1550 + _i))"
    _i=$((_i + 1))
done
[ "$(action_count)" -eq 1 ] ||
    fail "missing LocalAPI socket did not latch one restart"
assert_json '"status":"socket_missing"'
assert_json '"reason":"localapi_socket_missing"'
assert_json '"eligible_failure":true'
assert_json '"recovery_count":1'
[ ! -s "$CLI_ARGS_FILE" ] ||
    fail "missing socket still invoked the Tailscale CLI"
pass "active daemon with no Unix socket receives one bounded restart"

new_case socket-not-unix
rm -f "$SOCKET_PATH"
printf '%s\n' not-a-socket >"$SOCKET_PATH"
run_once running 0 770 1570
run_once running 0 771 1571
run_once running 0 772 1572
[ "$(action_count)" -eq 1 ] ||
    fail "non-socket filesystem entry did not reach bounded recovery"
assert_json '"status":"socket_missing"'
pass "a non-socket entry is classified exactly as socket_missing"

new_case socket-boot-grace
rm -f "$SOCKET_PATH"
BOOT_GRACE_VALUE=120
run_once running 0 10 1580
run_once running 0 20 1581
run_once running 0 30 1582
assert_json '"status":"socket_missing"'
assert_json '"action":"suppressed_boot_grace"'
assert_no_action
run_once running 0 121 1583
[ "$(action_count)" -eq 1 ] ||
    fail "post-grace socket failure did not request one restart"
unset BOOT_GRACE_VALUE
pass "socket recovery obeys the existing threshold, boot grace, and latch"

new_case socket-disabled-unit
rm -f "$SOCKET_PATH"
UNIT_FILE_STATE_VALUE=disabled
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 0 "$((780 + _i))" "$((1590 + _i))"
    _i=$((_i + 1))
done
unset UNIT_FILE_STATE_VALUE
assert_json '"status":"socket_missing"'
assert_json '"eligible_failure":false'
assert_no_action
pass "active but disabled unit remains operator-authoritative on socket loss"

new_case supervisor_inactive
_i=1
while [ "$_i" -le 6 ]; do
    run_once running 3 "$((800 + _i))" "$((1600 + _i))"
    _i=$((_i + 1))
done
[ "$(action_count)" -eq 1 ] || fail "inactive supervisor did not latch one restart"
assert_json '"status":"supervisor_inactive"'
assert_json '"recovery_latched":true'
assert_json '"recovery_count":1'
assert_json '"action":"latched"'
assert_json '"process_uptime_seconds":null'
pass "persistent supervisor inactivity receives exactly one restart"

new_case timeout
_i=1
while [ "$_i" -le 7 ]; do
    run_once timeout 0 "$((900 + _i))" "$((1700 + _i))"
    _i=$((_i + 1))
done
[ "$(action_count)" -eq 1 ] || fail "LocalAPI timeout did not latch one restart"
assert_json '"status":"localapi_timeout"'
assert_json '"eligible_failure":true'
assert_json '"recovery_count":1'
pass "proven LocalAPI timeout receives exactly one restart"

for _timeout_mode in timeout_137 timeout_143; do
    new_case "$_timeout_mode"
    _i=1
    while [ "$_i" -le 4 ]; do
        run_once "$_timeout_mode" 0 "$((950 + _i))" "$((1750 + _i))"
        _i=$((_i + 1))
    done
    [ "$(action_count)" -eq 1 ] ||
        fail "${_timeout_mode}: timeout-compatible exit did not latch one restart"
    assert_json '"status":"localapi_timeout"'
    assert_json '"eligible_failure":true'
done
pass "timeout exits 137 and 143 receive the same bounded recovery semantics"

new_case rearm
_i=1
while [ "$_i" -le 3 ]; do
    run_once timeout 0 "$((1000 + _i))" "$((1800 + _i))"
    _i=$((_i + 1))
done
[ "$(action_count)" -eq 1 ] || fail "first episode did not recover"
_i=1
while [ "$_i" -le 5 ]; do
    run_once needs_login 0 "$((1010 + _i))" "$((1810 + _i))"
    _i=$((_i + 1))
done
assert_json '"action":"rearmed"'
assert_json '"recovery_latched":false'
_i=1
while [ "$_i" -le 3 ]; do
    run_once running 3 "$((1020 + _i))" "$((1820 + _i))"
    _i=$((_i + 1))
done
[ "$(action_count)" -eq 2 ] || fail "second distinct episode did not recover once"
assert_json '"recovery_count":2'
pass "five supported responses rearm exactly one later episode"

new_case consecutive
run_once timeout 0 1101 1901
run_once timeout 0 1102 1902
run_once command_error 0 1103 1903
run_once timeout 0 1104 1904
run_once timeout 0 1105 1905
assert_no_action
run_once timeout 0 1106 1906
[ "$(action_count)" -eq 1 ] ||
    fail "ambiguous error did not break eligible-failure streak"
pass "only consecutive eligible failures reach the threshold"

new_case maintenance
printf '%s %s\n' 2000 2600 >"${STATE_DIR}/maintenance-until"
chmod 0600 "${STATE_DIR}/maintenance-until"
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 3 "$((1200 + _i))" 2000
    _i=$((_i + 1))
done
assert_json '"maintenance_active":true'
assert_json '"maintenance_state":"active"'
assert_json '"action":"suppressed_maintenance"'
assert_json '"consecutive_eligible_failures":0'
assert_no_action
printf '%s %s\n' 1000 1999 >"${STATE_DIR}/maintenance-until"
run_once running 3 1210 2000
assert_json '"maintenance_state":"expired"'
run_once running 3 1211 2001
run_once running 3 1212 2002
[ "$(action_count)" -eq 1 ] || fail "expired marker suppressed recovery"
pass "active and expired maintenance states are explicit and fail open"

new_case future_maintenance
printf '%s %s\n' 2000 5601 >"${STATE_DIR}/maintenance-until"
run_once timeout 0 1301 2000
run_once timeout 0 1302 2001
run_once timeout 0 1303 2002
[ "$(action_count)" -eq 1 ] || fail "unbounded marker suppressed recovery"
assert_json '"maintenance_active":false'
assert_json '"maintenance_state":"too_long"'
[ -f "${STATE_DIR}/maintenance-until" ] ||
    fail "invalid maintenance marker was silently deleted"
pass "overlong maintenance marker is retained, surfaced, and rejected"

new_case malformed_maintenance
printf '%s\n' 'sentinel-invalid-marker' >"${STATE_DIR}/maintenance-until"
run_once running 3 1351 2050
run_once running 3 1352 2051
run_once running 3 1353 2052
[ "$(action_count)" -eq 1 ] || fail "malformed marker suppressed recovery"
assert_json '"maintenance_active":false'
assert_json '"maintenance_state":"malformed"'
[ -f "${STATE_DIR}/maintenance-until" ] ||
    fail "malformed maintenance marker was silently deleted"
! grep -q 'sentinel-invalid-marker' "${STATE_DIR}/status.json" ||
    fail "malformed maintenance content leaked"
pass "malformed maintenance marker is retained, surfaced, and redacted"

new_case boot_grace
BOOT_GRACE_VALUE=120
run_once timeout 0 10 2100
run_once timeout 0 20 2101
run_once timeout 0 30 2102
assert_json '"action":"suppressed_boot_grace"'
assert_no_action
run_once timeout 0 121 2103
[ "$(action_count)" -eq 1 ] || fail "confirmed post-grace failure did not recover"
unset BOOT_GRACE_VALUE
pass "boot grace suppresses early restart without hiding confirmed failure"

new_case restart_failure
RESTART_RC_VALUE=1
_i=1
while [ "$_i" -le 6 ]; do
    run_once timeout 0 "$((1400 + _i))" "$((2200 + _i))"
    _i=$((_i + 1))
done
unset RESTART_RC_VALUE
[ "$(action_count)" -eq 1 ] || fail "failed restart was retried in same episode"
assert_json '"recovery_latched":true'
assert_json '"recovery_count":1'
pass "failed restart remains latched against a restart storm"

new_case supervisor_query_error
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 4 "$((1500 + _i))" "$((2300 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"supervisor_query_error"'
assert_json '"eligible_failure":false'
assert_no_action
pass "ambiguous systemd query failure never authorizes restart"

new_case supervisor_transition
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 5 "$((1550 + _i))" "$((2350 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"supervisor_transition"'
assert_json '"reason":"supervisor_transition"'
assert_json '"eligible_failure":false'
assert_no_action
pass "systemd activating state is not misclassified as inactive"

for _disabled_state in disabled masked; do
    new_case "supervisor_${_disabled_state}"
    UNIT_FILE_STATE_VALUE="$_disabled_state"
    _i=1
    while [ "$_i" -le 6 ]; do
        run_once running 3 "$((1570 + _i))" "$((2370 + _i))"
        _i=$((_i + 1))
    done
    assert_json '"status":"supervisor_disabled"'
    assert_json '"reason":"unit_disabled"'
    assert_json "\"unit_file_state\":\"${_disabled_state}\""
    assert_json '"eligible_failure":false'
    assert_no_action
    unset UNIT_FILE_STATE_VALUE
done
pass "disabled and masked tailscaled units remain operator-authoritative"

new_case stale-lock-evidence
printf 'pid=%s\n' "$$" >"${STATE_DIR}/watchdog.lock"
chmod 0600 "${STATE_DIR}/watchdog.lock"
_stale_inode="$(file_inode "${STATE_DIR}/watchdog.lock")"
run_once running 0 1590 2390
assert_json '"status":"running"'
[ "$(file_inode "${STATE_DIR}/watchdog.lock")" = "$_stale_inode" ] ||
    fail "stale diagnostic content caused lock inode replacement"
[ "$(file_mode "${STATE_DIR}/watchdog.lock")" = "600" ] ||
    fail "persistent watchdog lock file is not private"
[ "$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')" -eq 1 ] ||
    fail "stale live PID text suppressed a valid successor"
pass "stale live PID evidence cannot suppress a successor or replace the lock inode"

new_case singleton-sigkill
start_blocking_watchdog
wait_for_file "${CASE_DIR}/blocked-child-pid"
_blocked_child_pid="$(cat "${CASE_DIR}/blocked-child-pid")"
_before_calls="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
_lock_inode="$(file_inode "${STATE_DIR}/watchdog.lock")"
_i=1
_concurrent_pids=""
while [ "$_i" -le 8 ]; do
    run_once running 0 "$((1600 + _i))" "$((2400 + _i))" &
    _concurrent_pids="${_concurrent_pids} $!"
    _i=$((_i + 1))
done
for _concurrent_pid in $_concurrent_pids; do
    wait "$_concurrent_pid"
done
_after_calls="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
[ "$_after_calls" -eq "$_before_calls" ] ||
    fail "concurrent invocations reached LocalAPI despite held flock"
pass "direct concurrent starts serialize on one held file-description lock"

kill -KILL "$BLOCKING_WATCHDOG_PID"
_wait_rc=0
wait "$BLOCKING_WATCHDOG_PID" 2>/dev/null || _wait_rc=$?
[ "$_wait_rc" -eq 137 ] ||
    fail "SIGKILL test did not terminate the lock owner"
run_once running 0 1610 2410
_successor_calls="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
[ "$_successor_calls" -eq $((_before_calls + 1)) ] ||
    fail "successor remained suppressed after SIGKILL"
[ "$(file_inode "${STATE_DIR}/watchdog.lock")" = "$_lock_inode" ] ||
    fail "successor locked a replacement inode"
kill -TERM "$_blocked_child_pid" 2>/dev/null || true
pass "SIGKILL releases the lock for a successor without unlinking its inode"

new_case singleton-term
start_blocking_watchdog
wait_for_file "${CASE_DIR}/blocked-child-pid"
_blocked_child_pid="$(cat "${CASE_DIR}/blocked-child-pid")"
kill -TERM "$BLOCKING_WATCHDOG_PID"
_wait_rc=0
wait "$BLOCKING_WATCHDOG_PID" || _wait_rc=$?
[ "$_wait_rc" -eq 143 ] ||
    fail "signal handler did not exit with a termination status"
if kill -0 "$_blocked_child_pid" 2>/dev/null; then
    fail "signal handler left the bounded LocalAPI child alive"
fi
[ -f "${STATE_DIR}/watchdog.lock" ] ||
    fail "signal cleanup unlinked the persistent lock inode"
run_once running 0 1620 2420
assert_json '"status":"running"'
pass "handled termination reaps children and leaves a usable successor lock"

grep -Fq 'RuntimeDirectoryMode=0700' "$SERVICE_UNIT" ||
    fail "service lacks private RuntimeDirectory mode"
grep -Fq 'RuntimeDirectoryPreserve=yes' "$SERVICE_UNIT" ||
    fail "oneshot state would disappear between timer invocations"
grep -Fq 'ProtectSystem=strict' "$SERVICE_UNIT" ||
    fail "service filesystem hardening missing"
grep -Fq 'NoNewPrivileges=yes' "$SERVICE_UNIT" ||
    fail "service privilege hardening missing"
grep -Fq 'RestrictAddressFamilies=AF_UNIX' "$SERVICE_UNIT" ||
    fail "service address-family restriction missing"
grep -Fq 'OnBootSec=2min' "$TIMER_UNIT" ||
    fail "timer boot grace missing"
grep -Fq 'OnUnitActiveSec=15s' "$TIMER_UNIT" ||
    fail "timer cadence changed"
grep -Fq 'Persistent=false' "$TIMER_UNIT" ||
    fail "timer must not replay missed checks after boot"
pass "systemd units retain private state and explicit hardening"

if rg -n 'tailscale[[:space:]]+(up|down|login|logout)' \
    "$WATCHDOG" "${REPO_DIR}/vps/install-tailscale-watchdog.sh" \
    >/dev/null 2>&1; then
    fail "watchdog or installer contains a forbidden Tailscale mutation"
fi
grep -Fq 'systemctl restart "$TAILSCALED_UNIT"' "$WATCHDOG" &&
    fail "unbounded restart command found"
grep -Fq '"$TIMEOUT_CMD" --signal=TERM --kill-after=2 "$RESTART_TIMEOUT"' \
    "$WATCHDOG" || fail "restart request is not deadline-bounded"
pass "mutation surface is limited to one bounded supervisor restart"

[ "$(grep -c '9>&- &' "$WATCHDOG")" -eq 4 ] ||
    fail "a long-running watchdog child can inherit the singleton lock"
grep -Fq '>/dev/null 2>&1 9>&- || true' "$WATCHDOG" ||
    fail "logger child can inherit the singleton lock"
pass "every timeout tree and logger closes the singleton descriptor"

printf '1..%s\n' "$PASS_COUNT"
