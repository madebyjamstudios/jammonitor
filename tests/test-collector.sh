#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
COLLECTOR="${REPO_DIR}/router/jammonitor-collect"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT%/}"
TEST_DIR="$(mktemp -d "${TEST_TMP_ROOT}/jammonitor-collector-test.XXXXXX")"
cleanup_test_dir() {
    if [ "${KEEP_TEST_DIR:-0}" = "1" ]; then
        printf 'kept test artifacts: %s\n' "$TEST_DIR" >&2
    else
        rm -rf "$TEST_DIR"
    fi
}
trap cleanup_test_dir EXIT INT TERM

PASS_COUNT=0

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

MOCK_TIMEOUT="${TEST_DIR}/timeout"
cat > "$MOCK_TIMEOUT" <<'EOF'
#!/bin/sh
shift
flag="${TMPDIR:-/tmp}/jammonitor-sqlite-timeout.$$"
"$@" &
child=$!
(
    sleep "${MOCK_TIMEOUT_DELAY:-1}"
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
chmod 0755 "$MOCK_TIMEOUT"

sh -n "$COLLECTOR"
dash -n "$COLLECTOR"
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n "$COLLECTOR"
fi
pass "collector parses under POSIX sh and dash"

JAMMONITOR_LIB_ONLY=1 \
JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
    . "$COLLECTOR"
unset JAMMONITOR_LIB_ONLY

MOCK_FLOCK="${TEST_DIR}/flock"
cat > "$MOCK_FLOCK" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-n" ] || exit 64
state="${JAMMONITOR_TEST_FLOCK_STATE:?}"
if mkdir "$state" 2>/dev/null; then
    printf '%s\n' "$PPID" > "$state/owner"
    exit 0
fi
owner="$(cat "$state/owner" 2>/dev/null)"
if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
    exit 1
fi
rm -f "$state/owner"
rmdir "$state" 2>/dev/null || exit 1
mkdir "$state" 2>/dev/null || exit 1
printf '%s\n' "$PPID" > "$state/owner"
EOF
chmod 0755 "$MOCK_FLOCK"

LOCK_WORKER="${TEST_DIR}/lock-worker"
cat > "$LOCK_WORKER" <<'EOF'
#!/bin/sh
set -u
collector="$1"
flock_cmd="$2"
lock_file="$3"
pid_file="$4"
result_file="$5"
barrier="$6"
mode="$7"
hold_seconds="$8"

JAMMONITOR_LIB_ONLY=1
export JAMMONITOR_LIB_ONLY
. "$collector"
unset JAMMONITOR_LIB_ONLY

FLOCK_CMD="$flock_cmd"
LOCK_FILE="$lock_file"
PIDFILE="$pid_file"
JAMMONITOR_TEST_FLOCK_STATE="${lock_file}.mock-flock"
export JAMMONITOR_TEST_FLOCK_STATE
SYSLOG_PID=""
logger() { :; }
proc_start_ticks() {
    # Separate worker processes have distinct PIDs; a fixed positive start
    # tick is sufficient for this lock-protocol regression.
    printf '10000\n'
}

if [ "$barrier" != "-" ]; then
    : > "${barrier}.ready.$$"
    while [ ! -e "$barrier" ]; do sleep 0.02; done
fi

acquire_collector_lock
rc=$?
if [ "$rc" -eq 0 ]; then
    printf 'acquired %s\n' "$$" >> "$result_file"
    if [ "$mode" = "cleanup-hold" ]; then
        cleanup_processes
        printf 'cleaned %s\n' "$$" >> "$result_file"
    fi
    sleep "$hold_seconds"
    cleanup_processes
    exit 0
fi
printf 'blocked %s %s\n' "$$" "$rc" >> "$result_file"
exit "$rc"
EOF
chmod 0755 "$LOCK_WORKER"

LOCK_FILE_TEST="${TEST_DIR}/collector.lock"
PID_FILE_TEST="${TEST_DIR}/collector.pid"
LOCK_RESULTS="${TEST_DIR}/lock-results"
LOCK_BARRIER="${TEST_DIR}/lock-barrier"
sleep 5 &
unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$PID_FILE_TEST"

"$LOCK_WORKER" "$COLLECTOR" "$MOCK_FLOCK" "$LOCK_FILE_TEST" \
    "$PID_FILE_TEST" "$LOCK_RESULTS" "$LOCK_BARRIER" race 0.4 &
lock_worker_one=$!
"$LOCK_WORKER" "$COLLECTOR" "$MOCK_FLOCK" "$LOCK_FILE_TEST" \
    "$PID_FILE_TEST" "$LOCK_RESULTS" "$LOCK_BARRIER" race 0.4 &
lock_worker_two=$!

ready_attempts=0
while [ "$(find "$TEST_DIR" -name 'lock-barrier.ready.*' | wc -l | tr -d ' ')" -lt 2 ]; do
    ready_attempts=$((ready_attempts + 1))
    [ "$ready_attempts" -lt 100 ] || fail "lock workers did not reach the race barrier"
    sleep 0.02
done
: > "$LOCK_BARRIER"
lock_rc_one=0
lock_rc_two=0
wait "$lock_worker_one" || lock_rc_one=$?
wait "$lock_worker_two" || lock_rc_two=$?
kill "$unrelated_pid" 2>/dev/null || true
wait "$unrelated_pid" 2>/dev/null || true

[ "$(grep -c '^acquired ' "$LOCK_RESULTS")" -eq 1 ] ||
    fail "simultaneous collector starts did not select exactly one owner"
[ "$(grep -c '^blocked ' "$LOCK_RESULTS")" -eq 1 ] ||
    fail "simultaneous collector starts did not reject exactly one contender"
case "${lock_rc_one}:${lock_rc_two}" in
    0:2|2:0) ;;
    *) fail "collector race returned unexpected statuses ${lock_rc_one}:${lock_rc_two}" ;;
