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
    [ "${3:-}" = "--tsmp" ] || exit 92
    [ "${4:-}" = "--c=1" ] || exit 93
    [ "${5:-}" = "--timeout=3s" ] || exit 94
    [ "${6:-}" = "--until-direct=false" ] || exit 95
    [ "${7:-}" = "--" ] || exit 96
    [ -n "${8:-}" ] && [ "$#" -eq 8 ] || exit 97
    if [ "${MOCK_REPLACE_PEER_DURING_PING:-0}" = "1" ]; then
        replacement="${MOCK_CRITICAL_PEER_FILE}.replacement.$$"
        printf '%s\n' "${MOCK_PEER_REPLACEMENT_VALUE:-100.104.78.43}" \
            >"$replacement" || exit 98
        chmod 0644 "$replacement" || exit 98
        /bin/mv -f "$replacement" "$MOCK_CRITICAL_PEER_FILE" || exit 98
    fi
    [ "${MOCK_PEER_MODE:-reachable}" = "reachable" ]
    exit
fi

[ "${2:-}" = "status" ] || exit 92
[ "${3:-}" = "--json" ] || exit 93
[ "${4:-}" = "--peers=false" ] || exit 94
[ "$#" -eq 4 ] || exit 95

case "${MOCK_TAILSCALE_MODE:-running}" in
    running)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.70.186.127"]},"Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    running_warning)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.70.186.127"]},"Health":["sentinel-health-secret"],"AuthURL":"sentinel-auth-url"}'
        ;;
    control_offline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":false,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    tun_off)
        printf '%s\n' '{"BackendState":"Running","TUN":false,"Self":{"Online":true,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    live_1_98_9)
        printf '%s\n' '{"Version":"1.98.9","BackendState":"Running","TUN":true,"Self":{"Online":true,"InEngine":false,"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
        ;;
    multiple_addresses)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.70.186.127","fd7a:115c:a1e0::2"]},"Health":[]}'
        ;;
    no_address)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":[]},"Health":[]}'
        ;;
    invalid_address)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.64.not-an-ip"]},"Health":[]}'
        ;;
    ipv4_lower_bound)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.64.0.0"]},"Health":[]}'
        ;;
    ipv4_upper_bound)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.127.255.255"]},"Health":[]}'
        ;;
    ipv4_below_range)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.63.255.255"]},"Health":[]}'
        ;;
    ipv4_above_range)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.128.0.0"]},"Health":[]}'
        ;;
    ipv4_noncanonical)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.064.0.1"]},"Health":[]}'
        ;;
    ipv4_trailing_newline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["100.70.186.127\n"]},"Health":[]}'
        ;;
    ipv6_full)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e0:0000:0000:0000:0000:0001"]},"Health":[]}'
        ;;
    ipv6_compressed)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["FD7A:115C:A1E0::1"]},"Health":[]}'
        ;;
    ipv6_too_few)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e0:1"]},"Health":[]}'
        ;;
    ipv6_hextet_too_long)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e0:00000::1"]},"Health":[]}'
        ;;
    ipv6_double_compression)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e0::1::2"]},"Health":[]}'
        ;;
    ipv6_too_many)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e0:0:0:0:0:0:1"]},"Health":[]}'
        ;;
    ipv6_wrong_prefix)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"Online":true,"TailscaleIPs":["fd7a:115c:a1e1::1"]},"Health":[]}'
        ;;
    running_bad_schema)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.70.186.127"]},"Health":[]}'
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
    health_missing)
        printf '%s\n' '{"BackendState":"Running"}'
        ;;
    health_null)
        printf '%s\n' '{"BackendState":"Running","Health":null}'
        ;;
    health_nonstring)
        printf '%s\n' '{"BackendState":"Running","Health":[7]}'
        ;;
    health_oversized_string)
        printf '%s\n' '{"BackendState":"Running","Health":["sentinel-oversized"]}'
        ;;
    health_too_many)
        printf '%s\n' '{"BackendState":"Running","Health":["sentinel-too-many"]}'
        ;;
    command_error)
        printf '%s\n' 'sentinel-command-error sentinel-auth-url' >&2
        exit 1
        ;;
    oversized_output)
        dd if=/dev/zero bs=1024 count=256 2>/dev/null |
            tr '\000' x
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
    deadline_137)
        exit 85
        ;;
    command_124)
        exit 84
        ;;
    deadline_143)
        exit 83
        ;;
    command_124_rollover)
        printf '%s\n' '101.00 0.00' >"$MOCK_UPTIME_FILE"
        exit 82
        ;;
    finish_malformed)
        printf '%s\n' 'not-uptime' >"$MOCK_UPTIME_FILE"
        exit 81
        ;;
    clock_backstep)
        printf '%s\n' '99.99 0.00' >"$MOCK_UPTIME_FILE"
        exit 80
        ;;
    deadline_minus_one)
        printf '%s\n' '100.99 0.00' >"$MOCK_UPTIME_FILE"
        exit 79
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
            not-json*|*'"Health":"'*|*'"Health":null'*|\
            *'"Health":[7]'*|*'"Health":["sentinel-oversized"]'*|\
            *'"Health":["sentinel-too-many"]'*)
                exit 1
                ;;
            *'"BackendState":"'*'"Health":['*) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    *'.TUN | type == "boolean"'*)
        case "$raw" in
            *'"BackendState":"Running"'*'"Online":'*'"TailscaleIPs":['*) exit 0 ;;
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
    *'.Self.TailscaleIPs[]'*'select(test('*)
        case "$raw" in
            *'"TailscaleIPs":[]'*|*'not-an-ip'*) exit 0 ;;
            *'"TailscaleIPs":["100.70.186.127","fd7a:115c:a1e0::2"]'*)
                printf '%s\n' \
                    '100.70.186.127' \
                    'fd7a:115c:a1e0::2'
                exit 0
                ;;
        esac
        value="${raw#*\"TailscaleIPs\":[\"}"
        [ "$value" != "$raw" ] || exit 1
        printf '%s\n' "${value%%\"*}"
        ;;
    '.Health | length')
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
deadline="${3:-}"
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
advance_uptime() {
    increment="$1"
    [ -n "${MOCK_UPTIME_FILE:-}" ] || return 0
    [ -f "$MOCK_UPTIME_FILE" ] || return 0
    current="$(cut -d. -f1 "$MOCK_UPTIME_FILE" 2>/dev/null)"
    case "${current}:${increment}" in
        *[!0-9:]*|:*) return 0 ;;
    esac
    printf '%s.00 0.00\n' "$((current + increment))" \
        >"$MOCK_UPTIME_FILE"
}
if [ "$rc" -eq 88 ]; then
    advance_uptime "$deadline"
    exit 124
