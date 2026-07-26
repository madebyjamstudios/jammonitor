#!/bin/sh

set -eu

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
COLLECTOR="${REPO_DIR}/router/jammonitor-collect"
TEST_TMP_ROOT="${TMPDIR:-/tmp}"
TEST_TMP_ROOT="${TEST_TMP_ROOT%/}"
TEST_DIR="$(mktemp -d "${TEST_TMP_ROOT}/jammonitor-collector-test.XXXXXX")"
cleanup_test_dir() {
    for lifecycle_pid_file in "$TEST_DIR"/lifecycle-*.pid; do
        [ -f "$lifecycle_pid_file" ] || continue
        lifecycle_pid="$(cat "$lifecycle_pid_file" 2>/dev/null || true)"
        case "$lifecycle_pid" in
            ""|*[!0-9]*) continue ;;
        esac
        kill "$lifecycle_pid" 2>/dev/null || true
    done
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

grep -Fq \
    'CLIENT_SNAPSHOT="${JAMMONITOR_CLIENT_SNAPSHOT:-${RUNTIME_DIR}/client-traffic}"' \
    "$COLLECTOR" ||
    fail "client counter scratch files are not rooted in private runtime state"
if grep -Fq 'CLIENT_SNAPSHOT="/tmp/' "$COLLECTOR"; then
    fail "client counter scratch files still use attacker-writable /tmp"
fi
pass "client counter scratch files stay inside private runtime state"

grep -Fq 'if [ -L "$RUNTIME_DIR" ]; then' "$COLLECTOR" ||
    fail "collector startup does not reject a symlink runtime directory"
grep -Fq 'chmod 0700 "$RUNTIME_DIR" || exit 1' "$COLLECTOR" ||
    fail "collector startup does not enforce a private runtime directory"
pass "collector scratch directory fails closed on symlinks and enforces mode 0700"

grep -Fq 'ulimit -f "$CONNTRACK_SNAPSHOT_BLOCKS"' "$COLLECTOR" ||
    fail "conntrack producer lacks a kernel file-size ceiling"
grep -Fq \
    'exec "$TIMEOUT_CMD" -s TERM -k 2 "$CONNTRACK_TIMEOUT_SECONDS" \' \
    "$COLLECTOR" ||
    fail "conntrack producer lacks a TERM and kill-after deadline"
pass "conntrack producer is bounded before its private snapshot is parsed"

grep -Fq 'storage_data_tree_is_safe() {' "$COLLECTOR" ||
    fail "collector lacks mounted-data tree confinement"
grep -Fq 'storage_leaf_names_are_line_safe() {' "$COLLECTOR" ||
    fail "collector lacks a pre-parse newline pathname rejection gate"
grep -Fq '"$STAT_CMD" -c '\''%F|%u|%g|%h|%a'\''' "$COLLECTOR" ||
    fail "collector does not prove type, owner, link count, and mode for persistent leaves"
grep -Fq '[ "$_storage_count" -le 64 ]' "$COLLECTOR" ||
    fail "collector does not bound persistent data-tree fanout"
grep -Fq 'DATA_DIR="${FD_ROOT}/8"' "$COLLECTOR" ||
    fail "collector does not pin the verified data directory itself"
pass "persistent writes are confined to one root-owned non-symlink data tree"

grep -Fq 'ROTATED="${LOG_PATH}.old"' "$COLLECTOR" ||
    fail "syslog rotation does not use one fixed archive"
if grep -Fq 'ROTATED="${LOG_PATH}.$(date +%s)"' "$COLLECTOR"; then
    fail "syslog rotation can still create unbounded timestamped leaves"
fi
pass "syslog producer cannot create unbounded timestamped rotations"

grep -Fq \
    '! migrate_legacy_syslog_rotations "$_pinned_data_dir" ||' \
    "$COLLECTOR" ||
    fail "collector does not migrate legacy rotations before fanout rejection"
grep -Fq 'storage_sync_barrier || {' "$COLLECTOR" ||
    fail "legacy migration can delete archives before a durable preserve barrier"
if grep -Fq 'find "$DATA_DIR"' "$COLLECTOR"; then
    fail "post-start cleanup still relies on find descending an fd symlink"
fi
pass "legacy rotation migration precedes the bounded tree gate and cleanup is descriptor-relative"

MOCK_TIMEOUT="${TEST_DIR}/timeout"
cat > "$MOCK_TIMEOUT" <<'EOF'
#!/bin/sh
if [ -n "${MOCK_TIMEOUT_ARGS_FILE:-}" ]; then
    printf '%s\n' "$*" >> "$MOCK_TIMEOUT_ARGS_FILE"
fi
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|-k|--signal|--kill-after)
            [ "$#" -ge 2 ] || exit 64
            shift 2
            ;;
        --signal=*|--kill-after=*)
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done
[ "$#" -ge 2 ] || exit 64
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

FAST_TIMEOUT="${TEST_DIR}/fast-timeout"
cat > "$FAST_TIMEOUT" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s|-k|--signal|--kill-after)
            [ "$#" -ge 2 ] || exit 64
            shift 2
            ;;
        --signal=*|--kill-after=*)
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            break
            ;;
    esac
done
[ "$#" -ge 2 ] || exit 64
shift
exec "$@"
EOF
chmod 0755 "$FAST_TIMEOUT"

RANDOM_UUID_FIXTURE="${TEST_DIR}/random-uuid"
printf '%s\n' '12345678-1234-4abc-8def-1234567890ab' \
    >"$RANDOM_UUID_FIXTURE"
if [ -d /proc/self/fd ]; then
    PROCESS_FD_ROOT=/proc/self/fd
else
    PROCESS_FD_ROOT=/dev/fd
fi

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

MOCK_STAT="${TEST_DIR}/stat"
PYTHON3_BIN="$(command -v python3)"
cat > "$MOCK_STAT" <<EOF
#!${PYTHON3_BIN}
import os
import stat
import sys

args = sys.argv[1:]
follow = False
if args and args[0] == "-L":
    follow = True
    args = args[1:]
if len(args) != 3 or args[0] != "-c":
    raise SystemExit(64)
fmt = args[1]
path = args[2]
if path == "/dev/sda1" and fmt == "%F|%t:%T":
    print("block special file|8:1")
    raise SystemExit(0)
if follow and path in ("/dev/fd/8", "/proc/self/fd/8") and fmt == "%d":
    # macOS's fdesc view reports the pseudo-filesystem device for /dev/fd/N,
    # unlike Linux procfs. Model production's followed descriptor target.
    print(os.fstat(8).st_dev)
    raise SystemExit(0)
value = os.stat(path) if follow else os.lstat(path)
reported_uid = value.st_uid
if os.environ.get("JAMMONITOR_TEST_FOREIGN_PATH") == path:
    reported_uid += 1
kind = (
    "regular file" if stat.S_ISREG(value.st_mode)
    else "directory" if stat.S_ISDIR(value.st_mode)
    else "other"
)
if fmt == "%u:%F:%d:%i:%s:%Y":
    print(
        f"{reported_uid}:{kind}:{value.st_dev}:{value.st_ino}:"
        f"{value.st_size}:{int(value.st_mtime)}"
    )
elif fmt == "%F|%u|%g|%a":
    print(
        f"{kind}|{reported_uid}|{value.st_gid}|"
        f"{stat.S_IMODE(value.st_mode):o}"
    )
elif fmt == "%F|%u|%h|%s":
    print(f"{kind}|{reported_uid}|{value.st_nlink}|{value.st_size}")
elif fmt == "%F|%u|%g|%a|%d|%i":
    print(
        f"{kind}|{reported_uid}|{value.st_gid}|"
        f"{stat.S_IMODE(value.st_mode):o}|{value.st_dev}|{value.st_ino}"
    )
elif fmt == "%F|%u|%g|%h|%a":
    print(
        f"{kind}|{reported_uid}|{value.st_gid}|{value.st_nlink}|"
        f"{stat.S_IMODE(value.st_mode):o}"
    )
elif fmt == "%d":
    print(value.st_dev)
else:
    raise SystemExit(64)
EOF
chmod 0755 "$MOCK_STAT"

VOLATILE_RUNTIME="${TEST_DIR}/volatile-runtime"
mkdir -p "$VOLATILE_RUNTIME"
SAFE_VOLATILE="${TEST_DIR}/dhcp.leases"
printf '%s\n' '1 aa:bb:cc:dd:ee:ff 10.0.0.2 client *' > "$SAFE_VOLATILE"
SAVED_VOLATILE_RUNTIME="$RUNTIME_DIR"
SAVED_VOLATILE_STAT_CMD="$STAT_CMD"
SAVED_VOLATILE_UID="$EXPECTED_VOLATILE_UID"
SAVED_VOLATILE_TIMEOUT_CMD="$TIMEOUT_CMD"
SAVED_VOLATILE_DD_CMD="$DD_CMD"
SAVED_VOLATILE_MKTEMP_CMD="$MKTEMP_CMD"
RUNTIME_DIR="$VOLATILE_RUNTIME"
STAT_CMD="$MOCK_STAT"
EXPECTED_VOLATILE_UID="$(id -u)"
TIMEOUT_CMD="$FAST_TIMEOUT"
DD_CMD=dd
MKTEMP_CMD=mktemp
if ! pin_root_volatile_snapshot "$SAFE_VOLATILE" dhcp 1024 ||
   [ "$(cat "$VOLATILE_SNAPSHOT_FILE")" != \
     "1 aa:bb:cc:dd:ee:ff 10.0.0.2 client *" ]; then
    fail "bounded volatile snapshot rejected a valid root-authority fixture"
fi
release_volatile_snapshot

ln -s "$SAFE_VOLATILE" "${TEST_DIR}/dhcp-link"
if pin_root_volatile_snapshot "${TEST_DIR}/dhcp-link" dhcp 1024; then
    fail "volatile snapshot followed a symbolic link"
fi
mkfifo "${TEST_DIR}/dhcp-fifo"
if pin_root_volatile_snapshot "${TEST_DIR}/dhcp-fifo" dhcp 1024; then
    fail "volatile snapshot opened a FIFO"
fi
dd if=/dev/zero of="${TEST_DIR}/dhcp-oversized" bs=1025 count=1 \
    >/dev/null 2>&1
