#!/bin/sh

set -eu
umask 077

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
MOCK_PROCESS_BINARY="${MOCK_BIN}/tailscaled-process"
: > "$MOCK_PROCESS_BINARY"
chmod 0755 "$MOCK_PROCESS_BINARY"

# A real deadline wrapper for the hanging fixture. Keep enough headroom for
# valid short-lived shell commands when the test suites run concurrently; the
# hanging child still really blocks and must be terminated and reaped.
cat > "${MOCK_BIN}/timeout" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-s" ] && [ "${2:-}" = "TERM" ] || exit 90
[ "${3:-}" = "-k" ] && [ "${4:-}" = "2" ] || exit 91
shift 4
deadline="${1:-1}"
shift
flag="${MOCK_RUNTIME_DIR}/timeout.$$"
MOCK_TIMEOUT_ACTIVE=1 "$@" &
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
) 7>&- &
timer=$!
wait "$child" 2>/dev/null
rc=$?
kill "$timer" 2>/dev/null || true
wait "$timer" 2>/dev/null || true
if [ -f "$flag" ]; then
    rm -f "$flag"
    if [ -n "${MOCK_UPTIME_FILE:-}" ] &&
       [ -f "$MOCK_UPTIME_FILE" ]; then
        current="$(cut -d. -f1 "$MOCK_UPTIME_FILE" 2>/dev/null)"
        case "$current:$deadline" in
            *[!0-9:]*|:*) ;;
            *) printf '%s.00 0.00\n' "$((current + deadline))" \
                >"$MOCK_UPTIME_FILE" ;;
        esac
    fi
    if [ "${MOCK_TAILSCALE_MODE:-}" = "hang_143" ]; then
        exit 143
    fi
    exit 124
fi
exit "$rc"
EOF

cat > "${MOCK_BIN}/jsonfilter" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-i" ] && file="${2:-}" || exit 2
if [ "${MOCK_TIMEOUT_ACTIVE:-0}" = "1" ]; then
    printf '%s\n' bounded >> "${MOCK_RUNTIME_DIR}/jsonfilter-bounds"
else
    printf '%s\n' unbounded >> "${MOCK_RUNTIME_DIR}/jsonfilter-bounds"
fi
{
    printf 'projection'
    printf ' <%s>' "$@"
    printf '\n'
} >> "${MOCK_RUNTIME_DIR}/jsonfilter-argv"
if "$MOCK_PYTHON3" -c 'import os; os.fstat(9)' 2>/dev/null; then
    printf '%s\n' open >> "${MOCK_RUNTIME_DIR}/jsonfilter-fd9"
else
    printf '%s\n' closed >> "${MOCK_RUNTIME_DIR}/jsonfilter-fd9"
fi
if [ "${MOCK_JSONFILTER_MODE:-normal}" = "hang" ]; then
    printf '%s\n' "$$" > "${MOCK_RUNTIME_DIR}/jsonfilter-hang-pid"
    fifo="${MOCK_RUNTIME_DIR}/jsonfilter-fifo"
    [ -p "$fifo" ] || mkfifo "$fifo"
    read -r ignored < "$fifo"
fi
if [ "${MOCK_JSONFILTER_MODE:-normal}" = "flood" ]; then
    awk 'BEGIN { for (i = 0; i < 70000; i++) printf "x" }'
    exit 0
fi
"$MOCK_PYTHON3" - "$@" <<'PY'
import json
import sys


MISSING = object()


def value_type(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "double"
    raise ValueError("unsupported JSON type")


def resolve(document, expression):
    if expression == "@":
        return document
    paths = {
        "@.BackendState": ("BackendState",),
        "@.Self.TailscaleIPs": ("Self", "TailscaleIPs"),
        "@.Self.KeyExpiry": ("Self", "KeyExpiry"),
        "@.Self.Online": ("Self", "Online"),
        "@.TUN": ("TUN",),
        "@.Health": ("Health",),
    }
    if expression in ("@.Self.TailscaleIPs[*]", "@.Health[*]"):
        base = expression[:-3]
        container = resolve(document, base)
        if not isinstance(container, list) or not container:
            return MISSING
        return container
    path = paths.get(expression)
    if path is None:
        raise ValueError("unknown expression")
    value = document
    for component in path:
        if not isinstance(value, dict) or component not in value:
            return MISSING
        value = value[component]
    return value


def normalize_fixtures(document):
    if document.get("BackendState") == "backend-newline-fixture":
        document["BackendState"] = "Running\n"
    self_value = document.get("Self")
    if isinstance(self_value, dict):
        ips = self_value.get("TailscaleIPs")
        if ips == ["ip-newline-fixture"]:
            self_value["TailscaleIPs"] = ["100.104.78.42\n"]
        elif ips == ["max-type-header"]:
            self_value["TailscaleIPs"] = [False] * 100
        elif ips == ["pathological-type-header"]:
            self_value["TailscaleIPs"] = [False] * 300
        if ips in (["max-type-header"], ["pathological-type-header"]):
            self_value["KeyExpiry"] = False
    health = document.get("Health")
    if health == ["oversized-string"]:
        document["Health"] = ["x" * 513]
    elif health == ["too-many"]:
        document["Health"] = ["redacted-warning"] * 101
    elif health == ["max-type-header"]:
        document["Health"] = [False] * 100
    elif health == ["pathological-type-header"]:
        document["Health"] = [False] * 300
    elif health == ["near-limit-null-header"]:
        document["Health"] = [None] * 10000


def emit_record(value):
    if isinstance(value, bool):
        sys.stdout.write(("true" if value else "false") + "\n")
    elif isinstance(value, (dict, list)):
        sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    else:
        sys.stdout.write(str(value) + "\n")


def emit_value(value, wildcard):
    if value is None:
        return False
    if wildcard:
        emitted = False
        for item in value:
            if item is None:
                continue
            emit_record(item)
            emitted = True
        return emitted
    emit_record(value)
    return True


args = sys.argv[1:]
if len(args) < 4 or args[0] != "-i":
    raise SystemExit(2)
status_path = args[1]
operations = args[2:]
if len(operations) % 2:
    raise SystemExit(2)
try:
    with open(status_path, "r", encoding="utf-8") as status_file:
        document = json.load(status_file)
    normalize_fixtures(document)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)

aggregate_rc = 0
for index in range(0, len(operations), 2):
    operation = operations[index]
    expression = operations[index + 1]
    if operation not in ("-t", "-e"):
        raise SystemExit(2)
    name = None
    if operation == "-t" and "=" in expression:
        name, expression = expression.split("=", 1)
        if not name or not name.replace("_", "").isalnum():
            raise SystemExit(2)
    try:
        value = resolve(document, expression)
    except ValueError:
        raise SystemExit(2)
    if value is MISSING:
        aggregate_rc = 1
        continue
    if operation == "-t":
        if isinstance(value, list) and expression.endswith("[*]"):
            rendered = r"\ ".join(value_type(item) for item in value)
        else:
            rendered = value_type(value)
        if name is not None:
            sys.stdout.write(f"export {name}={rendered}; ")
        else:
            sys.stdout.write(rendered + "\n")
    elif not emit_value(value, expression.endswith("[*]")):
        aggregate_rc = 1
raise SystemExit(aggregate_rc)
PY
parser_rc=$?
if [ "${MOCK_JSONFILTER_MODE:-normal}" = "raw_cleanup_fail" ]; then
    rm -f "$file"
    mkdir "$file"
fi
exit "$parser_rc"
EOF

cat > "${MOCK_BIN}/tailscale" <<'EOF'
#!/bin/sh
swap_process_generation() {
    for old_process_dir in "${MOCK_PROC_ROOT}"/[0-9]*; do
        [ -d "$old_process_dir" ] || continue
        rm -f "$old_process_dir/stat" "$old_process_dir/exe"
        rmdir "$old_process_dir"
    done
    mkdir -p "${MOCK_PROC_ROOT}/4243"
    printf '%s (tailscaled) S 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0 0 0\n' \
        4243 20000 > "${MOCK_PROC_ROOT}/4243/stat"
    ln -s "${MOCK_PROCESS_BINARY}" "${MOCK_PROC_ROOT}/4243/exe"
}

if [ "${2:-}" = "ping" ]; then
    printf '%s\n' ping >> "${MOCK_PEER_PINGS_FILE}"
    case "${1:-}" in --socket=*) ;; *) exit 90 ;; esac
    [ "${3:-}" = "--tsmp" ] || exit 91
    [ "${4:-}" = "--c=1" ] || exit 92
    [ "${5:-}" = "--timeout=3s" ] || exit 93
    [ "${6:-}" = "--until-direct=false" ] || exit 94
    [ "${7:-}" = "--" ] || exit 95
    [ -n "${8:-}" ] && [ "$#" -eq 8 ] || exit 96
    case "${MOCK_PEER_MODE:-reachable}" in
        reachable) exit 0 ;;
        reachable_swap_peer_contract)
            printf '%s\n' '100.70.186.128' \
                >"${MOCK_CRITICAL_PEER_FILE}.replacement"
            chmod 0600 "${MOCK_CRITICAL_PEER_FILE}.replacement"
            mv -f "${MOCK_CRITICAL_PEER_FILE}.replacement" \
                "$MOCK_CRITICAL_PEER_FILE"
            exit 0
            ;;
        reachable_swap_generation)
            swap_process_generation
            exit 0
            ;;
        unreachable|acl_denied|expired) exit 1 ;;
        hang)
            fifo="${MOCK_RUNTIME_DIR}/peer-fifo"
            [ -p "$fifo" ] || mkfifo "$fifo"
            read -r ignored < "$fifo"
            ;;
    esac
    exit 1
fi