fi
[ "$rc" -eq 87 ] && exit 137
[ "$rc" -eq 86 ] && exit 143
[ "$rc" -eq 85 ] && {
    advance_uptime "$((deadline + 2))"
    exit 137
}
[ "$rc" -eq 84 ] && exit 124
[ "$rc" -eq 83 ] && {
    advance_uptime "$deadline"
    exit 143
}
[ "$rc" -eq 82 ] && exit 124
[ "$rc" -eq 81 ] && exit 124
[ "$rc" -eq 80 ] && exit 124
[ "$rc" -eq 79 ] && exit 124
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
        show_count_file="${MOCK_SHOW_COUNT_FILE:-${MOCK_CASE_DIR}/show-count}"
        show_count=0
        if [ -f "$show_count_file" ]; then
            show_count="$(cat "$show_count_file" 2>/dev/null)"
            case "$show_count" in
                0|[1-9]|[1-9][0-9]*) ;;
                *) exit 97 ;;
            esac
        fi
        show_count=$((show_count + 1))
        printf '%s\n' "$show_count" >"$show_count_file"
        service_state="${MOCK_SERVICE_STATE:-active}"
        unit_file_state="${MOCK_UNIT_FILE_STATE:-enabled}"
        nrestarts="${MOCK_NRESTARTS:-0}"
        process_start_usec="${MOCK_PROCESS_START_USEC:-100000000}"
        if [ "$show_count" -eq 2 ]; then
            service_state="${MOCK_JOIN_SERVICE_STATE:-$service_state}"
            unit_file_state="${MOCK_JOIN_UNIT_FILE_STATE:-$unit_file_state}"
            nrestarts="${MOCK_JOIN_NRESTARTS:-$nrestarts}"
            process_start_usec="${MOCK_JOIN_PROCESS_START_USEC:-$process_start_usec}"
        elif [ "$show_count" -ge 3 ]; then
            if [ -n "${MOCK_GENERATION_CHANGE_FILE:-}" ] &&
               [ -f "$MOCK_GENERATION_CHANGE_FILE" ]; then
                service_state="${MOCK_AFTER_MEMORY_SERVICE_STATE:-${MOCK_JOIN_SERVICE_STATE:-$service_state}}"
                unit_file_state="${MOCK_AFTER_MEMORY_UNIT_FILE_STATE:-${MOCK_JOIN_UNIT_FILE_STATE:-$unit_file_state}}"
                nrestarts="${MOCK_AFTER_MEMORY_NRESTARTS:-${MOCK_JOIN_NRESTARTS:-$nrestarts}}"
                process_start_usec="${MOCK_AFTER_MEMORY_PROCESS_START_USEC:-${MOCK_JOIN_PROCESS_START_USEC:-$process_start_usec}}"
            else
                service_state="${MOCK_PRE_RESTART_SERVICE_STATE:-${MOCK_JOIN_SERVICE_STATE:-$service_state}}"
                unit_file_state="${MOCK_PRE_RESTART_UNIT_FILE_STATE:-${MOCK_JOIN_UNIT_FILE_STATE:-$unit_file_state}}"
                nrestarts="${MOCK_PRE_RESTART_NRESTARTS:-${MOCK_JOIN_NRESTARTS:-$nrestarts}}"
                process_start_usec="${MOCK_PRE_RESTART_PROCESS_START_USEC:-${MOCK_JOIN_PROCESS_START_USEC:-$process_start_usec}}"
            fi
        fi

        [ "$service_state" != "query_error" ] || exit 4
        printf 'ActiveState=%s\n' "$service_state"
        printf 'UnitFileState=%s\n' "$unit_file_state"
        printf 'NRestarts=%s\n' "$nrestarts"
        printf 'ExecMainStartTimestampMonotonic=%s\n' \
            "$process_start_usec"
        ;;
    restart)
        [ "${2:-}" = "tailscaled.service" ] || exit 99
        if [ -e /dev/fd/9 ]; then
            printf '%s\n' open >"${MOCK_CASE_DIR}/restart-fd9"
        else
            printf '%s\n' closed >"${MOCK_CASE_DIR}/restart-fd9"
        fi
        printf '%s\n' restart >>"${MOCK_ACTIONS_FILE}"
        if [ "${MOCK_RESTART_BLOCK:-0}" = "1" ]; then
            fifo="${MOCK_CASE_DIR}/restart-fifo"
            [ -p "$fifo" ] || mkfifo "$fifo"
            printf '%s\n' "$$" >"${MOCK_CASE_DIR}/restart-child-pid"
            read -r ignored <"$fifo"
        fi
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

cat >"${MOCK_BIN}/mv" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-T" ] || exit 2
[ "${2:-}" = "-f" ] || exit 2
[ "$#" -eq 4 ] || exit 2
source="$3"
target="$4"
if [ "${MOCK_MV_FAIL_MEMORY:-0}" = "1" ] &&
   [ "${target##*/}" = "memory" ]; then
    exit 1
fi
[ ! -d "$target" ] && [ ! -L "$target" ] || exit 1
/bin/mv -f "$source" "$target" || exit 1
if [ "${MOCK_MV_GENERATION_CHANGE:-0}" = "1" ] &&
   [ "${target##*/}" = "memory" ] &&
   [ -n "${MOCK_GENERATION_CHANGE_FILE:-}" ]; then
    : >"$MOCK_GENERATION_CHANGE_FILE"
fi
if [ "${MOCK_MV_PUBLISH_MAINTENANCE:-0}" = "1" ] &&
   [ "${target##*/}" = "memory" ] &&
   [ ! -e "${MOCK_MAINTENANCE_FILE:?}" ]; then
    printf '%s %s\n' \
        "${MOCK_MAINTENANCE_CREATED:?}" \
        "${MOCK_MAINTENANCE_EXPIRY:?}" \
        >"${MOCK_MAINTENANCE_FILE:?}" || exit 1
    chmod 0600 "${MOCK_MAINTENANCE_FILE:?}" || exit 1
fi
if [ "${MOCK_REPLACE_PEER_AFTER_MEMORY:-0}" = "1" ] &&
   [ "${target##*/}" = "memory" ] &&
   [ ! -e "${MOCK_CASE_DIR}/peer-replaced-after-memory" ]; then
    replacement="${MOCK_CRITICAL_PEER_FILE}.replacement.$$"
    printf '%s\n' "${MOCK_PEER_REPLACEMENT_VALUE:-100.104.78.43}" \
        >"$replacement" || exit 1
    chmod 0644 "$replacement" || exit 1
    /bin/mv -f "$replacement" "$MOCK_CRITICAL_PEER_FILE" || exit 1
    : >"${MOCK_CASE_DIR}/peer-replaced-after-memory" || exit 1
fi
exit 0
EOF

cat >"${MOCK_BIN}/dd" <<'EOF'
#!/bin/sh
input=""
for argument in "$@"; do
    case "$argument" in
        if=*) input="${argument#if=}" ;;
    esac
done
/bin/dd "$@"
rc=$?
if [ "$rc" -eq 0 ] &&
   [ "${MOCK_DD_GENERATION_CHANGE_ON_SECOND_MAINTENANCE:-0}" = "1" ]; then
    case "$input" in
        */maintenance-until)
            count=0
            if [ -f "${MOCK_DD_MAINTENANCE_COUNT_FILE:?}" ]; then
                count="$(cat "${MOCK_DD_MAINTENANCE_COUNT_FILE:?}")"
            fi
            case "$count" in
                0|[1-9]|[1-9][0-9]*) ;;
                *) exit 97 ;;
            esac
            count=$((count + 1))
            printf '%s\n' "$count" \
                >"${MOCK_DD_MAINTENANCE_COUNT_FILE:?}" || exit 98
            if [ "$count" -eq 2 ]; then
                : >"${MOCK_GENERATION_CHANGE_FILE:?}" || exit 99
            fi
            ;;
    esac
fi
exit "$rc"
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

cat >"${MOCK_BIN}/stat" <<'EOF'
#!/usr/bin/env python3
import os
import stat
import sys

if len(sys.argv) != 4 or sys.argv[1] != "-c":
    raise SystemExit(2)
if sys.argv[2] != "%u:%g:%a:%h:%d:%i:%s":
    raise SystemExit(2)
value = os.lstat(sys.argv[3])
mode = format(stat.S_IMODE(value.st_mode), "o")
print(
    f"{value.st_uid}:{value.st_gid}:{mode}:{value.st_nlink}:"
    f"{value.st_dev}:{value.st_ino}:{value.st_size}"
)
EOF

chmod 0755 "${MOCK_BIN}/tailscale" "${MOCK_BIN}/jq" \
    "${MOCK_BIN}/timeout" "${MOCK_BIN}/systemctl" "${MOCK_BIN}/logger" \
    "${MOCK_BIN}/mv" "${MOCK_BIN}/dd" "${MOCK_BIN}/flock" \
    "${MOCK_BIN}/stat"