if pin_root_volatile_snapshot "${TEST_DIR}/dhcp-oversized" dhcp 1024; then
    fail "volatile snapshot accepted an oversized source"
fi
[ -z "$VOLATILE_SNAPSHOT_FILE" ] ||
    fail "rejected volatile input left a private snapshot behind"
pass "DHCP and resolver inputs are single-inode bounded regular snapshots"
RUNTIME_DIR="$SAVED_VOLATILE_RUNTIME"
STAT_CMD="$SAVED_VOLATILE_STAT_CMD"
EXPECTED_VOLATILE_UID="$SAVED_VOLATILE_UID"
TIMEOUT_CMD="$SAVED_VOLATILE_TIMEOUT_CMD"
DD_CMD="$SAVED_VOLATILE_DD_CMD"
MKTEMP_CMD="$SAVED_VOLATILE_MKTEMP_CMD"

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

for ip in \
    100.64.0.0 \
    100.127.255.255 \
    fd7a:115c:a1e0:: \
    fd7a:115c:a1e0::1 \
    fd7a:115c:a1e0:0:0:0:0:1 \
    fd7a:115c:a1e0:1:2:3:4:: \
    FD7A:115C:A1E0:ABCD:0:1:2:3
do
    is_tailscale_ip "$ip" || fail "expected Tailscale address: $ip"
done
for ip in \
    10.0.0.1 \
    100.63.255.255 \
    100.128.0.1 \
    100.064.0.1 \
    100.64.00.1 \
    100.64.0.256 \
    100.64.0.1. \
    100.64..1 \
    8.8.8.8 \
    fd00::1 \
    fd7a:115c:a1df::1 \
    fd7a:115c:a1e0: \
    fd7a:115c:a1e0:1:2:3:4 \
    fd7a:115c:a1e0:1:2:3:4:5:6 \
    fd7a:115c:a1e0::1:2:3:4:5 \
    fd7a:115c:a1e0::1::2 \
    fd7a:115c:a1e0:::1 \
    fd7a:115c:a1e0:00000::1 \
    fd7a:115c:a1e0::1%tailscale0 \
    fd7a:115c:a1e0::192.0.2.1
do
    if is_tailscale_ip "$ip"; then
        fail "unexpected Tailscale address: $ip"
    fi
done
if is_tailscale_ip " fd7a:115c:a1e0::1"; then
    fail "whitespace-prefixed Tailscale address was accepted"
fi
pass "Tailscale delivery validation is exact for IPv4 and IPv6 literals"

MOUNT_POINT="${TEST_DIR}/mnt/data"
PROC_MOUNTS="${TEST_DIR}/proc-mounts"
mkdir -p "$MOUNT_POINT"

printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
data_mount_is_safe || fail "valid persistent rw mount was rejected"

printf 'overlay %s overlay rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "overlay fallback was accepted"; fi

printf '/dev/sda1 %s ext4 ro,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "read-only mount was accepted"; fi

printf '/dev/sda1 %s ext4 rw,ro,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "contradictory read-write/read-only options were accepted"; fi

printf '/dev/sda1 %s vfat rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "non-ext4 filesystem was accepted"; fi

printf '/dev/sda1 %s-old ext4 rw,relatime 0 0\n' "$MOUNT_POINT" > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "mount-path substring was accepted"; fi

{
    printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT"
    printf 'overlay %s overlay rw,relatime 0 0\n' "$MOUNT_POINT"
} > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "stacked overlay after ext4 was accepted"; fi

{
    printf 'overlay %s overlay rw,relatime 0 0\n' "$MOUNT_POINT"
    printf '/dev/sda1 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT"
} > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "stacked ext4 after overlay was accepted"; fi

{
    printf '/dev/sda1 %s ext4 ro,relatime 0 0\n' "$MOUNT_POINT"
    printf '/dev/sda2 %s ext4 rw,relatime 0 0\n' "$MOUNT_POINT"
} > "$PROC_MOUNTS"
if data_mount_is_safe; then fail "duplicate ext4 mount rows were accepted"; fi

pass "mount guard requires exactly one ext4 read-write filesystem"

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

grep -Fq 'exec 7>>"$LOG_PATH"' "$COLLECTOR" ||
    fail "syslog guardian does not open the pinned log before dropping descriptors"
grep -Fq 'exec 8<&-' "$COLLECTOR" ||
    fail "syslog guardian still inherits the mount-pin descriptor"
grep -Fq 'exec 9>&-' "$COLLECTOR" ||
    fail "syslog guardian still inherits the collector singleton descriptor"
grep -Fq '"$LOGREAD_CMD" -f 6>&- 8>&- 9>&- >&7' "$COLLECTOR" ||
    fail "logread child inherits a collector-owned or stream-lock descriptor"
grep -Fq 'sleep 60 8>&- 9>&-' "$COLLECTOR" ||
    fail "collection sleep inherits the mount pin or singleton lock"
pass "long-lived collector children drop mount and singleton descriptors"

MOCK_GENERATION_STAT="${TEST_DIR}/generation-stat"
cat > "$MOCK_GENERATION_STAT" <<'EOF'
#!/bin/sh
path="${1:-}"
pid="${path%/stat}"
pid="${pid##*/}"
case "$pid" in ""|*[!0-9]*) exit 1 ;; esac
kill -0 "$pid" 2>/dev/null || exit 1
state="${JAMMONITOR_TEST_PROC_STATE:-S}"
ticks="${JAMMONITOR_TEST_PROC_START_TICKS:-$pid}"
printf '%s (jammonitor-collect) %s' "$pid" "$state"
i=1
while [ "$i" -le 18 ]; do
    printf ' 0'
    i=$((i + 1))
done
printf ' %s\n' "$ticks"
EOF
chmod 0755 "$MOCK_GENERATION_STAT"

SAVED_PROC_STAT_CMD="$PROC_STAT_CMD"
SAVED_PROC_ROOT="$PROC_ROOT"
PROC_STAT_CMD="$MOCK_GENERATION_STAT"
PROC_ROOT="${TEST_DIR}/proc"
JAMMONITOR_TEST_PROC_START_TICKS="$$"
JAMMONITOR_TEST_PROC_STATE=S
export JAMMONITOR_TEST_PROC_START_TICKS JAMMONITOR_TEST_PROC_STATE
collector_generation_is_live "$$" "$$" ||
    fail "current collector generation was rejected"
if collector_generation_is_live "$$" "$(($$ + 1))"; then
    fail "collector PID with a different start tick was accepted"
fi
JAMMONITOR_TEST_PROC_STATE=Z
export JAMMONITOR_TEST_PROC_STATE
if collector_generation_is_live "$$" "$$"; then
    fail "zombie collector generation was accepted as live"
fi
PROC_STAT_CMD="$SAVED_PROC_STAT_CMD"
PROC_ROOT="$SAVED_PROC_ROOT"
unset JAMMONITOR_TEST_PROC_START_TICKS JAMMONITOR_TEST_PROC_STATE
pass "stream ownership requires the exact live non-zombie parent generation"

MOCK_LOGREAD="${TEST_DIR}/logread"
cat > "$MOCK_LOGREAD" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-f" ] || exit 64
events="${JAMMONITOR_TEST_SYSLOG_EVENTS:?}"
instance="${JAMMONITOR_TEST_SYSLOG_INSTANCE:?}"
pid_file="${JAMMONITOR_TEST_LOGREAD_PID_FILE:?}"
printf '%s\n' "$$" > "$pid_file"
if ( : <&6 ) 2>/dev/null; then
    printf 'leak %s fd6\n' "$instance" >> "$events"
fi
if ( : <&8 ) 2>/dev/null; then
    printf 'leak %s fd8\n' "$instance" >> "$events"
fi
if ( : <&9 ) 2>/dev/null; then
    printf 'leak %s fd9\n' "$instance" >> "$events"
fi
printf 'start %s %s\n' "$instance" "$$" >> "$events"
finish() {
    trap - HUP INT TERM
    printf 'stop %s %s\n' "$instance" "$$" >> "$events"
    exit 0
}
if [ "${JAMMONITOR_TEST_LOGREAD_IGNORE_TERM:-0}" = "1" ]; then
    printf 'ignore %s %s\n' "$instance" "$$" >> "$events"
    trap '' HUP INT TERM
else
    trap finish HUP INT TERM
fi
while :; do
    :
done
EOF
chmod 0755 "$MOCK_LOGREAD"

SYSLOG_WORKER="${TEST_DIR}/syslog-worker"
cat > "$SYSLOG_WORKER" <<'EOF'
#!/bin/sh
set -eu
collector="$1"
mock_flock="$2"
mock_generation="$3"
mock_logread="$4"
runtime_dir="$5"
log_path="$6"
events="$7"
instance="$8"
flock_state="$9"

JAMMONITOR_LIB_ONLY=1
export JAMMONITOR_LIB_ONLY
. "$collector"
unset JAMMONITOR_LIB_ONLY

RUNTIME_DIR="$runtime_dir"
PIDFILE="${runtime_dir}/collector.pid"
LOCK_FILE="${runtime_dir}/collector.lock"
SYSLOG_LOCK_FILE="${flock_state}.lock"
LOG_PATH="$log_path"
PROC_ROOT="${runtime_dir}/proc"
PROC_STAT_CMD="$mock_generation"
FLOCK_CMD="$mock_flock"
LOGREAD_CMD="$mock_logread"
COLLECTOR_START_TICKS="$$"
SYSLOG_PID=""
JAMMONITOR_TEST_FLOCK_STATE="$flock_state"
JAMMONITOR_TEST_PROC_START_TICKS="$$"
JAMMONITOR_TEST_PROC_STATE=S
JAMMONITOR_TEST_SYSLOG_EVENTS="$events"
JAMMONITOR_TEST_SYSLOG_INSTANCE="$instance"
JAMMONITOR_TEST_LOGREAD_PID_FILE="${runtime_dir}/logread.pid"
export JAMMONITOR_TEST_FLOCK_STATE JAMMONITOR_TEST_PROC_START_TICKS
export JAMMONITOR_TEST_PROC_STATE JAMMONITOR_TEST_SYSLOG_EVENTS
export JAMMONITOR_TEST_SYSLOG_INSTANCE JAMMONITOR_TEST_LOGREAD_PID_FILE