case "${MOCK_TAILSCALE_MODE:-running}" in
    running)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true,"KeyExpiry":"0001-01-01T00:00:00Z"},"Health":[],"AuthURL":"sentinel-auth-url"}'
        ;;
    running_swap_generation)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        swap_process_generation
        ;;
    running_backend_space)
        printf '%s\n' '{"BackendState":"Runn ing","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_backend_metachar)
        printf '%s\n' '{"BackendState":"Runn$ing","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_backend_newline)
        printf '%s\n' '{"BackendState":"backend-newline-fixture","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_ip_leading_space)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":[" 100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_ip_trailing_space)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42 "],"Online":true},"Health":[]}'
        ;;
    running_ip_newline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["ip-newline-fixture"],"Online":true},"Health":[]}'
        ;;
    running_warning)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true,"InEngine":true,"KeyExpiry":"0001-01-01T00:00:00Z"},"Health":["secret warning text"]}'
        ;;
    running_health_object_literal)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":["object"]}'
        ;;
    running_health_newline)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":["warning\nnext"]}'
        ;;
    running_nested_health_array)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[[]]}'
        ;;
    running_nested_ip_array)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":[[]],"Online":true},"Health":[]}'
        ;;
    running_raw_nul_unterminated)
        printf '%s' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42\u00008.8.8.8"],"Online":true},"Health":[]}'
        ;;
    running_raw_whitespace_bomb)
        printf '%s' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]'
        awk 'BEGIN { for (i = 0; i < 60000; i++) printf "\n" }'
        printf '%s\n' '}'
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
    running_string_tun)
        printf '%s\n' '{"BackendState":"Running","TUN":"true","Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    running_string_online)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":"true"},"Health":[]}'
        ;;
    running_scalar_ips)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":"100.104.78.42","Online":true},"Health":[]}'
        ;;
    running_nonstring_ip)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":[100],"Online":true},"Health":[]}'
        ;;
    running_string_health)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":"[]"}'
        ;;
    running_null_health_element)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[null]}'
        ;;
    running_number_health_element)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[7]}'
        ;;
    running_object_health_element)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[{}]}'
        ;;
    running_oversized_health_string)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":["oversized-string"]}'
        ;;
    running_too_many_health_elements)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":["too-many"]}'
        ;;
    running_max_type_header)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["max-type-header"],"Online":true},"Health":["max-type-header"]}'
        ;;
    running_pathological_type_header)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["pathological-type-header"],"Online":true},"Health":["pathological-type-header"]}'
        ;;
    running_near_limit_null_header)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":["near-limit-null-header"]}'
        ;;
    running_boolean_backend)
        printf '%s\n' '{"BackendState":true,"TUN":true,"Self":{"TailscaleIPs":["100.104.78.42"],"Online":true},"Health":[]}'
        ;;
    live_1_98_9)
        printf '%s\n' '{"Version":"1.98.9","BackendState":"Running","TUN":true,"Self":{"HostName":"omr-vps-use1","TailscaleIPs":["100.70.186.127","fd7a:115c:a1e0::1234"],"Online":true,"InEngine":false,"KeyExpiry":"0001-01-01T00:00:00Z"},"Health":[]}'
        ;;
    running_ipv6_compressed)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["fd7a:115c:a1e0::1234"],"Online":true},"Health":[]}'
        ;;
    running_ipv6_full)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["FD7A:115C:A1E0:ABCD:0:1:2:3"],"Online":true},"Health":[]}'
        ;;
    running_bad_ip)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["8.8.8.8"],"Online":true,"InEngine":true},"Health":[]}'
        ;;
    running_bad_ipv6_groups)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["fd7a:115c:a1e0::1:2:3:4:5"],"Online":true},"Health":[]}'
        ;;
    running_bad_ipv6_zone)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["fd7a:115c:a1e0::1%tailscale0"],"Online":true},"Health":[]}'
        ;;
    running_bad_ipv6_dotted)
        printf '%s\n' '{"BackendState":"Running","TUN":true,"Self":{"TailscaleIPs":["fd7a:115c:a1e0::192.0.2.1"],"Online":true},"Health":[]}'
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
    hang|hang_143)
        fifo="${MOCK_RUNTIME_DIR}/status-fifo"
        [ -p "$fifo" ] || mkfifo "$fifo"
        read -r ignored < "$fifo"
        ;;
    hang_drift_init)
        printf '%s\n' '# status-window drift' >> "${MOCK_INIT_FILE}"
        chmod 0755 "${MOCK_INIT_FILE}"
        fifo="${MOCK_RUNTIME_DIR}/status-fifo"
        [ -p "$fifo" ] || mkfifo "$fifo"
        read -r ignored < "$fifo"
        ;;
    early_137)
        exit 137
        ;;
    early_143)
        exit 143
        ;;
    early_137_rollover)
        printf '%s\n' '101.00 0.00' > "${MOCK_UPTIME_FILE}"
        exit 137
        ;;
    early_143_rollover)
        printf '%s\n' '101.00 0.00' > "${MOCK_UPTIME_FILE}"
        exit 143
        ;;
    oversized_output)
        dd if=/dev/zero bs=1024 count=256 2>/dev/null |
            tr '\000' x
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
        case "${MOCK_SERVICE_ENABLED:-1}" in
            1) exit 0 ;;
            0) exit 1 ;;
            error) exit 2 ;;
            hang)
                fifo="${MOCK_RUNTIME_DIR}/enabled-fifo"
                [ -p "$fifo" ] || mkfifo "$fifo"
                read -r ignored < "$fifo"
                ;;
        esac
        exit 2
        ;;
    running)
        _mock_running="${MOCK_SERVICE_RUNNING:-1}"
        if [ -n "${MOCK_RUNNING_SEQUENCE_FILE:-}" ] &&
           [ -f "$MOCK_RUNNING_SEQUENCE_FILE" ]; then
            _mock_running="$(sed -n '1p' "$MOCK_RUNNING_SEQUENCE_FILE")"
            sed '1d' "$MOCK_RUNNING_SEQUENCE_FILE" \
                > "${MOCK_RUNNING_SEQUENCE_FILE}.next"
            mv -f "${MOCK_RUNNING_SEQUENCE_FILE}.next" \
                "$MOCK_RUNNING_SEQUENCE_FILE"
        fi
        case "$_mock_running" in
            1) exit 0 ;;
            0) exit 1 ;;
            error) exit 2 ;;
            hang)
                fifo="${MOCK_RUNTIME_DIR}/running-fifo"
                [ -p "$fifo" ] || mkfifo "$fifo"
                read -r ignored < "$fifo"
                ;;
        esac
        exit 2
        ;;
    restart)
        if "$MOCK_PYTHON3" -c 'import os; os.fstat(7)' 2>/dev/null; then
            printf '%s\n' open >> "${MOCK_RUNTIME_DIR}/restart-fd7"
        else
            printf '%s\n' closed >> "${MOCK_RUNTIME_DIR}/restart-fd7"
        fi
        if [ "${MOCK_REQUIRE_DURABLE_LATCH:-0}" = "1"; then
            grep -qx 'recovery_attempted=1' \
                "${MOCK_STATE_DIR}/tailscale-watchdog.memory" || exit 98
        fi
        printf '%s\n' restart >> "${MOCK_ACTIONS_FILE}"
        if [ "${MOCK_RESTART_MODE:-complete}" = "hang" ]; then
            printf '%s\n' "$$" > "${MOCK_RUNTIME_DIR}/restart-hang-pid"
            fifo="${MOCK_RUNTIME_DIR}/restart-fifo"
            [ -p "$fifo" ] || mkfifo "$fifo"
            read -r ignored < "$fifo"
        fi
        exit "${MOCK_RESTART_RC:-0}"
        ;;
    *)
        exit 2
        ;;
esac
EOF

cat > "${MOCK_BIN}/logger" <<'EOF'
#!/bin/sh
if [ "${MOCK_TIMEOUT_ACTIVE:-0}" = "1" ]; then
    printf '%s\n' bounded >> "${MOCK_RUNTIME_DIR}/logger-bounds"
else
    printf '%s\n' unbounded >> "${MOCK_RUNTIME_DIR}/logger-bounds"
fi
if "$MOCK_PYTHON3" -c 'import os; os.fstat(9)' 2>/dev/null; then
    printf '%s\n' open >> "${MOCK_RUNTIME_DIR}/logger-fd9"
else
    printf '%s\n' closed >> "${MOCK_RUNTIME_DIR}/logger-fd9"
fi
if [ "${MOCK_LOGGER_MODE:-normal}" = "hang" ]; then
    printf '%s\n' "$$" > "${MOCK_RUNTIME_DIR}/logger-hang-pid"
    fifo="${MOCK_RUNTIME_DIR}/logger-fifo"
    [ -p "$fifo" ] || mkfifo "$fifo"
    read -r ignored < "$fifo"
fi
printf '%s\n' "$*" >> "${MOCK_LOG_FILE}"
EOF

cat > "${MOCK_BIN}/flock" <<EOF
#!${PYTHON3}
import fcntl
import os
import pathlib
import sys
import time

if len(sys.argv) != 3 or sys.argv[1] != "-n" or sys.argv[2] not in {"7", "9"}:
    raise SystemExit(64)
descriptor = int(sys.argv[2])

memory_path_text = os.environ.get("MOCK_MEMORY_FILE", "")
memory_path = pathlib.Path(memory_path_text) if memory_path_text else None
latched = bool(
    memory_path
    and memory_path.is_file()
    and "recovery_attempted=1\n" in memory_path.read_text()
)
gate_path_text = os.environ.get("MOCK_FLOCK_GATE_AFTER_LATCH", "")
if descriptor == 7 and latched and gate_path_text:
    gate_path = pathlib.Path(gate_path_text)
    used_path = pathlib.Path(gate_path_text + ".used")
    if not used_path.exists():
        used_path.touch()
        pathlib.Path(gate_path_text + ".ready").touch()
        release_path = pathlib.Path(gate_path_text + ".release")
        for _ in range(1000):
            if release_path.exists():
                break
            time.sleep(0.01)
        else:
            raise SystemExit(124)

try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
except OSError:
    raise SystemExit(70)

swap_path_text = os.environ.get("MOCK_FLOCK_REPLACE_AFTER_LATCH_PATH", "")
if descriptor == 7 and swap_path_text and latched:
    swap_path = pathlib.Path(swap_path_text)
    swapped_marker = pathlib.Path(swap_path_text + ".swapped")
    if not swapped_marker.exists():
        orphan_path = pathlib.Path(swap_path_text + ".orphaned")
        swap_path.rename(orphan_path)
        replacement_descriptor = os.open(
            swap_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
        )
        os.close(replacement_descriptor)
        swapped_marker.touch()
EOF

cat > "${MOCK_BIN}/sha256sum" <<EOF
#!${PYTHON3}
import hashlib
import os
import pathlib
import sys
import time

if len(sys.argv) != 2:
    raise SystemExit(64)


def install_lock_descriptor_state():
    lock_path_text = os.environ.get("WATCHDOG_INSTALL_LOCK_FILE", "")
    if not lock_path_text:
        return "closed"
    try:
        lock_stat = os.stat(lock_path_text)
    except OSError:
        return "closed"
    matching = []
    for descriptor_number in range(3, 64):
        try:
            descriptor_stat = os.fstat(descriptor_number)
        except OSError:
            continue
        if (
            descriptor_stat.st_dev == lock_stat.st_dev
            and descriptor_stat.st_ino == lock_stat.st_ino
        ):
            matching.append(str(descriptor_number))
    if not matching:
        return "closed"
    return "open:" + ",".join(matching)