PASS_COUNT=0
EXPECTED_TEST_UID="$(id -u)"
EXPECTED_TEST_GID="$(id -g)"

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
    UPTIME_FILE="${CASE_DIR}/uptime"
    SOCKET_COUNTER=$((SOCKET_COUNTER + 1))
    SOCKET_PATH="${TMPDIR:-/tmp}/jmvps-watchdog-sock.$$.${SOCKET_COUNTER}"
    CRITICAL_PEER_PATH="${CASE_DIR}/critical-peer"
    mkdir -p "$STATE_DIR"
    : >"$ACTIONS_FILE"
    : >"$LOG_FILE"
    : >"$CLI_ARGS_FILE"
    : >"$SYSTEMCTL_ARGS_FILE"
    printf '100.00 0.00\n' >"$UPTIME_FILE"
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
    _unit_file_state="${UNIT_FILE_STATE_VALUE:-enabled}"
    _nrestarts="${NRESTARTS_VALUE:-0}"
    _process_start_usec="${PROCESS_START_USEC_VALUE:-100000000}"
    _join_service_state="${JOIN_SERVICE_STATE_VALUE:-$_service_state}"
    _join_unit_file_state="${JOIN_UNIT_FILE_STATE_VALUE:-$_unit_file_state}"
    _join_nrestarts="${JOIN_NRESTARTS_VALUE:-$_nrestarts}"
    _join_process_start_usec="${JOIN_PROCESS_START_USEC_VALUE:-$_process_start_usec}"
    _pre_restart_service_state="${PRE_RESTART_SERVICE_STATE_VALUE:-$_join_service_state}"
    _pre_restart_unit_file_state="${PRE_RESTART_UNIT_FILE_STATE_VALUE:-$_join_unit_file_state}"
    _pre_restart_nrestarts="${PRE_RESTART_NRESTARTS_VALUE:-$_join_nrestarts}"
    _pre_restart_process_start_usec="${PRE_RESTART_PROCESS_START_USEC_VALUE:-$_join_process_start_usec}"
    _after_memory_service_state="${AFTER_MEMORY_SERVICE_STATE_VALUE:-$_pre_restart_service_state}"
    _after_memory_unit_file_state="${AFTER_MEMORY_UNIT_FILE_STATE_VALUE:-$_pre_restart_unit_file_state}"
    _after_memory_nrestarts="${AFTER_MEMORY_NRESTARTS_VALUE:-$_pre_restart_nrestarts}"
    _after_memory_process_start_usec="${AFTER_MEMORY_PROCESS_START_USEC_VALUE:-$_pre_restart_process_start_usec}"
    _show_count_file="${CASE_DIR}/show-count.${_mono}.${_epoch}"
    _generation_change_file="${_show_count_file}.memory-committed"
    _maintenance_count_file="${_show_count_file}.maintenance-count"
    rm -f "$_show_count_file"
    rm -f "$_generation_change_file"
    rm -f "$_maintenance_count_file"
    env \
        MOCK_TAILSCALE_MODE="$_mode" \
        MOCK_PEER_MODE="${PEER_MODE_VALUE:-reachable}" \
        MOCK_EXPECTED_SOCKET="$SOCKET_PATH" \
        MOCK_SERVICE_STATE="$_service_state" \
        MOCK_UNIT_FILE_STATE="$_unit_file_state" \
        MOCK_NRESTARTS="$_nrestarts" \
        MOCK_PROCESS_START_USEC="$_process_start_usec" \
        MOCK_JOIN_SERVICE_STATE="$_join_service_state" \
        MOCK_JOIN_UNIT_FILE_STATE="$_join_unit_file_state" \
        MOCK_JOIN_NRESTARTS="$_join_nrestarts" \
        MOCK_JOIN_PROCESS_START_USEC="$_join_process_start_usec" \
        MOCK_PRE_RESTART_SERVICE_STATE="$_pre_restart_service_state" \
        MOCK_PRE_RESTART_UNIT_FILE_STATE="$_pre_restart_unit_file_state" \
        MOCK_PRE_RESTART_NRESTARTS="$_pre_restart_nrestarts" \
        MOCK_PRE_RESTART_PROCESS_START_USEC="$_pre_restart_process_start_usec" \
        MOCK_AFTER_MEMORY_SERVICE_STATE="$_after_memory_service_state" \
        MOCK_AFTER_MEMORY_UNIT_FILE_STATE="$_after_memory_unit_file_state" \
        MOCK_AFTER_MEMORY_NRESTARTS="$_after_memory_nrestarts" \
        MOCK_AFTER_MEMORY_PROCESS_START_USEC="$_after_memory_process_start_usec" \
        MOCK_SHOW_COUNT_FILE="$_show_count_file" \
        MOCK_GENERATION_CHANGE_FILE="$_generation_change_file" \
        MOCK_MV_GENERATION_CHANGE="${MV_GENERATION_CHANGE_VALUE:-0}" \
        MOCK_MV_PUBLISH_MAINTENANCE="${MV_PUBLISH_MAINTENANCE_VALUE:-0}" \
        MOCK_DD_GENERATION_CHANGE_ON_SECOND_MAINTENANCE="${DD_GENERATION_CHANGE_DURING_FINAL_MAINTENANCE_VALUE:-0}" \
        MOCK_DD_MAINTENANCE_COUNT_FILE="$_maintenance_count_file" \
        MOCK_REPLACE_PEER_DURING_PING="${REPLACE_PEER_DURING_PING_VALUE:-0}" \
        MOCK_REPLACE_PEER_AFTER_MEMORY="${REPLACE_PEER_AFTER_MEMORY_VALUE:-0}" \
        MOCK_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        MOCK_PEER_REPLACEMENT_VALUE="${PEER_REPLACEMENT_VALUE:-100.104.78.43}" \
        MOCK_MAINTENANCE_FILE="${STATE_DIR}/maintenance-until" \
        MOCK_MAINTENANCE_CREATED="$_epoch" \
        MOCK_MAINTENANCE_EXPIRY="$((_epoch + 600))" \
        MOCK_RESTART_RC="${RESTART_RC_VALUE:-0}" \
        MOCK_RESTART_BLOCK="${RESTART_BLOCK_VALUE:-0}" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_ARGS_FILE="$CLI_ARGS_FILE" \
        MOCK_SYSTEMCTL_ARGS_FILE="$SYSTEMCTL_ARGS_FILE" \
        MOCK_CASE_DIR="$CASE_DIR" \
        MOCK_UPTIME_FILE="$UPTIME_FILE" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_SOCKET="$SOCKET_PATH" \
        WATCHDOG_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        WATCHDOG_SYSTEMCTL_CMD="${MOCK_BIN}/systemctl" \
        WATCHDOG_TIMEOUT_CMD="${MOCK_BIN}/timeout" \
        WATCHDOG_JQ_CMD="${MOCK_BIN}/jq" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_MV_CMD="${MOCK_BIN}/mv" \
        WATCHDOG_DD_CMD="${MOCK_BIN}/dd" \
        WATCHDOG_STAT_CMD="${MOCK_BIN}/stat" \
        WATCHDOG_EXPECTED_ROOT_UID="$EXPECTED_TEST_UID" \
        WATCHDOG_EXPECTED_ROOT_GID="$EXPECTED_TEST_GID" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_UPTIME_FILE="$UPTIME_FILE" \
        WATCHDOG_MEMORY_FILE="${MEMORY_FILE_VALUE:-${STATE_DIR}/memory}" \
        WATCHDOG_CONTINUITY_MAX_GAP=30 \
        MOCK_MV_FAIL_MEMORY="${MV_FAIL_MEMORY_VALUE:-0}" \
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