esac
grep -q '^pid=[0-9][0-9]*$' "$LOCK_FILE_TEST" ||
    fail "collector lock omitted its owner PID"
grep -q '^start_ticks=10000$' "$LOCK_FILE_TEST" ||
    fail "collector lock omitted its process start ticks"
grep -q '^identity=lock-worker$' "$LOCK_FILE_TEST" ||
    fail "collector lock omitted its process identity"
[ ! -e "$PID_FILE_TEST" ] ||
    fail "collector owner cleanup left a stale PID file"
pass "kernel lock defeats stale live PIDs and simultaneous collector starts"

: > "$LOCK_RESULTS"
LOCK_HOLD_READY="${TEST_DIR}/lock-hold-ready"
"$LOCK_WORKER" "$COLLECTOR" "$MOCK_FLOCK" "$LOCK_FILE_TEST" \
    "$PID_FILE_TEST" "$LOCK_RESULTS" - cleanup-hold 0.5 &
lock_owner=$!
hold_attempts=0
while ! grep -q '^cleaned ' "$LOCK_RESULTS" 2>/dev/null; do
    hold_attempts=$((hold_attempts + 1))
    [ "$hold_attempts" -lt 100 ] || fail "lock owner did not enter cleanup hold"
    sleep 0.02
done
if "$LOCK_WORKER" "$COLLECTOR" "$MOCK_FLOCK" "$LOCK_FILE_TEST" \
    "$PID_FILE_TEST" "$LOCK_RESULTS" - successor 0
then
    fail "owner cleanup released the singleton lock before process exit"
else
    cleanup_contender_rc=$?
fi
[ "$cleanup_contender_rc" -eq 2 ] ||
    fail "cleanup contender returned $cleanup_contender_rc instead of lock-busy"
wait "$lock_owner"
"$LOCK_WORKER" "$COLLECTOR" "$MOCK_FLOCK" "$LOCK_FILE_TEST" \
    "$PID_FILE_TEST" "$LOCK_RESULTS" - successor 0
pass "only process exit releases ownership and a successor can acquire safely"

DB_PATH="${TEST_DIR}/escape.db"
sqlite3 "$DB_PATH" 'CREATE TABLE payloads (payload TEXT);'
payload='{"path":"C:\\tmp","name":"O'\''Reilly"}'
escaped="$(sql_escape "$payload")"
sqlite3 "$DB_PATH" "INSERT INTO payloads VALUES ('$escaped');"
stored="$(sqlite3 "$DB_PATH" 'SELECT payload FROM payloads;')"
[ "$stored" = "$payload" ] || fail "SQLite escaping changed JSON bytes"
[ "$(sqlite3 "$DB_PATH" 'SELECT json_valid(payload) FROM payloads;')" = "1" ] ||
    fail "SQLite escaping stored invalid JSON"
