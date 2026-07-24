#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
WATCHDOG="${REPO_DIR}/router/jammonitor-tailscale-watchdog"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT%/}"
TEST_DIR="$(mktemp -d "${TEST_TMP_ROOT}/jammonitor-watchdog-test.XXXXXX")"
SHORT_SOCKET="/tmp/jammonitor-watchdog-socket.$$"
cleanup_test_dir() {
    rm -f "$SHORT_SOCKET"
    if [ "${KEEP_TEST_DIR:-0}" = "1" ]; then
        printf 'kept test artifacts: %s\n' "$TEST_DIR" >&2
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup_test_dir EXIT INT TERM

MOCK_BIN="${TEST_DIR}/bin"
mkdir -p "$MOCK_BIN"
PYTHON3="$(command -v python3)"

# A real deadline wrapper for the hanging fixture. Keep enough headroom for
# valid short-lived shell commands when the test suites run concurrently; the
# hanging child still really blocks and must be terminated and reaped.
cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/sh
shift
flag="${MOCK_RUNTIME_DIR}/timeout.$$"
"$@" &
child=$!
timer=""
cleanup_timeout() {
    [ -n "$timer" ] && kill "$timer" 2>/dev/null || true
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
}
trap 'cleanup_timeout; exit 143' INT TERM
(
    sleep "${MOCK_TIMEOUT_DELAY:-0.5}"
    if kill -0 "$child" 2>/dev/null; then
        : > "$flag"
        kill -TERM "$child" 2>/dev/null || true
        sleep 0.02
        kill -KILL "$child" 2>/dev/null || true
    fi
) &
timer=$!
wait "$child" 2>/dev/null
rc=$?
kill "$timer" 2>/dev/null || true
wait "$timer" 2>/dev/null || true
if [ -f "$flag" ]; then
    rm -f "$flag"
    exit 124
fi
exit "$rc"
EOF

cat > "${MOCK_BIN}/jsonfilter" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-i" ] && file="${2:-}" || exit 2
[ "${3:-}" = "-e" ] && expression="${4:-}" || exit 2
[ -s "$file" ] || exit 1
raw="$(cat "$file")"
case "$raw" in
    \{*\}) ;;
    *) exit 1 ;;
esac
case "$expression" in
    '@.BackendState')
        case "$raw" in
            *'"BackendState":"'*)
                value="${raw#*\"BackendState\":\"}"
                printf '%s\n' "${value%%\"*}"
                ;;
        esac
        ;;
    '@.Self.TailscaleIPs[0]')
        case "$raw" in
            *'"TailscaleIPs":["'*)
                value="${raw#*\"TailscaleIPs\":[\"}"
                printf '%s\n' "${value%%\"*}"
                ;;
        esac
        ;;
    '@.Self.KeyExpiry')
        case "$raw" in
            *'"KeyExpiry":"'*)
                value="${raw#*\"KeyExpiry\":\"}"
                printf '%s\n' "${value%%\"*}"
                ;;
        esac
        ;;
    '@.TUN')
        case "$raw" in
            *'"TUN":true'*) printf 'true\n' ;;
            *'"TUN":false'*) printf 'false\n' ;;
        esac
        ;;
    '@.Self.InEngine')
        case "$raw" in
            *'"InEngine":true'*) printf 'true\n' ;;
            *'"InEngine":false'*) printf 'false\n' ;;
        esac
        ;;
    '@.Self.Online')
        case "$raw" in
            *'"Online":true'*) printf 'true\n' ;;
            *'"Online":false'*) printf 'false\n' ;;
        esac
        ;;
    '@.Health[*]')
        case "$raw" in
            *'"Health":[]'*) ;;
            *'"Health":['*) printf 'redacted-warning\n' ;;
        esac
        ;;
    *) exit 1 ;;
esac
EOF