start_restart_blocking_watchdog() {
    _restart_show_count_file="${CASE_DIR}/restart-show-count"
    rm -f "$_restart_show_count_file"
    env \
        MOCK_TAILSCALE_MODE=timeout \
        MOCK_PEER_MODE=reachable \
        MOCK_EXPECTED_SOCKET="$SOCKET_PATH" \
        MOCK_SERVICE_STATE=active \
        MOCK_UNIT_FILE_STATE=enabled \
        MOCK_NRESTARTS=0 \
        MOCK_PROCESS_START_USEC=100000000 \
        MOCK_SHOW_COUNT_FILE="$_restart_show_count_file" \
        MOCK_RESTART_RC=0 \
        MOCK_RESTART_BLOCK=1 \
        MOCK_REPLACE_PEER_DURING_PING=0 \
        MOCK_REPLACE_PEER_AFTER_MEMORY=0 \
        MOCK_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_ARGS_FILE="$CLI_ARGS_FILE" \
        MOCK_SYSTEMCTL_ARGS_FILE="$SYSTEMCTL_ARGS_FILE" \
        MOCK_CASE_DIR="$CASE_DIR" \
        MOCK_UPTIME_FILE="$UPTIME_FILE" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_SOCKET="$SOCKET_PATH" \
        WATCHDOG_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        WATCHDOG_SYSTEMCTL_CMD="${MOCK_BIN}/systemctl" \
        WATCHDOG_TIMEOUT_CMD="${MOCK_BIN}/timeout" \
        WATCHDOG_JQ_CMD="${MOCK_BIN}/jq" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_MV_CMD="${MOCK_BIN}/mv" \
        WATCHDOG_DD_CMD="/bin/dd" \
        WATCHDOG_STAT_CMD="${MOCK_BIN}/stat" \
        WATCHDOG_EXPECTED_ROOT_UID="$EXPECTED_TEST_UID" \
        WATCHDOG_EXPECTED_ROOT_GID="$EXPECTED_TEST_GID" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_UPTIME_FILE="$UPTIME_FILE" \
        WATCHDOG_MEMORY_FILE="${MEMORY_FILE_VALUE:-${STATE_DIR}/memory}" \
        WATCHDOG_CONTINUITY_MAX_GAP=30 \
        MOCK_MV_FAIL_MEMORY="${MV_FAIL_MEMORY_VALUE:-0}" \
        WATCHDOG_STATUS_TIMEOUT=1 \
        WATCHDOG_PEER_TIMEOUT=1 \
        WATCHDOG_RESTART_TIMEOUT=30 \
        WATCHDOG_FAILURE_THRESHOLD=3 \
        WATCHDOG_VALID_STREAK_REQUIRED=5 \
        WATCHDOG_BOOT_GRACE=0 \
        WATCHDOG_MAINTENANCE_MAX_FUTURE=3600 \
        WATCHDOG_NOW_MONO=1603 \
        WATCHDOG_NOW_EPOCH=2403 \
        /bin/dash "$WATCHDOG" --once &
    RESTART_WATCHDOG_PID=$!
}