pass "SQL escaping preserves JSON quotes and backslashes"

for ip in \
    10.0.0.1 \
    10.255.255.255 \
    172.16.0.1 \
    172.31.255.255 \
    192.168.0.1 \
    100.64.0.1 \
    100.127.255.254
do
    is_local_client_ip "$ip" || fail "expected local address: $ip"
done

for ip in \
    9.255.255.255 \
    172.15.255.255 \
    172.32.0.1 \
    192.169.0.1 \
    100.63.255.255 \
    100.128.0.1 \
    100.1.2.3 \
    256.1.1.1 \
    100.64.0 \
    example.com
do
    if is_local_client_ip "$ip"; then
        fail "unexpected local address: $ip"
    fi
done
pass "client attribution uses exact RFC1918 and Tailscale /10 boundaries"

for ip in 100.64.0.1 100.127.255.254 fd7a:115c:a1e0::1; do
    is_tailscale_ip "$ip" || fail "expected Tailscale address: $ip"
done
for ip in 10.0.0.1 100.63.255.255 100.128.0.1 8.8.8.8 fd00::1; do
    if is_tailscale_ip "$ip"; then
        fail "unexpected Tailscale address: $ip"
    fi
done
pass "Tailscale delivery validation accepts only assigned tailnet ranges"

MOUNT_POINT="${TEST_DIR}/mnt/data"
PROC_MOUNTS="${TEST_DIR}/proc-mounts"
mkdir -p "$MOUNT_POINT"

printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
data_mount_is_safe || fail "valid persistent rw mount was rejected"

printf 'overlay %s overlay rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "overlay fallback was accepted"; fi

printf '/dev/sda1 %s ext4 ro,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "read-only mount was accepted"; fi

printf '/dev/sda1 %s-old ext4 rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "mount-path substring was accepted"; fi
pass "mount guard requires an exact persistent read-write filesystem"

DATA_DIR="${TEST_DIR}/migration"
DB_PATH="${DATA_DIR}/history.db"
mkdir -p "$DATA_DIR"
printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"

# Model the exact pre-hardening service_health shape so init_db must exercise
# every additive ALTER instead of merely observing a freshly created table.
sqlite3 "$DB_PATH" '
    CREATE TABLE service_health (
        ts INTEGER,
        service TEXT,
        boot_id TEXT,
        status TEXT,
        reason TEXT,
        healthy INTEGER,
        connected INTEGER,
        degraded INTEGER,
        local_api_responsive INTEGER,
        backend_state TEXT,
        key_expiry TEXT,
        condition_since_at INTEGER,
        connected_since_at INTEGER,
        connectivity_uptime_seconds INTEGER,
        peer_state TEXT,
        peer_reachable INTEGER,
        recovery_attempted INTEGER,
        recovery_count INTEGER,
        PRIMARY KEY (ts, service)
    );
'
init_db >/dev/null
sqlite3 "$DB_PATH" "
    INSERT INTO metrics
    VALUES (1, '0.1 0.2 0.3', 10, 40000,
            '{' || char(92) || char(34) || 'vps' || char(92) || char(34) || ':10}',
            '{' || char(92) || char(34) || 'wan1' || char(92) || char(34) || ':1}');
"
[ "$(sqlite3 "$DB_PATH" 'SELECT json_valid(wan_pings) AND json_valid(iface_status) FROM metrics;')" = "0" ] ||
    fail "legacy fixture unexpectedly started valid"
init_db >/dev/null
[ "$(sqlite3 "$DB_PATH" 'SELECT json_valid(wan_pings) AND json_valid(iface_status) FROM metrics;')" = "1" ] ||
    fail "legacy JSON migration did not repair stored rows"
columns="$(sqlite3 "$DB_PATH" 'PRAGMA table_info(service_health);' | cut -d'|' -f2)"
for column in connected degraded local_api_responsive key_expiry \
    control_online process_generation process_uptime_seconds \
    connectivity_uptime_seconds peer_state recovery_attempted
do
    printf '%s\n' "$columns" | grep -qx "$column" ||
        fail "service_health is missing $column"
done
pass "database migration repairs legacy JSON and installs uptime schema"

grep -Fq 'logread -f 9>&- >> "$LOG_PATH"' "$COLLECTOR" ||
    fail "indefinite logread child still inherits the collector lock"
grep -Fq 'sleep 60 9>&-' "$COLLECTOR" ||
    fail "collection sleep still inherits the collector lock"