cat > "${MOCK_BIN}/tailscale" <<'EOF'
#!/bin/sh
case " $* " in
    *" ping "*)
        case "${MOCK_PEER_MODE:-reachable}" in
            reachable) exit 0 ;;
            unreachable|acl_denied|expired) exit 1 ;;
            hang)
                fifo="${MOCK_RUNTIME_DIR}/peer-fifo"
                [ -p "$fifo" ] || mkfifo "$fifo"
                read -r ignored < "$fifo"
                ;;
        esac
        exit 1
        ;;
esac

case "${MOCK_TAILSCALE_MODE:-running}" in
    running)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true,"KeyExpiry":"0001-01-01T00:00:00Z"},"Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    running_warning)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true,"KeyExpiry":"0001-01-01T00:00:00Z"},"Health":["secret warning text"]}'
        ;;
    running_no_ip)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":null,"Online":true,"InEngine":true},"Health":[]}'
        ;;
    running_no_tun)
        printf '%s\n' '{"BackendState":"Running","TUN":false,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true},"Health":[]}'
        ;;
    running_missing_tun)
        printf '%s\n' '{"BackendState":"Running","Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true},"Health":[]}'
        ;;
    running_missing_engine)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_bad_ip)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["8.8.8.8"],"Online":true,"InEngine":true},"Health":[]}'
        ;;
    running_control_offline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":false,"InEngine":true},"Health":[]}'
        ;;
    running_missing_online)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"InEngine":true},"Health":[]}'
        ;;
    needs_login)
        printf '%s\n' '{"BackendState":"NeedsLogin","TUN":true,"Self":{"Online":true,"InEngine":false,"KeyExpiry":"2026-07-03T04:38:38Z"},"Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    needs_machine_auth)
        printf '%s\n' '{"BackendState":"NeedsMachineAuth","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"InEngine":false},"Health":[]}'
        ;;
    stopped|starting|nostate|other_user)
        case "$MOCK_TAILSCALE_MODE" in
            stopped) backend="Stopped" ;;
            starting) backend="Starting" ;;
            nostate) backend="NoState" ;;
            other_user) backend="InUseOtherUser" ;;
        esac
        printf '{"BackendState":"%s","TUN":true,"Self":{},"Health":[]}\n' "$backend"
        ;;
    future_state)
        printf '%s\n' '{"BackendState":"FutureState","TUN":true,"Self":{},"Health":[]}'
        ;;
    malformed)
        printf '%s\n' 'not-json BackendState Running sentinel-auth-url'
        ;;
    generic_error|wrong_socket|version_mismatch)
        printf '%s\n' 'local command error sentinel-auth-url' >&2
        exit 1
        ;;
    hang)
        fifo="${MOCK_RUNTIME_DIR}/status-fifo"
        [ -p "$fifo" ] || mkfifo "$fifo"
        read -r ignored < "$fifo"
        ;;
    *)
        exit 99
        ;;
esac
EOF

cat > "${MOCK_BIN}/tailscale-init" <<'EOF'
#!/bin/sh
case "${1:-}" in
    enabled)
        [ "${MOCK_SERVICE_ENABLED:-1}" = "1" ]
        ;;
    running)
        [ "${MOCK_SERVICE_RUNNING:-1}" = "1" ]
        ;;
    restart)
        printf '%s\n' restart >> "${MOCK_ACTIONS_FILE}"
        exit "${MOCK_RESTART_RC:-0}"
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "${MOCK_BIN}/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_LOG_FILE}"
EOF

cat > "${MOCK_BIN}/flock" <<EOF
#!${PYTHON3}
import fcntl
import sys

if sys.argv[1:] != ["-n", "9"]:
    raise SystemExit(64)
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
except OSError:
    raise SystemExit(70)
EOF

chmod 0755 "${MOCK_BIN}/timeout" "${MOCK_BIN}/jsonfilter" \
    "${MOCK_BIN}/tailscale" "${MOCK_BIN}/tailscale-init" \
    "${MOCK_BIN}/logger" "${MOCK_BIN}/flock"

PASS_COUNT=0

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