mkdir -p "$runtime_dir"
: > "${runtime_dir}/mount-pin"
: > "$LOCK_FILE"
exec 8<"${runtime_dir}/mount-pin"
exec 9<>"$LOCK_FILE"

worker_cleanup() {
    cleanup_processes
}
trap 'exit 0' HUP INT TERM
trap worker_cleanup EXIT

start_syslog_stream
printf '%s\n' "$SYSLOG_PID" > "${runtime_dir}/guardian.pid"
while :; do
    sleep 1 8>&- 9>&-
done
EOF
chmod 0755 "$SYSLOG_WORKER"

wait_for_event() {
    _event_pattern="$1"
    _event_attempts=0
    while ! grep -q "$_event_pattern" "$SYSLOG_EVENTS" 2>/dev/null; do
        _event_attempts=$((_event_attempts + 1))
        [ "$_event_attempts" -lt 200 ] ||
            fail "timed out waiting for syslog event: $_event_pattern"
        sleep 0.02
    done
}

wait_for_process_exit() {
    _exit_pid="$1"
    _exit_attempts=0
    while kill -0 "$_exit_pid" 2>/dev/null; do
        _exit_attempts=$((_exit_attempts + 1))
        [ "$_exit_attempts" -lt 400 ] ||
            fail "process $_exit_pid survived its collector generation"
        sleep 0.02
    done
}

SYSLOG_EVENTS="${TEST_DIR}/syslog-events"
SYSLOG_DATA="${TEST_DIR}/syslog.txt"
SYSLOG_FLOCK_STATE="${TEST_DIR}/syslog.mock-flock"
: > "$SYSLOG_EVENTS"
TEST_CHILD_SHELL="${JAMMONITOR_TEST_CHILD_SHELL:-sh}"
command -v "$TEST_CHILD_SHELL" >/dev/null 2>&1 ||
    fail "requested child shell is unavailable: $TEST_CHILD_SHELL"

FIRST_RUNTIME="${TEST_DIR}/lifecycle-first"
"$TEST_CHILD_SHELL" "$SYSLOG_WORKER" "$COLLECTOR" "$MOCK_FLOCK" \
    "$MOCK_GENERATION_STAT" "$MOCK_LOGREAD" "$FIRST_RUNTIME" \
    "$SYSLOG_DATA" "$SYSLOG_EVENTS" first "$SYSLOG_FLOCK_STATE" &
first_worker=$!
printf '%s\n' "$first_worker" > "${TEST_DIR}/lifecycle-first-worker.pid"
wait_for_event '^start first '
first_guardian="$(cat "${FIRST_RUNTIME}/guardian.pid")"
first_logread="$(cat "${FIRST_RUNTIME}/logread.pid")"
printf '%s\n' "$first_guardian" > "${TEST_DIR}/lifecycle-first-guardian.pid"
printf '%s\n' "$first_logread" > "${TEST_DIR}/lifecycle-first-logread.pid"

kill -KILL "$first_worker"
wait "$first_worker" 2>/dev/null || true

# Start the successor immediately. Its guardian may exist, but the dedicated
# stream lock must prevent its logread until the exact old generation is gone.
SECOND_RUNTIME="${TEST_DIR}/lifecycle-second"
"$TEST_CHILD_SHELL" "$SYSLOG_WORKER" "$COLLECTOR" "$MOCK_FLOCK" \
    "$MOCK_GENERATION_STAT" "$MOCK_LOGREAD" "$SECOND_RUNTIME" \
    "$SYSLOG_DATA" "$SYSLOG_EVENTS" second "$SYSLOG_FLOCK_STATE" &
second_worker=$!
printf '%s\n' "$second_worker" > "${TEST_DIR}/lifecycle-second-worker.pid"
wait_for_event '^stop first '
wait_for_event '^start second '
second_guardian="$(cat "${SECOND_RUNTIME}/guardian.pid")"
second_logread="$(cat "${SECOND_RUNTIME}/logread.pid")"
printf '%s\n' "$second_guardian" > "${TEST_DIR}/lifecycle-second-guardian.pid"
printf '%s\n' "$second_logread" > "${TEST_DIR}/lifecycle-second-logread.pid"

wait_for_process_exit "$first_guardian"
wait_for_process_exit "$first_logread"
if grep -q '^leak ' "$SYSLOG_EVENTS"; then
    fail "syslog child inherited a lifecycle descriptor: $(grep '^leak ' "$SYSLOG_EVENTS" | head -1)"
fi
event_order="$(awk '$1 == "start" || $1 == "stop" {
    printf "%s%s:%s", separator, $1, $2
    separator=","
}' "$SYSLOG_EVENTS")"
[ "$event_order" = "start:first,stop:first,start:second" ] ||
    fail "successor overlapped the killed collector stream: $event_order"

kill -TERM "$second_worker"
wait "$second_worker" 2>/dev/null || true
wait_for_event '^stop second '
wait_for_process_exit "$second_guardian"
wait_for_process_exit "$second_logread"
[ "$(grep -c '^start first ' "$SYSLOG_EVENTS")" -eq 1 ] &&
    [ "$(grep -c '^stop first ' "$SYSLOG_EVENTS")" -eq 1 ] &&
    [ "$(grep -c '^start second ' "$SYSLOG_EVENTS")" -eq 1 ] &&
    [ "$(grep -c '^stop second ' "$SYSLOG_EVENTS")" -eq 1 ] ||
    fail "syslog lifecycle emitted duplicate start or stop events"
pass "SIGKILL retires the exact old log stream before a successor starts"

STUBBORN_RUNTIME="${TEST_DIR}/lifecycle-stubborn"
stubborn_started_at="$(date +%s)"
JAMMONITOR_TEST_LOGREAD_IGNORE_TERM=1 \
"$TEST_CHILD_SHELL" "$SYSLOG_WORKER" "$COLLECTOR" "$MOCK_FLOCK" \
    "$MOCK_GENERATION_STAT" "$MOCK_LOGREAD" "$STUBBORN_RUNTIME" \
    "$SYSLOG_DATA" "$SYSLOG_EVENTS" stubborn "$SYSLOG_FLOCK_STATE" &
stubborn_worker=$!
printf '%s\n' "$stubborn_worker" \
    > "${TEST_DIR}/lifecycle-stubborn-worker.pid"
wait_for_event '^start stubborn '
wait_for_event '^ignore stubborn '
stubborn_guardian="$(cat "${STUBBORN_RUNTIME}/guardian.pid")"
stubborn_logread="$(cat "${STUBBORN_RUNTIME}/logread.pid")"
printf '%s\n' "$stubborn_guardian" \
    > "${TEST_DIR}/lifecycle-stubborn-guardian.pid"
printf '%s\n' "$stubborn_logread" \
    > "${TEST_DIR}/lifecycle-stubborn-logread.pid"
kill -TERM "$stubborn_worker"
wait "$stubborn_worker" 2>/dev/null || true
wait_for_process_exit "$stubborn_guardian"
wait_for_process_exit "$stubborn_logread"
stubborn_elapsed=$(($(date +%s) - stubborn_started_at))
[ "$stubborn_elapsed" -le $((SYSLOG_STOP_GRACE_SECONDS + 4)) ] ||
    fail "TERM-ignoring logread exceeded its forced-stop deadline"
if grep -q '^stop stubborn ' "$SYSLOG_EVENTS"; then
    fail "TERM-ignoring logread fixture did not require forced termination"
fi
pass "TERM-ignoring logread is killed and reaped within a bounded deadline"

if ! (
    ROTATION_TREE="${TEST_DIR}/bounded-syslog-rotation"
    mkdir -m 0700 "$ROTATION_TREE"
    DATA_DIR="$ROTATION_TREE"
    LOG_PATH="${ROTATION_TREE}/syslog.txt"
    MAX_LOG_SIZE=0
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    STAT_CMD="$MOCK_STAT"
    RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE"
    SYSLOG_PID=$$
    start_syslog_stream() {
        : > "$LOG_PATH"
        chmod 0600 "$LOG_PATH"
        SYSLOG_PID=$$
    }
    stop_syslog_stream() {
        SYSLOG_PID=""
    }

    _rotation_cycle=1
    while [ "$_rotation_cycle" -le 100 ]; do
        printf 'rotation %s\n' "$_rotation_cycle" > "$LOG_PATH"
        chmod 0600 "$LOG_PATH"
        maintain_syslog_stream
        _rotation_cycle=$((_rotation_cycle + 1))
    done
    set -- "$ROTATION_TREE"/syslog.txt*
    [ "$#" -eq 2 ]
    [ -f "$LOG_PATH" ]
    [ -f "${LOG_PATH}.old" ]
    storage_data_tree_is_safe "$ROTATION_TREE"
); then
    fail "steady-state syslog rotation can exceed the collector data-tree bound"
fi
pass "repeated syslog rotation remains bounded to one fixed archive"

if ! (
    ARCHIVE_TREE="${TEST_DIR}/descriptor-syslog-cleanup"
    mkdir -m 0700 "$ARCHIVE_TREE"
    printf '%s\n' archived > "${ARCHIVE_TREE}/syslog.txt.old"
    chmod 0600 "${ARCHIVE_TREE}/syslog.txt.old"
    touch -t 200001010000 "${ARCHIVE_TREE}/syslog.txt.old"
    ln -s "$ARCHIVE_TREE" "${TEST_DIR}/descriptor-data-path"
    LOG_PATH="${TEST_DIR}/descriptor-data-path/syslog.txt"
    RETENTION_DAYS=0
    cleanup_syslog_archive
    [ ! -e "${ARCHIVE_TREE}/syslog.txt.old" ]
); then
    fail "fixed archive cleanup does not work through the pinned fd path"
fi
pass "fixed archive age cleanup works through the descriptor-relative data path"

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