gate = os.environ.get("MOCK_FINAL_PROOF_GATE", "")
second_integrity_gate = os.environ.get(
    "MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH", ""
)
memory = pathlib.Path(os.environ.get(
    "MOCK_MEMORY_FILE", "/nonexistent-watchdog-memory"
))
latched = bool(
    memory.is_file() and "recovery_attempted=1\n" in memory.read_text()
)
if gate and latched:
    claim = pathlib.Path(f"{gate}.claimed")
    try:
        descriptor = os.open(claim, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        descriptor = None
    if descriptor is not None:
        os.close(descriptor)
        pathlib.Path(f"{gate}.fd7").write_text(
            install_lock_descriptor_state() + "\n"
        )
        pathlib.Path(f"{gate}.ready").touch()
        release = pathlib.Path(f"{gate}.release")
        for _ in range(500):
            if release.exists():
                break
            time.sleep(0.01)
        else:
            raise SystemExit(124)
if second_integrity_gate and latched:
    counter_path = pathlib.Path(f"{second_integrity_gate}.count")
    try:
        counter = int(counter_path.read_text())
    except (FileNotFoundError, ValueError):
        counter = 0
    counter += 1
    counter_path.write_text(f"{counter}\n")
    if counter == 4:
        pathlib.Path(f"{second_integrity_gate}.fd7").write_text(
            install_lock_descriptor_state() + "\n"
        )
        pathlib.Path(f"{second_integrity_gate}.ready").touch()
        release = pathlib.Path(f"{second_integrity_gate}.release")
        for _ in range(500):
            if release.exists():
                break
            time.sleep(0.01)
        else:
            raise SystemExit(124)
path = pathlib.Path(sys.argv[1])
with path.open("rb") as source:
    digest = hashlib.sha256(source.read()).hexdigest()
print(f"{digest}  {path}")
EOF

cat > "${MOCK_BIN}/stat" <<EOF
#!${PYTHON3}
import os
import stat
import sys

arguments = sys.argv[1:]
follow_links = False
if arguments and arguments[0] == "-L":
    follow_links = True
    arguments = arguments[1:]
if len(arguments) != 3 or arguments[0] != "-c":
    raise SystemExit(64)
fmt = arguments[1]
path = arguments[2]
if follow_links and path.startswith("/dev/fd/"):
    value = os.fstat(int(path.rsplit("/", 1)[1]))
elif follow_links:
    value = os.stat(path)
else:
    value = os.lstat(path)
mode = f"{stat.S_IMODE(value.st_mode):o}"
if fmt == "%u:%g:%a":
    print(f"{value.st_uid}:{value.st_gid}:{mode}")
elif fmt == "%u:%g:%a:%d:%i:%s":
    print(
        f"{value.st_uid}:{value.st_gid}:{mode}:"
        f"{value.st_dev}:{value.st_ino}:{value.st_size}"
    )
elif fmt == "%u:%g:%a:%h:%d:%i:%s":
    print(
        f"{value.st_uid}:{value.st_gid}:{mode}:{value.st_nlink}:"
        f"{value.st_dev}:{value.st_ino}:{value.st_size}"
    )
else:
    raise SystemExit(64)
EOF

chmod 0755 "${MOCK_BIN}/timeout" "${MOCK_BIN}/jsonfilter" \
    "${MOCK_BIN}/tailscale" "${MOCK_BIN}/tailscale-init" \
    "${MOCK_BIN}/logger" "${MOCK_BIN}/flock" \
    "${MOCK_BIN}/sha256sum" "${MOCK_BIN}/stat"

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

write_process_generation() {
    _generation_pid="$1"
    _generation_start="$2"
    _generation_state="${3:-S}"
    _generation_binary="${4:-$MOCK_PROCESS_BINARY}"
    for _old_process_dir in "$PROC_ROOT"/[0-9]*; do
        [ -d "$_old_process_dir" ] || continue
        rm -f "$_old_process_dir/stat" "$_old_process_dir/exe"
        rmdir "$_old_process_dir"
    done
    mkdir -p "${PROC_ROOT}/${_generation_pid}"
    printf '%s (tailscaled) %s 1 1 1 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 %s 0 0 0\n' \
        "$_generation_pid" "$_generation_state" "$_generation_start" \
        > "${PROC_ROOT}/${_generation_pid}/stat"
    ln -s "$_generation_binary" "${PROC_ROOT}/${_generation_pid}/exe"
}

remove_process_generation() {
    for _old_process_dir in "$PROC_ROOT"/[0-9]*; do
        [ -d "$_old_process_dir" ] || continue
        rm -f "$_old_process_dir/stat" "$_old_process_dir/exe"
        rmdir "$_old_process_dir"
    done
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
    PEER_PINGS_FILE="${CASE_DIR}/peer-pings"
    LOG_FILE="${CASE_DIR}/log"
    PEER_FILE="${CASE_DIR}/critical-peer"
    PROC_ROOT="${CASE_DIR}/proc"
    UPTIME_FILE="${CASE_DIR}/uptime"
    ROUTER_MANIFEST="${CASE_DIR}/router-files.sha256"
    ROUTER_MANIFEST_DIGEST="${CASE_DIR}/router-files.sha256.sha256"
    INSTALL_LOCK_PATH="${STATE_DIR}/router-install.lock"
    mkdir -p "$STATE_DIR" "$RUNTIME_DIR" "$PROC_ROOT"
    SOCKET_FILE="$SHORT_SOCKET"
    rm -f "$SOCKET_FILE"
    create_unix_socket "$SOCKET_FILE"
    write_process_generation 4242 10000
    : > "$ACTIONS_FILE"
    : > "$PEER_PINGS_FILE"
    : > "$LOG_FILE"
    printf '100.00 0.00\n' >"$UPTIME_FILE"
    _init_sha="$(
        "${MOCK_BIN}/sha256sum" "${MOCK_BIN}/tailscale-init" |
            awk '{print $1}'
    )"
    printf '%s  %s\n' "$_init_sha" 'router/tailscale.init' \
        > "$ROUTER_MANIFEST"
    _manifest_sha="$(
        "${MOCK_BIN}/sha256sum" "$ROUTER_MANIFEST" | awk '{print $1}'
    )"
    printf '%s\n' "$_manifest_sha" > "$ROUTER_MANIFEST_DIGEST"
    chmod 0644 "$ROUTER_MANIFEST" "$ROUTER_MANIFEST_DIGEST"
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
        MOCK_JSONFILTER_MODE="${MOCK_JSONFILTER_MODE_VALUE:-normal}" \
        MOCK_SERVICE_RUNNING="$2" \
        MOCK_PEER_MODE="${3:-reachable}" \
        MOCK_LOGGER_MODE="${MOCK_LOGGER_MODE_VALUE:-normal}" \
        MOCK_SERVICE_ENABLED="${MOCK_SERVICE_ENABLED_VALUE:-1}" \
        MOCK_RESTART_RC="${MOCK_RESTART_RC_VALUE:-0}" \
        MOCK_RESTART_MODE="${MOCK_RESTART_MODE_VALUE:-complete}" \
        MOCK_REQUIRE_DURABLE_LATCH="${MOCK_REQUIRE_DURABLE_LATCH_VALUE:-0}" \
        MOCK_FINAL_PROOF_GATE="${MOCK_FINAL_PROOF_GATE_VALUE:-}" \
        MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH="${MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE:-}" \
        MOCK_FLOCK_REPLACE_AFTER_LATCH_PATH="${MOCK_FLOCK_REPLACE_AFTER_LATCH_PATH_VALUE:-}" \
        MOCK_FLOCK_GATE_AFTER_LATCH="${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE:-}" \
        MOCK_MEMORY_FILE="${STATE_DIR}/tailscale-watchdog.memory" \
        MOCK_RUNNING_SEQUENCE_FILE="${MOCK_RUNNING_SEQUENCE_FILE_VALUE:-}" \
        MOCK_TIMEOUT_DELAY="${MOCK_TIMEOUT_DELAY_VALUE:-0.5}" \
        MOCK_ACTIONS_FILE="$ACTIONS_FILE" \
        MOCK_PEER_PINGS_FILE="$PEER_PINGS_FILE" \
        MOCK_CRITICAL_PEER_FILE="$PEER_FILE" \
        MOCK_LOG_FILE="$LOG_FILE" \
        MOCK_RUNTIME_DIR="$RUNTIME_DIR" \
        MOCK_STATE_DIR="$STATE_DIR" \
        MOCK_UPTIME_FILE="$UPTIME_FILE" \
        MOCK_INIT_FILE="${MOCK_BIN}/tailscale-init" \
        MOCK_PROC_ROOT="$PROC_ROOT" \
        MOCK_PROCESS_BINARY="$MOCK_PROCESS_BINARY" \
        MOCK_PYTHON3="$PYTHON3" \
        TAILSCALE_CLI="${MOCK_BIN}/tailscale" \
        TAILSCALE_INIT="${MOCK_BIN}/tailscale-init" \
        TAILSCALE_SOCKET="$SOCKET_FILE" \
        WATCHDOG_STATE_DIR="$STATE_DIR" \
        WATCHDOG_INSTALL_LOCK_FILE="$INSTALL_LOCK_PATH" \
        WATCHDOG_FD_ROOT="/dev/fd" \
        WATCHDOG_TIMEOUT_CMD="${WATCHDOG_TIMEOUT_OVERRIDE:-${MOCK_BIN}/timeout}" \
        WATCHDOG_JSONFILTER_CMD="${WATCHDOG_JSONFILTER_OVERRIDE:-${MOCK_BIN}/jsonfilter}" \
        WATCHDOG_LOGGER_CMD="${MOCK_BIN}/logger" \
        WATCHDOG_FLOCK_CMD="${MOCK_BIN}/flock" \
        WATCHDOG_SLEEP_CMD="${WATCHDOG_SLEEP_OVERRIDE:-/bin/sleep}" \
        WATCHDOG_CRITICAL_PEER_FILE="$PEER_FILE" \
        WATCHDOG_PROC_ROOT="$PROC_ROOT" \
        WATCHDOG_UPTIME_FILE="$UPTIME_FILE" \
        WATCHDOG_PROCESS_BINARY="$MOCK_PROCESS_BINARY" \
        WATCHDOG_ROUTER_MANIFEST="$ROUTER_MANIFEST" \
        WATCHDOG_ROUTER_MANIFEST_DIGEST="$ROUTER_MANIFEST_DIGEST" \
        WATCHDOG_EXPECTED_ROOT_UID="$EXPECTED_TEST_UID" \
        WATCHDOG_EXPECTED_ROOT_GID="$EXPECTED_TEST_GID" \
        WATCHDOG_STAT_CMD="${MOCK_BIN}/stat" \
        WATCHDOG_SHA256_CMD="${MOCK_BIN}/sha256sum" \
        WATCHDOG_CLOCK_TICKS=100 \
        WATCHDOG_STATUS_TIMEOUT=1 \
        WATCHDOG_PEER_TIMEOUT=1 \
        WATCHDOG_RESTART_TIMEOUT=1 \
        WATCHDOG_FAILURE_THRESHOLD="${WATCHDOG_THRESHOLD_VALUE:-3}" \
        WATCHDOG_VALID_STREAK_REQUIRED="${WATCHDOG_STREAK_VALUE:-5}" \
        WATCHDOG_BOOT_GRACE="${WATCHDOG_BOOT_GRACE_VALUE:-0}" \
        WATCHDOG_CONTINUITY_MAX_GAP=30 \
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

assert_not_json() {
    _fragment="$1"
    if grep -q "$_fragment" "${STATE_DIR}/tailscale-watchdog.json"; then
        fail "${CASE_NAME}: unexpected JSON fragment ${_fragment}"
    fi
}

assert_no_actions() {
    [ ! -s "$ACTIONS_FILE" ] || fail "${CASE_NAME}: unexpected recovery action"
}

assert_no_raw_status_artifacts() {
    if find "$STATE_DIR" -maxdepth 1 \
        \( -name 'tailscale-status.*' \
        -o -name 'tailscale-status-error.*' \
        -o -name 'tailscale-status-projection.*' \) \
        -print -quit | grep -q .; then
        fail "${CASE_NAME}: raw status or projection artifact survived observation"
    fi
}

action_count() {
    wc -l < "$ACTIONS_FILE" | tr -d ' '
}

write_maintenance_marker() {
    printf '%s\n' "$1" > "${STATE_DIR}/tailscale-maintenance"
    chmod 0600 "${STATE_DIR}/tailscale-maintenance"
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

wait_for_action_count() {
    _expected="$1"
    _attempt=0
    while [ "$_attempt" -lt 100 ]; do
        [ "$(action_count)" -ge "$_expected" ] && return 0
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    fail "${CASE_NAME}: timed out waiting for ${_expected} recovery action(s)"
}

wait_for_pid_exit() {
    _wait_pid="$1"
    _wait_label="$2"
    _attempt=0
    while [ "$_attempt" -lt 250 ]; do
        if ! kill -0 "$_wait_pid" 2>/dev/null; then
            return 0
        fi
        _wait_state="$(
            ps -o stat= -p "$_wait_pid" 2>/dev/null | tr -d ' \r\n'
        )"
        case "$_wait_state" in
            ""|Z*) return 0 ;;
        esac
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    fail "${CASE_NAME}: timed out waiting for ${_wait_label} PID ${_wait_pid}"
}