write_process_generation() {
    _generation_pid="$1"
    _generation_start="$2"
    for _old_process_dir in "$PROC_ROOT"/[0-9]*; do
        [ -d "$_old_process_dir" ] || continue
        rm -f "$_old_process_dir/stat"
        rmdir "$_old_process_dir"
    done
    mkdir -p "${PROC_ROOT}/${_generation_pid}"
    printf '%s (tailscaled) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0 0 0\n' \
        "$_generation_pid" "$_generation_start" \
        > "${PROC_ROOT}/${_generation_pid}/stat"
}

create_unix_socket() {
    _socket_path="$1"
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
    CASE_DIR="${TEST_DIR}/${CASE_NAME}"
    STATE_DIR="${CASE_DIR}/state"
    RUNTIME_DIR="${CASE_DIR}/runtime"
    ACTIONS_FILE="${CASE_DIR}/actions"
    LOG_FILE="${CASE_DIR}/log"
    PEER_FILE="${CASE_DIR}/critical-peer"
    PROC_ROOT="${CASE_DIR}/proc"
    mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$PROC_ROOT"
    SOCKET_FILE="$SHORT_SOCKET"
    rm -f "$SOCKET_FILE"
    create_unix_socket "$SOCKET_FILE"
    write_process_generation 4242 10000
    : > "$ACTIONS_FILE"
    : > "$LOG_FILE"
}

watchdog_env() {
    _watchdog_arg="${4---once}"
    if [ -n "$_watchdog_arg" ]; then
        set -- "$1" "$2" "${3:-reachable}" "$_watchdog_arg"
    else
        set -- "$1" "$2" "${3:-reachable}"
    fi
    env \
        MOCK_TAILSCALE_MODE="$1" \
        MOCK_SERVICE_RUNNING="$2" \
        MOCK_PEER_MODE="${3:-reachable}" \
        MOCK_SERVICE_ENABLED="${MOCK_SERVICE_ENABLED_VALUE:-1}" \
        MOCK_RESTART_RC="${MOCK_RESTART_RC_VALUE:-0}" \
    MOCK_TIMEOUT_DELAY="${MOCK_TIMEOUT_DELAY_VALUE:-0.5}" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_RUNTIME_DIR="$RUNTIME_DIR" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_INIT="${MOCK_BIN}/tailscale-init" \
        TAILSCALE_SOCKET="$SOCKET_FILE" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_TIMEOUT_CMD="${WATCHDOG_TIMEOUT_OVERRIDE:-${MOCK_BIN}/timeout}" \
        WATCHDOG_JSONFILTER_CMD="${WATCHDOG_JSONFILTER_OVERRIDE:-${MOCK_BIN}/jsonfilter}" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_SLEEP_CMD="${WATCHDOG_SLEEP_OVERRIDE:-/bin/sleep}" \
        WATCHDOG_CRITICAL_PEER_FILE="$PEER_FILE" \
        WATCHDOG_PROC_ROOT="$PROC_ROOT" \
        WATCHDOG_CLOCK_TICKS=100 \
        WATCHDOG_STATUS_TIMEOUT=1 \
        WATCHDOG_PEER_TIMEOUT=1 \
        WATCHDOG_RESTART_TIMEOUT=1 \
        WATCHDOG_FAILURE_THRESHOLD="${WATCHDOG_THRESHOLD_VALUE:-3}" \
        WATCHDOG_VALID_STREAK_REQUIRED="${WATCHDOG_STREAK_VALUE:-5}" \
        WATCHDOG_BOOT_GRACE="${WATCHDOG_BOOT_GRACE_VALUE:-0}" \
        WATCHDOG_NOW_MONO="${WATCHDOG_MONO_VALUE:-200}" \
        WATCHDOG_NOW_EPOCH="${WATCHDOG_EPOCH_VALUE:-1000}" \
        /bin/sh -c 'watchdog=$1; shift; exec "$watchdog" "$@"' \
        jammonitor-test "$WATCHDOG" ${4+"$4"}
}