pass "long-lived collector children close the singleton lock descriptor"

sqlite3 "$DB_PATH" "
    INSERT INTO client_traffic
        (ts, ip, mac, hostname, rx_bytes, tx_bytes)
    VALUES (1, '10.0.0.2', 'aa:bb:cc:dd:ee:ff', 'fixture', 10, 20);
    INSERT INTO client_traffic_hourly
        (hour_ts, ip, mac, hostname, rx_bytes, tx_bytes)
    VALUES (0, '10.0.0.2', 'aa:bb:cc:dd:ee:ff', 'fixture', 5, 7);
    CREATE TRIGGER fail_raw_delete
    BEFORE DELETE ON client_traffic
    BEGIN
        SELECT RAISE(ABORT, 'forced delete failure');
    END;
"
ITERATION_WRITE_FAILED=0
if rollup_client_traffic >/dev/null 2>&1; then
    fail "forced rollup delete failure unexpectedly committed"
fi
[ "$(sqlite3 "$DB_PATH" "SELECT rx_bytes FROM client_traffic_hourly WHERE ip='10.0.0.2';")" = "5" ] ||
    fail "failed rollup partially committed and double-counted hourly traffic"
[ "$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM client_traffic WHERE ip='10.0.0.2';")" = "1" ] ||
    fail "failed rollup lost its raw traffic row"
sqlite3 "$DB_PATH" "DROP TRIGGER fail_raw_delete; DELETE FROM client_traffic; DELETE FROM client_traffic_hourly;"
pass "client rollup insert and raw deletion are one atomic transaction"

HANG_SQLITE="${TEST_DIR}/hang-sqlite"
cat > "$HANG_SQLITE" <<'EOF'
#!/bin/sh
fifo="${TMPDIR:-/tmp}/jammonitor-sqlite-hang.$$"
mkfifo "$fifo"
read -r ignored < "$fifo"
EOF
chmod 0755 "$HANG_SQLITE"
SQLITE_CMD="$HANG_SQLITE"
if sqlite_read "SELECT 1;" >/dev/null 2>&1; then
    fail "hanging SQLite command escaped the external deadline"
else
    sqlite_timeout_rc=$?
fi
[ "$sqlite_timeout_rc" -eq 124 ] ||
    fail "hanging SQLite deadline returned $sqlite_timeout_rc instead of 124"
pass "every collector SQLite call crosses an external deadline"

REAL_SQLITE="$(command -v sqlite3)"
SQLITE_CMD="$REAL_SQLITE"
TIMEOUT_CMD="$MOCK_TIMEOUT"
CONNTRACK_CMD="$HANG_SQLITE"
CONNTRACK_TIMEOUT_SECONDS=1
CLIENT_SNAPSHOT="${TEST_DIR}/hanging-conntrack"
ITERATION_WRITE_FAILED=0
if collect_client_traffic >/dev/null 2>&1; then
    fail "hanging conntrack command escaped the external deadline"
fi
[ "$ITERATION_WRITE_FAILED" -eq 1 ] ||
    fail "conntrack deadline did not poison the collection cycle"
[ ! -e "${CLIENT_SNAPSHOT}.current" ] &&
    [ ! -e "${CLIENT_SNAPSHOT}.conntrack" ] ||
    fail "conntrack deadline left a partial snapshot"
pass "conntrack collection has a real external deadline and fails closed"

FIXTURE_CONNTRACK="${TEST_DIR}/fixture-conntrack"
cat > "$FIXTURE_CONNTRACK" <<'EOF'
#!/bin/sh
printf '%s\n' 'tcp 6 100 ESTABLISHED src=10.0.0.2 dst=1.1.1.1 sport=123 dport=443 packets=1 bytes=150 src=1.1.1.1 dst=10.0.0.2 sport=443 dport=123 packets=1 bytes=260 [ASSURED]'
EOF
chmod 0755 "$FIXTURE_CONNTRACK"
CONNTRACK_CMD="$FIXTURE_CONNTRACK"
CLIENT_SNAPSHOT="${TEST_DIR}/client-counters"
printf '%s\n' '10.0.0.2 100 200' > "${CLIENT_SNAPSHOT}.last"
sqlite3 "$DB_PATH" "
    CREATE TRIGGER fail_client_insert
    BEFORE INSERT ON client_traffic
    BEGIN
        SELECT RAISE(ABORT, 'forced client insert failure');
    END;