lock_inode() {
    stat -f '%i' "$1" 2>/dev/null ||
        stat -c '%i' "$1" 2>/dev/null
}

start_install_lock_holder() {
    _holder_path="$1"
    _holder_ready="$2"
    _holder_release="$3"
    "$PYTHON3" - "$_holder_path" "$_holder_ready" "$_holder_release" <<'PY' &
import fcntl
import pathlib
import sys
import time

lock_path = pathlib.Path(sys.argv[1])
ready_path = pathlib.Path(sys.argv[2])
release_path = pathlib.Path(sys.argv[3])
with lock_path.open("r+b") as lock_file:
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    ready_path.touch()
    for _ in range(1000):
        if release_path.exists():
            break
        time.sleep(0.01)
    else:
        raise SystemExit(124)
PY
    INSTALL_LOCK_HOLDER_PID=$!
    wait_for_path "$_holder_ready"
}

stop_install_lock_holder() {
    _holder_release="$1"
    : > "$_holder_release"
    wait "$INSTALL_LOCK_HOLDER_PID"
    INSTALL_LOCK_HOLDER_PID=""
}

install_lock_is_available() {
    (
        exec 7<>"$INSTALL_LOCK_PATH"
        "${MOCK_BIN}/flock" -n 7
    )
}

wait_for_install_lock_available() {
    _attempt=0
    while [ "$_attempt" -lt 250 ]; do
        if install_lock_is_available; then
            return 0
        fi
        sleep 0.02
        _attempt=$((_attempt + 1))
    done
    fail "${CASE_NAME}: shared install lock remained held"
}

sh -n "$WATCHDOG"
dash -n "$WATCHDOG"
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n "$WATCHDOG"
fi
pass "watchdog parses under POSIX sh and dash"
grep -qx 'RECOVERY_MAX_ATTEMPTS=3' "$WATCHDOG" &&
    grep -qx 'RECOVERY_RETRY_SHORT=60' "$WATCHDOG" &&
    grep -qx 'RECOVERY_RETRY_LONG=300' "$WATCHDOG" ||
    fail "bounded recovery authority is not the fixed 3/60/300 contract"
pass "bounded recovery authority is fixed at three attempts with 60s and 300s cooldowns"

new_case running
run_once running 1 200 1000
assert_status running
assert_json '"schema":3'
assert_json '"connected":true'
assert_json '"healthy":true'
assert_json '"control_online":true'
assert_json '"process_generation":"4242:10000"'
assert_json '"process_uptime_seconds":100'
assert_json '"connectivity_uptime_seconds":0'
assert_json '"peer_configured":false'
assert_json '"peer_state":"not_configured"'
assert_json '"peer_reachable":null'
assert_no_actions
pass "an absent critical-peer file leaves peer proof optional"

new_case live_1_98_9_inengine_false
run_once live_1_98_9 1 200 1000
assert_status running
assert_json '"connected":true'
assert_json '"healthy":true'
assert_json '"tailscale_ip":"100.70.186.127"'
assert_not_json '"in_engine":'
assert_no_actions
pass "Tailscale 1.98.9 Self.InEngine=false is healthy when delivery succeeds"

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
for mode in running_no_tun running_bad_ip running_bad_ipv6_groups \
    running_bad_ipv6_zone running_bad_ipv6_dotted
do
    run_once "$mode" 1 200 1000
    assert_status running_degraded
    assert_json '"connected":false'
    assert_json '"healthy":false'
done
for mode in running_ipv6_compressed running_ipv6_full; do
    run_once "$mode" 1 200 1000
    assert_status running
    assert_json '"connected":true'
done
run_once running_missing_tun 1 215 1015
assert_status running_degraded
assert_json '"connected":null'
assert_json '"healthy":false'
run_once running_missing_engine 1 230 1030
assert_status running
assert_json '"connected":true'
assert_json '"healthy":true'
assert_not_json '"in_engine":'
assert_no_actions
pass "TUN and address prerequisites fail closed while Self.InEngine is ignored"

new_case typed_status_schema
run_once running_string_tun 1 200 1000
assert_status running_degraded
assert_json '"reason":"tun_state_unknown"'
assert_json '"connected":null'
assert_json '"healthy":false'
run_once running_string_online 1 215 1015
assert_status running_degraded
assert_json '"reason":"control_state_unknown"'
assert_json '"connected":true'
assert_json '"healthy":false'
for mode in running_scalar_ips running_nonstring_ip; do
    run_once "$mode" 1 230 1030
    assert_status running_degraded
    assert_json '"reason":"tailnet_ip_missing"'
    assert_json '"connected":false'
    assert_json '"healthy":false'
done
run_once running_string_health 1 245 1045
assert_status running_degraded
assert_json '"reason":"health_state_unknown"'
assert_json '"connected":true'
assert_json '"healthy":false'
run_once running_boolean_backend 1 260 1060
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"connected":null'
assert_json '"healthy":false'
assert_no_actions
pass "JSON scalar types cannot be coerced into healthy delivery evidence"

new_case byte_exact_delivery_fields
for mode in \
    running_backend_space \
    running_backend_metachar \
    running_backend_newline
do
    run_once "$mode" 1 200 1000
    assert_status watchdog_error
    assert_json '"reason":"invalid_status_json"'
    assert_json '"backend_state":""'
    assert_json '"healthy":false'
    assert_json '"connected":null'
done
for mode in \
    running_ip_leading_space \
    running_ip_trailing_space
do
    run_once "$mode" 1 215 1015
    assert_status running_degraded
    assert_json '"reason":"tailnet_ip_missing"'
    assert_json '"tailscale_ip":""'
    assert_json '"healthy":false'
    assert_json '"connected":false'
done
run_once running_ip_newline 1 230 1030
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"backend_state":""'
assert_json '"tailscale_ip":""'
assert_json '"connected":null'
assert_no_actions
pass "recognized states and tailnet addresses are validated byte-exactly before publication"

new_case exact_health_schema
for mode in \
    running_null_health_element \
    running_number_health_element \
    running_object_health_element \
    running_oversized_health_string \
    running_too_many_health_elements
do
    run_once "$mode" 1 200 1000
    assert_status running_degraded
    assert_json '"reason":"health_state_unknown"'
    assert_json '"connected":true'
    assert_json '"healthy":false'
done
assert_no_actions
pass "Health requires at most 100 bounded string elements"

new_case bounded_type_header
run_once running_max_type_header 1 200 1000
assert_status running_degraded
assert_json '"reason":"tailnet_ip_missing"'
assert_json '"connected":false'
assert_json '"healthy":false'
run_once running_pathological_type_header 1 215 1015
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"backend_state":""'
assert_json '"connected":null'
assert_json '"recoverable":false'
assert_no_raw_status_artifacts
run_once running_near_limit_null_header 1 230 1030
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"backend_state":""'
assert_json '"connected":null'
assert_json '"recoverable":false'
assert_no_raw_status_artifacts
assert_no_actions
grep -qx 'PROJECTION_TYPE_HEADER_MAX_BYTES=2048' "$WATCHDOG" ||
    fail "bounded_type_header: fixed parser work bound changed"
awk '
    /if \[ "\$\{#_type_header\}" -gt "\$PROJECTION_TYPE_HEADER_MAX_BYTES" \]/ {
        cap_line = NR
    }
    /parse_projection_type_header "\$_type_header"/ {
        parse_line = NR
    }
    END {
        exit !(cap_line > 0 && parse_line > cap_line)
    }
' "$WATCHDOG" ||
    fail "bounded_type_header: work cap does not precede interpreted parsing"
[ "$(grep -Fc 'parse_projection_type_sequence "$_type_value"' "$WATCHDOG")" \
    -eq 2 ] ||
    fail "bounded_type_header: fixed member vectors are reparsed"
if grep -F 'parse_projection_type_sequence "$TYPE_' "$WATCHDOG" >/dev/null; then
    fail "bounded_type_header: cached member vectors are reparsed"
fi
pass "maximum and near-limit pathological type framing obey fixed work bounds"

new_case projection_record_framing
run_once running_raw_whitespace_bomb 1 190 990
assert_status running
assert_json '"connected":true'
assert_no_raw_status_artifacts
if rg -n '_raw_status_line|while IFS= read -r _raw' "$WATCHDOG" \
    >/dev/null 2>&1; then
    fail "projection_record_framing: raw input uses interpreted line scanning"
fi
grep -Fq "grep -Fq '\\u0000' \"\$STATUS_OUTPUT\"" "$WATCHDOG" ||
    fail "projection_record_framing: literal NUL escape scan is missing"
run_once running_health_object_literal 1 200 1000
assert_status running_degraded
assert_json '"reason":"health_warning"'
assert_json '"health_warnings":1'
assert_json '"connected":true'
run_once running_nested_health_array 1 215 1015
assert_status running_degraded
assert_json '"reason":"health_state_unknown"'
assert_json '"connected":true'
run_once running_nested_ip_array 1 230 1030
assert_status running_degraded
assert_json '"reason":"tailnet_ip_missing"'
assert_json '"tailscale_ip":""'
run_once running_health_newline 1 245 1045
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"backend_state":""'
run_once running_raw_nul_unterminated 1 260 1060
assert_status watchdog_error
assert_json '"reason":"invalid_status_json"'
assert_json '"backend_state":""'
assert_no_raw_status_artifacts
assert_no_actions
pass "projection framing distinguishes anchors, nested values, controls, and unterminated NUL input"

new_case unknown_breaks_uptime
run_once running 1 200 1000
run_once malformed 1 215 1015
assert_json '"connected":null'
run_once running 1 230 1030
assert_json '"connected_since_at":1030'
assert_json '"connectivity_uptime_seconds":0'
assert_no_actions
pass "an unobserved LocalAPI interval cannot be included in connectivity uptime"

new_case watchdog_observation_gap
run_once running 1 200 1000
run_once running 1 215 1015
assert_json '"connectivity_uptime_seconds":15'
run_once running 1 260 1060
assert_json '"connected_since_at":1060'
assert_json '"connectivity_uptime_seconds":0'
assert_no_actions
pass "connected uptime cannot cross an absent watchdog observation window"

new_case peer_contract_change
run_once running 1 200 1000
run_once running 1 215 1015
assert_json '"connectivity_uptime_seconds":15'
printf '%s\n' '100.70.186.127' > "$PEER_FILE"
run_once running 1 230 1030 reachable
assert_json '"peer_reachable":true'
assert_json '"connected_since_at":1030'
assert_json '"connectivity_uptime_seconds":0'
run_once running 1 245 1045 reachable
assert_json '"connectivity_uptime_seconds":15'
printf '%s\n' '100.70.186.128' > "$PEER_FILE"
run_once running 1 260 1060 unreachable
assert_json '"connected":false'
assert_json '"connected_since_at":0'
assert_json '"last_connected_at":0'
assert_json '"peer_last_success_at":0'
assert_no_actions
pass "critical-peer changes reset uptime and prior delivery evidence"

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
rm -f "$PROC_ROOT/4242/stat" "$PROC_ROOT/4242/exe"
rmdir "$PROC_ROOT/4242"
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"process_uptime_seconds":null'
assert_no_actions
pass "process uptime is never published without its exact PID generation"