OVERSIZED_CONNTRACK="${TEST_DIR}/oversized-conntrack"
cat > "$OVERSIZED_CONNTRACK" <<'EOF'
#!/bin/sh
exec dd if=/dev/zero bs=4096 count=1
EOF
chmod 0755 "$OVERSIZED_CONNTRACK"
CONNTRACK_TIMEOUT_ARGS="${TEST_DIR}/conntrack-timeout-args"
: > "$CONNTRACK_TIMEOUT_ARGS"
MOCK_TIMEOUT_ARGS_FILE="$CONNTRACK_TIMEOUT_ARGS"
export MOCK_TIMEOUT_ARGS_FILE
CONNTRACK_CMD="$OVERSIZED_CONNTRACK"
CONNTRACK_SNAPSHOT_BLOCKS=2
CLIENT_SNAPSHOT="${TEST_DIR}/oversized-conntrack-snapshot"
ITERATION_WRITE_FAILED=0
if collect_client_traffic >/dev/null 2>&1; then
    fail "oversized conntrack output escaped the kernel file-size ceiling"
fi
[ "$ITERATION_WRITE_FAILED" -eq 1 ] ||
    fail "oversized conntrack output did not poison the collection cycle"
[ ! -e "${CLIENT_SNAPSHOT}.current" ] &&
    [ ! -e "${CLIENT_SNAPSHOT}.conntrack" ] ||
    fail "oversized conntrack output left a partial snapshot"
grep -Eq '^-s TERM -k 2 1 .*/oversized-conntrack -L$' \
    "$CONNTRACK_TIMEOUT_ARGS" ||
    fail "conntrack timeout lacks the TERM and kill-after contract"
unset MOCK_TIMEOUT_ARGS_FILE
CONNTRACK_SNAPSHOT_BLOCKS=2048
pass "conntrack output is file-bounded and a TERM-ignoring child has a kill-after deadline"
TIMEOUT_CMD="$FAST_TIMEOUT"

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
SAVED_RUNTIME_DIR="$RUNTIME_DIR"
SNAPSHOT_RUNTIME="${TEST_DIR}/snapshot-runtime"
RUNTIME_DIR="$SNAPSHOT_RUNTIME"
mkdir -p "$RUNTIME_DIR"
SNAPSHOT_SOURCE="${RUNTIME_DIR}/tailscale-watchdog.json"
printf '%s\n' '{"schema":3,"marker":"old"}' > "$SNAPSHOT_SOURCE"
pin_watchdog_snapshot "$SNAPSHOT_SOURCE" ||
    fail "regular bounded watchdog snapshot was rejected"
PINNED_SNAPSHOT="$WATCHDOG_SNAPSHOT_FILE"
printf '%s\n' '{"schema":99,"marker":"new"}' > "${SNAPSHOT_SOURCE}.new"
mv "${SNAPSHOT_SOURCE}.new" "$SNAPSHOT_SOURCE"
grep -q '"marker":"old"' "$PINNED_SNAPSHOT" ||
    fail "pinned watchdog snapshot changed after producer rename"
release_watchdog_snapshot
[ ! -e "$PINNED_SNAPSHOT" ] ||
    fail "released watchdog snapshot remained in runtime storage"

printf '%s\n' '{"schema":3}' > "${SNAPSHOT_SOURCE}.target"
rm -f "$SNAPSHOT_SOURCE"
ln -s "${SNAPSHOT_SOURCE}.target" "$SNAPSHOT_SOURCE"
if pin_watchdog_snapshot "$SNAPSHOT_SOURCE"; then
    fail "watchdog symlink was accepted as a regular publication"
fi
rm -f "$SNAPSHOT_SOURCE"
mkfifo "$SNAPSHOT_SOURCE"
if pin_watchdog_snapshot "$SNAPSHOT_SOURCE"; then
    fail "watchdog FIFO was accepted as a regular publication"
fi
rm -f "$SNAPSHOT_SOURCE"
: > "$SNAPSHOT_SOURCE"
if pin_watchdog_snapshot "$SNAPSHOT_SOURCE"; then
    fail "empty watchdog publication was accepted"
fi
dd if=/dev/zero of="$SNAPSHOT_SOURCE" \
    bs=$((WATCHDOG_SNAPSHOT_MAX_BYTES + 1)) count=1 2>/dev/null
if pin_watchdog_snapshot "$SNAPSHOT_SOURCE"; then
    fail "oversized watchdog publication was accepted"
fi
if find "$RUNTIME_DIR" -type f -name 'tailscale-watchdog.snapshot.*' |
   grep -q .
then
    fail "rejected watchdog publication left a private snapshot behind"
fi
pass "watchdog snapshot pinning accepts only one regular bounded publication"

REPLACING_JSONFILTER="${TEST_DIR}/jsonfilter"
cat > "$REPLACING_JSONFILTER" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-i" ] || exit 2
input="${2:-}"
mode="${3:-}"
expression="${4:-}"
printf '%s\n' "$input" >> "${JAMMONITOR_TEST_JSONFILTER_CALLS:?}"
if mkdir "${JAMMONITOR_TEST_JSONFILTER_TRIGGER:?}" 2>/dev/null; then
    mv "${JAMMONITOR_TEST_WATCHDOG_REPLACEMENT:?}" \
        "${JAMMONITOR_TEST_WATCHDOG_SOURCE:?}"
fi
if grep -q '"marker":"old"' "$input"; then
    generation=old
else
    generation=new
fi
if [ "$mode" = "-t" ]; then
    case "$expression" in
        '@.schema'|'@.observed_at'|'@.process_uptime_seconds'|\
        '@.health_warnings'|'@.condition_since_at'|'@.connected_since_at'|\
        '@.connectivity_uptime_seconds'|'@.recovery_attempted'|\
        '@.recovery_count')
            printf '%s\n' int ;;
        '@.healthy'|'@.connected'|'@.degraded'|\
        '@.local_api_responsive'|'@.control_online'|'@.installed'|\
        '@.service_enabled'|'@.service_running'|'@.tun_available'|\
        '@.in_engine'|'@.peer_configured')
            printf '%s\n' boolean ;;
        '@.peer_reachable')
            printf '%s\n' null ;;
        *)
            printf '%s\n' string ;;
    esac
    exit 0
fi
[ "$mode" = "-e" ] || exit 2
case "$expression" in
    '@.schema')
        [ "$generation" = old ] && printf '3\n' || printf '99\n' ;;
    '@.observed_at'|'@.condition_since_at'|'@.connected_since_at')
        printf '%s\n' "${JAMMONITOR_TEST_WATCHDOG_OBSERVED:?}" ;;
    '@.status') printf 'running\n' ;;
    '@.reason') printf 'ok\n' ;;
    '@.backend_state') printf 'Running\n' ;;
    '@.tailscale_ip') printf '100.70.1.1\n' ;;
    '@.healthy'|'@.connected'|'@.local_api_responsive'|\
    '@.control_online'|'@.installed'|'@.service_enabled'|\
    '@.service_running'|'@.tun_available')
        printf 'true\n' ;;
    '@.degraded'|'@.in_engine'|'@.peer_configured')
        printf 'false\n' ;;
    '@.process_generation') printf '4242:10000\n' ;;
    '@.process_uptime_seconds') printf '100\n' ;;
    '@.health_warnings'|'@.connectivity_uptime_seconds'|\
    '@.recovery_attempted'|'@.recovery_count')
        printf '0\n' ;;
    '@.key_expiry') printf '0001-01-01T00:00:00Z\n' ;;
    '@.peer_state') printf 'not_configured\n' ;;
    '@.peer_reachable') printf 'null\n' ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$REPLACING_JSONFILTER"

printf '%s\n' '{"schema":3,"marker":"old"}' > "$SNAPSHOT_SOURCE"
printf '%s\n' '{"schema":99,"marker":"new"}' \
    > "${SNAPSHOT_SOURCE}.replacement"
JSONFILTER_CALLS="${TEST_DIR}/jsonfilter-calls"
JSONFILTER_TRIGGER="${TEST_DIR}/jsonfilter-replaced"
: > "$JSONFILTER_CALLS"
JAMMONITOR_TEST_JSONFILTER_CALLS="$JSONFILTER_CALLS"
JAMMONITOR_TEST_JSONFILTER_TRIGGER="$JSONFILTER_TRIGGER"
JAMMONITOR_TEST_WATCHDOG_SOURCE="$SNAPSHOT_SOURCE"
JAMMONITOR_TEST_WATCHDOG_REPLACEMENT="${SNAPSHOT_SOURCE}.replacement"
JAMMONITOR_TEST_WATCHDOG_OBSERVED="$(date +%s)"
export JAMMONITOR_TEST_JSONFILTER_CALLS JAMMONITOR_TEST_JSONFILTER_TRIGGER
export JAMMONITOR_TEST_WATCHDOG_SOURCE JAMMONITOR_TEST_WATCHDOG_REPLACEMENT
export JAMMONITOR_TEST_WATCHDOG_OBSERVED
SAVED_PATH="$PATH"
PATH="${TEST_DIR}:$PATH"
ITERATION_WRITE_FAILED=0
collect_tailscale_health >/dev/null
PATH="$SAVED_PATH"
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || reason || ':' || healthy || ':' || connected FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "running:ok:1:1" ] ||
    fail "concurrent watchdog replacement mixed publication generations"