"
ITERATION_WRITE_FAILED=0
if collect_client_traffic >/dev/null 2>&1; then
    fail "forced client batch failure unexpectedly succeeded"
fi
[ "$(cat "${CLIENT_SNAPSHOT}.last")" = "10.0.0.2 100 200" ] ||
    fail "failed client batch advanced its counter baseline"
sqlite3 "$DB_PATH" "DROP TRIGGER fail_client_insert;"
ITERATION_WRITE_FAILED=0
collect_client_traffic >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT rx_bytes || ':' || tx_bytes FROM client_traffic WHERE ip='10.0.0.2' ORDER BY ts DESC LIMIT 1;")" = "60:50" ] ||
    fail "retry after a failed client batch lost or double-counted traffic"
[ "$(cat "${CLIENT_SNAPSHOT}.last")" = "10.0.0.2 150 260" ] ||
    fail "successful client batch did not advance its counter baseline"
pass "traffic counter baselines advance only after an atomic database batch"

SELECTIVE_SQLITE="${TEST_DIR}/selective-sqlite"
REAL_SQLITE="$(command -v sqlite3)"
cat > "$SELECTIVE_SQLITE" <<EOF
#!/bin/sh
case "\${2:-}" in
    *service_health*) exit 9 ;;
esac
exec "$REAL_SQLITE" "\$@"
EOF
chmod 0755 "$SELECTIVE_SQLITE"
SQLITE_CMD="$SELECTIVE_SQLITE"
DB_PATH="${DATA_DIR}/history.db"
ITERATION_WRITE_FAILED=0
if sqlite_write "INSERT INTO service_health (ts, service) VALUES (999, 'tailscale');" \
    >/dev/null 2>&1
then
    fail "selective essential-table failure unexpectedly succeeded"
fi
[ "$ITERATION_WRITE_FAILED" -eq 1 ] ||
    fail "an essential non-metrics write did not poison the collection cycle"
pass "any essential table write failure marks the collection cycle unhealthy"

SQLITE_CMD="$REAL_SQLITE"
jsonfilter() {
    [ "${1:-}" = "-i" ] || return 2
    [ "${3:-}" = "-e" ] || return 2
    case "$4" in
        '@.schema') printf '%s\n' "$FIXTURE_SCHEMA" ;;
        '@.observed_at') printf '%s\n' "$FIXTURE_OBSERVED" ;;
        '@.status') printf '%s\n' "$FIXTURE_STATUS" ;;
        '@.reason') printf '%s\n' "$FIXTURE_REASON" ;;
        '@.backend_state') printf '%s\n' "$FIXTURE_BACKEND" ;;
        '@.tailscale_ip') printf '%s\n' "$FIXTURE_IP" ;;
        '@.healthy') printf '%s\n' "$FIXTURE_HEALTHY" ;;
        '@.connected') printf '%s\n' "$FIXTURE_CONNECTED" ;;
        '@.degraded') printf '%s\n' "$FIXTURE_DEGRADED" ;;
        '@.local_api_responsive') printf '%s\n' "$FIXTURE_LOCAL_API" ;;
        '@.control_online') printf '%s\n' "$FIXTURE_CONTROL_ONLINE" ;;
        '@.process_generation') printf '%s\n' "$FIXTURE_PROCESS_GENERATION" ;;
        '@.process_uptime_seconds') printf '%s\n' "$FIXTURE_PROCESS_UPTIME" ;;
        '@.installed') printf '%s\n' "$FIXTURE_INSTALLED" ;;
        '@.service_enabled') printf '%s\n' "$FIXTURE_ENABLED" ;;
        '@.service_running') printf '%s\n' "$FIXTURE_RUNNING" ;;
        '@.tun_available') printf '%s\n' "$FIXTURE_TUN" ;;
        '@.in_engine') printf '%s\n' "$FIXTURE_ENGINE" ;;
        '@.key_expiry') printf '%s\n' '0001-01-01T00:00:00Z' ;;
        '@.condition_since_at'|'@.connected_since_at') printf '%s\n' "$FIXTURE_OBSERVED" ;;
        '@.connectivity_uptime_seconds'|'@.recovery_attempted'|'@.recovery_count') printf '0\n' ;;
        '@.peer_state') printf 'not_configured\n' ;;
        '@.peer_reachable') printf 'null\n' ;;
        *) return 1 ;;
    esac
}