new_case process_identity_requires_live_exact_binary
write_process_generation 4242 10000 Z
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"healthy":false'
write_process_generation 4242 10000 S "${MOCK_BIN}/tailscale"
run_once running 1 215 1015
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"healthy":false'
assert_no_actions
pass "zombies and same-name processes with the wrong executable cannot prove a generation"

new_case status_generation_join
run_once running 1 200 1000
assert_status running
run_once running_swap_generation 1 215 1015
assert_status running_degraded
assert_json '"reason":"process_restarted"'
assert_json '"healthy":false'
assert_json '"connected":null'
assert_json '"local_api_responsive":null'
assert_json '"connected_since_at":0'
assert_json '"connectivity_uptime_seconds":null'
assert_json '"process_generation":"4243:20000"'
assert_no_actions
pass "a generation swap during LocalAPI status cannot inherit connectivity or healthy evidence"

new_case final_generation_join
printf '%s\n' '100.70.186.127' > "$PEER_FILE"
run_once running 1 200 1000 reachable_swap_generation
assert_status running_degraded
assert_json '"reason":"process_restarted"'
assert_json '"healthy":false'
assert_json '"connected":null'
assert_json '"peer_state":"unknown"'
assert_json '"peer_reachable":null'
assert_json '"peer_last_success_at":0'
assert_json '"process_generation":"4243:20000"'
assert_no_actions
pass "the final pre-publication join rejects a swap during critical-peer proof"

new_case future_process_generation
write_process_generation 4242 30000
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"process_generation_unknown"'
assert_json '"process_generation":null'
assert_json '"process_uptime_seconds":null'
assert_json '"healthy":false'
assert_no_actions
pass "future process start ticks cannot become healthy evidence"

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

new_case supervisor_query_errors
for mode in error hang; do
    for ignored in 1 2 3 4; do
        run_once running "$mode" $((200 + ignored)) $((1000 + ignored))
    done
    assert_status watchdog_error
    assert_json '"reason":"service_running_query_failed"'
    assert_json '"recoverable":false'
    assert_no_actions
done
for mode in error hang; do
    MOCK_SERVICE_ENABLED_VALUE="$mode"
    run_once running 1 220 1020
    assert_status watchdog_error
    assert_json '"reason":"service_enabled_query_failed"'
    assert_json '"recoverable":false'
    assert_no_actions
done
MOCK_SERVICE_ENABLED_VALUE=1
pass "ambiguous or hung supervisor queries never prove daemon absence"

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

new_case bounded_status_projection
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
wait_for_path "${STATE_DIR}/tailscale-watchdog.json"
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
assert_status running
assert_no_raw_status_artifacts
projection_count="$(
    wc -l < "$RUNTIME_DIR/jsonfilter-argv" | tr -d ' \r\n'
)"
bounded_count="$(
    grep -c '^bounded$' "$RUNTIME_DIR/jsonfilter-bounds"
)"
[ "$projection_count" -eq 1 ] &&
    [ "$bounded_count" -eq "$projection_count" ] ||
    fail "bounded_status_projection: expected one bounded status projection"
expected_projection="projection <-i> <${STATE_DIR}/tailscale-status.${watchdog_pid}>"
expected_projection="${expected_projection} <-t> <JM_BT=@.BackendState>"
expected_projection="${expected_projection} <-t> <JM_IAT=@.Self.TailscaleIPs>"
expected_projection="${expected_projection} <-t> <JM_KT=@.Self.KeyExpiry>"
expected_projection="${expected_projection} <-t> <JM_OT=@.Self.Online>"
expected_projection="${expected_projection} <-t> <JM_TT=@.TUN>"
expected_projection="${expected_projection} <-t> <JM_HT=@.Health>"
expected_projection="${expected_projection} <-t> <JM_IPT=@.Self.TailscaleIPs[*]>"
expected_projection="${expected_projection} <-t> <JM_HET=@.Health[*]>"
expected_projection="${expected_projection} <-t> <@>"
expected_projection="${expected_projection} <-e> <@.BackendState>"
expected_projection="${expected_projection} <-e> <@.Self.KeyExpiry>"
expected_projection="${expected_projection} <-e> <@.Self.Online>"
expected_projection="${expected_projection} <-e> <@.TUN>"
expected_projection="${expected_projection} <-t> <@>"
expected_projection="${expected_projection} <-e> <@.Self.TailscaleIPs[*]>"
expected_projection="${expected_projection} <-t> <@>"
expected_projection="${expected_projection} <-e> <@.Health[*]>"
expected_projection="${expected_projection} <-t> <@>"
[ "$(sed -n '1p' "$RUNTIME_DIR/jsonfilter-argv")" = \
  "$expected_projection" ] ||
    fail "bounded_status_projection: exact ordered projection contract changed"
if grep -Fqx unbounded "$RUNTIME_DIR/jsonfilter-bounds" ||
   grep -Fvx closed "$RUNTIME_DIR/jsonfilter-fd9" | grep -q .; then
    fail "bounded_status_projection: parser escaped its timeout or inherited fd9"
fi
kill -TERM "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
assert_no_raw_status_artifacts
pass "one exact parser projection is bounded, lock-free, and secret-clean before sleep"

new_case parser_faults_never_recover
MOCK_JSONFILTER_MODE_VALUE=hang
for observation in 1 2 3 4; do
    run_once running 1 $((200 + observation)) $((1000 + observation))
    assert_status watchdog_error
    assert_json '"reason":"status_parse_timeout"'
    assert_json '"recoverable":false'
    assert_json '"consecutive_failures":0'
    assert_no_actions
    assert_no_raw_status_artifacts
done
parser_pid="$(
    cat "$RUNTIME_DIR/jsonfilter-hang-pid" 2>/dev/null || true
)"
case "$parser_pid" in
    ""|*[!0-9]*) ;;
    *)
        kill -0 "$parser_pid" 2>/dev/null &&
            fail "parser_faults_never_recover: timed-out parser survived"
        ;;
esac
MOCK_JSONFILTER_MODE_VALUE=flood
run_once running 1 220 1020
assert_status watchdog_error
assert_json '"reason":"status_parse_error"'
assert_json '"recoverable":false'
assert_no_actions
assert_no_raw_status_artifacts
MOCK_JSONFILTER_MODE_VALUE=normal
pass "parser timeout and output flood are non-recoverable and leave no raw data"

new_case status_artifact_cleanup_failure
MOCK_JSONFILTER_MODE_VALUE=raw_cleanup_fail
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"status_artifact_cleanup_failed"'
assert_json '"recoverable":false'
assert_json '"consecutive_failures":0'
assert_no_actions
if find "$STATE_DIR" -maxdepth 1 \
    -name 'tailscale-status-projection.*' -print -quit | grep -q .; then
    fail "status_artifact_cleanup_failure: projection cleanup was skipped"
fi
MOCK_JSONFILTER_MODE_VALUE=normal
pass "artifact cleanup failure suppresses recovery and still removes the projection"

new_case real_hang
run_once hang 1 200 1000
run_once hang 1 215 1015
assert_no_actions
run_once hang 1 230 1030
[ "$(action_count)" -eq 1 ] || fail "real_hang: expected one supervisor restart"
assert_json '"recovery_attempted":1'
assert_json '"recovery_state":"restart_completed"'
for ignored in 1 2 3; do
    run_once hang 1 $((230 + ignored * 15)) $((1030 + ignored * 15))
done
[ "$(action_count)" -eq 1 ] || fail "real_hang: cooldown allowed an early retry"
assert_json '"recovery_state":"recovery_cooldown"'
pass "a real LocalAPI deadline gets one restart followed by a durable cooldown"

new_case busybox_signal_deadline
run_once hang_143 1 200 1000
run_once hang_143 1 215 1015
assert_no_actions
run_once hang_143 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "busybox_signal_deadline: delayed rc143 did not authorize recovery"
assert_status daemon_unresponsive
assert_json '"reason":"localapi_timeout"'
pass "elapsed deadline evidence recognizes BusyBox-style rc143 timeout"

new_case restart_deadline_status
WATCHDOG_THRESHOLD_VALUE=1
MOCK_RESTART_MODE_VALUE=hang
run_once hang 1 200 1000
[ "$(action_count)" -eq 1 ] ||
    fail "restart_deadline_status: bounded restart was not requested"
assert_status daemon_unresponsive
assert_json '"recovery_attempted":1'
assert_json '"recovery_state":"restart_timeout"'
MOCK_RESTART_MODE_VALUE=complete
WATCHDOG_THRESHOLD_VALUE=3
pass "completed and deadline-expired restart results are published exactly"

new_case early_signal_exit
for mode in early_137 early_143; do
    for ignored in 1 2 3 4; do
        run_once "$mode" 1 $((200 + ignored)) $((1000 + ignored))
    done
    assert_status watchdog_error
    assert_json '"reason":"localapi_command_error"'
    assert_json '"recoverable":false'
done
assert_no_actions
pass "early rc137 and rc143 exits are ambiguous and never recoverable"

new_case early_signal_second_rollover
for mode in early_137_rollover early_143_rollover; do
    printf '%s\n' '100.99 0.00' > "$UPTIME_FILE"
    run_once "$mode" 1 200 1000
    assert_status watchdog_error
    assert_json '"reason":"localapi_command_error"'
    assert_json '"recoverable":false'
done
assert_no_actions
pass "a one-centisecond whole-second rollover cannot turn early rc137 or rc143 into a timeout"

new_case raw_status_cap
run_once oversized_output 1 200 1000
assert_status watchdog_error
assert_json '"reason":"localapi_command_error"'
assert_json '"recoverable":false'
assert_no_actions
pass "raw LocalAPI output is constrained by a 64 KiB file limit"

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
assert_json '"recovery_state":"recovery_cooldown"'
pass "a missing LocalAPI Unix socket gets one restart followed by cooldown"

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
write_process_generation 4242 1000
rm -f "$SOCKET_FILE"
write_maintenance_marker 1600
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
remove_process_generation
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
[ "$(action_count)" -eq 1 ] || fail "failed_restart_latched: cooldown allowed an early retry"
assert_json '"recovery_state":"recovery_cooldown"'
MOCK_RESTART_RC_VALUE=0
pass "a failed recovery command retains its durable retry cooldown"

new_case bounded_recovery_retries
WATCHDOG_THRESHOLD_VALUE=1
MOCK_RESTART_RC_VALUE=7
run_once hang 1 200 1000
[ "$(action_count)" -eq 1 ] ||
    fail "bounded_recovery_retries: first attempt was not requested"
grep -qx 'recovery_attempt_count=1' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: first attempt count was not durable"
grep -qx 'recovery_next_retry_monotonic=260' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: short deadline was not durable"
run_once hang 1 259 1059
[ "$(action_count)" -eq 1 ] ||
    fail "bounded_recovery_retries: retry happened before 60 seconds"
assert_json '"recovery_state":"recovery_cooldown"'
run_once hang 1 260 1060
[ "$(action_count)" -eq 2 ] ||
    fail "bounded_recovery_retries: second attempt was not requested"
grep -qx 'recovery_attempt_count=2' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: second attempt count was not durable"
grep -qx 'recovery_next_retry_monotonic=560' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: long deadline was not durable"
run_once hang 1 559 1359
[ "$(action_count)" -eq 2 ] ||
    fail "bounded_recovery_retries: third attempt preceded long cooldown"