run_once() {
    WATCHDOG_MONO_VALUE="$3"
    WATCHDOG_EPOCH_VALUE="$4"
    watchdog_env "$1" "$2" "${5:-reachable}" --once
}

assert_status() {
    _expected="$1"
    grep -q "\"status\":\"${_expected}\"" "${STATE_DIR}/tailscale-watchdog.json" ||
        fail "${CASE_NAME}: expected status ${_expected}"
}

assert_json() {
    _fragment="$1"
    grep -q "$_fragment" "${STATE_DIR}/tailscale-watchdog.json" ||
        fail "${CASE_NAME}: missing JSON fragment ${_fragment}"
}

assert_no_actions() {
    [ ! -s "$ACTIONS_FILE" ] || fail "${CASE_NAME}: unexpected recovery action"
}

action_count() {
    wc -l < "$ACTIONS_FILE" | tr -d ' '
}

wait_for_path() {
    _path="$1"
    _attempt=0
    while [ ! -e "$_path" ] && [ "$_attempt" -lt 100 ]; do
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    [ -e "$_path" ] || fail "${CASE_NAME}: timed out waiting for $_path"
}

wait_for_lock_pid() {
    _lock_path="$1"
    _attempt=0
    while [ "$_attempt" -lt 100 ]; do
        _lock_pid="$(sed -n 's/^pid=//p' "$_lock_path" 2>/dev/null || true)"
        case "$_lock_pid" in
            ""|*[!0-9]*) ;;
            *) return 0 ;;
        esac
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    fail "${CASE_NAME}: timed out waiting for lock owner metadata"
}

lock_inode() {
    stat -f '%i' "$1" 2>/dev/null ||
        stat -c '%i' "$1" 2>/dev/null
}

sh -n "$WATCHDOG"
dash -n "$WATCHDOG"
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n "$WATCHDOG"
fi
pass "watchdog parses under POSIX sh and dash"

new_case running
run_once running 1 200 1000
assert_status running
assert_json '"connected":true'
assert_json '"healthy":true'
assert_json '"control_online":true'
assert_json '"process_generation":"4242:10000"'
assert_json '"process_uptime_seconds":100'
assert_json '"connectivity_uptime_seconds":0'
assert_no_actions
pass "Running is connected without recovery"

new_case degraded_semantics
run_once running 1 200 1000
run_once running_warning 1 215 1015
assert_status running_degraded
assert_json '"connected":true'
assert_json '"degraded":true'
assert_json '"connected_since_at":1000'
assert_json '"connectivity_uptime_seconds":15'
run_once running_no_ip 1 230 1030
assert_json '"connected":false'
assert_json '"healthy":false'
assert_json '"connected_since_at":0'
assert_json '"connectivity_uptime_seconds":null'
assert_no_actions
pass "warnings preserve local connectivity but a missing Tailscale IP ends uptime"

new_case delivery_prerequisites
for mode in running_no_tun running_bad_ip; do
    run_once "$mode" 1 200 1000
    assert_status running_degraded
    assert_json '"connected":false'
    assert_json '"healthy":false'
done
for mode in running_missing_tun running_missing_engine; do
    run_once "$mode" 1 215 1015
    assert_status running_degraded
    assert_json '"connected":null'
    assert_json '"healthy":false'
done
assert_no_actions
pass "explicit delivery prerequisites fail closed and missing schema stays unknown"

new_case unknown_breaks_uptime
run_once running 1 200 1000
run_once malformed 1 215 1015
assert_json '"connected":null'
run_once running 1 230 1030
assert_json '"connected_since_at":1030'
assert_json '"connectivity_uptime_seconds":0'
assert_no_actions
pass "an unobserved LocalAPI interval cannot be included in connectivity uptime"