start_blocking_watchdog() {
    _blocking_show_count_file="${CASE_DIR}/blocking-show-count"
    rm -f "$_blocking_show_count_file"
    env \
        MOCK_TAILSCALE_MODE=block \
        MOCK_PEER_MODE=reachable \
        MOCK_EXPECTED_SOCKET="$SOCKET_PATH" \
        MOCK_SERVICE_STATE=active \
        MOCK_UNIT_FILE_STATE=enabled \
        MOCK_NRESTARTS=0 \
        MOCK_PROCESS_START_USEC=100000000 \
        MOCK_SHOW_COUNT_FILE="$_blocking_show_count_file" \
        MOCK_RESTART_RC=0 \
        MOCK_REPLACE_PEER_DURING_PING=0 \
        MOCK_REPLACE_PEER_AFTER_MEMORY=0 \
        MOCK_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_ARGS_FILE="$CLI_ARGS_FILE" \
        MOCK_SYSTEMCTL_ARGS_FILE="$SYSTEMCTL_ARGS_FILE" \
        MOCK_CASE_DIR="$CASE_DIR" \
        MOCK_UPTIME_FILE="$UPTIME_FILE" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_SOCKET="$SOCKET_PATH" \
        WATCHDOG_CRITICAL_PEER_FILE="$CRITICAL_PEER_PATH" \
        WATCHDOG_SYSTEMCTL_CMD="${MOCK_BIN}/systemctl" \
        WATCHDOG_TIMEOUT_CMD="${MOCK_BIN}/timeout" \
        WATCHDOG_JQ_CMD="${MOCK_BIN}/jq" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_MV_CMD="${MOCK_BIN}/mv" \
        WATCHDOG_DD_CMD="/bin/dd" \
        WATCHDOG_STAT_CMD="${MOCK_BIN}/stat" \
        WATCHDOG_EXPECTED_ROOT_UID="$EXPECTED_TEST_UID" \
        WATCHDOG_EXPECTED_ROOT_GID="$EXPECTED_TEST_GID" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_UPTIME_FILE="$UPTIME_FILE" \
        WATCHDOG_MEMORY_FILE="${MEMORY_FILE_VALUE:-${STATE_DIR}/memory}" \
        WATCHDOG_CONTINUITY_MAX_GAP=30 \
        MOCK_MV_FAIL_MEMORY="${MV_FAIL_MEMORY_VALUE:-0}" \
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

watchdog_lock_is_available() (
    exec 9<>"${STATE_DIR}/watchdog.lock"
    "${MOCK_BIN}/flock" -n 9
)

wait_for_watchdog_lock_available() {
    _attempt=0
    while ! watchdog_lock_is_available && [ "$_attempt" -lt 100 ]; do
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    watchdog_lock_is_available ||
        fail "timed out waiting for watchdog lock guardian"
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
grep -qx 'RECOVERY_MAX_ATTEMPTS=3' "$WATCHDOG" &&
    grep -qx 'RECOVERY_RETRY_SHORT=60' "$WATCHDOG" &&
    grep -qx 'RECOVERY_RETRY_LONG=300' "$WATCHDOG" ||
    fail "bounded recovery authority is not the fixed 3/60/300 contract"
pass "bounded recovery authority is fixed at three attempts with 60s and 300s cooldowns"

new_case running
run_once running 0 200 1000
assert_json '"schema":3'
assert_json '"status":"running"'
assert_json '"localapi_valid":true'
assert_json '"healthy":true'
assert_json '"connected":true'
assert_json '"degraded":false'
assert_json '"control_online":true'
assert_json '"tun_available":true'
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

new_case process_generation_evidence_gap
run_once running 0 200 1000
PROCESS_START_USEC_VALUE=0
run_once running 0 215 1015
assert_json '"process_started_monotonic_usec":null'
assert_json '"status":"running_degraded"'
assert_json '"reason":"process_generation_unknown"'
assert_json '"healthy":false'
assert_json '"connected":true'
assert_json '"connectivity_uptime_seconds":0'
PROCESS_START_USEC_VALUE=100000000
run_once running 0 230 1030
unset PROCESS_START_USEC_VALUE
assert_json '"process_started_monotonic_usec":100000000'
assert_json '"connectivity_uptime_seconds":0'
assert_no_action
pass "known generation cannot bridge an intervening generation-evidence gap"

new_case future_process_generation
PROCESS_START_USEC_VALUE=300000000
run_once running 0 200 1000
unset PROCESS_START_USEC_VALUE
assert_json '"process_started_monotonic_usec":null'
assert_json '"process_uptime_seconds":null'
assert_json '"status":"running_degraded"'
assert_json '"reason":"process_generation_unknown"'
assert_json '"healthy":false'
assert_json '"connected":true'
assert_no_action
pass "future systemd process timestamps cannot become healthy evidence"

new_case generation-replaced-during-semantic-probe
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
JOIN_PROCESS_START_USEC_VALUE=200000000
run_once running 0 210 1010
unset JOIN_PROCESS_START_USEC_VALUE
assert_json '"status":"supervisor_generation_changed"'
assert_json '"reason":"supervisor_generation_changed"'
assert_json '"service_active":false'
assert_json '"localapi_valid":false'
assert_json '"connected":false'
assert_json '"healthy":false'
assert_json '"degraded":true'
assert_json '"process_started_monotonic_usec":null'
assert_json '"connectivity_uptime_seconds":null'
assert_json '"consecutive_eligible_failures":0'
assert_json '"action":"suppressed_generation_change"'
[ "$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')" -eq 2 ] ||
    fail "generation race did not occur after LocalAPI and peer probes"
[ "$(grep -c '^show ' "$SYSTEMCTL_ARGS_FILE")" -eq 2 ] ||
    fail "healthy semantic observation was not joined to a second systemd read"
assert_no_action
pass "a generation replacement after LocalAPI and peer probes fails closed"

new_case generation-replaced-before-threshold-restart
run_once timeout 0 220 1020
run_once timeout 0 221 1021
MV_GENERATION_CHANGE_VALUE=1
AFTER_MEMORY_PROCESS_START_USEC_VALUE=200000000
run_once timeout 0 222 1022
unset MV_GENERATION_CHANGE_VALUE AFTER_MEMORY_PROCESS_START_USEC_VALUE
assert_json '"status":"supervisor_generation_changed"'
assert_json '"reason":"supervisor_generation_changed"'
assert_json '"eligible_failure":false'
assert_json '"consecutive_eligible_failures":0'
assert_json '"recovery_latched":false'
assert_json '"recovery_count":0'
assert_json '"action":"suppressed_generation_change"'
grep -Fqx 'consecutive_failures=0' "${STATE_DIR}/memory" ||
    fail "pre-restart generation race left a durable failure streak"
grep -Fqx 'recovery_latched=0' "${STATE_DIR}/memory" ||
    fail "pre-restart generation race left a false durable latch"
[ "$(grep -c '^show ' "$SYSTEMCTL_ARGS_FILE")" -eq 7 ] ||
    fail "threshold recovery lacked the immediate third systemd identity read"
assert_no_action
pass "a replacement after latch persistence and before restart is suppressed"

new_case maintenance-published-before-threshold-restart
run_once timeout 0 220 1020
run_once timeout 0 221 1021
MV_PUBLISH_MAINTENANCE_VALUE=1
run_once timeout 0 222 1022
unset MV_PUBLISH_MAINTENANCE_VALUE
assert_json '"maintenance_active":true'
assert_json '"maintenance_state":"active"'
assert_json '"eligible_failure":false'
assert_json '"consecutive_eligible_failures":0'
assert_json '"recovery_latched":false'
assert_json '"recovery_count":0'
assert_json '"action":"suppressed_maintenance"'
grep -Fqx 'consecutive_failures=0' "${STATE_DIR}/memory" ||
    fail "late maintenance race left a durable failure streak"
grep -Fqx 'recovery_latched=0' "${STATE_DIR}/memory" ||
    fail "late maintenance race left a false durable latch"
assert_no_action
pass "maintenance published after latch persistence suppresses restart durably"

new_case generation-changes-during-final-maintenance-proof
printf '%s %s\n' 1000 1001 >"${STATE_DIR}/maintenance-until"
run_once timeout 0 220 1020
run_once timeout 0 221 1021
DD_GENERATION_CHANGE_DURING_FINAL_MAINTENANCE_VALUE=1
AFTER_MEMORY_PROCESS_START_USEC_VALUE=200000000
run_once timeout 0 222 1022
unset DD_GENERATION_CHANGE_DURING_FINAL_MAINTENANCE_VALUE \
    AFTER_MEMORY_PROCESS_START_USEC_VALUE
assert_json '"status":"supervisor_generation_changed"'
assert_json '"reason":"supervisor_generation_changed"'
assert_json '"eligible_failure":false'
assert_json '"consecutive_eligible_failures":0'
assert_json '"recovery_latched":false'
assert_json '"recovery_count":0'
assert_json '"action":"suppressed_generation_change"'
grep -Fqx 'consecutive_failures=0' "${STATE_DIR}/memory" ||
    fail "maintenance-proof generation race left a durable failure streak"
grep -Fqx 'recovery_latched=0' "${STATE_DIR}/memory" ||
    fail "maintenance-proof generation race left a false durable latch"
[ "$(grep -c '^show ' "$SYSTEMCTL_ARGS_FILE")" -eq 7 ] ||
    fail "generation was not rejoined after the final maintenance proof"
assert_no_action
pass "generation change during final maintenance proof is joined and refunded"

new_case inactive-becomes-live-before-recovery
THRESHOLD_VALUE=1
PRE_RESTART_SERVICE_STATE_VALUE=active
PRE_RESTART_PROCESS_START_USEC_VALUE=200000000
run_once running 3 230 1030
unset THRESHOLD_VALUE PRE_RESTART_SERVICE_STATE_VALUE \
    PRE_RESTART_PROCESS_START_USEC_VALUE
assert_json '"status":"supervisor_generation_changed"'
assert_json '"service_active":false'
assert_json '"localapi_valid":false'
assert_json '"connected":false'
assert_json '"eligible_failure":false'
assert_json '"consecutive_eligible_failures":0'
assert_json '"recovery_latched":false'
assert_json '"recovery_count":0'
assert_json '"action":"suppressed_generation_change"'
[ "$(grep -c '^show ' "$SYSTEMCTL_ARGS_FILE")" -eq 3 ] ||
    fail "inactive recovery lacked both generation joins"
assert_no_action
pass "an inactive enabled unit that becomes live is never restarted as stale"

new_case persistence_observation_gap
run_once running 0 200 1000
MV_FAIL_MEMORY_VALUE=1
if run_once running 0 205 1005 2>/dev/null; then
    fail "forced memory persistence failure unexpectedly succeeded"
fi
unset MV_FAIL_MEMORY_VALUE
assert_json '"status":"watchdog_error"'
assert_json '"reason":"state_persistence_failed"'
[ -f "${STATE_DIR}/continuity-broken" ] ||
    fail "persistence failure did not leave a continuity-break sentinel"
run_once running 0 215 1015
assert_json '"status":"running"'
assert_json '"connectivity_uptime_seconds":0'
[ ! -e "${STATE_DIR}/continuity-broken" ] ||
    fail "successful reset did not clear the continuity-break sentinel"
assert_no_action
pass "uptime cannot bridge a known unpersisted observation"

new_case critical_peer_contract_change
run_once running 0 200 1000
run_once running 0 215 1015
assert_json '"connectivity_uptime_seconds":15'
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
run_once running 0 230 1030
assert_json '"peer_reachable":true'
assert_json '"connectivity_uptime_seconds":0'
run_once running 0 245 1045
assert_json '"connectivity_uptime_seconds":15'
printf '%s\n' '100.104.78.43' >"$CRITICAL_PEER_PATH"
run_once running 0 260 1060
assert_json '"peer_reachable":true'
assert_json '"connectivity_uptime_seconds":0'
assert_no_action
pass "adding or changing critical-peer proof starts a new uptime contract"

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

for _delivery_mode in no_address invalid_address tun_off; do
    new_case "delivery-${_delivery_mode}"
    run_once "$_delivery_mode" 0 550 1350
    assert_json '"status":"running_degraded"'
    assert_json '"healthy":false'
    assert_json '"connected":false'
    assert_json '"degraded":true'
    assert_json '"connectivity_uptime_seconds":null'
    assert_no_action
done
pass "connected requires Running, a tailnet address, and the expected TUN"

for _valid_ipv4_mode in ipv4_lower_bound ipv4_upper_bound; do
    new_case "$_valid_ipv4_mode"
    run_once "$_valid_ipv4_mode" 0 551 1351
    assert_json '"status":"running"'
    assert_json '"tailnet_ip_present":true'
    assert_json '"connected":true'
    assert_no_action
done
for _invalid_ipv4_mode in \
    ipv4_below_range ipv4_above_range ipv4_noncanonical ipv4_trailing_newline
do
    new_case "$_invalid_ipv4_mode"
    run_once "$_invalid_ipv4_mode" 0 551 1351
    assert_json '"status":"running_degraded"'
    assert_json '"reason":"address_missing"'
    assert_json '"tailnet_ip_present":false'
    assert_json '"connected":false'
    assert_no_action
done
pass "IPv4 delivery remains bounded to canonical 100.64.0.0/10 literals"

for _valid_ipv6_mode in ipv6_full ipv6_compressed; do
    new_case "$_valid_ipv6_mode"
    run_once "$_valid_ipv6_mode" 0 552 1352
    assert_json '"schema":3'
    assert_json '"status":"running"'
    assert_json '"tailnet_ip_present":true'
    assert_json '"connected":true'
    assert_no_action
done
pass "full and compressed Tailscale ULA addresses satisfy strict IPv6 parsing"

for _invalid_ipv6_mode in \
    ipv6_too_few \
    ipv6_hextet_too_long \
    ipv6_double_compression \
    ipv6_too_many \
    ipv6_wrong_prefix
do
    new_case "$_invalid_ipv6_mode"
    run_once "$_invalid_ipv6_mode" 0 553 1353
    assert_json '"schema":3'
    assert_json '"status":"running_degraded"'
    assert_json '"reason":"address_missing"'
    assert_json '"tailnet_ip_present":false'
    assert_json '"connected":false'
    assert_no_action
done
pass "malformed or out-of-prefix IPv6 strings cannot claim tailnet delivery"

new_case live-1.98.9-self-in-engine-false
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
run_once live_1_98_9 0 555 1355
assert_json '"status":"running"'
assert_json '"healthy":true'
assert_json '"connected":true'
assert_json '"degraded":false'
assert_json '"peer_state":"reachable"'
assert_json '"peer_reachable":true'
if grep -Fq '"in_engine":' "${STATE_DIR}/status.json"; then
    fail "live-1.98.9-self-in-engine-false: peer-only field was republished"
fi
assert_no_action
pass "Tailscale 1.98.9 Self.InEngine=false is healthy when delivery succeeds"

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
pass "a WireGuard TSMP response from the critical peer is required for connected"

new_case critical-peer-replaced-during-ping
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
REPLACE_PEER_DURING_PING_VALUE=1
run_once running 0 562 1362
unset REPLACE_PEER_DURING_PING_VALUE
assert_json '"status":"running_degraded"'
assert_json '"reason":"critical_peer_invalid"'
assert_json '"peer_state":"invalid_configuration"'
assert_json '"peer_reachable":false'
assert_json '"connected":false'
[ "$(cat "$CRITICAL_PEER_PATH")" = "100.104.78.43" ] ||
    fail "during-ping peer replacement fixture did not run"
assert_no_action
pass "an atomic peer replacement during TSMP invalidates the in-flight delivery proof"

new_case critical-peer-replaced-before-publish
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
REPLACE_PEER_AFTER_MEMORY_VALUE=1
run_once running 0 563 1363
unset REPLACE_PEER_AFTER_MEMORY_VALUE
assert_json '"status":"running_degraded"'
assert_json '"reason":"critical_peer_invalid"'
assert_json '"peer_state":"invalid_configuration"'
assert_json '"peer_reachable":false'
assert_json '"connected":false'
[ -f "${STATE_DIR}/continuity-broken" ] ||
    fail "prepublication peer replacement did not break continuity durably"
assert_no_action
pass "the final prepublication peer join rejects an atomic replacement"

assert_invalid_vps_peer_config() {
    _peer_cli_before="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
    run_once running 0 564 1364
    assert_json '"status":"running_degraded"'
    assert_json '"reason":"critical_peer_invalid"'
    assert_json '"peer_state":"invalid_configuration"'
    assert_json '"peer_reachable":false'
    assert_json '"connected":false'
    _peer_cli_after="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
    [ "$_peer_cli_after" -eq $((_peer_cli_before + 1)) ] ||
        fail "invalid critical-peer configuration invoked a peer ping"
    assert_no_action
}

new_case critical-peer-invalid-config
: >"$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
printf '%s\n' router-magicdns-name >"$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
printf '%s\n\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
printf '100.104.78.42\r\n' >"$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
printf '%s\n' '100.104.78.42' >"$CRITICAL_PEER_PATH"
chmod 0600 "$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
chmod 0644 "$CRITICAL_PEER_PATH"
ln "$CRITICAL_PEER_PATH" "${CASE_DIR}/peer-hardlink"
assert_invalid_vps_peer_config
rm -f "${CASE_DIR}/peer-hardlink"
python3 - "$CRITICAL_PEER_PATH" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"100.104.78.42\x00")
PY
assert_invalid_vps_peer_config
rm -f "$CRITICAL_PEER_PATH"
mkdir "$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
rmdir "$CRITICAL_PEER_PATH"
printf '%s\n' '100.104.78.42' >"${CASE_DIR}/peer-real"
ln -s "${CASE_DIR}/peer-real" "$CRITICAL_PEER_PATH"
assert_invalid_vps_peer_config
pass "only one exact Tailscale IP line can configure the critical peer"

new_case critical-peer-self-target
printf '%s\n' 'FD7A:115C:A1E0:0000:0000:0000:0000:0002' \
    >"$CRITICAL_PEER_PATH"
run_once multiple_addresses 0 565 1365
assert_json '"schema":3'
assert_json '"status":"running_degraded"'
assert_json '"reason":"critical_peer_invalid"'
assert_json '"peer_state":"invalid_configuration"'
assert_json '"peer_reachable":false'
assert_json '"connected":false'
[ "$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')" -eq 1 ] ||
    fail "self-targeted critical peer invoked a Tailscale ping"
assert_no_action
pass "equivalent IPv6 spelling cannot target a local Self.TailscaleIPs address"

new_case schema_errors
for _mode in \
    malformed running_bad_schema health_bad_schema health_missing health_null \
    health_nonstring health_oversized_string health_too_many unknown
do
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

for _health_schema_mode in \
    health_bad_schema health_missing health_null health_nonstring \
    health_oversized_string health_too_many
do
    new_case "$_health_schema_mode"
    run_once "$_health_schema_mode" 0 650 1450
    assert_json '"status":"schema_error"'
    assert_json '"reason":"status_schema_invalid"'
    assert_json '"localapi_valid":false'
    assert_json '"healthy":false'
    assert_json '"connected":false'
    assert_no_action
done
pass "Health must be a bounded array of strings and can never default healthy"

new_case raw_status_cap
run_once oversized_output 0 660 1460
assert_json '"status":"command_error"'
assert_json '"reason":"localapi_command_failed"'
assert_json '"eligible_failure":false'
assert_no_action
pass "raw VPS LocalAPI output is constrained by a 64 KiB file limit"

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

for _nonpersistent_state in disabled masked static enabled-runtime; do
    new_case "active-nonpersistent-${_nonpersistent_state}"
    UNIT_FILE_STATE_VALUE="$_nonpersistent_state"
    run_once running 0 790 1599
    assert_json '"status":"running_degraded"'
    assert_json '"reason":"service_not_persistently_enabled"'
    assert_json '"connected":true'
    assert_json '"healthy":false'
    assert_json '"degraded":true'
    assert_json '"eligible_failure":false'
    assert_no_action
    unset UNIT_FILE_STATE_VALUE
done
pass "active runtime-only or disabled services cannot claim reboot durability"

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
assert_json '"action":"recovery_cooldown"'
assert_json '"process_uptime_seconds":null'
pass "persistent supervisor inactivity receives one restart then cooldown"

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

for _interrupted_mode in command_124 timeout_137 timeout_143; do
    new_case "$_interrupted_mode"
    _i=1
    while [ "$_i" -le 4 ]; do
        run_once "$_interrupted_mode" 0 "$((950 + _i))" "$((1750 + _i))"
        _i=$((_i + 1))
    done
    assert_json '"status":"command_error"'
    assert_json '"reason":"localapi_command_failed"'
    assert_json '"eligible_failure":false'
    assert_no_action
done
pass "command-owned rc124 and early signal exits cannot authorize restart"

new_case command_124_rollover
printf '%s\n' '100.99 0.00' >"$UPTIME_FILE"
run_once command_124_rollover 0 960 1760
assert_json '"status":"command_error"'
assert_json '"reason":"localapi_command_failed"'
assert_json '"eligible_failure":false'
assert_no_action
pass "a one-centisecond rollover cannot turn command-owned rc124 into a timeout"

new_case malformed_uptime
printf '%s\n' 'not-uptime' >"$UPTIME_FILE"
_i=1
while [ "$_i" -le 4 ]; do
    run_once timeout 0 "$((965 + _i))" "$((1765 + _i))"
    _i=$((_i + 1))
done
assert_json '"status":"command_error"'
assert_json '"reason":"localapi_command_failed"'
assert_json '"eligible_failure":false'
assert_no_action
pass "malformed monotonic deadline evidence fails closed without restart"

new_case missing_uptime
rm -f "$UPTIME_FILE"
: >"${CASE_DIR}/missing-uptime-stderr"
_i=1
while [ "$_i" -le 4 ]; do
    run_once timeout 0 "$((968 + _i))" "$((1768 + _i))" \
        2>>"${CASE_DIR}/missing-uptime-stderr"
    _i=$((_i + 1))
done
assert_json '"status":"command_error"'
assert_json '"reason":"localapi_command_failed"'
assert_json '"eligible_failure":false'
assert_no_action
[ ! -s "${CASE_DIR}/missing-uptime-stderr" ] ||
    fail "an absent monotonic source leaked a shell diagnostic"
pass "an absent monotonic source fails closed without restart"

for _fail_closed_boundary in \
    finish_malformed clock_backstep deadline_minus_one
do
    new_case "$_fail_closed_boundary"
    run_once "$_fail_closed_boundary" 0 970 1770
    assert_json '"status":"command_error"'
    assert_json '"reason":"localapi_command_failed"'
    assert_json '"eligible_failure":false'
    assert_no_action
done
pass "malformed finish, clock backstep, and deadline-minus-one fail closed"

for _deadline_mode in deadline_137 deadline_143; do
    new_case "$_deadline_mode"
    _i=1
    while [ "$_i" -le 3 ]; do
        run_once "$_deadline_mode" 0 "$((970 + _i))" "$((1770 + _i))"
        _i=$((_i + 1))
    done
    [ "$(action_count)" -eq 1 ] ||
        fail "${_deadline_mode} did not latch one restart"
    assert_json '"status":"localapi_timeout"'
    assert_json '"eligible_failure":true'
    assert_json '"recovery_count":1'
done
pass "deadline evidence recognizes signal-derived GNU timeout exits"

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

new_case multiline_maintenance
printf '%s\n%s\n' '1000 2600' 'unexpected-second-line' \
    >"${STATE_DIR}/maintenance-until"
run_once timeout 0 1361 2000
run_once timeout 0 1362 2001
run_once timeout 0 1363 2002
assert_json '"maintenance_active":false'
assert_json '"maintenance_state":"malformed"'
[ "$(action_count)" -eq 1 ] ||
    fail "extra maintenance-marker content suppressed recovery"
pass "maintenance suppression requires exactly one validated line"

new_case byte_exact_maintenance
for _marker in '08 09' '9999999999999999999 9999999999999999999'; do
    printf '%s\n' "$_marker" >"${STATE_DIR}/maintenance-until"
    run_once timeout 0 1371 2000
    assert_json '"maintenance_active":false'
    assert_json '"maintenance_state":"malformed"'
done
python3 - "${STATE_DIR}/maintenance-until" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"1000 2600\x00")
PY
run_once timeout 0 1372 2000
assert_json '"maintenance_active":false'
assert_json '"maintenance_state":"malformed"'
run_once timeout 0 1373 2001
[ "$(action_count)" -eq 1 ] ||
    fail "byte-invalid maintenance marker suppressed recovery"