run_once hang 1 560 1360
[ "$(action_count)" -eq 3 ] ||
    fail "bounded_recovery_retries: third attempt was not requested"
grep -qx 'recovery_attempt_count=3' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: exhausted count was not durable"
grep -qx 'recovery_next_retry_monotonic=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "bounded_recovery_retries: exhausted deadline was not cleared"
run_once hang 1 1000 1800
[ "$(action_count)" -eq 3 ] ||
    fail "bounded_recovery_retries: exhausted episode restarted again"
assert_json '"recovery_state":"recovery_exhausted"'
assert_json '"recoverable":false'
MOCK_RESTART_RC_VALUE=0
WATCHDOG_THRESHOLD_VALUE=3
pass "three durable attempts use 60s and 300s cooldowns then exhaust"

trusted_init_copy="${MOCK_BIN}/tailscale-init.trusted"
cp "${MOCK_BIN}/tailscale-init" "$trusted_init_copy"
chmod 0755 "$trusted_init_copy"
for drift_style in direct indirect; do
    new_case "restart_init_${drift_style}_stateful_drift"
    case "$drift_style" in
        direct)
            {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' 'printf "%s\n" unsafe-init-ran >> "$MOCK_ACTIONS_FILE"'
                printf '%s\n' '"$TAILSCALE_CLI" down'
                printf '%s\n' 'case "${1:-}" in'
                printf '%s\n' 'enabled|running) exit 0 ;;'
                printf '%s\n' 'restart)'
                printf '%s\n' '    ;;'
                printf '%s\n' 'esac'
            } > "${MOCK_BIN}/tailscale-init"
            ;;
        indirect)
            {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' 'stateful_action() {'
                printf '%s\n' '    "$TAILSCALE_CLI" logout'
                printf '%s\n' '}'
                printf '%s\n' 'printf "%s\n" unsafe-init-ran >> "$MOCK_ACTIONS_FILE"'
                printf '%s\n' 'stateful_action'
                printf '%s\n' 'case "${1:-}" in'
                printf '%s\n' 'enabled|running) exit 0 ;;'
                printf '%s\n' 'restart)'
                printf '%s\n' '    ;;'
                printf '%s\n' 'esac'
            } > "${MOCK_BIN}/tailscale-init"
            ;;
    esac
    chmod 0755 "${MOCK_BIN}/tailscale-init"
    WATCHDOG_THRESHOLD_VALUE=1
    run_once hang 1 200 1000
    assert_status watchdog_error
    assert_json '"reason":"init_integrity_unknown"'
    assert_json '"recovery_state":"init_integrity_unknown"'
    assert_json '"recoverable":false'
    assert_json '"recovery_attempted":0'
    assert_json '"recovery_count":0'
    assert_no_actions
    cp "$trusted_init_copy" "${MOCK_BIN}/tailscale-init"
    chmod 0755 "${MOCK_BIN}/tailscale-init"
done
WATCHDOG_THRESHOLD_VALUE=3

new_case restart_init_runtime_drift
WATCHDOG_THRESHOLD_VALUE=1
run_once hang_drift_init 1 200 1000
assert_status daemon_unresponsive
assert_json '"recovery_state":"init_integrity_unknown"'
assert_json '"recoverable":false'
assert_json '"recovery_attempted":0'
assert_no_actions
cp "$trusted_init_copy" "${MOCK_BIN}/tailscale-init"
chmod 0755 "${MOCK_BIN}/tailscale-init"
WATCHDOG_THRESHOLD_VALUE=3

new_case restart_init_metadata_drift
chmod 0775 "${MOCK_BIN}/tailscale-init"
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"init_integrity_unknown"'
assert_json '"recovery_state":"init_integrity_unknown"'
assert_json '"recoverable":false'
assert_no_actions
chmod 0755 "${MOCK_BIN}/tailscale-init"
WATCHDOG_THRESHOLD_VALUE=3

new_case restart_root_ownership_unproven
saved_expected_uid="$EXPECTED_TEST_UID"
EXPECTED_TEST_UID=$((EXPECTED_TEST_UID + 1))
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"init_integrity_unknown"'
assert_json '"recovery_state":"init_integrity_unknown"'
assert_json '"recoverable":false'
assert_no_actions
EXPECTED_TEST_UID="$saved_expected_uid"
WATCHDOG_THRESHOLD_VALUE=3

new_case restart_manifest_digest_drift
printf '%064d\n' 0 > "$ROUTER_MANIFEST_DIGEST"
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"init_integrity_unknown"'
assert_json '"recovery_state":"init_integrity_unknown"'
assert_json '"recoverable":false'
assert_json '"recovery_attempted":0'
assert_no_actions
WATCHDOG_THRESHOLD_VALUE=3
rm -f "$trusted_init_copy"
pass "automatic restart requires an exact root-owned init, manifest, and manifest digest proof"

new_case invalid_memory_target
rm -f "$SOCKET_FILE"
mkdir "${STATE_DIR}/tailscale-watchdog.memory"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"state_persistence_failed"'
assert_json '"connected":false'
assert_json '"recovery_attempted":1'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"recovery_exhausted"'
assert_json '"recoverable":false'
assert_no_actions
WATCHDOG_THRESHOLD_VALUE=3
pass "an invalid durable memory object fails closed to exhausted recovery"

new_case invalid_retry_state
{
    printf 'recovery_attempted=1\n'
    printf 'recovery_attempt_count=1\n'
    printf 'recovery_next_retry_monotonic=0\n'
} >"${STATE_DIR}/tailscale-watchdog.memory"
chmod 0600 "${STATE_DIR}/tailscale-watchdog.memory"
WATCHDOG_THRESHOLD_VALUE=1
run_once hang 1 200 1000
assert_no_actions
assert_json '"recovery_attempted":1'
assert_json '"recovery_state":"recovery_exhausted"'
assert_json '"recoverable":false'
grep -qx 'recovery_attempt_count=3' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "invalid_retry_state: invalid authority was not rewritten exhausted"
WATCHDOG_THRESHOLD_VALUE=3
pass "inconsistent retry memory cannot mint fresh restart authority"

new_case restart_generation_changes_after_latch
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FINAL_PROOF_GATE_VALUE="${CASE_DIR}/final-proof"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_FINAL_PROOF_GATE_VALUE}.ready"
grep -qx closed "${MOCK_FINAL_PROOF_GATE_VALUE}.fd7" ||
    fail "restart_generation_changes_after_latch: proof child inherited install authority"
if install_lock_is_available; then
    fail "restart_generation_changes_after_latch: parent lost install authority"
fi
write_process_generation 4243 20000
: > "${MOCK_FINAL_PROOF_GATE_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"restart_generation_changed"'
assert_json '"connected":false'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "restart_generation_changes_after_latch: latch rollback was not durable"
grep -qx 'recovery_count=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "restart_generation_changes_after_latch: recovery count was spent"
MOCK_FINAL_PROOF_GATE_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "a generation swap during latch persistence rolls back the unspent restart"

new_case generation_changes_during_second_integrity
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE="${CASE_DIR}/second-integrity"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE}.ready"
grep -qx closed "${MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE}.fd7" ||
    fail "generation_changes_during_second_integrity: proof child inherited install authority"
if install_lock_is_available; then
    fail "generation_changes_during_second_integrity: parent lost install authority"
fi
write_process_generation 4244 21000
: > "${MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"restart_generation_changed"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "generation_changes_during_second_integrity: latch was not refunded"
install_lock_is_available ||
    fail "generation_changes_during_second_integrity: final proof retained lock"
MOCK_SECOND_INTEGRITY_GATE_AFTER_LATCH_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "generation is rejoined after the second init-integrity proof"

new_case inactive_becomes_running_after_latch
remove_process_generation
RUNNING_SEQUENCE="${CASE_DIR}/running-sequence"
printf '0\n1\n' > "$RUNNING_SEQUENCE"
MOCK_RUNNING_SEQUENCE_FILE_VALUE="$RUNNING_SEQUENCE"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 0 200 1000
assert_no_actions
assert_status daemon_missing
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"restart_state_changed"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "inactive_becomes_running_after_latch: latch rollback was not durable"
MOCK_RUNNING_SEQUENCE_FILE_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "an inactive-to-running supervisor race suppresses restart and refunds its latch"

new_case maintenance_appears_after_latch
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FINAL_PROOF_GATE_VALUE="${CASE_DIR}/final-proof"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_FINAL_PROOF_GATE_VALUE}.ready"
MAINTENANCE_TEMP="${STATE_DIR}/tailscale-maintenance.test"
printf '%s\n' 1600 > "$MAINTENANCE_TEMP"
chmod 0600 "$MAINTENANCE_TEMP"
mv -f "$MAINTENANCE_TEMP" "${STATE_DIR}/tailscale-maintenance"
: > "${MOCK_FINAL_PROOF_GATE_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_status maintenance
assert_json '"maintenance_state":"active"'
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"maintenance_started"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "maintenance_appears_after_latch: latch rollback was not durable"
MOCK_FINAL_PROOF_GATE_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "an atomically appearing maintenance lease wins the final restart race"

new_case active_install_transaction
rm -f "$SOCKET_FILE"
: > "$INSTALL_LOCK_PATH"
chmod 0600 "$INSTALL_LOCK_PATH"
install_lock_inode="$(lock_inode "$INSTALL_LOCK_PATH")"
write_maintenance_marker 999
holder_ready="${CASE_DIR}/holder.ready"
holder_release="${CASE_DIR}/holder.release"
start_install_lock_holder \
    "$INSTALL_LOCK_PATH" "$holder_ready" "$holder_release"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"install_transaction_active"'
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"install_transaction_active"'
assert_no_actions
[ "$(lock_inode "$INSTALL_LOCK_PATH")" = "$install_lock_inode" ] ||
    fail "active_install_transaction: watchdog replaced the shared lock inode"
stop_install_lock_holder "$holder_release"
rm -f "${STATE_DIR}/tailscale-maintenance"
run_once running 1 215 1015
[ "$(action_count)" -eq 1 ] ||
    fail "active_install_transaction: idle successor could not recover"
grep -qx closed "$RUNTIME_DIR/restart-fd7" ||
    fail "active_install_transaction: restart child inherited install authority"
install_lock_is_available ||
    fail "active_install_transaction: completed restart retained install authority"
WATCHDOG_THRESHOLD_VALUE=3
pass "expired lease cannot race a live installer or upgrader transaction"

new_case install_transaction_appears_after_latch
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE="${CASE_DIR}/flock-gate"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.ready"
install_lock_inode="$(lock_inode "$INSTALL_LOCK_PATH")"
holder_ready="${CASE_DIR}/holder.ready"
holder_release="${CASE_DIR}/holder.release"
start_install_lock_holder \
    "$INSTALL_LOCK_PATH" "$holder_ready" "$holder_release"
: > "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"install_transaction_active"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "install_transaction_appears_after_latch: latch was not refunded"
[ "$(lock_inode "$INSTALL_LOCK_PATH")" = "$install_lock_inode" ] ||
    fail "install_transaction_appears_after_latch: lock inode changed"
stop_install_lock_holder "$holder_release"
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "a transaction starting after latch persistence wins the final restart race"