[ "$(sort -u "$JSONFILTER_CALLS" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail "watchdog fields were parsed from more than one pinned pathname"
if grep -Fxq "$SNAPSHOT_SOURCE" "$JSONFILTER_CALLS"; then
    fail "jsonfilter read the replaceable public watchdog pathname"
fi
grep -q '"marker":"new"' "$SNAPSHOT_SOURCE" ||
    fail "replacement fixture did not atomically publish its new generation"
PINNED_PARSE_PATH="$(head -n 1 "$JSONFILTER_CALLS")"
[ ! -e "$PINNED_PARSE_PATH" ] ||
    fail "private watchdog parse snapshot was not released"
unset JAMMONITOR_TEST_JSONFILTER_CALLS JAMMONITOR_TEST_JSONFILTER_TRIGGER
unset JAMMONITOR_TEST_WATCHDOG_SOURCE JAMMONITOR_TEST_WATCHDOG_REPLACEMENT
unset JAMMONITOR_TEST_WATCHDOG_OBSERVED
RUNTIME_DIR="$SAVED_RUNTIME_DIR"
pass "one immutable watchdog generation feeds every parsed field"

jsonfilter() {
    [ "${1:-}" = "-i" ] || return 2
    if [ "${3:-}" = "-t" ]; then
        case "$4" in
            '@.schema') printf '%s\n' "$FIXTURE_SCHEMA_TYPE" ;;
            '@.observed_at') printf '%s\n' int ;;
            '@.status'|'@.reason'|'@.backend_state'|'@.tailscale_ip'|'@.key_expiry')
                printf '%s\n' string ;;
            '@.healthy') printf '%s\n' "$FIXTURE_HEALTHY_TYPE" ;;
            '@.connected') printf '%s\n' "$FIXTURE_CONNECTED_TYPE" ;;
            '@.degraded') printf '%s\n' "$FIXTURE_DEGRADED_TYPE" ;;
            '@.local_api_responsive') printf '%s\n' "$FIXTURE_LOCAL_API_TYPE" ;;
            '@.control_online') printf '%s\n' "$FIXTURE_CONTROL_ONLINE_TYPE" ;;
            '@.process_generation') printf '%s\n' "$FIXTURE_PROCESS_GENERATION_TYPE" ;;
            '@.process_uptime_seconds') printf '%s\n' "$FIXTURE_PROCESS_UPTIME_TYPE" ;;
            '@.installed') printf '%s\n' "$FIXTURE_INSTALLED_TYPE" ;;
            '@.service_enabled') printf '%s\n' "$FIXTURE_ENABLED_TYPE" ;;
            '@.service_running') printf '%s\n' "$FIXTURE_RUNNING_TYPE" ;;
            '@.tun_available') printf '%s\n' "$FIXTURE_TUN_TYPE" ;;
            '@.health_warnings'|'@.condition_since_at'|'@.connected_since_at'|\
            '@.recovery_attempted'|'@.recovery_count')
                printf '%s\n' int ;;
            '@.connectivity_uptime_seconds') printf '%s\n' "$FIXTURE_UPTIME_TYPE" ;;
            '@.in_engine') printf '%s\n' "$FIXTURE_IN_ENGINE_TYPE" ;;
            '@.peer_configured') printf '%s\n' "$FIXTURE_PEER_CONFIGURED_TYPE" ;;
            '@.peer_state') printf '%s\n' "$FIXTURE_PEER_STATE_TYPE" ;;
            '@.peer_reachable') printf '%s\n' "$FIXTURE_PEER_REACHABLE_TYPE" ;;
            *) return 1 ;;
        esac
        return
    fi
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
        '@.health_warnings') printf '%s\n' "$FIXTURE_HEALTH_WARNINGS" ;;
        '@.in_engine') printf '%s\n' "$FIXTURE_IN_ENGINE" ;;
        '@.key_expiry') printf '%s\n' '0001-01-01T00:00:00Z' ;;
        '@.condition_since_at') printf '%s\n' "$FIXTURE_OBSERVED" ;;
        '@.connected_since_at')
            printf '%s\n' "${FIXTURE_CONNECTED_SINCE_OVERRIDE:-$FIXTURE_OBSERVED}"
            ;;
        '@.connectivity_uptime_seconds') printf '%s\n' "$FIXTURE_UPTIME" ;;
        '@.recovery_attempted'|'@.recovery_count') printf '0\n' ;;
        '@.peer_configured') printf '%s\n' "$FIXTURE_PEER_CONFIGURED" ;;
        '@.peer_state') printf '%s\n' "$FIXTURE_PEER_STATE" ;;
        '@.peer_reachable') printf '%s\n' "$FIXTURE_PEER_REACHABLE" ;;
        *) return 1 ;;
    esac
}

RUNTIME_DIR="${TEST_DIR}/watchdog-runtime"
mkdir -p "$RUNTIME_DIR"
printf '%s\n' '{"schema":3}' \
    > "${RUNTIME_DIR}/tailscale-watchdog.json"
FIXTURE_OBSERVED="$(date +%s)"
FIXTURE_SCHEMA=2
FIXTURE_SCHEMA_TYPE=int
FIXTURE_STATUS=running
FIXTURE_REASON=ok
FIXTURE_BACKEND=Running
FIXTURE_IP=100.104.78.42
FIXTURE_HEALTHY=true
FIXTURE_HEALTHY_TYPE=boolean
FIXTURE_CONNECTED=true
FIXTURE_CONNECTED_TYPE=boolean
FIXTURE_DEGRADED=false
FIXTURE_DEGRADED_TYPE=boolean
FIXTURE_LOCAL_API=true
FIXTURE_LOCAL_API_TYPE=boolean
FIXTURE_CONTROL_ONLINE=true
FIXTURE_CONTROL_ONLINE_TYPE=boolean
FIXTURE_PROCESS_GENERATION=4242:10000
FIXTURE_PROCESS_GENERATION_TYPE=string
FIXTURE_PROCESS_UPTIME=100
FIXTURE_PROCESS_UPTIME_TYPE=int
FIXTURE_INSTALLED=true
FIXTURE_INSTALLED_TYPE=boolean
FIXTURE_ENABLED=true
FIXTURE_ENABLED_TYPE=boolean
FIXTURE_RUNNING=true
FIXTURE_RUNNING_TYPE=boolean
FIXTURE_TUN=true
FIXTURE_TUN_TYPE=boolean
FIXTURE_HEALTH_WARNINGS=0
FIXTURE_UPTIME=0
FIXTURE_UPTIME_TYPE=int
FIXTURE_IN_ENGINE=true
FIXTURE_IN_ENGINE_TYPE=boolean
FIXTURE_PEER_CONFIGURED=false
FIXTURE_PEER_CONFIGURED_TYPE=boolean
FIXTURE_PEER_STATE=not_configured
FIXTURE_PEER_STATE_TYPE=string
FIXTURE_PEER_REACHABLE=null
FIXTURE_PEER_REACHABLE_TYPE=null
ITERATION_WRITE_FAILED=0
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy || ':' || connected FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "running:1:1" ] ||
    fail "valid schema-2 watchdog snapshot was rejected"
[ "$(sqlite3 "$DB_PATH" "SELECT control_online || ':' || process_generation || ':' || process_uptime_seconds FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "1:4242:10000:100" ] ||
    fail "control-plane and process-generation evidence was not retained"
pass "legacy schema-2 snapshot with positive engine evidence remains compatible"

FIXTURE_HEALTHY_TYPE=string
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "string-typed healthy=true was accepted"
FIXTURE_HEALTHY_TYPE=boolean
pass "watchdog scalar types are enforced before historical persistence"

FIXTURE_IN_ENGINE=false
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-2 connected snapshot with in_engine=false was accepted"
FIXTURE_IN_ENGINE=null
FIXTURE_IN_ENGINE_TYPE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-2 connected snapshot without boolean in_engine=true was accepted"
FIXTURE_IN_ENGINE=true
FIXTURE_IN_ENGINE_TYPE=string
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-2 connected snapshot with string in_engine=true was accepted"

FIXTURE_SCHEMA=3
FIXTURE_IN_ENGINE=false
FIXTURE_IN_ENGINE_TYPE=boolean
FIXTURE_IP=fd7a:115c:a1e0::1234
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy || ':' || connected FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "running:1:1" ] ||
    fail "schema-3 snapshot incorrectly inherited the legacy InEngine gate"
FIXTURE_IP=fd7a:115c:a1e0::1:2:3:4:5
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-3 snapshot accepted malformed zero-width IPv6 compression"
FIXTURE_IP=100.104.78.42
FIXTURE_IN_ENGINE=true
FIXTURE_SCHEMA=2
FIXTURE_SCHEMA_TYPE=string
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "string-typed watchdog schema was accepted"
FIXTURE_SCHEMA_TYPE=int
pass "schema-2 compatibility is gated while schema 3 uses current semantics"

FIXTURE_PEER_CONFIGURED=true
FIXTURE_PEER_STATE=unknown
FIXTURE_PEER_REACHABLE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "connected snapshot with configured but unproven peer was accepted"

FIXTURE_PEER_STATE=unreachable
FIXTURE_PEER_REACHABLE=false
FIXTURE_PEER_REACHABLE_TYPE=boolean
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "connected snapshot with unreachable critical peer was accepted"

FIXTURE_PEER_CONFIGURED=false
FIXTURE_PEER_STATE=reachable
FIXTURE_PEER_REACHABLE=true
FIXTURE_PEER_REACHABLE_TYPE=boolean
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "contradictory unconfigured peer tuple was accepted"

FIXTURE_PEER_CONFIGURED=not-a-boolean
FIXTURE_PEER_CONFIGURED_TYPE=string
FIXTURE_PEER_STATE=not_configured
FIXTURE_PEER_REACHABLE=null
FIXTURE_PEER_REACHABLE_TYPE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "malformed peer_configured type was accepted"

FIXTURE_PEER_CONFIGURED=true
FIXTURE_PEER_CONFIGURED_TYPE=boolean
FIXTURE_PEER_STATE=reachable
FIXTURE_PEER_REACHABLE=true
FIXTURE_PEER_REACHABLE_TYPE=string
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "string-typed peer_reachable=true was accepted"

FIXTURE_STATUS=running_degraded
FIXTURE_REASON=critical_peer_invalid
FIXTURE_HEALTHY=false
FIXTURE_CONNECTED=false
FIXTURE_DEGRADED=true
FIXTURE_PEER_CONFIGURED=true
FIXTURE_PEER_CONFIGURED_TYPE=boolean
FIXTURE_PEER_STATE=invalid_configuration
FIXTURE_PEER_REACHABLE=false
FIXTURE_PEER_REACHABLE_TYPE=boolean
FIXTURE_CONNECTED_SINCE_OVERRIDE=0
FIXTURE_UPTIME=null
FIXTURE_UPTIME_TYPE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || reason || ':' || connected || ':' || peer_state || ':' || peer_reachable FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "running_degraded:critical_peer_invalid:0:invalid_configuration:0" ] ||
    fail "valid fail-closed invalid-configuration tuple was rejected"
pass "forged and contradictory critical-peer snapshots fail closed"