new_case process_generation_change
run_once running 1 200 1000
assert_json '"connected_since_at":1000'
assert_json '"process_uptime_seconds":100'
write_process_generation 4243 20000
run_once running 1 215 1015
assert_status running_degraded
assert_json '"reason":"process_restarted"'
assert_json '"connected":true'
assert_json '"connected_since_at":1015'
assert_json '"connectivity_uptime_seconds":0'
assert_json '"process_uptime_seconds":15'
assert_json '"process_generation":"4243:20000"'
run_once running 1 230 1030
assert_status running
assert_json '"connected_since_at":1015'
assert_json '"connectivity_uptime_seconds":15'
assert_json '"process_uptime_seconds":30'
assert_no_actions
pass "a process generation change resets continuity across an unobserved procd recovery"

new_case process_generation_unknown
rm -f "$PROC_ROOT/4242/stat"
rmdir "$PROC_ROOT/4242"
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"process_uptime_seconds":null'
assert_no_actions
pass "process uptime is never published without its exact PID generation"

new_case oversized_process_generation
oversized_ticks=99999999999999999999999999999999999999999999999999
write_process_generation 4242 "$oversized_ticks"
oversized_output="$(run_once running 1 200 1000 2>&1)" ||
    fail "oversized_process_generation: watchdog did not fail closed cleanly"
case "$oversized_output" in
    *"Illegal number"*|*"integer expression expected"*|*"out of range"*)
        fail "oversized_process_generation: shell numeric overflow escaped validation"
        ;;
esac
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"process_uptime_seconds":null'
assert_no_actions
pass "oversized PID-generation fields fail closed before shell arithmetic"

new_case control_plane_state
run_once running_control_offline 1 200 1000
assert_status running_degraded
assert_json '"reason":"control_offline"'
assert_json '"control_online":false'
assert_json '"connected":true'
assert_json '"recoverable":false'
run_once running_missing_online 1 215 1015
assert_status running_degraded
assert_json '"reason":"control_state_unknown"'
assert_json '"control_online":null'
assert_json '"connected":true'
assert_no_actions
pass "explicit control loss degrades health without discarding delivered connectivity"

new_case needs_login_live_shape
run_once needs_login 1 200 1000
assert_status needs_login
assert_json '"connected":false'
assert_json '"key_expiry":"2026-07-03T04:38:38Z"'
assert_no_actions
if grep -R -q 'sentinel-auth-url\|secret warning text' "$CASE_DIR"; then
    fail "needs_login_live_shape: a raw secret crossed an artifact boundary"
fi
pass "NeedsLogin exit zero is visible, non-recoverable, and secret-free"

new_case operator_states
for mode in needs_machine_auth stopped starting nostate other_user future_state; do
    run_once "$mode" 1 200 1000
done
assert_no_actions
assert_status unsupported_backend
pass "approval, stopped, starting, other-user, and future states never restart"

new_case malformed
for ignored in 1 2 3 4 5; do run_once malformed 1 $((200 + ignored)) $((1000 + ignored)); done
assert_status watchdog_error
assert_no_actions
pass "malformed status is a watchdog error, not a daemon hang"

new_case fast_errors
for mode in generic_error wrong_socket version_mismatch; do
    for ignored in 1 2 3 4; do run_once "$mode" 1 $((200 + ignored)) $((1000 + ignored)); done
done
assert_status watchdog_error
assert_no_actions
pass "fast CLI, socket, and version errors fail closed"

new_case missing_dependency
WATCHDOG_JSONFILTER_OVERRIDE="${CASE_DIR}/does-not-exist"
run_once running 1 200 1000
assert_status watchdog_error
assert_no_actions
WATCHDOG_JSONFILTER_OVERRIDE=""
WATCHDOG_TIMEOUT_OVERRIDE="${CASE_DIR}/does-not-exist"
run_once running 1 215 1015
assert_status watchdog_error
assert_no_actions
WATCHDOG_TIMEOUT_OVERRIDE=""
pass "missing timeout or parser cannot trigger recovery"

new_case real_hang
run_once hang 1 200 1000
run_once hang 1 215 1015
assert_no_actions
run_once hang 1 230 1030
[ "$(action_count)" -eq 1 ] || fail "real_hang: expected one supervisor restart"
assert_json '"recovery_attempted":1'
for ignored in 1 2 3 4 5 6 7 8 9 10 11 12; do
    run_once hang 1 $((230 + ignored * 15)) $((1030 + ignored * 15))