new_case unsafe_install_lock
unsafe_lock_target="${CASE_DIR}/unsafe-lock-target"
printf '%s\n' sentinel > "$unsafe_lock_target"
ln -s "$unsafe_lock_target" "$INSTALL_LOCK_PATH"
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
run_once running 1 200 1000
assert_status watchdog_error
assert_json '"reason":"install_lock_invalid"'
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_no_actions
[ "$(cat "$unsafe_lock_target")" = "sentinel" ] ||
    fail "unsafe_install_lock: watchdog followed the lock symlink"
WATCHDOG_THRESHOLD_VALUE=3
pass "an unsafe shared install-lock object suppresses recovery"

new_case install_lock_replaced_after_latch
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE="${CASE_DIR}/flock-gate"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.ready"
mv "$INSTALL_LOCK_PATH" "${INSTALL_LOCK_PATH}.replaced"
: > "$INSTALL_LOCK_PATH"
chmod 0600 "$INSTALL_LOCK_PATH"
: > "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"install_lock_invalid"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "install_lock_replaced_after_latch: latch was not refunded"
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "shared install-lock inode replacement invalidates final restart authority"

new_case install_lock_replaced_during_flock
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FLOCK_REPLACE_AFTER_LATCH_PATH_VALUE="$INSTALL_LOCK_PATH"
run_once running 1 200 1000
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"install_lock_invalid"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "install_lock_replaced_during_flock: latch was not refunded"
[ -f "${INSTALL_LOCK_PATH}.swapped" ] &&
    [ -f "${INSTALL_LOCK_PATH}.orphaned" ] ||
    fail "install_lock_replaced_during_flock: race hook did not replace the lock"
MOCK_FLOCK_REPLACE_AFTER_LATCH_PATH_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "post-flock inode rejoin rejects path replacement during acquisition"

new_case transaction_completes_before_final_lock
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE="${CASE_DIR}/flock-gate"
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_path "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.ready"
write_process_generation 5252 11000
: > "${MOCK_FLOCK_GATE_AFTER_LATCH_VALUE}.release"
wait "$watchdog_launcher_pid"
assert_no_actions
assert_json '"recovery_attempted":0'
assert_json '"recovery_count":0'
assert_json '"recovery_state":"restart_generation_changed"'
grep -qx 'recovery_attempted=0' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "transaction_completes_before_final_lock: latch was not refunded"
install_lock_is_available ||
    fail "transaction_completes_before_final_lock: final proof retained lock"
MOCK_FLOCK_GATE_AFTER_LATCH_VALUE=
WATCHDOG_THRESHOLD_VALUE=3
pass "final mutable proofs run only after shared install authority is held"

new_case ordinary_persistence_failure
run_once running 1 200 1000
assert_status running
rm -f "${STATE_DIR}/tailscale-watchdog.memory"
mkdir "${STATE_DIR}/tailscale-watchdog.memory"
run_once running 1 215 1015
assert_status watchdog_error
assert_json '"reason":"state_persistence_failed"'
assert_json '"healthy":false'
assert_json '"connected":false'
assert_json '"connected_since_at":0'
assert_json '"connectivity_uptime_seconds":null'
[ -f "${STATE_DIR}/tailscale-watchdog.continuity-broken" ] ||
    fail "ordinary_persistence_failure: missing continuity-break sentinel"
rmdir "${STATE_DIR}/tailscale-watchdog.memory"
run_once running 1 216 1016
assert_status running
assert_json '"connected_since_at":1016'
assert_json '"connectivity_uptime_seconds":0'
[ ! -e "${STATE_DIR}/tailscale-watchdog.continuity-broken" ] ||
    fail "ordinary_persistence_failure: committed recovery left sentinel"
assert_no_actions
pass "ordinary persistence failure is visible and breaks connectivity uptime"

new_case restart_latch_survives_sigkill
rm -f "$SOCKET_FILE"
WATCHDOG_THRESHOLD_VALUE=1
MOCK_RESTART_MODE_VALUE=hang
MOCK_REQUIRE_DURABLE_LATCH_VALUE=1
MOCK_TIMEOUT_DELAY_VALUE=2
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
wait_for_action_count 1
wait_for_lock_pid "${STATE_DIR}/tailscale-watchdog.lock"
watchdog_pid="$(sed -n 's/^pid=//p' \
    "${STATE_DIR}/tailscale-watchdog.lock")"
grep -qx 'recovery_attempted=1' \
    "${STATE_DIR}/tailscale-watchdog.memory" ||
    fail "restart_latch_survives_sigkill: action preceded durable latch"
kill -KILL "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
if install_lock_is_available; then
    fail "restart_latch_survives_sigkill: timeout guardian lost the install lock"
fi
grep -qx closed "$RUNTIME_DIR/restart-fd7" ||
    fail "restart_latch_survives_sigkill: restart child inherited install authority"
wait_for_install_lock_available
MOCK_RESTART_MODE_VALUE=complete
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
[ "$(action_count)" -eq 1 ] ||
    fail "restart_latch_survives_sigkill: successor repeated the restart"
assert_json '"recovery_attempted":1'
assert_json '"recovery_state":"recovery_cooldown"'
WATCHDOG_THRESHOLD_VALUE=3
MOCK_REQUIRE_DURABLE_LATCH_VALUE=0
pass "SIGKILL during restart leaves the successor in durable cooldown"

new_case signal_restart_and_logger_term
rm -f "$SOCKET_FILE"
run_once running 1 200 1000
assert_no_actions
WATCHDOG_THRESHOLD_VALUE=2
MOCK_RESTART_MODE_VALUE=hang
MOCK_LOGGER_MODE_VALUE=hang
MOCK_REQUIRE_DURABLE_LATCH_VALUE=1
MOCK_TIMEOUT_DELAY_VALUE=10
WATCHDOG_MONO_VALUE=215
WATCHDOG_EPOCH_VALUE=1015
watchdog_env running 1 reachable --once &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
wait_for_path "$RUNTIME_DIR/restart-hang-pid"
wait_for_path "$RUNTIME_DIR/logger-hang-pid"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
restart_pid="$(cat "$RUNTIME_DIR/restart-hang-pid")"
logger_pid="$(cat "$RUNTIME_DIR/logger-hang-pid")"
restart_logger_inode="$(lock_inode "$LOCK_PATH")"
kill -0 "$watchdog_pid" 2>/dev/null &&
    kill -0 "$restart_pid" 2>/dev/null &&
    kill -0 "$logger_pid" 2>/dev/null ||
    fail "signal_restart_and_logger_term: both tracked children were not live"
if grep -Fvx bounded "$RUNTIME_DIR/logger-bounds" | grep -q . ||
   grep -Fvx closed "$RUNTIME_DIR/logger-fd9" | grep -q .; then
    fail "signal_restart_and_logger_term: logger escaped deadline or inherited fd9"
fi
kill -TERM "$watchdog_pid"
wait_for_pid_exit "$watchdog_pid" "watchdog after restart/logger TERM"
wait_for_pid_exit "$restart_pid" "restart after watchdog TERM"
wait_for_pid_exit "$logger_pid" "logger after watchdog TERM"
wait "$watchdog_launcher_pid" 2>/dev/null || true
install_lock_is_available ||
    fail "signal_restart_and_logger_term: TERM retained install authority"
grep -Fvx closed "$RUNTIME_DIR/restart-fd7" | grep -q . &&
    fail "signal_restart_and_logger_term: restart inherited install authority"
MOCK_RESTART_MODE_VALUE=complete
MOCK_LOGGER_MODE_VALUE=normal
MOCK_REQUIRE_DURABLE_LATCH_VALUE=0
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "signal_restart_and_logger_term: successor repeated the restart"
[ "$(lock_inode "$LOCK_PATH")" = "$restart_logger_inode" ] ||
    fail "signal_restart_and_logger_term: successor replaced the lock inode"
WATCHDOG_THRESHOLD_VALUE=3
pass "TERM reaps restart children and releases shared install authority"

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
printf '%s\n' '100.70.186.127' > "$PEER_FILE"
run_once running_no_tun 1 190 990 unreachable
assert_status running_degraded
assert_json '"reason":"tun_unavailable"'
assert_json '"peer_state":"unknown"'
assert_json '"peer_reachable":null'
run_once running 1 195 995 reachable
assert_status running
assert_json '"peer_configured":true'
assert_json '"peer_state":"reachable"'
assert_json '"peer_reachable":true'
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
pass "TSMP peer proof is exact and failures end connectivity without authorizing restart"

new_case peer_contract_replaced_during_probe
printf '%s\n' '100.70.186.127' > "$PEER_FILE"
chmod 0600 "$PEER_FILE"
run_once running 1 200 1000 reachable_swap_peer_contract
assert_status running_degraded
assert_json '"reason":"critical_peer_invalid"'
assert_json '"healthy":false'
assert_json '"connected":false'
assert_json '"peer_configured":true'
assert_json '"peer_state":"invalid_configuration"'
assert_json '"peer_reachable":false'
[ "$(wc -l < "$PEER_PINGS_FILE" | tr -d ' ')" -eq 1 ] ||
    fail "peer_contract_replaced_during_probe: expected one bounded probe"
assert_no_actions
pass "an atomic peer-contract replacement invalidates the in-flight delivery proof"

new_case self_peer_is_invalid
printf '%s\n' '100.104.78.42' > "$PEER_FILE"
run_once running 1 200 1000 reachable
assert_status running_degraded
assert_json '"reason":"critical_peer_invalid"'
assert_json '"connected":false'
assert_json '"peer_state":"invalid_configuration"'
[ ! -s "$PEER_PINGS_FILE" ] ||
    fail "self_peer_is_invalid: watchdog pinged its own local address"

printf '%s\n' 'FD7A:115C:A1E0:0:0:0:0:1234' > "$PEER_FILE"
run_once live_1_98_9 1 215 1015 reachable
assert_status running_degraded
assert_json '"reason":"critical_peer_invalid"'
assert_json '"peer_state":"invalid_configuration"'
[ ! -s "$PEER_PINGS_FILE" ] ||
    fail "self_peer_is_invalid: equivalent IPv6 self literal was pinged"
assert_no_actions
pass "IPv4 and equivalent IPv6 self-peer literals fail closed without ping"

assert_invalid_peer_config() {
    run_once running 1 200 1000 reachable
    assert_status running_degraded
    assert_json '"reason":"critical_peer_invalid"'
    assert_json '"healthy":false'
    assert_json '"connected":false'
    assert_json '"peer_configured":true'
    assert_json '"peer_state":"invalid_configuration"'
    assert_json '"peer_reachable":false'
    assert_no_actions
}

new_case invalid_peer_files
: > "$PEER_FILE"
assert_invalid_peer_config
printf '%s\n' vps-node > "$PEER_FILE"
assert_invalid_peer_config
printf '%s\n%s\n' vps-node unexpected-second-line > "$PEER_FILE"
assert_invalid_peer_config
awk 'BEGIN { for (i = 0; i < 254; i++) printf "a" }' > "$PEER_FILE"
assert_invalid_peer_config
printf '%s\n' 'bad target' > "$PEER_FILE"
assert_invalid_peer_config
python3 - "$PEER_FILE" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"100.70.186.127\x00")
PY
assert_invalid_peer_config
rm -f "$PEER_FILE"
mkdir "$PEER_FILE"
assert_invalid_peer_config
rmdir "$PEER_FILE"
printf '%s\n' vps-node > "${CASE_DIR}/peer-target"
ln -s "${CASE_DIR}/peer-target" "$PEER_FILE"
assert_invalid_peer_config
rm -f "$PEER_FILE"
ln -s "${CASE_DIR}/missing-peer-target" "$PEER_FILE"
assert_invalid_peer_config
rm -f "$PEER_FILE"
printf '%s\n' vps-node > "$PEER_FILE"
chmod 000 "$PEER_FILE"
if [ ! -r "$PEER_FILE" ]; then
    assert_invalid_peer_config