FIXTURE_STATUS=running
FIXTURE_REASON=ok
FIXTURE_HEALTHY=true
FIXTURE_CONNECTED=true
FIXTURE_DEGRADED=false
FIXTURE_PEER_CONFIGURED=false
FIXTURE_PEER_CONFIGURED_TYPE=boolean
FIXTURE_PEER_STATE=not_configured
FIXTURE_PEER_REACHABLE=null
FIXTURE_PEER_REACHABLE_TYPE=null
unset FIXTURE_CONNECTED_SINCE_OVERRIDE
FIXTURE_UPTIME=0
FIXTURE_UPTIME_TYPE=int
FIXTURE_SCHEMA=1
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy || ':' || COALESCE(connected, -1) FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0:-1" ] ||
    fail "unknown watchdog schema created historical uptime"
FIXTURE_SCHEMA=4
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "future watchdog schema created historical uptime"

FIXTURE_SCHEMA=2
FIXTURE_TUN=false
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid:0" ] ||
    fail "healthy snapshot without a usable TUN created historical uptime"

FIXTURE_TUN=true
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
FIXTURE_CONTROL_ONLINE_TYPE=null
FIXTURE_TUN=null
FIXTURE_TUN_TYPE=null
FIXTURE_BACKEND=
FIXTURE_CONNECTED_SINCE_OVERRIDE=0
FIXTURE_UPTIME=null
FIXTURE_UPTIME_TYPE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status || ':' || reason || ':' || healthy FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "socket_missing:localapi_socket_missing:0" ] ||
    fail "valid missing-socket recovery state was rejected"
FIXTURE_IN_ENGINE=false
FIXTURE_IN_ENGINE_TYPE=boolean
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "socket_missing" ] ||
    fail "schema-2 disconnected snapshot rejected boolean in_engine=false"
FIXTURE_IN_ENGINE=null
FIXTURE_IN_ENGINE_TYPE=null
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-2 disconnected snapshot accepted null in_engine"
FIXTURE_IN_ENGINE=false
FIXTURE_IN_ENGINE_TYPE=string
collect_tailscale_health >/dev/null
[ "$(sqlite3 "$DB_PATH" "SELECT status FROM service_health WHERE service='tailscale' ORDER BY ts DESC LIMIT 1;")" = "watchdog_invalid" ] ||
    fail "schema-2 disconnected snapshot accepted string in_engine=false"
pass "historical Tailscale uptime requires a supported schema and all delivery invariants"

SQLITE_CMD="$REAL_SQLITE"
STATUS_FILE="${TEST_DIR}/collector-status.json"
# This focused readiness unit uses the already-tested exact-one mount fixture.
# Full-process cases below exercise the production source/UUID/fstab/mount-ID
# authority function without replacing it.
storage_authority_is_current() {
    data_mount_is_safe
}
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

# Restore the production authority function after the focused readiness stub.
JAMMONITOR_LIB_ONLY=1 \
JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
    . "$COLLECTOR"
unset JAMMONITOR_LIB_ONLY

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

STORAGE_FSTAB="${TEST_DIR}/fstab"
printf '%s\n' 'config mount' >"$STORAGE_FSTAB"
STORAGE_SYSFS="${TEST_DIR}/sys-class-block"
mkdir -p "$STORAGE_SYSFS/sda1" "$STORAGE_SYSFS/sda"
printf '%s\n' '8:1' >"$STORAGE_SYSFS/sda1/dev"
printf '%s\n' '1' >"$STORAGE_SYSFS/sda1/partition"
printf '%s\n' '1' >"$STORAGE_SYSFS/sda/removable"

MOCK_STORAGE_UCI="${TEST_DIR}/storage-uci"
cat >"$MOCK_STORAGE_UCI" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-q" ] || exit 64
action="${2:-}"
name="${3:-}"
section="${JAMMONITOR_TEST_FSTAB_SECTION:-@mount[0]}"
target="${JAMMONITOR_MOUNT_POINT:?}"
uuid="${JAMMONITOR_TEST_STORAGE_UUID:-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
case "$action:$name" in
    show:fstab)
        printf "fstab.%s=mount\n" "$section"
        printf "fstab.%s.target='%s'\n" "$section" "$target"
        printf "fstab.%s.uuid='%s'\n" "$section" "$uuid"
        printf "fstab.%s.options='rw,noatime,nosuid,nodev,noexec'\n" \
            "$section"
        printf "fstab.%s.enabled='1'\n" "$section"
        if [ "${JAMMONITOR_TEST_DUPLICATE_FSTAB:-0}" = "1" ]; then
            printf "fstab.duplicate=mount\n"
            printf "fstab.duplicate.target='%s'\n" "$target"
            printf "fstab.duplicate.uuid='%s'\n" "$uuid"
            printf "fstab.duplicate.options='rw,noatime,nosuid,nodev,noexec'\n"
            printf "fstab.duplicate.enabled='1'\n"
        fi
        ;;
    get:"fstab.${section}") printf '%s\n' mount ;;
    get:"fstab.${section}.uuid") printf '%s\n' "$uuid" ;;
    get:"fstab.${section}.options")
        printf '%s\n' 'rw,noatime,nosuid,nodev,noexec' ;;
    get:"fstab.${section}.enabled") printf '%s\n' 1 ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$MOCK_STORAGE_UCI"

MOCK_STORAGE_BLOCK="${TEST_DIR}/storage-block"
cat >"$MOCK_STORAGE_BLOCK" <<'EOF'
#!/bin/sh
[ "${1:-}" = "info" ] || exit 64
uuid="${JAMMONITOR_TEST_STORAGE_UUID:-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
target="${JAMMONITOR_MOUNT_POINT:?}"
printf '/dev/sda1: UUID="%s" MOUNT="%s" TYPE="ext4"\n' "$uuid" "$target"
if [ "${JAMMONITOR_TEST_CLONED_UUID:-0}" = "1" ]; then
    printf '/dev/sdb1: UUID="%s" TYPE="ext4"\n' "$uuid"
fi
EOF
chmod 0755 "$MOCK_STORAGE_BLOCK"

make_storage_authority_fixture() {
    _fixture_prefix="$1"
    _fixture_mount="$2"
    _fixture_mount_id="${3:-42}"
    printf '%s 1 0:42 / %s rw,relatime - ext4 /dev/sda1 rw\n' \
        "$_fixture_mount_id" "$_fixture_mount" \
        >"${_fixture_prefix}.mountinfo"
    mkdir -p "${_fixture_prefix}.fdinfo"
    printf 'pos:\t0\nflags:\t0100000\nmnt_id:\t%s\n' \
        "$_fixture_mount_id" >"${_fixture_prefix}.fdinfo/8"
}

AUTH_MOUNT="${TEST_DIR}/authority-data"
AUTH_MOUNTS="${TEST_DIR}/authority-mounts"
AUTH_FD_ROOT="${TEST_DIR}/authority-fd"
mkdir -p "$AUTH_MOUNT" "$AUTH_FD_ROOT"
ln -s "$AUTH_MOUNT" "$AUTH_FD_ROOT/8"
printf '/dev/sda1 %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
    "$AUTH_MOUNT" >"$AUTH_MOUNTS"
make_storage_authority_fixture "${TEST_DIR}/authority" "$AUTH_MOUNT" 42
MOUNT_POINT="$AUTH_MOUNT"
PROC_MOUNTS="$AUTH_MOUNTS"
PROC_MOUNTINFO="${TEST_DIR}/authority.mountinfo"
FDINFO_ROOT="${TEST_DIR}/authority.fdinfo"
FD_ROOT="$AUTH_FD_ROOT"
SYS_CLASS_BLOCK_ROOT="$STORAGE_SYSFS"
FSTAB_CONFIG="$STORAGE_FSTAB"
STORAGE_RECOVERY_JOURNAL="${TEST_DIR}/authority-recovery"
STORAGE_RECOVERY_FAILED="${TEST_DIR}/authority-recovery-failed"
STAT_CMD="$MOCK_STAT"
UCI_CMD="$MOCK_STORAGE_UCI"
BLOCK_CMD="$MOCK_STORAGE_BLOCK"
TIMEOUT_CMD="$FAST_TIMEOUT"
EXPECTED_STORAGE_UID="$(id -u)"
EXPECTED_STORAGE_GID="$(id -g)"
JAMMONITOR_MOUNT_POINT="$AUTH_MOUNT"
export JAMMONITOR_MOUNT_POINT
PINNED_STORAGE_TOKEN=""

if prove_storage_authority; then
    PINNED_STORAGE_TOKEN="$PROVED_STORAGE_TOKEN"
    PINNED_STORAGE_SOURCE="$PROVED_STORAGE_SOURCE"
    PINNED_STORAGE_UUID="$PROVED_STORAGE_UUID"
    PINNED_STORAGE_KERNEL_ID="$PROVED_STORAGE_KERNEL_ID"
    PINNED_STORAGE_MOUNT_ID="$PROVED_STORAGE_MOUNT_ID"
    storage_authority_is_current ||
        fail "stable source/UUID/fstab/mount-ID authority did not rejoin"
else
    fail "stable source/UUID/fstab/mount-ID authority was rejected"
fi
pass "collector authority joins exact source UUID fstab removable root and pinned mount ID"

JAMMONITOR_TEST_CLONED_UUID=1
export JAMMONITOR_TEST_CLONED_UUID
if prove_storage_authority; then
    fail "cloned removable UUID retained collector authority"
fi
unset JAMMONITOR_TEST_CLONED_UUID
JAMMONITOR_TEST_DUPLICATE_FSTAB=1
export JAMMONITOR_TEST_DUPLICATE_FSTAB
if prove_storage_authority; then
    fail "duplicate /mnt/data fstab authority was accepted"
fi
unset JAMMONITOR_TEST_DUPLICATE_FSTAB
printf '%s\n' 0 >"$STORAGE_SYSFS/sda/removable"
if prove_storage_authority; then
    fail "non-removable source retained collector authority"
fi
printf '%s\n' 1 >"$STORAGE_SYSFS/sda/removable"
chmod 0770 "$AUTH_MOUNT"
if prove_storage_authority; then
    fail "group-writable mount root retained collector authority"
fi
chmod 0755 "$AUTH_MOUNT"
ln -s "${TEST_DIR}/absent-recovery-target" "$STORAGE_RECOVERY_JOURNAL"
if prove_storage_authority; then
    fail "dangling recovery evidence retained collector authority"