RUNTIME_DIR="${TEST_DIR}/watchdog-runtime"
mkdir -p "$RUNTIME_DIR"
: > "${RUNTIME_DIR}/tailscale-watchdog.json"
FIXTURE_OBSERVED="$(date +%s)"
FIXTURE_SCHEMA=2
FIXTURE_STATUS=running
FIXTURE_REASON=ok
FIXTURE_BACKEND=Running
FIXTURE_IP=100.104.78.42
FIXTURE_HEALTHY=true
FIXTURE_CONNECTED=true
FIXTURE_DEGRADED=false
FIXTURE_LOCAL_API=true
FIXTURE_CONTROL_ONLINE=true
FIXTURE_PROCESS_GENERATION=4242:10000
FIXTURE_PROCESS_UPTIME=100
FIXTURE_INSTALLED=true
FIXTURE_ENABLED=true
FIXTURE_RUNNING=true
FIXTURE_TUN=true
FIXTURE_ENGINE=true
ITERATION_WRITE_FAILED=0
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy || ':' || connected FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "running:1:1" ] ||
    fail "valid schema-2 watchdog snapshot was rejected"
[ "$(sqlite3 "$DB_PATH" "SELECT control_online || ':' || process_generation || ':' || process_uptime_seconds FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "1:4242:10000:100" ] ||
    fail "control-plane and process-generation evidence was not retained"

FIXTURE_SCHEMA=1
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy || ':' || COALESCE(connected, -1) FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0:-1" ] ||
    fail "unknown watchdog schema created historical uptime"

FIXTURE_SCHEMA=2
FIXTURE_TUN=false
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot without a usable TUN created historical uptime"

FIXTURE_TUN=true
FIXTURE_ENGINE=false
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot outside the engine created historical uptime"

FIXTURE_ENGINE=true
FIXTURE_BACKEND=NeedsLogin
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot with a non-Running backend created historical uptime"

FIXTURE_BACKEND=Running
FIXTURE_CONTROL_ONLINE=false
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot with an offline control plane created historical uptime"

FIXTURE_CONTROL_ONLINE=true
FIXTURE_PROCESS_GENERATION=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot without a proven process generation created historical uptime"

FIXTURE_PROCESS_GENERATION=4242:10000
FIXTURE_PROCESS_UPTIME=not-a-number
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot with malformed process uptime created historical uptime"

FIXTURE_PROCESS_GENERATION=4242:10000
FIXTURE_PROCESS_UPTIME=100
FIXTURE_STATUS=socket_missing
FIXTURE_REASON=localapi_socket_missing
FIXTURE_HEALTHY=false
FIXTURE_CONNECTED=false
FIXTURE_DEGRADED=false
FIXTURE_LOCAL_API=false
FIXTURE_CONTROL_ONLINE=null
FIXTURE_TUN=null
FIXTURE_ENGINE=null
FIXTURE_BACKEND=
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || reason || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "socket_missing:localapi_socket_missing:0" ] ||
    fail "valid missing-socket recovery state was rejected"
pass "historical Tailscale uptime requires schema 2 and all delivery invariants"

SQLITE_CMD="$REAL_SQLITE"
STATUS_FILE="${TEST_DIR}/collector-status.json"
now="$(date +%s)"
COLLECTOR_STARTED_AT="$now"
LAST_SAMPLE_AT="$now"
LAST_SUCCESS_AT=0
CONSECUTIVE_WRITE_FAILURES=0
QUICK_CHECK=ok
publish_collector_status
grep -q '"healthy":false' "$STATUS_FILE" ||
    fail "a pre-start sample made startup readiness healthy"
LAST_SUCCESS_AT="$now"
publish_collector_status
grep -q '"healthy":true' "$STATUS_FILE" ||
    fail "a successful post-start cycle did not become healthy"
pass "collector readiness requires a success from the current service start"

LUA_CONTROLLER="${REPO_DIR}/jammonitor.lua"
if grep -n 'sys\.exec("sqlite3' "$LUA_CONTROLLER" >/dev/null 2>&1; then
    fail "Lua controller still contains an unbounded sqlite3 sys.exec"
fi
if grep -n 'sys\.exec("df /mnt/data' "$LUA_CONTROLLER" >/dev/null 2>&1; then
    fail "Lua controller still contains an unbounded df /mnt/data call"