done
[ "$(action_count)" -eq 1 ] || fail "real_hang: episode latch allowed a restart loop"
assert_json '"recovery_state":"episode_latched"'
pass "a real LocalAPI deadline gets exactly one supervisor restart per episode"

new_case missing_socket
rm -f "$SOCKET_FILE"
run_once running 1 200 1000
run_once running 1 215 1015
assert_no_actions
run_once running 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "missing_socket: expected one bounded supervisor restart"
assert_status socket_missing
assert_json '"reason":"localapi_socket_missing"'
assert_json '"local_api_responsive":false'
assert_json '"recoverable":true'
assert_json '"process_generation":"4242:10000"'
for ignored in 1 2 3 4 5 6; do
    run_once running 1 $((230 + ignored)) $((1030 + ignored))
done
[ "$(action_count)" -eq 1 ] ||
    fail "missing_socket: episode latch allowed a restart loop"
assert_json '"recovery_state":"episode_latched"'
pass "a missing LocalAPI Unix socket gets one bounded restart per episode"

new_case nonsocket_path
rm -f "$SOCKET_FILE"
: > "$SOCKET_FILE"
run_once running 1 200 1000
run_once running 1 215 1015
run_once running 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "nonsocket_path: regular file was mistaken for a Unix socket"
assert_status socket_missing
pass "a non-socket filesystem entry is treated as a missing LocalAPI socket"

new_case socket_recovery_guards
rm -f "$SOCKET_FILE"
printf '%s\n' 1600 > "${STATE_DIR}/tailscale-maintenance"
run_once running 1 20 1000
assert_status maintenance
assert_no_actions
rm -f "${STATE_DIR}/tailscale-maintenance"
WATCHDOG_BOOT_GRACE_VALUE=120
run_once running 1 20 1000
run_once running 1 40 1020
run_once running 1 60 1040
assert_status socket_missing
assert_json '"recovery_state":"boot_grace"'
assert_no_actions
WATCHDOG_BOOT_GRACE_VALUE=0
pass "socket recovery obeys maintenance and boot-grace suppression"

new_case missing_process
run_once running 0 200 1000
run_once running 0 215 1015
assert_no_actions
run_once running 0 230 1030
[ "$(action_count)" -eq 1 ] || fail "missing_process: restart not requested at threshold"
assert_status daemon_missing
assert_json '"process_generation":null'
assert_json '"process_uptime_seconds":null'
pass "supervisor-confirmed process absence gets one bounded restart"

new_case failed_restart_latched
MOCK_RESTART_RC_VALUE=7
run_once hang 1 200 1000
run_once hang 1 215 1015
run_once hang 1 230 1030
assert_json '"recovery_state":"restart_failed"'
for ignored in 1 2 3 4 5 6; do run_once hang 1 $((230 + ignored)) $((1030 + ignored)); done
[ "$(action_count)" -eq 1 ] || fail "failed_restart_latched: failure cleared the latch"
MOCK_RESTART_RC_VALUE=0
pass "a failed recovery command remains latched across watchdog restarts"

new_case rearm_after_five
run_once hang 1 200 1000
run_once hang 1 215 1015
run_once hang 1 230 1030
run_once running 1 245 1045
run_once hang 1 260 1060
[ "$(action_count)" -eq 1 ] || fail "rearm_after_five: one valid response rearmed recovery"
run_once running 1 275 1075
run_once running 1 290 1090
run_once running 1 305 1105
run_once running 1 320 1120
run_once running 1 335 1135
assert_json '"recovery_attempted":0'
run_once hang 1 350 1150
run_once hang 1 365 1165
run_once hang 1 380 1180
[ "$(action_count)" -eq 2 ] || fail "rearm_after_five: independent episode did not recover"
pass "five valid responses rearm exactly one later failure episode"