fi
rm -f "$STORAGE_RECOVERY_JOURNAL"
pass "collector authority rejects UUID clones fstab conflicts unsafe roots and any recovery evidence"

# Same path, source, UUID, and reusable major:minor with a new kernel mount ID
# models both a swap after the first proof and a lazy-unmount/remount while FD8
# still pins the prior generation.
printf '%s 1 0:42 / %s rw,relatime - ext4 /dev/sda1 rw\n' \
    43 "$AUTH_MOUNT" >"$PROC_MOUNTINFO"
if storage_authority_is_current; then
    fail "same-device remount inherited the pinned collector generation"
fi
printf '%s 1 0:42 / %s rw,relatime - ext4 /dev/sda1 rw\n' \
    42 "$AUTH_MOUNT" >"$PROC_MOUNTINFO"
storage_authority_is_current ||
    fail "restored exact mount generation did not rejoin its pin"
pass "collector pin rejects check-open and lazy-remount generation swaps"

TREE_AUTHORITY="${TEST_DIR}/tree-authority"
mkdir -m 0700 "$TREE_AUTHORITY"
printf '%s\n' ok >"$TREE_AUTHORITY/history.db"
chmod 0600 "$TREE_AUTHORITY/history.db"
RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE"
TIMEOUT_CMD="$FAST_TIMEOUT"
NEWLINE_LEAF="${TREE_AUTHORITY}/syslog.txt.1
history.db"
printf '%s\n' unsafe >"$NEWLINE_LEAF"
chmod 0600 "$NEWLINE_LEAF"
if storage_leaf_names_are_line_safe "$TREE_AUTHORITY" 5; then
    fail "line-oriented tree parser accepted a newline-bearing pathname"
fi
if storage_data_tree_is_safe "$TREE_AUTHORITY"; then
    fail "newline-bearing pathname retained collector tree authority"
fi
rm -f "$NEWLINE_LEAF"
storage_data_tree_is_safe "$TREE_AUTHORITY" ||
    fail "safe bounded collector data tree was rejected"
ln "$TREE_AUTHORITY/history.db" "${TEST_DIR}/history-hardlink"
if storage_data_tree_is_safe "$TREE_AUTHORITY"; then
    fail "hardlinked database leaf retained collector authority"
fi
rm -f "${TEST_DIR}/history-hardlink"
JAMMONITOR_TEST_FOREIGN_PATH="$TREE_AUTHORITY/history.db"
export JAMMONITOR_TEST_FOREIGN_PATH
if storage_data_tree_is_safe "$TREE_AUTHORITY"; then
    fail "foreign-owned database leaf retained collector authority"
fi
unset JAMMONITOR_TEST_FOREIGN_PATH
_rotation=1
while [ "$_rotation" -le 65 ]; do
    printf '%s\n' "$_rotation" >"$TREE_AUTHORITY/syslog.txt.${_rotation}"
    chmod 0600 "$TREE_AUTHORITY/syslog.txt.${_rotation}"
    _rotation=$((_rotation + 1))
done
if storage_data_tree_is_safe "$TREE_AUTHORITY"; then
    fail "oversized offline-crafted data directory retained authority"