pass "maintenance epochs are canonical bounded decimals with exact bytes"

new_case oversized_maintenance
python3 - "${STATE_DIR}/maintenance-until" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"1" * (1024 * 1024))
PY
run_once timeout 0 1381 2000
run_once timeout 0 1382 2001
run_once timeout 0 1383 2002
assert_json '"maintenance_active":false'
assert_json '"maintenance_state":"malformed"'
[ "$(action_count)" -eq 1 ] ||
    fail "oversized maintenance marker suppressed bounded recovery"
pass "oversized maintenance input is rejected before content scanning"

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
assert_json '"action":"recovery_cooldown"'
pass "failed restart retains a durable cooldown against a restart storm"

new_case bounded-recovery-retries
THRESHOLD_VALUE=1
RESTART_RC_VALUE=1
run_once timeout 0 2000 3000
[ "$(action_count)" -eq 1 ] ||
    fail "bounded retries did not request the first attempt"
grep -Fqx 'recovery_attempt_count=1' "${STATE_DIR}/memory" ||
    fail "first recovery attempt count was not durable"
grep -Fqx 'recovery_next_retry_monotonic=2060' "${STATE_DIR}/memory" ||
    fail "short recovery deadline was not durable"
run_once timeout 0 2059 3059
[ "$(action_count)" -eq 1 ] ||
    fail "second recovery attempt preceded its 60-second cooldown"