new_case peer_observation
printf '%s\n' 'vps-node' > "$PEER_FILE"
run_once running_no_tun 1 190 990 unreachable
assert_status running_degraded
assert_json '"reason":"tun_unavailable"'
assert_json '"peer_state":"unknown"'
assert_json '"peer_reachable":null'
for mode in unreachable acl_denied expired; do
    run_once running 1 200 1000 "$mode"
    assert_status running_degraded
    assert_json '"healthy":false'
    assert_json '"connected":false'
    assert_json '"connected_since_at":0'
    assert_json '"connectivity_uptime_seconds":null'
    assert_json '"peer_configured":true'
    assert_json '"peer_reachable":false'
done
assert_no_actions
run_once needs_login 1 215 1015 unreachable
assert_json '"peer_configured":true'
assert_json '"peer_state":"unknown"'
assert_no_actions
pass "critical-peer failures end delivered connectivity but never authorize restart"

new_case intentional_states
MOCK_SERVICE_ENABLED_VALUE=0
run_once running 1 200 1000
assert_status disabled
assert_no_actions
MOCK_SERVICE_ENABLED_VALUE=1
printf '%s\n' 1600 > "${STATE_DIR}/tailscale-maintenance"
run_once hang 1 215 1015
assert_status maintenance
assert_json '"maintenance_state":"active"'
assert_json '"maintenance_expires_at":1600'
assert_no_actions
pass "disabled and maintenance states never gain recovery authority"

new_case expired_maintenance
printf '%s\n' 999 > "${STATE_DIR}/tailscale-maintenance"
run_once hang 1 200 1000
run_once hang 1 215 1015
run_once hang 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "expired_maintenance: expired marker suppressed bounded recovery"
assert_json '"maintenance_state":"expired"'
pass "an expired maintenance marker is visible but cannot suppress recovery"

new_case malformed_maintenance
printf '%s\n' not-an-epoch > "${STATE_DIR}/tailscale-maintenance"
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"maintenance_marker_invalid"'
assert_json '"maintenance_state":"malformed"'
assert_json '"healthy":false'
assert_no_actions
pass "a malformed maintenance marker degrades health without pausing recovery"

new_case far_future_maintenance
printf '%s\n' 99999 > "${STATE_DIR}/tailscale-maintenance"
run_once running 1 200 1000
assert_status running_degraded
assert_json '"maintenance_state":"out_of_bounds"'
assert_no_actions
pass "an overly long maintenance lease is rejected and surfaced"

new_case boot_grace
WATCHDOG_BOOT_GRACE_VALUE=120
run_once hang 1 20 1000
run_once hang 1 40 1020
run_once hang 1 60 1040
assert_json '"recovery_state":"boot_grace"'
assert_no_actions
WATCHDOG_BOOT_GRACE_VALUE=0
pass "boot grace suppresses premature recovery"

new_case stale_live_lock_metadata
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
sleep 5 &
unrelated_pid=$!
printf 'pid=%s\nidentity=stale-owner\n' "$unrelated_pid" > "$LOCK_PATH"
stale_lock_inode="$(lock_inode "$LOCK_PATH")"
run_once running 1 200 1000
assert_status running
grep -q "^pid=${unrelated_pid}$" "$LOCK_PATH" &&
    fail "stale_live_lock_metadata: a live metadata PID blocked kernel-lock acquisition"
[ "$(lock_inode "$LOCK_PATH")" = "$stale_lock_inode" ] ||
    fail "stale_live_lock_metadata: persistent lock inode was replaced"
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true
pass "stale live PID metadata cannot impersonate kernel lock ownership"

new_case concurrent_singleton
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
MOCK_TIMEOUT_DELAY_VALUE=5
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env hang 1 reachable "" &
watchdog_launcher_pid=$!
wait_for_lock_pid "$LOCK_PATH"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
singleton_lock_inode="$(lock_inode "$LOCK_PATH")"
watchdog_env running 1 reachable --once ||
    fail "concurrent_singleton: lock contender did not exit cleanly"