fi
chmod 0600 "$PEER_FILE"
printf '%s\n' '100.70.186.127' > "$PEER_FILE"
chmod 0644 "$PEER_FILE"
assert_invalid_peer_config
chmod 0600 "$PEER_FILE"
ln "$PEER_FILE" "${CASE_DIR}/peer-hardlink"
assert_invalid_peer_config
rm -f "${CASE_DIR}/peer-hardlink"
for ignored in 1 2 3 4; do
    : > "$PEER_FILE"
    run_once running 1 $((200 + ignored)) $((1000 + ignored)) reachable
done
assert_no_actions
WATCHDOG_JSONFILTER_OVERRIDE="${CASE_DIR}/missing-jsonfilter"
run_once running 1 210 1010 reachable
assert_status watchdog_error
assert_json '"connected":false'
assert_json '"peer_state":"invalid_configuration"'
WATCHDOG_JSONFILTER_OVERRIDE=""
pass "existing invalid peer files fail closed and never authorize recovery"

new_case intentional_states
MOCK_SERVICE_ENABLED_VALUE=0
run_once running 1 200 1000
assert_status disabled
assert_no_actions
MOCK_SERVICE_ENABLED_VALUE=1
write_maintenance_marker 1600
run_once hang 1 215 1015
assert_status maintenance
assert_json '"maintenance_state":"active"'
assert_json '"maintenance_expires_at":1600'
assert_no_actions
pass "disabled and maintenance states never gain recovery authority"

new_case expired_maintenance
write_maintenance_marker 999
run_once hang 1 200 1000
run_once hang 1 215 1015
run_once hang 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "expired_maintenance: expired marker suppressed bounded recovery"
assert_json '"maintenance_state":"expired"'
pass "an expired maintenance marker is visible but cannot suppress recovery"

new_case symlink_maintenance
printf '%s\n' 1600 >"${CASE_DIR}/real-maintenance"
ln -s "${CASE_DIR}/real-maintenance" \
    "${STATE_DIR}/tailscale-maintenance"
run_once hang 1 200 1000
run_once hang 1 215 1015
run_once hang 1 230 1030
[ "$(action_count)" -eq 1 ] ||
    fail "symlink_maintenance: symlink suppressed bounded recovery"
assert_json '"maintenance_state":"malformed"'
pass "symlinked maintenance markers are invalid and cannot suppress recovery"

new_case malformed_maintenance
write_maintenance_marker not-an-epoch
run_once running 1 200 1000
assert_status running_degraded
assert_json '"reason":"maintenance_marker_invalid"'
assert_json '"maintenance_state":"malformed"'
assert_json '"healthy":false'
assert_no_actions
pass "a malformed maintenance marker degrades health without pausing recovery"

new_case byte_exact_maintenance
for marker in 08 9999999999999999999; do
    write_maintenance_marker "$marker"
    run_once running 1 200 1000
    assert_status running_degraded
    assert_json '"maintenance_state":"malformed"'
done
python3 - "${STATE_DIR}/tailscale-maintenance" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"1600\x00")
PY
run_once running 1 215 1015
assert_status running_degraded
assert_json '"maintenance_state":"malformed"'
assert_no_actions
pass "maintenance epochs are canonical bounded decimals with exact bytes"

new_case far_future_maintenance
write_maintenance_marker 99999
run_once running 1 200 1000
assert_status running_degraded
assert_json '"maintenance_state":"out_of_bounds"'
assert_no_actions
pass "an overly long maintenance lease is rejected and surfaced"

new_case boot_grace
write_process_generation 4242 1000
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

new_case signal_logger_term
MOCK_TIMEOUT_DELAY_VALUE=10
MOCK_LOGGER_MODE_VALUE=hang
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
wait_for_path "$RUNTIME_DIR/logger-hang-pid"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
logger_pid="$(cat "$RUNTIME_DIR/logger-hang-pid")"
signal_logger_inode="$(lock_inode "$LOCK_PATH")"
kill -0 "$watchdog_pid" 2>/dev/null &&
    kill -0 "$logger_pid" 2>/dev/null ||
    fail "signal_logger_term: deterministic logger hang was not live"
grep -qx bounded "$RUNTIME_DIR/logger-bounds" ||
    fail "signal_logger_term: logger did not run below a deadline"
grep -qx closed "$RUNTIME_DIR/logger-fd9" ||
    fail "signal_logger_term: logger inherited the singleton descriptor"
kill -TERM "$watchdog_pid"
wait_for_pid_exit "$watchdog_pid" "watchdog after logger TERM"
wait_for_pid_exit "$logger_pid" "logger after watchdog TERM"
wait "$watchdog_launcher_pid" 2>/dev/null || true
MOCK_LOGGER_MODE_VALUE=normal
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$signal_logger_inode" ] ||
    fail "signal_logger_term: successor replaced the lock inode"
pass "TERM during diagnostic logging reaps it and preserves singleton recovery"

new_case sigkill_logger_lock_release
MOCK_TIMEOUT_DELAY_VALUE=10
MOCK_LOGGER_MODE_VALUE=hang
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
wait_for_path "$RUNTIME_DIR/logger-hang-pid"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
logger_pid="$(cat "$RUNTIME_DIR/logger-hang-pid")"
logger_parent_pid="$(
    ps -o ppid= -p "$logger_pid" 2>/dev/null | tr -d ' \r\n'
)"
sigkill_logger_inode="$(lock_inode "$LOCK_PATH")"
kill -KILL "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
kill -0 "$logger_pid" 2>/dev/null ||
    fail "sigkill_logger_lock_release: logger did not survive parent SIGKILL"
MOCK_LOGGER_MODE_VALUE=normal
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$sigkill_logger_inode" ] ||
    fail "sigkill_logger_lock_release: successor replaced the lock inode"
[ "$(sed -n 's/^pid=//p' "$LOCK_PATH")" != "$watchdog_pid" ] ||
    fail "sigkill_logger_lock_release: successor did not own metadata"
case "$logger_parent_pid" in
    ""|*[!0-9]*)
        kill -TERM "$logger_pid" 2>/dev/null || true
        ;;
    *)
        kill -TERM "$logger_parent_pid" 2>/dev/null || true
        wait_for_pid_exit "$logger_parent_pid" \
            "orphan logger timeout wrapper after successor proof"
        ;;
esac
wait_for_pid_exit "$logger_pid" "orphan logger after successor proof"
pass "SIGKILL during diagnostic logging cannot leak fd9 into the successor"

new_case signal_projection_term
MOCK_TIMEOUT_DELAY_VALUE=10
MOCK_JSONFILTER_MODE_VALUE=hang
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
wait_for_path "$RUNTIME_DIR/jsonfilter-hang-pid"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
parser_pid="$(cat "$RUNTIME_DIR/jsonfilter-hang-pid")"
signal_projection_inode="$(lock_inode "$LOCK_PATH")"
kill -0 "$watchdog_pid" 2>/dev/null &&
    kill -0 "$parser_pid" 2>/dev/null ||
    fail "signal_projection_term: deterministic parser hang was not live"
kill -TERM "$watchdog_pid"
wait_for_pid_exit "$watchdog_pid" "watchdog after parser TERM"
wait_for_pid_exit "$parser_pid" "parser after watchdog TERM"
wait "$watchdog_launcher_pid" 2>/dev/null || true
assert_no_raw_status_artifacts
MOCK_JSONFILTER_MODE_VALUE=normal
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$signal_projection_inode" ] ||
    fail "signal_projection_term: successor replaced the lock inode"
pass "TERM during parser projection reaps it, clears secrets, and preserves singleton recovery"

new_case sigkill_projection_lock_release
MOCK_TIMEOUT_DELAY_VALUE=10
MOCK_JSONFILTER_MODE_VALUE=hang
WATCHDOG_MONO_VALUE=200
WATCHDOG_EPOCH_VALUE=1000
watchdog_env running 1 reachable "" &
watchdog_launcher_pid=$!
LOCK_PATH="${STATE_DIR}/tailscale-watchdog.lock"
wait_for_lock_pid "$LOCK_PATH"
wait_for_path "$RUNTIME_DIR/jsonfilter-hang-pid"
watchdog_pid="$(sed -n 's/^pid=//p' "$LOCK_PATH")"
parser_pid="$(cat "$RUNTIME_DIR/jsonfilter-hang-pid")"
parser_parent_pid="$(
    ps -o ppid= -p "$parser_pid" 2>/dev/null | tr -d ' \r\n'
)"
sigkill_projection_inode="$(lock_inode "$LOCK_PATH")"
kill -KILL "$watchdog_pid"
wait "$watchdog_launcher_pid" 2>/dev/null || true
kill -0 "$parser_pid" 2>/dev/null ||
    fail "sigkill_projection_lock_release: parser did not survive parent SIGKILL"
if ! find "$STATE_DIR" -maxdepth 1 \
    \( -name 'tailscale-status.*' \
    -o -name 'tailscale-status-error.*' \
    -o -name 'tailscale-status-projection.*' \) \
    -print -quit | grep -q .; then
    fail "sigkill_projection_lock_release: no stale crash artifact was created"
fi
MOCK_JSONFILTER_MODE_VALUE=normal
MOCK_TIMEOUT_DELAY_VALUE=0.5
run_once running 1 215 1015
assert_status running
[ "$(lock_inode "$LOCK_PATH")" = "$sigkill_projection_inode" ] ||
    fail "sigkill_projection_lock_release: successor replaced the lock inode"
[ "$(sed -n 's/^pid=//p' "$LOCK_PATH")" != "$watchdog_pid" ] ||
    fail "sigkill_projection_lock_release: successor did not own metadata"
assert_no_raw_status_artifacts
kill -TERM "$parser_pid" 2>/dev/null || true
wait_for_pid_exit "$parser_pid" "orphan parser after successor proof"
case "$parser_parent_pid" in
    ""|*[!0-9]*) ;;
    *)
        wait_for_pid_exit "$parser_parent_pid" \
            "orphan timeout wrapper after successor proof"
        ;;
esac
pass "SIGKILL during parser projection cannot leak fd9 or stale secrets into the successor"

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
if [ "$(grep -Fc '7>&-' "$WATCHDOG")" -lt 7 ]; then
    fail "watchdog children do not close shared install authority"
fi
if grep -Eq 'rm -f .*LOCK_FILE|rm -f .*tailscale-watchdog\\.lock' "$WATCHDOG"; then
    fail "watchdog removes the persistent kernel-lock inode"
fi
if grep -Eq 'rm -f .*INSTALL_LOCK_FILE|rm -f .*router-install\\.lock' \
    "$WATCHDOG"; then
    fail "watchdog removes the shared router-install lock inode"
fi
grep -Fq 'router-install.lock' "$WATCHDOG" &&
    grep -Fq 'router-install.lock' \
        "${REPO_DIR}/router/install-jammonitor-router.sh" &&
    grep -Fq 'router-install.lock' \
        "${REPO_DIR}/router/upgrade-tailscale-arm64.sh" ||
    fail "watchdog, installer, and upgrader do not share one exact lock path"
pass "all child and shared-lock descriptor inheritance is explicit"

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