fi
LEGACY_RUNTIME="${TEST_DIR}/legacy-migration-runtime"
mkdir -m 0700 "$LEGACY_RUNTIME"
if ! (
    RUNTIME_DIR="$LEGACY_RUNTIME"
	    TIMEOUT_CMD="$FAST_TIMEOUT"
	    MKTEMP_CMD=mktemp
	    SYNC_CMD=sync
	    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "above-ceiling legitimate legacy rotations could not migrate"
fi
[ "$(cat "$TREE_AUTHORITY/syslog.txt.old")" = "65" ] ||
    fail "legacy migration did not preserve the newest archive"
if find -H "$TREE_AUTHORITY" -maxdepth 1 \
    -name 'syslog.txt.[0-9]*' -print | grep -q .; then
    fail "legacy migration left timestamped rotations behind"
fi
storage_data_tree_is_safe "$TREE_AUTHORITY" ||
    fail "migrated legacy tree still exceeds the startup authority bound"

_rotation=66
while [ "$_rotation" -le 130 ]; do
    printf '%s\n' "$_rotation" >"$TREE_AUTHORITY/syslog.txt.${_rotation}"
    chmod 0600 "$TREE_AUTHORITY/syslog.txt.${_rotation}"
    _rotation=$((_rotation + 1))
done
if ! (
    RUNTIME_DIR="$LEGACY_RUNTIME"
	    TIMEOUT_CMD="$FAST_TIMEOUT"
	    MKTEMP_CMD=mktemp
	    SYNC_CMD=sync
	    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "legacy migration could not collapse rotations beside an existing archive"
fi
[ "$(cat "$TREE_AUTHORITY/syslog.txt.old")" = "65" ] ||
    fail "legacy migration replaced an existing fixed archive"
if find -H "$TREE_AUTHORITY" -maxdepth 1 \
    -name 'syslog.txt.[0-9]*' -print | grep -q .; then
    fail "existing-archive migration left timestamped rotations behind"
fi

FAIL_SYNC="${TEST_DIR}/fail-sync"
cat >"$FAIL_SYNC" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 0755 "$FAIL_SYNC"
printf '%s\n' barrier >"$TREE_AUTHORITY/syslog.txt.150"
chmod 0600 "$TREE_AUTHORITY/syslog.txt.150"
if (
    RUNTIME_DIR="$LEGACY_RUNTIME"
    TIMEOUT_CMD="$FAST_TIMEOUT"
    MKTEMP_CMD=mktemp
    SYNC_CMD="$FAIL_SYNC"
    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "legacy migration ignored a failed pre-delete durability barrier"
fi
[ -f "$TREE_AUTHORITY/syslog.txt.150" ] ||
    fail "failed preserve barrier allowed a legacy archive deletion"
if ! (
    RUNTIME_DIR="$LEGACY_RUNTIME"
    TIMEOUT_CMD="$FAST_TIMEOUT"
    MKTEMP_CMD=mktemp
    SYNC_CMD=sync
    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "legacy migration did not resume after the durability barrier recovered"
fi
[ ! -e "$TREE_AUTHORITY/syslog.txt.150" ] ||
    fail "recovered durability barrier did not retire the redundant archive"

printf '%s\n' safe >"$TREE_AUTHORITY/syslog.txt.200"
chmod 0600 "$TREE_AUTHORITY/syslog.txt.200"
ln "$TREE_AUTHORITY/history.db" "$TREE_AUTHORITY/syslog.txt.201"
if (
    RUNTIME_DIR="$LEGACY_RUNTIME"
	    TIMEOUT_CMD="$FAST_TIMEOUT"
	    MKTEMP_CMD=mktemp
	    SYNC_CMD=sync
	    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "unsafe legacy hardlink was migrated or deleted"
fi
[ -f "$TREE_AUTHORITY/syslog.txt.200" ] &&
    [ -f "$TREE_AUTHORITY/syslog.txt.201" ] ||
    fail "failed legacy validation partially deleted archives"
rm -f "$TREE_AUTHORITY/syslog.txt.201"
if ! (
    RUNTIME_DIR="$LEGACY_RUNTIME"
	    TIMEOUT_CMD="$FAST_TIMEOUT"
	    MKTEMP_CMD=mktemp
	    SYNC_CMD=sync
	    STAT_CMD="$MOCK_STAT"
    EXPECTED_STORAGE_UID="$(id -u)"
    EXPECTED_STORAGE_GID="$(id -g)"
    require_data_mount() { :; }
    logger() { :; }
    migrate_legacy_syslog_rotations "$TREE_AUTHORITY"
); then
    fail "legacy migration did not recover after unsafe input was removed"
fi
[ ! -e "$TREE_AUTHORITY/syslog.txt.200" ] ||
    fail "legacy migration beside a fixed archive did not retire safe timestamps"
storage_data_tree_is_safe "$TREE_AUTHORITY" ||
    fail "post-migration tree did not regain bounded authority"
pass "collector bounds fanout and safely migrates legacy rotations before startup"

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
   JAMMONITOR_PROC_MOUNTINFO="${TEST_DIR}/missing.mountinfo" \
   JAMMONITOR_FDINFO_ROOT="${TEST_DIR}/missing.fdinfo" \
   JAMMONITOR_SYS_CLASS_BLOCK_ROOT="$STORAGE_SYSFS" \
   JAMMONITOR_FSTAB_CONFIG="$STORAGE_FSTAB" \
   JAMMONITOR_UCI_CMD="$MOCK_STORAGE_UCI" \
   JAMMONITOR_BLOCK_CMD="$MOCK_STORAGE_BLOCK" \
   JAMMONITOR_STAT_CMD="$MOCK_STAT" \
   JAMMONITOR_EXPECTED_STORAGE_UID="$(id -u)" \
   JAMMONITOR_EXPECTED_STORAGE_GID="$(id -g)" \
   JAMMONITOR_RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE" \
   JAMMONITOR_TIMEOUT_CMD="$FAST_TIMEOUT" \
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

POISON_OUTSIDE="${TEST_DIR}/outside-network"
printf '%s\n' 'network-sentinel' >"$POISON_OUTSIDE"

DIR_LINK_MOUNT="${TEST_DIR}/dir-link-data"
DIR_LINK_RUNTIME="${TEST_DIR}/dir-link-runtime"
DIR_LINK_MOUNTS="${TEST_DIR}/dir-link-mounts"
DIR_LINK_FD_ROOT="${TEST_DIR}/dir-link-fd"
mkdir -p "$DIR_LINK_MOUNT"
mkdir -p "$DIR_LINK_FD_ROOT"
ln -s "$DIR_LINK_MOUNT" "${DIR_LINK_FD_ROOT}/8"
ln -s "$TEST_DIR" "${DIR_LINK_MOUNT}/jammonitor"
printf '/dev/sda1 %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
    "$DIR_LINK_MOUNT" >"$DIR_LINK_MOUNTS"
make_storage_authority_fixture "${TEST_DIR}/dir-link" "$DIR_LINK_MOUNT"
if JAMMONITOR_LIB_ONLY=0 \
   JAMMONITOR_MOUNT_POINT="$DIR_LINK_MOUNT" \
   JAMMONITOR_RUNTIME_DIR="$DIR_LINK_RUNTIME" \
   JAMMONITOR_PIDFILE="${TEST_DIR}/dir-link.pid" \
   JAMMONITOR_LOCK_FILE="${TEST_DIR}/dir-link.lock" \
   JAMMONITOR_FLOCK_CMD="$MOCK_FLOCK" \
   JAMMONITOR_TEST_FLOCK_STATE="${TEST_DIR}/dir-link.mock-flock" \
   JAMMONITOR_PROC_STAT_CMD="$MOCK_PROC_STAT" \
   JAMMONITOR_PROC_MOUNTS="$DIR_LINK_MOUNTS" \
   JAMMONITOR_PROC_MOUNTINFO="${TEST_DIR}/dir-link.mountinfo" \
   JAMMONITOR_FDINFO_ROOT="${TEST_DIR}/dir-link.fdinfo" \
   JAMMONITOR_FD_ROOT="$PROCESS_FD_ROOT" \
   JAMMONITOR_SYS_CLASS_BLOCK_ROOT="$STORAGE_SYSFS" \
   JAMMONITOR_FSTAB_CONFIG="$STORAGE_FSTAB" \
   JAMMONITOR_UCI_CMD="$MOCK_STORAGE_UCI" \
   JAMMONITOR_BLOCK_CMD="$MOCK_STORAGE_BLOCK" \
   JAMMONITOR_STAT_CMD="$MOCK_STAT" \
   JAMMONITOR_EXPECTED_STORAGE_UID="$(id -u)" \
   JAMMONITOR_EXPECTED_STORAGE_GID="$(id -g)" \
   JAMMONITOR_RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE" \
   JAMMONITOR_TIMEOUT_CMD="$FAST_TIMEOUT" \
   JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
   "$COLLECTOR" >/dev/null 2>&1
then
    fail "collector followed a symlinked persistent data directory"
fi
[ "$(cat "$POISON_OUTSIDE")" = "network-sentinel" ] ||
    fail "symlinked data directory changed an outside file"
[ ! -e "${TEST_DIR}/history.db" ] ||
    fail "symlinked data directory created an outside database"

LEAF_LINK_MOUNT="${TEST_DIR}/leaf-link-data"
LEAF_LINK_RUNTIME="${TEST_DIR}/leaf-link-runtime"
LEAF_LINK_MOUNTS="${TEST_DIR}/leaf-link-mounts"
LEAF_LINK_FD_ROOT="${TEST_DIR}/leaf-link-fd"
mkdir -p "${LEAF_LINK_MOUNT}/jammonitor"
mkdir -p "$LEAF_LINK_FD_ROOT"
ln -s "$LEAF_LINK_MOUNT" "${LEAF_LINK_FD_ROOT}/8"
ln -s "$POISON_OUTSIDE" "${LEAF_LINK_MOUNT}/jammonitor/syslog.txt"
printf '/dev/sda1 %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
    "$LEAF_LINK_MOUNT" >"$LEAF_LINK_MOUNTS"
make_storage_authority_fixture "${TEST_DIR}/leaf-link" "$LEAF_LINK_MOUNT"
if JAMMONITOR_LIB_ONLY=0 \
   JAMMONITOR_MOUNT_POINT="$LEAF_LINK_MOUNT" \
   JAMMONITOR_RUNTIME_DIR="$LEAF_LINK_RUNTIME" \
   JAMMONITOR_PIDFILE="${TEST_DIR}/leaf-link.pid" \
   JAMMONITOR_LOCK_FILE="${TEST_DIR}/leaf-link.lock" \
   JAMMONITOR_FLOCK_CMD="$MOCK_FLOCK" \
   JAMMONITOR_TEST_FLOCK_STATE="${TEST_DIR}/leaf-link.mock-flock" \
   JAMMONITOR_PROC_STAT_CMD="$MOCK_PROC_STAT" \
   JAMMONITOR_PROC_MOUNTS="$LEAF_LINK_MOUNTS" \
   JAMMONITOR_PROC_MOUNTINFO="${TEST_DIR}/leaf-link.mountinfo" \
   JAMMONITOR_FDINFO_ROOT="${TEST_DIR}/leaf-link.fdinfo" \
   JAMMONITOR_FD_ROOT="$PROCESS_FD_ROOT" \
   JAMMONITOR_SYS_CLASS_BLOCK_ROOT="$STORAGE_SYSFS" \
   JAMMONITOR_FSTAB_CONFIG="$STORAGE_FSTAB" \
   JAMMONITOR_UCI_CMD="$MOCK_STORAGE_UCI" \
   JAMMONITOR_BLOCK_CMD="$MOCK_STORAGE_BLOCK" \
   JAMMONITOR_STAT_CMD="$MOCK_STAT" \
   JAMMONITOR_EXPECTED_STORAGE_UID="$(id -u)" \
   JAMMONITOR_EXPECTED_STORAGE_GID="$(id -g)" \
   JAMMONITOR_RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE" \
   JAMMONITOR_TIMEOUT_CMD="$FAST_TIMEOUT" \
   JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
   "$COLLECTOR" >/dev/null 2>&1
then
    fail "collector followed a symlinked persistent log leaf"
fi
[ "$(cat "$POISON_OUTSIDE")" = "network-sentinel" ] ||
    fail "symlinked syslog leaf changed an outside file"
pass "offline directory and leaf symlink poison cannot escape mounted storage"

CORRUPT_MOUNT="${TEST_DIR}/corrupt-data"
CORRUPT_RUNTIME="${TEST_DIR}/corrupt-runtime"
CORRUPT_PID="${TEST_DIR}/corrupt.pid"
CORRUPT_MOUNTS="${TEST_DIR}/corrupt-mounts"
CORRUPT_FD_ROOT="${TEST_DIR}/corrupt-fd"
mkdir -p "${CORRUPT_MOUNT}/jammonitor"
mkdir -p "$CORRUPT_FD_ROOT"
ln -s "$CORRUPT_MOUNT" "${CORRUPT_FD_ROOT}/8"
printf '/dev/sda1 %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
    "$CORRUPT_MOUNT" > "$CORRUPT_MOUNTS"
printf '%s\n' 'not a sqlite database' > "${CORRUPT_MOUNT}/jammonitor/history.db"
make_storage_authority_fixture "${TEST_DIR}/corrupt" "$CORRUPT_MOUNT"

SAVED_CORRUPT_DB_PATH="$DB_PATH"
SAVED_CORRUPT_SQLITE_CMD="$SQLITE_CMD"
SAVED_CORRUPT_SQLITE_TIMEOUT_CMD="$SQLITE_TIMEOUT_CMD"
DB_PATH="${CORRUPT_MOUNT}/jammonitor/history.db"
SQLITE_CMD="$REAL_SQLITE"
SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT"
if init_db; then
    fail "real sqlite accepted an existing corrupt history database"
fi
DB_PATH="$SAVED_CORRUPT_DB_PATH"
SQLITE_CMD="$SAVED_CORRUPT_SQLITE_CMD"
SQLITE_TIMEOUT_CMD="$SAVED_CORRUPT_SQLITE_TIMEOUT_CMD"
pass "real SQLite rejects an existing corrupt history database"

FAIL_SQLITE="${TEST_DIR}/fail-sqlite"
cat >"$FAIL_SQLITE" <<'EOF'
#!/bin/sh
exit 26
EOF
chmod 0755 "$FAIL_SQLITE"
if JAMMONITOR_LIB_ONLY=0 \
   JAMMONITOR_MOUNT_POINT="$CORRUPT_MOUNT" \
   JAMMONITOR_RUNTIME_DIR="$CORRUPT_RUNTIME" \
   JAMMONITOR_PIDFILE="$CORRUPT_PID" \
   JAMMONITOR_LOCK_FILE="${TEST_DIR}/corrupt.lock" \
   JAMMONITOR_FLOCK_CMD="$MOCK_FLOCK" \
   JAMMONITOR_TEST_FLOCK_STATE="${TEST_DIR}/corrupt.mock-flock" \
   JAMMONITOR_PROC_STAT_CMD="$MOCK_PROC_STAT" \
   JAMMONITOR_PROC_MOUNTS="$CORRUPT_MOUNTS" \
   JAMMONITOR_PROC_MOUNTINFO="${TEST_DIR}/corrupt.mountinfo" \
   JAMMONITOR_FDINFO_ROOT="${TEST_DIR}/corrupt.fdinfo" \
   JAMMONITOR_FD_ROOT="$CORRUPT_FD_ROOT" \
   JAMMONITOR_SYS_CLASS_BLOCK_ROOT="$STORAGE_SYSFS" \
   JAMMONITOR_FSTAB_CONFIG="$STORAGE_FSTAB" \
   JAMMONITOR_UCI_CMD="$MOCK_STORAGE_UCI" \
   JAMMONITOR_BLOCK_CMD="$MOCK_STORAGE_BLOCK" \
   JAMMONITOR_STAT_CMD="$MOCK_STAT" \
   JAMMONITOR_EXPECTED_STORAGE_UID="$(id -u)" \
   JAMMONITOR_EXPECTED_STORAGE_GID="$(id -g)" \
   JAMMONITOR_RANDOM_UUID_FILE="$RANDOM_UUID_FIXTURE" \
   JAMMONITOR_TIMEOUT_CMD="$FAST_TIMEOUT" \
   JAMMONITOR_CONNTRACK_CMD=/usr/bin/true \
   JAMMONITOR_LOGREAD_CMD=/usr/bin/true \
   JAMMONITOR_SQLITE_CMD="$FAIL_SQLITE" \
   JAMMONITOR_SQLITE_TIMEOUT_CMD="$MOCK_TIMEOUT" \
   "$COLLECTOR" >/dev/null 2>&1
then
    fail "collector continued with corrupt SQLite"
fi
[ ! -e "$CORRUPT_PID" ] || fail "collector left PID after SQLite failure"
grep -q '"database_quick_check":"failed"' \
    "${CORRUPT_RUNTIME}/collector-status.json" ||
    fail "collector did not publish its SQLite initialization failure"
pass "SQLite initialization failure exits visibly for supervised handling"

printf '1..%s\n' "$PASS_COUNT"