[ "$(sed -n 's/^pid=//p' "$LOCK_PATH")" = "$watchdog_pid" ] ||
    fail "concurrent_singleton: contender overwrote owner metadata"
[ ! -e "${STATE_DIR}/tailscale-watchdog.json" ] ||
    fail "concurrent_singleton: contender executed an observation"
kill -TERM "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
[ -f "$LOCK_PATH" ] ||
    fail "concurrent_singleton: persistent lock file was removed"
[ "$(lock_inode "$LOCK_PATH")" = "$singleton_lock_inode" ] ||
    fail "concurrent_singleton: lock inode changed during owner cleanup"
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$singleton_lock_inode" ] ||
    fail "concurrent_singleton: successor replaced the persistent lock inode"
pass "one concurrent watchdog owns the lock and a successor acquires after exit"

new_case sigkill_lock_release
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
MOCK_TIMEOUT_DELAY_VALUE=2
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env hang 1 reachable "" &
watchdog_launcher_pid=$!
wait_for_lock_pid "$LOCK_PATH"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
sigkill_lock_inode="$(lock_inode "$LOCK_PATH")"
kill -KILL "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$sigkill_lock_inode" ] ||
    fail "sigkill_lock_release: successor replaced the persistent lock inode"
pass "SIGKILL releases ownership even while a detached query child survives"

new_case signal_status
MOCK_TIMEOUT_DELAY_VALUE=5
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env hang 1 reachable "" &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
sleep 0.05
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
signal_status_inode="$(lock_inode "$LOCK_PATH")"
kill -TERM "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
kill -0 "$watchdog_pid" 2>/dev/null &&
    fail "signal_status: watchdog survived TERM during status query"
[ -f "$LOCK_PATH" ] &&
    [ "$(lock_inode "$LOCK_PATH")" = "$signal_status_inode" ] ||
    fail "signal_status: persistent lock inode was removed or replaced"
MOCK_TIMEOUT_DELAY_VALUE=0.5
pass "TERM during a status query reaps the active child and exits"

new_case signal_sleep
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
wait_for_path "${STATE_DIR}/tailscale-watchdog.json"
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
sleep 0.05
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
signal_sleep_inode="$(lock_inode "$LOCK_PATH")"
kill -TERM "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
kill -0 "$watchdog_pid" 2>/dev/null &&
    fail "signal_sleep: watchdog survived TERM during sleep"
[ -f "$LOCK_PATH" ] &&
    [ "$(lock_inode "$LOCK_PATH")" = "$signal_sleep_inode" ] ||
    fail "signal_sleep: persistent lock inode was removed or replaced"
pass "TERM during interval sleep reaps the active child and exits"

if [ "$(grep -Fc '9>&-' "$WATCHDOG")" -lt 4 ]; then
    fail "watchdog long-lived children do not all close the singleton descriptor"
fi
if grep -Eq 'rm -f .*LOCK_FILE|rm -f .*tailscale-watchdog\\.lock' "$WATCHDOG"; then
    fail "watchdog removes the persistent kernel-lock inode"
fi
pass "all potentially surviving watchdog children close the persistent lock descriptor"

if rg -n 'tailscale[[:space:]].*(down|up|logout)|rm .*tailscaled\\.state' \
    "${REPO_DIR}/router/tailscale.init" \
    "${REPO_DIR}/router/jammonitor-tailscale-watchdog" >/dev/null 2>&1; then
    fail "init/watchdog contains a forbidden persistent identity action"
fi
grep -Eq 'procd_set_param[[:space:]]+respawn[[:space:]]*$' \
    "${REPO_DIR}/router/tailscale.init" ||
    fail "tailscale init does not use finite default respawn"
grep -Eq 'procd_set_param[[:space:]]+respawn[[:space:]]*$' \
    "${REPO_DIR}/router/jammonitor-tailscale-watchdog.init" ||
    fail "watchdog init does not use finite default respawn"
pass "init lifecycle is identity-safe and uses finite respawn budgets"

printf '1..%s\n' "$PASS_COUNT"