fi
grep -q 'result.sample_after_start' "$LUA_CONTROLLER" ||
    fail "storage initialization lacks a post-start sample gate"
grep -q 'result.collector_report_ready' "$LUA_CONTROLLER" ||
    fail "storage initialization lacks a current collector-report gate"
pass "Lua storage and history subprocesses have static deadline and readiness gates"

MOCK_PROC_STAT="${TEST_DIR}/proc-stat"
cat > "$MOCK_PROC_STAT" <<'EOF'
#!/bin/sh
printf '123 (jammonitor-collect) S'
i=1
while [ "$i" -le 18 ]; do
    printf ' 0'
    i=$((i + 1))
done
printf ' 10000\n'
EOF
chmod 0755 "$MOCK_PROC_STAT"

MISSING_MOUNT="${TEST_DIR}/missing-data"
MISSING_RUNTIME="${TEST_DIR}/missing-runtime"
MISSING_PID="${TEST_DIR}/missing.pid"
MISSING_MOUNTS="${TEST_DIR}/missing-mounts"
: > "$MISSING_MOUNTS"
if JAMMONITOR_LIB_ONLY=0 \
   JAMMONITOR_MOUNT_POINT="$MISSING_MOUNT" \
   JAMMONITOR_RUNTIME_DIR="$MISSING_RUNTIME" \
   JAMMONITOR_PIDFILE="$MISSING_PID" \
   JAMMONITOR_LOCK_FILE="${TEST_DIR}/missing.lock" \
   JAMMONITOR_FLOCK_CMD="$MOCK_FLOCK" \
   JAMMONITOR_TEST_FLOCK_STATE="${TEST_DIR}/missing.mock-flock" \
   JAMMONITOR_PROC_STAT_CMD="$MOCK_PROC_STAT" \
   JAMMONITOR_PROC_MOUNTS="$MISSING_MOUNTS" \
   JAMMONITOR_CONNTRACK_CMD=/usr/bin/true \
   JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
   "$COLLECTOR" >/dev/null 2>&1
then
    fail "collector started without the persistent mount"
fi
[ ! -e "${MISSING_MOUNT}/jammonitor" ] ||
    fail "collector created an internal-flash fallback directory"
[ ! -e "$MISSING_PID" ] ||
    fail "collector left a stale PID after mount refusal"
pass "missing USB fails closed before any data directory or stale PID"

CORRUPT_MOUNT="${TEST_DIR}/corrupt-data"
CORRUPT_RUNTIME="${TEST_DIR}/corrupt-runtime"
CORRUPT_PID="${TEST_DIR}/corrupt.pid"
CORRUPT_MOUNTS="${TEST_DIR}/corrupt-mounts"
mkdir -p "${CORRUPT_MOUNT}/jammonitor"
printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$CORRUPT_MOUNT" > "$CORRUPT_MOUNTS"
printf '%s\n' 'not a sqlite database' > "${CORRUPT_MOUNT}/jammonitor/history.db"
if JAMMONITOR_LIB_ONLY=0 \
   JAMMONITOR_MOUNT_POINT="$CORRUPT_MOUNT" \
   JAMMONITOR_RUNTIME_DIR="$CORRUPT_RUNTIME" \
   JAMMONITOR_PIDFILE="$CORRUPT_PID" \
   JAMMONITOR_LOCK_FILE="${TEST_DIR}/corrupt.lock" \
   JAMMONITOR_FLOCK_CMD="$MOCK_FLOCK" \
   JAMMONITOR_TEST_FLOCK_STATE="${TEST_DIR}/corrupt.mock-flock" \
   JAMMONITOR_PROC_STAT_CMD="$MOCK_PROC_STAT" \
   JAMMONITOR_PROC_MOUNTS="$CORRUPT_MOUNTS" \
   JAMMONITOR_CONNTRACK_CMD=/usr/bin/true \
   JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
   "$COLLECTOR" >/dev/null 2>&1
then
    fail "collector continued with corrupt SQLite"
fi
[ ! -e "$CORRUPT_PID" ] || fail "collector left PID after SQLite failure"
grep -q '"database_quick_check":"failed"' \
    "${CORRUPT_RUNTIME}/collector-status.json" ||
    fail "collector did not publish its SQLite initialization failure"
pass "corrupt SQLite exits visibly for supervised handling"

printf '1..%s\n' "$PASS_COUNT"