assert_json '"action":"recovery_cooldown"'
run_once timeout 0 2060 3060
[ "$(action_count)" -eq 2 ] ||
    fail "bounded retries did not request the second attempt"
grep -Fqx 'recovery_attempt_count=2' "${STATE_DIR}/memory" ||
    fail "second recovery attempt count was not durable"
grep -Fqx 'recovery_next_retry_monotonic=2360' "${STATE_DIR}/memory" ||
    fail "long recovery deadline was not durable"
run_once timeout 0 2359 3359
[ "$(action_count)" -eq 2 ] ||
    fail "third recovery attempt preceded its 300-second cooldown"
run_once timeout 0 2360 3360
[ "$(action_count)" -eq 3 ] ||
    fail "bounded retries did not request the third attempt"
grep -Fqx 'recovery_attempt_count=3' "${STATE_DIR}/memory" ||
    fail "exhausted recovery attempt count was not durable"
grep -Fqx 'recovery_next_retry_monotonic=0' "${STATE_DIR}/memory" ||
    fail "exhausted recovery deadline was not cleared"
run_once timeout 0 3000 4000
[ "$(action_count)" -eq 3 ] ||
    fail "exhausted recovery episode requested a fourth restart"
assert_json '"action":"recovery_exhausted"'
RESTART_RC_VALUE=0
unset RESTART_RC_VALUE THRESHOLD_VALUE
pass "three durable attempts use 60s and 300s cooldowns then exhaust"

new_case recovery-latch-sigkill
run_once timeout 0 1601 2401
run_once timeout 0 1602 2402
start_restart_blocking_watchdog
wait_for_file "${CASE_DIR}/restart-child-pid"
wait_for_file "${CASE_DIR}/restart-fd9"
[ "$(cat "${CASE_DIR}/restart-fd9")" = "closed" ] ||
    fail "actual systemctl restart child inherited singleton fd9"
grep -Fqx 'recovery_latched=1' "${STATE_DIR}/memory" ||
    fail "recovery latch was not durable before systemctl restart"
grep -Fqx 'recovery_count=1' "${STATE_DIR}/memory" ||
    fail "recovery count was not durable before systemctl restart"
[ "$(action_count)" -eq 1 ] ||
    fail "blocking recovery did not invoke exactly one restart"
kill -KILL "$RESTART_WATCHDOG_PID"
_wait_rc=0
wait "$RESTART_WATCHDOG_PID" 2>/dev/null || _wait_rc=$?
[ "$_wait_rc" -gt 128 ] ||
    fail "SIGKILL did not terminate the watchdog during restart"
_calls_before_blocked_successor="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
run_once running 0 1604 2404
_calls_after_blocked_successor="$(wc -l <"$CLI_ARGS_FILE" | tr -d ' ')"
[ "$_calls_after_blocked_successor" -eq "$_calls_before_blocked_successor" ] ||
    fail "successor reached LocalAPI while restart guardian held fd9"
if watchdog_lock_is_available; then
    fail "restart timeout did not retain singleton authority after SIGKILL"
fi
printf '%s\n' continue >"${CASE_DIR}/restart-fifo"
wait_for_watchdog_lock_available
run_once timeout 0 1605 2405
[ "$(action_count)" -eq 1 ] ||
    fail "successor retried recovery after watchdog SIGKILL"
assert_json '"recovery_latched":true'
assert_json '"recovery_count":1'
assert_json '"action":"recovery_cooldown"'
pass "bounded restart guardian prevents overlap and durable cooldown survives SIGKILL"

new_case recovery-state-write-failure
MEMORY_FILE_VALUE="${CASE_DIR}/memory-store/memory"
mkdir -p "${CASE_DIR}/memory-store"
chmod 0700 "${CASE_DIR}/memory-store"
run_once timeout 0 1651 2451
run_once timeout 0 1652 2452
cp "$MEMORY_FILE_VALUE" "${CASE_DIR}/memory-before-failure"
chmod 0500 "${CASE_DIR}/memory-store"
if run_once timeout 0 1653 2453 2>/dev/null; then
    fail "watchdog succeeded after recovery-state persistence failed"
fi
assert_json '"status":"watchdog_error"'
assert_json '"reason":"state_persistence_failed"'
assert_json '"action":"restart_suppressed_state_persistence_failed"'
assert_json '"eligible_failure":false'
assert_json '"recovery_latched":false'
assert_json '"recovery_count":0'
assert_no_action
cmp -s "$MEMORY_FILE_VALUE" "${CASE_DIR}/memory-before-failure" ||
    fail "failed atomic state write changed the durable memory file"
grep -Fq 'state_persistence_failed' "$LOG_FILE" ||
    fail "persistence failure did not emit its fixed diagnostic enum"
! grep -Fq "$MEMORY_FILE_VALUE" "$LOG_FILE" "${STATE_DIR}/status.json" ||
    fail "persistence failure leaked a state path"
chmod 0700 "${CASE_DIR}/memory-store"
run_once timeout 0 1654 2454
[ "$(action_count)" -eq 1 ] ||
    fail "restored persistence did not permit the first recovery"
unset MEMORY_FILE_VALUE
pass "state-write failure is atomic, observable, and suppresses restart"

new_case recovery-state-rename-failure
MEMORY_FILE_VALUE="${CASE_DIR}/rename-target"
THRESHOLD_VALUE=1
mkdir -p "$MEMORY_FILE_VALUE"
chmod 0700 "$MEMORY_FILE_VALUE"
if run_once timeout 0 1661 2461 2>/dev/null; then
    fail "watchdog accepted a directory as its durable memory file"
fi
assert_json '"status":"watchdog_error"'
assert_json '"reason":"state_persistence_failed"'
assert_json '"action":"restart_suppressed_state_persistence_failed"'
assert_json '"eligible_failure":false'
assert_json '"recovery_latched":true'
assert_json '"recovery_count":0'
assert_no_action
if find "$MEMORY_FILE_VALUE" -mindepth 1 -print | grep -q .; then
    fail "directory memory target received a false durable latch"
fi

rmdir "$MEMORY_FILE_VALUE"
mkdir "${CASE_DIR}/rename-real-directory"
ln -s "${CASE_DIR}/rename-real-directory" "$MEMORY_FILE_VALUE"
if run_once timeout 0 1662 2462 2>/dev/null; then
    fail "watchdog accepted a symlink-to-directory durable memory target"
fi
assert_json '"status":"watchdog_error"'
assert_json '"reason":"state_persistence_failed"'
assert_json '"action":"restart_suppressed_state_persistence_failed"'
assert_no_action
if find "${CASE_DIR}/rename-real-directory" -mindepth 1 -print | grep -q .; then
    fail "symlinked memory target received a false durable latch"
fi
rm -f "$MEMORY_FILE_VALUE"
unset MEMORY_FILE_VALUE THRESHOLD_VALUE
pass "directory and symlink memory targets fail closed before restart"

new_case oversized-memory
python3 - "${STATE_DIR}/memory" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(
    b"recovery_latched=0\nconsecutive_failures=999\n" +
    b"x" * (1024 * 1024)
)
PY
THRESHOLD_VALUE=1
run_once timeout 0 1671 2471
assert_json '"recovery_latched":true'
assert_json '"recovery_count":0'
assert_json '"action":"recovery_exhausted"'
assert_no_action
[ "$(wc -c <"${STATE_DIR}/memory")" -le 4096 ] ||
    fail "oversized memory was not replaced with bounded durable state"
unset THRESHOLD_VALUE
pass "oversized prior memory cannot erase an unknown durable restart latch"

new_case invalid-retry-memory
{
    printf 'recovery_latched=1\n'
    printf 'recovery_attempt_count=1\n'
    printf 'recovery_next_retry_monotonic=0\n'
} >"${STATE_DIR}/memory"
chmod 0600 "${STATE_DIR}/memory"
THRESHOLD_VALUE=1
run_once timeout 0 1681 2481
assert_no_action
assert_json '"recovery_latched":true'
assert_json '"action":"recovery_exhausted"'
grep -Fqx 'recovery_attempt_count=3' "${STATE_DIR}/memory" ||
    fail "invalid retry memory was not rewritten as exhausted"
unset THRESHOLD_VALUE
pass "inconsistent retry memory cannot mint fresh restart authority"

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

new_case supervisor_runtime_only_inactive
UNIT_FILE_STATE_VALUE=enabled-runtime
_i=1
while [ "$_i" -le 5 ]; do
    run_once running 3 "$((1580 + _i))" "$((2380 + _i))"
    _i=$((_i + 1))
done
unset UNIT_FILE_STATE_VALUE
assert_json '"status":"supervisor_unmanaged"'
assert_json '"reason":"unit_not_persistently_enabled"'
assert_json '"eligible_failure":false'
assert_no_action
pass "runtime-only enablement cannot authorize inactive-service recovery"

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
[ "$_wait_rc" -gt 128 ] ||
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
[ "$_wait_rc" -gt 128 ] ||
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
service_limit_core_contract() {
    [ "$(
        awk '
            /^\[/ {
                in_service = ($0 == "[Service]")
                next
            }
            in_service &&
              /^[[:space:]]*LimitCORE[[:space:]]*=/ {
                directive_count++
                if ($0 == "LimitCORE=0") {
                    exact_count++
                }
            }
            END {
                printf "%d:%d\n", directive_count + 0, exact_count + 0
            }
        ' "$1"
    )" = "1:1" ]
}
service_limit_core_contract "$SERVICE_UNIT" ||
    fail "service does not have one exact active LimitCORE=0 directive"
_commented_core_unit="${TEST_ROOT}/commented-core.service"
sed 's/^LimitCORE=0$/# LimitCORE=0/' \
    "$SERVICE_UNIT" >"$_commented_core_unit"
if service_limit_core_contract "$_commented_core_unit"; then
    fail "commented LimitCORE text satisfied the active directive contract"
fi
_misplaced_core_unit="${TEST_ROOT}/misplaced-core.service"
awk '
    $0 == "[Unit]" {
        print
        print "LimitCORE=0"
        next
    }
    $0 == "LimitCORE=0" {
        next
    }
    {
        print
    }
' "$SERVICE_UNIT" >"$_misplaced_core_unit"
if service_limit_core_contract "$_misplaced_core_unit"; then
    fail "LimitCORE outside [Service] satisfied the unit contract"
fi
_conflicting_core_unit="${TEST_ROOT}/conflicting-core.service"
awk '
    {
        print
        if ($0 == "LimitCORE=0") {
            print "LimitCORE=infinity"
        }
    }
' "$SERVICE_UNIT" >"$_conflicting_core_unit"
if service_limit_core_contract "$_conflicting_core_unit"; then
    fail "conflicting LimitCORE directives satisfied the unit contract"
fi
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

_unit_start_timeout="$(
    sed -n 's/^TimeoutStartSec=\([0-9][0-9]*\)s$/\1/p' "$SERVICE_UNIT"
)"
case "$_unit_start_timeout" in
    ""|*[!0-9]*) fail "service TimeoutStartSec is not a bounded second value" ;;
esac
grep -Fq \
    'STATUS_TIMEOUT="$(bounded_positive_or "$STATUS_TIMEOUT" 5 5)"' \
    "$WATCHDOG" || fail "LocalAPI timeout is not capped by the unit budget"
grep -Fq \
    'RESTART_TIMEOUT="$(bounded_positive_or "$RESTART_TIMEOUT" 20 20)"' \
    "$WATCHDOG" || fail "restart timeout is not capped by the unit budget"
grep -Fq \
    'SUPERVISOR_TIMEOUT="$(bounded_positive_or "$SUPERVISOR_TIMEOUT" 3 3)"' \
    "$WATCHDOG" || fail "systemd query timeout is not capped by the unit budget"
_timeout_kill_grace=2
_supervisor_query_count=3
_eligible_recovery_command_budget=$((
    _supervisor_query_count * (3 + _timeout_kill_grace) +
    (5 + _timeout_kill_grace) +
    (20 + _timeout_kill_grace)
))
_unit_completion_margin=5
[ $((_eligible_recovery_command_budget + _unit_completion_margin)) \
    -le "$_unit_start_timeout" ] ||
    fail "watchdog command deadlines exceed systemd TimeoutStartSec"
pass "systemd deadline includes every recovery command plus completion margin"

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
grep -Fq "/bin/sh -c 'exec 9>&-; exec \"\$@\"'" "$WATCHDOG" ||
    fail "restart child does not close fd9 behind a bounded lock guardian"
grep -Fq '>/dev/null 2>&1 9>&- || true' "$WATCHDOG" ||
    fail "logger child can inherit the singleton lock"
pass "observation children close fd9 and the restart timeout is its bounded guardian"

printf '1..%s\n' "$PASS_COUNT"
