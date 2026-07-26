#!/bin/sh

set -eu
umask 077
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
UPGRADER="$REPO_ROOT/router/upgrade-tailscale-arm64.sh"
TARGET_VERSION="1.98.9"
TARGET_ARCHIVE="tailscale_${TARGET_VERSION}_arm64.tgz"
TARGET_DIRECTORY="tailscale_${TARGET_VERSION}_arm64"
PYTHON_BIN="$(command -v python3)"

PASS=0
FAIL=0
TEST_ROOT=""
LAST_OUTPUT=""

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

cleanup_case() {
    [ -n "$TEST_ROOT" ] || return 0
    case "$TEST_ROOT" in
        /tmp/tailscale-upgrade-test.*|/private/tmp/tailscale-upgrade-test.*)
            rm -rf -- "$TEST_ROOT"
            ;;
    esac
    TEST_ROOT=""
}

trap cleanup_case EXIT HUP INT TERM

pass() {
    PASS=$((PASS + 1))
    printf 'ok %s - %s\n' "$PASS" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1" >&2
    if [ -n "$LAST_OUTPUT" ] && [ -f "$LAST_OUTPUT" ]; then
        sed -n '1,80p' "$LAST_OUTPUT" >&2
    fi
}

assert_file_contains() {
    file="$1"
    text="$2"
    grep -Fq "$text" "$file"
}

file_mode() {
    "$PYTHON_BIN" -c \
        'import os, stat, sys; print(f"{stat.S_IMODE(os.lstat(sys.argv[1]).st_mode):o}")' \
        "$1"
}

make_tailscale_binary() {
    path="$1"
    version="$2"
    cat > "$path" <<EOF
#!/bin/sh
VERSION="$version"
printf 'cli %s\\n' "\$*" >> "\$TS_TEST_CONTROL_DIR/actions"
for argument in "\$@"; do
    if [ "\$argument" = "version" ]; then
        printf '%s\\n' "\$VERSION"
        exit 0
    fi
done
is_ping=0
for argument in "\$@"; do
    [ "\$argument" = "ping" ] && is_ping=1
done
if [ "\$is_ping" -eq 1 ]; then
    if [ -f "\$TS_TEST_CONTROL_DIR/peer-fail-all" ] ||
       { [ "\$VERSION" = "1.98.9" ] &&
         [ -f "\$TS_TEST_CONTROL_DIR/peer-fail-new" ]; } ||
       { [ "\$VERSION" != "1.98.9" ] &&
         [ -f "\$TS_TEST_CONTROL_DIR/peer-fail-rollback" ]; }; then
        exit 1
    fi
    exit 0
fi
if [ -f "\$TS_TEST_CONTROL_DIR/status-oversized" ]; then
    awk 'BEGIN { for (i = 0; i < 70000; i++) printf "x" }'
    exit 0
fi
if [ -f "\$TS_TEST_CONTROL_DIR/status-infinite" ]; then
    while :; do
        printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
    done
fi
if [ -f "\$TS_TEST_CONTROL_DIR/status-json-file" ]; then
    cat "\$TS_TEST_CONTROL_DIR/status-json-file"
    exit 0
fi
backend="\$(cat "\$TS_TEST_CONTROL_DIR/backend")"
runtime_version="\$(cat "\$TS_TEST_CONTROL_DIR/runtime-version")"
stable_id="\$(cat "\$TS_TEST_CONTROL_DIR/stable-id")"
tun="\$(cat "\$TS_TEST_CONTROL_DIR/tun")"
engine="\$(cat "\$TS_TEST_CONTROL_DIR/in-engine")"
tailnet_ip="\$(cat "\$TS_TEST_CONTROL_DIR/tailnet-ip")"
auth_url="\$(cat "\$TS_TEST_CONTROL_DIR/auth-url")"
printf '{"BackendState":"%s","Version":"%s","TUN":%s,"Self":{"ID":"%s","InEngine":%s,"TailscaleIPs":["%s"]},"AuthURL":"%s"}\\n' \
    "\$backend" "\$runtime_version" "\$tun" "\$stable_id" "\$engine" "\$tailnet_ip" "\$auth_url"
if [ -f "\$TS_TEST_CONTROL_DIR/status-nonzero" ]; then
    exit 1
fi
exit 0
EOF
    chmod 0755 "$path"
}

make_tailscaled_binary() {
    path="$1"
    version="$2"
    cat > "$path" <<EOF
#!/bin/sh
printf '%s\\n' "$version"
EOF
    chmod 0755 "$path"
}

make_safe_init() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
TAILSCALED="/usr/sbin/tailscaled"
STATE_FILE="/etc/tailscale/tailscaled.state"
SOCKET_FILE="/var/run/tailscale/tailscaled.sock"
start_service() {
    procd_set_param command "$TAILSCALED"
    procd_append_param command --state="$STATE_FILE"
    procd_append_param command --socket="$SOCKET_FILE"
    procd_append_param command --tun=tailscale0
}
stop_service() {
    "$TAILSCALED" --cleanup
}
# JAMMONITOR_BOOT_FENCE_V1
# JAMMONITOR_TAILSCALE_UPGRADE_FENCE_TOKEN
# TEST-HARNESS-BEGIN
case "${1:-}" in
    running)
        if [ -f "$TS_TEST_CONTROL_DIR/running-rc2" ]; then
            exit 2
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/running-hang" ]; then
            exit 88
        fi
        test -f "$TS_TEST_CONTROL_DIR/running"
        ;;
    stop)
        printf '%s\n' stop >> "$TS_TEST_CONTROL_DIR/actions"
        if [ -f "$TS_TEST_CONTROL_DIR/tamper-init-after-stop" ]; then
            printf '%s\n' '/usr/sbin/tailscal\e d\own' >> "$0"
        fi
        cp "$TS_UPGRADE_ROOT/var/run/jammonitor/tailscale-maintenance" \
            "$TS_TEST_CONTROL_DIR/observed-marker"
        if [ -f "$TS_TEST_CONTROL_DIR/stop-timeout" ]; then
            exit 124
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/delayed-stop-timeout" ]; then
            (
                while [ ! -f "$TS_TEST_CONTROL_DIR/release-delayed-stop" ]; do
                    sleep 0.01
                done
                rm -f "$TS_TEST_CONTROL_DIR/running"
                rm -f "$TS_UPGRADE_PROC_ROOT/4242/comm"
                rmdir "$TS_UPGRADE_PROC_ROOT/4242" 2>/dev/null || true
                rm -f "$TS_UPGRADE_ROOT/var/run/tailscale/tailscaled.sock"
                : > "$TS_TEST_CONTROL_DIR/delayed-stop-completed"
            ) &
            exit 124
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/flush-state-on-stop" ]; then
            printf '%s\n' "QUIESCENT_STATE" \
                > "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
        fi
        rm -f "$TS_TEST_CONTROL_DIR/running"
        if [ ! -f "$TS_TEST_CONTROL_DIR/daemon-stays-live" ]; then
            rm -f "$TS_UPGRADE_PROC_ROOT/4242/comm"
            rmdir "$TS_UPGRADE_PROC_ROOT/4242" 2>/dev/null || true
            rm -f "$TS_UPGRADE_ROOT/var/run/tailscale/tailscaled.sock"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/fail-rollback-restore" ]; then
            version="$("$TS_UPGRADE_ROOT/usr/sbin/tailscaled" --version)"
            if [ "$version" = "1.98.9" ]; then
                bundle="$TS_UPGRADE_ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
                if [ -d "$bundle" ]; then
                    rm -f "$bundle/tailscale" "$bundle/tailscaled.state"
                fi
            fi
        fi
        ;;
    start)
        fence="$TS_UPGRADE_ROOT/etc/jammonitor/tailscale-upgrade-fence"
        if [ -e "$fence" ] || [ -L "$fence" ]; then
            [ -f "$fence" ] && [ ! -L "$fence" ] || exit 97
            expected_token="$(
                awk -F= '$1 == "token" { count++; value=$2 }
                    END { if (count != 1) exit 1; print value }' "$fence"
            )" || exit 97
            [ -n "${JAMMONITOR_TAILSCALE_UPGRADE_FENCE_TOKEN:-}" ] &&
                [ "$JAMMONITOR_TAILSCALE_UPGRADE_FENCE_TOKEN" = \
                  "$expected_token" ] ||
                exit 97
            : > "$TS_TEST_CONTROL_DIR/authorized-fence-start"
        fi
        printf '%s\n' start >> "$TS_TEST_CONTROL_DIR/actions"
        version="$("$TS_UPGRADE_ROOT/usr/sbin/tailscaled" --version)"
        printf '%s\n' "$version" > "$TS_TEST_CONTROL_DIR/runtime-version"
        backend="$(cat "$TS_TEST_CONTROL_DIR/original-backend")"
        if [ -f "$TS_TEST_CONTROL_DIR/fail-new" ] &&
           [ "$version" = "1.98.9" ]; then
            backend="Starting"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/running-on-new" ] &&
           [ "$version" = "1.98.9" ]; then
            backend="Running"
        fi
        printf '%s\n' "$backend" > "$TS_TEST_CONTROL_DIR/backend"
        if [ -f "$TS_TEST_CONTROL_DIR/delete-state-on-new" ] &&
           [ "$version" = "1.98.9" ]; then
            rm -f "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/mutate-state-on-new" ] &&
           [ "$version" = "1.98.9" ]; then
            printf '%s\n' "NEW_DAEMON_STATE" \
                > "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/change-identity-on-new" ]; then
            if [ "$version" = "1.98.9" ]; then
                printf '%s\n' "node-stable-new" > "$TS_TEST_CONTROL_DIR/stable-id"
                printf '%s\n' "NEW_IDENTITY_STATE" \
                    > "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
            elif [ "$(cat "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state")" = \
                   "SUPER_SECRET_STATE" ]; then
                printf '%s\n' "node-stable-123" > "$TS_TEST_CONTROL_DIR/stable-id"
            fi
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/nonempty-identity-on-new" ] &&
           [ "$version" = "1.98.9" ]; then
            printf '%s\n' "node-stable-new" > "$TS_TEST_CONTROL_DIR/stable-id"
        elif [ -f "$TS_TEST_CONTROL_DIR/nonempty-identity-on-new" ]; then
            : > "$TS_TEST_CONTROL_DIR/stable-id"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/expire-identity-on-new" ] &&
           [ "$version" = "1.98.9" ]; then
            : > "$TS_TEST_CONTROL_DIR/stable-id"
            printf '%s\n' "EXPIRED_KEY_REGENERATED_STATE" \
                > "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/mutate-state-on-rollback" ] &&
           [ "$version" = "1.92.3" ]; then
            printf '%s\n' "ROLLBACK_DAEMON_STATE" \
                > "$TS_UPGRADE_ROOT/etc/tailscale/tailscaled.state"
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/remove-auth-url-on-new" ]; then
            if [ "$version" = "1.98.9" ]; then
                : > "$TS_TEST_CONTROL_DIR/auth-url"
            else
                printf '%s\n' "SUPER_SECRET_AUTH_URL" \
                    > "$TS_TEST_CONTROL_DIR/auth-url"
            fi
        fi
        if [ -f "$TS_TEST_CONTROL_DIR/remove-auth-url-on-rollback" ] &&
           [ "$version" = "1.92.3" ]; then
            : > "$TS_TEST_CONTROL_DIR/auth-url"
        fi
        : > "$TS_TEST_CONTROL_DIR/running"
        mkdir -p "$TS_UPGRADE_PROC_ROOT/4242" \
            "$TS_UPGRADE_ROOT/var/run/tailscale"
        printf 'tailscaled\n' > "$TS_UPGRADE_PROC_ROOT/4242/comm"
        : > "$TS_UPGRADE_ROOT/var/run/tailscale/tailscaled.sock"
        if [ -f "$TS_TEST_CONTROL_DIR/tamper-installed-daemon" ] &&
           [ "$version" = "1.98.9" ]; then
            printf '# tampered\n' >> "$TS_UPGRADE_ROOT/usr/sbin/tailscaled"
        fi
        ;;
    *)
        exit 2
        ;;
esac
# TEST-HARNESS-END
EOF
    chmod 0755 "$path"
}

make_unsafe_init() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
: tailscaled --cleanup
stop_service() {
    /usr/sbin/tailscale \
        --socket=/var/run/tailscale/tailscaled.sock \
        "down"
}
EOF
    chmod 0755 "$path"
}

make_timeout_mock() {
    path="$1"
cat > "$path" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-s" ] && [ "${2:-}" = "TERM" ] || exit 90
[ "${3:-}" = "-k" ] && [ "${4:-}" = "2" ] || exit 91
shift 4
shift
last_argument=""
has_status=0
has_cp=0
for timeout_argument in "$@"; do
    last_argument="$timeout_argument"
    [ "$timeout_argument" = "status" ] && has_status=1
    [ "$timeout_argument" = "cp" ] && has_cp=1
done
if [ "$has_cp" -eq 1 ] &&
   [ -f "$TS_TEST_CONTROL_DIR/capture-fetch-child" ]; then
    printf '%s\n' "$$" > "$TS_TEST_CONTROL_DIR/fetch-child-pid"
fi
if [ "$has_status" -eq 1 ] &&
   [ -f "$TS_TEST_CONTROL_DIR/status-infinite" ]; then
    : > "$TS_TEST_CONTROL_DIR/status-timeout-intercepted"
    exit 124
fi
if [ "$last_argument" = "running" ] &&
   [ -f "$TS_TEST_CONTROL_DIR/running-hang" ]; then
    : > "$TS_TEST_CONTROL_DIR/running-timeout-intercepted"
    exit 124
fi
exec "$@"
EOF
    chmod 0755 "$path"
}

make_stat_mock() {
    path="$1"
    cat > "$path" <<EOF
#!${PYTHON_BIN}
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
replacements = {
    "%u": str(value.st_uid),
    "%g": str(value.st_gid),
    "%a": f"{stat.S_IMODE(value.st_mode):o}",
    "%h": str(value.st_nlink),
    "%d": str(value.st_dev),
    "%i": str(value.st_ino),
    "%t": f"{os.major(value.st_rdev):x}",
    "%T": f"{os.minor(value.st_rdev):x}",
}
for token in ("%u", "%g", "%a", "%h", "%d", "%i", "%t", "%T"):
    fmt = fmt.replace(token, replacements[token])
print(fmt)
EOF
    chmod 0755 "$path"
}

make_uci_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
[ "$#" -eq 5 ] &&
    [ "$1" = "-q" ] &&
    [ "$2" = "-c" ] &&
    [ "$4" = "show" ] &&
    [ "$5" = "fstab" ] || exit 64
cat "$TS_TEST_CONTROL_DIR/fstab-show"
EOF
    chmod 0755 "$path"
}

make_block_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = "info" ] || exit 64
device="$2"
name="${device##*/}"
uuid_file="$TS_TEST_CONTROL_DIR/block-uuid-$name"
[ -f "$uuid_file" ] || uuid_file="$TS_TEST_CONTROL_DIR/block-uuid"
uuid="$(cat "$uuid_file")"
if [ "$name" = "sda1" ]; then
    mount_value="/mnt/data"
else
    mount_value=""
fi
printf '%s: UUID="%s" LABEL="JAMMONITOR" VERSION="1.0" MOUNT="%s" TYPE="ext4"\n' \
    "$device" "$uuid" "$mount_value"
EOF
    chmod 0755 "$path"
}

make_sync_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
[ "$#" -eq 0 ] || {
    : > "$TS_TEST_CONTROL_DIR/sync-received-unsupported-arguments"
    exit 93
}
count=0
if [ -f "$TS_TEST_CONTROL_DIR/sync-count" ]; then
    count="$(cat "$TS_TEST_CONTROL_DIR/sync-count")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$TS_TEST_CONTROL_DIR/sync-count"
printf '%s\n' sync >> "$TS_TEST_CONTROL_DIR/actions"
printf 'sync-target:%s\n' "$*" >> "$TS_TEST_CONTROL_DIR/actions"
if [ -f "$TS_TEST_CONTROL_DIR/release-delayed-stop-at-sync" ] &&
   [ "$count" = "$(cat "$TS_TEST_CONTROL_DIR/release-delayed-stop-at-sync")" ]; then
    : > "$TS_TEST_CONTROL_DIR/release-delayed-stop"
    attempts=100
    while [ ! -f "$TS_TEST_CONTROL_DIR/delayed-stop-completed" ] &&
          [ "$attempts" -gt 0 ]; do
        sleep 0.01
        attempts=$((attempts - 1))
    done
fi
if [ -f "$TS_TEST_CONTROL_DIR/invalidate-mount-at-sync" ] &&
   [ "$count" = "$(cat "$TS_TEST_CONTROL_DIR/invalidate-mount-at-sync")" ]; then
    printf 'otherdev /elsewhere ext4 rw,relatime 0 0\n' \
        > "$TS_UPGRADE_PROC_ROOT/mounts"
fi
if [ -f "$TS_TEST_CONTROL_DIR/expire-maintenance-at-sync" ] &&
   [ "$count" = "$(cat "$TS_TEST_CONTROL_DIR/expire-maintenance-at-sync")" ]; then
    printf '0\n' \
        > "$TS_UPGRADE_ROOT/var/run/jammonitor/tailscale-maintenance"
fi
if [ -f "$TS_TEST_CONTROL_DIR/restart-daemon-at-sync" ] &&
   [ "$count" = "$(cat "$TS_TEST_CONTROL_DIR/restart-daemon-at-sync")" ]; then
    : > "$TS_TEST_CONTROL_DIR/running"
    mkdir -p "$TS_UPGRADE_PROC_ROOT/4242" \
        "$TS_UPGRADE_ROOT/var/run/tailscale"
    printf 'tailscaled\n' > "$TS_UPGRADE_PROC_ROOT/4242/comm"
    : > "$TS_UPGRADE_ROOT/var/run/tailscale/tailscaled.sock"
fi
if [ -f "$TS_TEST_CONTROL_DIR/sync-fails" ]; then
    exit 1
fi
if [ -f "$TS_TEST_CONTROL_DIR/sync-fail-at" ] &&
   [ "$count" = "$(cat "$TS_TEST_CONTROL_DIR/sync-fail-at")" ]; then
    exit 1
fi
exit 0
EOF
    chmod 0755 "$path"
}

make_flock_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = "-n" ] || exit 90
exec "$TS_TEST_PYTHON" -c '
import fcntl
import sys

descriptor = int(sys.argv[1])
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    raise SystemExit(1)
' "$2"
EOF
    chmod 0755 "$path"
}

make_jsonfilter_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
file=""
operation=""
expression=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i)
            file="$2"
            shift 2
            ;;
        -e|-t)
            operation="$1"
            expression="$2"
            shift 2
            ;;
        *)
            exit 2
            ;;
    esac
done
exec "$TS_TEST_PYTHON" -c '
import json
import sys

path, operation, expression = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    document = json.load(handle)

paths = {
    "@.BackendState": ("BackendState",),
    "@.Version": ("Version",),
    "@.Self.ID": ("Self", "ID"),
    "@.TUN": ("TUN",),
    "@.Self.InEngine": ("Self", "InEngine"),
    "@.Self.TailscaleIPs": ("Self", "TailscaleIPs"),
    "@.Self.TailscaleIPs[0]": ("Self", "TailscaleIPs", 0),
    "@.AuthURL": ("AuthURL",),
}

def resolve(parts):
    value = document
    for part in parts:
        value = value[part]
    return value

def kind(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    if value is None:
        return "null"
    return "number"

try:
    if expression == "@.Self.TailscaleIPs[*]":
        values = resolve(("Self", "TailscaleIPs"))
        if not isinstance(values, list):
            raise KeyError
        if operation == "-t":
            print("\\ ".join(kind(value) for value in values))
        else:
            for value in values:
                if isinstance(value, bool):
                    print("true" if value else "false")
                else:
                    print(value)
    else:
        value = resolve(paths[expression])
        if operation == "-t":
            print(kind(value))
        elif isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value, separators=(",", ":")))
        elif value is not None:
            print(value)
except (KeyError, IndexError, TypeError):
    pass
' "$file" "$operation" "$expression"
EOF
    chmod 0755 "$path"
}

build_package() {
    package_root="$TEST_ROOT/package-build"
    package_dir="$package_root/$TARGET_DIRECTORY"
    mkdir -p "$package_dir" "$TEST_ROOT/packages"
    make_tailscale_binary "$package_dir/tailscale" "$TARGET_VERSION"
    make_tailscaled_binary "$package_dir/tailscaled" "$TARGET_VERSION"
    tar czf "$TEST_ROOT/packages/$TARGET_ARCHIVE" \
        -C "$package_root" "$TARGET_DIRECTORY"
    PACKAGE_SHA="$(sha256_file "$TEST_ROOT/packages/$TARGET_ARCHIVE")"
    printf '%s\n' "$PACKAGE_SHA" \
        > "$TEST_ROOT/packages/$TARGET_ARCHIVE.sha256"
}

refresh_package_pin() {
    PACKAGE_SHA="$(sha256_file "$TEST_ROOT/packages/$TARGET_ARCHIVE")"
    printf '%s\n' "$PACKAGE_SHA" \
        > "$TEST_ROOT/packages/$TARGET_ARCHIVE.sha256"
}

setup_case() {
    backend="${1:-Running}"
    old_version="${2:-1.92.3}"
    cleanup_case
    TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tailscale-upgrade-test.XXXXXX")"
    ROOT="$TEST_ROOT/root"
    CONTROL="$TEST_ROOT/control"
    TOOLS="$TEST_ROOT/tools"
    mkdir -p \
        "$ROOT/usr/sbin" \
        "$ROOT/usr/share/jammonitor" \
        "$ROOT/etc/init.d" \
        "$ROOT/etc/jammonitor" \
        "$ROOT/etc/config" \
        "$ROOT/etc/tailscale" \
        "$ROOT/dev" \
        "$ROOT/sys/class/block/sda1" \
        "$ROOT/sys/class/block/sda" \
        "$ROOT/var/run/jammonitor" \
        "$ROOT/var/run/tailscale" \
        "$ROOT/proc/4242" \
        "$ROOT/mnt/data" \
        "$CONTROL" \
        "$TOOLS" \
        "$TEST_ROOT/work"

    : > "$CONTROL/actions"
    : > "$CONTROL/running"
    printf '%s\n' "$backend" > "$CONTROL/backend"
    printf '%s\n' "$backend" > "$CONTROL/original-backend"
    printf '%s\n' "$old_version" > "$CONTROL/runtime-version"
    printf '%s\n' "node-stable-123" > "$CONTROL/stable-id"
    printf '%s\n' "SUPER_SECRET_AUTH_URL" > "$CONTROL/auth-url"
    if [ "$backend" = "Running" ]; then
        printf 'true\n' > "$CONTROL/tun"
        printf 'true\n' > "$CONTROL/in-engine"
        printf '100.104.78.42\n' > "$CONTROL/tailnet-ip"
        printf '100.70.186.127\n' \
            > "$ROOT/etc/jammonitor/tailscale-critical-peer"
    else
        printf 'false\n' > "$CONTROL/tun"
        printf 'false\n' > "$CONTROL/in-engine"
        printf '\n' > "$CONTROL/tailnet-ip"
    fi
    printf '%s\n' "SUPER_SECRET_STATE" \
        > "$ROOT/etc/tailscale/tailscaled.state"
    chmod 0600 "$ROOT/etc/tailscale/tailscaled.state"
    printf 'tailscaled\n' > "$ROOT/proc/4242/comm"
    : > "$ROOT/dev/sda1"
    printf '1\n' > "$ROOT/sys/class/block/sda1/partition"
    printf '1\n' > "$ROOT/sys/class/block/sda/removable"
    printf '/dev/disk/by-uuid/TEST-USB\n' > "$CONTROL/unused"
    printf 'TEST-USB-UUID\n' > "$CONTROL/block-uuid"
    {
        printf '%s\n' "fstab.jammonitor=mount"
        printf '%s\n' "fstab.jammonitor.target='/mnt/data'"
        printf '%s\n' "fstab.jammonitor.uuid='TEST-USB-UUID'"
        printf '%s\n' "fstab.jammonitor.fstype='ext4'"
        printf '%s\n' \
            "fstab.jammonitor.options='rw,noatime,nosuid,nodev,noexec'"
        printf '%s\n' "fstab.jammonitor.enabled='1'"
    } > "$CONTROL/fstab-show"
    printf '%s %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
        "$ROOT/dev/sda1" "$ROOT/mnt/data" \
        > "$ROOT/proc/mounts"
    : > "$ROOT/var/run/tailscale/tailscaled.sock"

    make_tailscale_binary "$ROOT/usr/sbin/tailscale" "$old_version"
    make_tailscaled_binary "$ROOT/usr/sbin/tailscaled" "$old_version"
    make_safe_init "$ROOT/etc/init.d/tailscale"
    init_sha="$(sha256_file "$ROOT/etc/init.d/tailscale")"
    printf '%s  %s\n' "$init_sha" "router/tailscale.init" \
        > "$ROOT/usr/share/jammonitor/router-files.sha256"
    manifest_sha="$(
        sha256_file "$ROOT/usr/share/jammonitor/router-files.sha256"
    )"
    printf '%s\n' "$manifest_sha" \
        > "$ROOT/usr/share/jammonitor/router-files.sha256.sha256"
    chmod 0644 \
        "$ROOT/usr/share/jammonitor/router-files.sha256" \
        "$ROOT/usr/share/jammonitor/router-files.sha256.sha256"
    make_timeout_mock "$TOOLS/timeout"
    make_stat_mock "$TOOLS/stat"
    make_sync_mock "$TOOLS/sync"
    make_flock_mock "$TOOLS/flock"
    make_jsonfilter_mock "$TOOLS/jsonfilter"
    make_uci_mock "$TOOLS/uci"
    make_block_mock "$TOOLS/block"
    build_package
}

run_upgrade_command() {
    output="$1"
    arch="$2"
    shift 2
    LAST_OUTPUT="$output"
    env \
        TS_UPGRADE_TESTING=1 \
        TS_UPGRADE_ROOT="$ROOT" \
        TS_UPGRADE_PACKAGE_SOURCE_DIR="$TEST_ROOT/packages" \
        TS_UPGRADE_EXPECTED_SHA256="$PACKAGE_SHA" \
        TS_UPGRADE_UNAME_OVERRIDE="$arch" \
        TS_UPGRADE_TIMEOUT_CMD="$TOOLS/timeout" \
        TS_UPGRADE_JSONFILTER_CMD="$TOOLS/jsonfilter" \
        TS_UPGRADE_SYNC_CMD="$TOOLS/sync" \
        TS_UPGRADE_SYNC_TIMEOUT=5 \
        TS_UPGRADE_FLOCK_CMD="$TOOLS/flock" \
        TS_UPGRADE_STAT_CMD="$TOOLS/stat" \
        TS_UPGRADE_UCI_CMD="$TOOLS/uci" \
        TS_UPGRADE_BLOCK_CMD="$TOOLS/block" \
        TS_UPGRADE_EXPECTED_ROOT_UID="$(id -u)" \
        TS_UPGRADE_EXPECTED_ROOT_GID="$(id -g)" \
        TS_UPGRADE_STATUS_ATTEMPTS=2 \
        TS_UPGRADE_STATUS_DELAY=0 \
        TS_UPGRADE_FETCH_TIMEOUT="${TS_UPGRADE_FETCH_TIMEOUT:-5}" \
        TS_UPGRADE_QUIESCE_ATTEMPTS=2 \
        TS_UPGRADE_QUIESCE_DELAY=0 \
        TS_UPGRADE_TMPDIR="$TEST_ROOT/work" \
        TS_UPGRADE_PROC_ROOT="$ROOT/proc" \
        TS_UPGRADE_SYS_CLASS_BLOCK="$ROOT/sys/class/block" \
        TS_UPGRADE_FSTAB_CONFIG_DIR="$ROOT/etc/config" \
        TS_UPGRADE_FD_ROOT="/dev/fd" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_CLI="${TS_UPGRADE_TEST_INTERRUPT_AFTER_CLI:-0}" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_FENCE="${TS_UPGRADE_TEST_INTERRUPT_AFTER_FENCE:-0}" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_DAEMON="${TS_UPGRADE_TEST_INTERRUPT_AFTER_DAEMON:-0}" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_LIVE_SYNC="${TS_UPGRADE_TEST_INTERRUPT_AFTER_LIVE_SYNC:-0}" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE="${TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE:-0}" \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_USB_CLEAR="${TS_UPGRADE_TEST_INTERRUPT_AFTER_USB_CLEAR:-0}" \
        TS_UPGRADE_TEST_RESTART_DAEMON_AFTER_CLI="${TS_UPGRADE_TEST_RESTART_DAEMON_AFTER_CLI:-0}" \
        TS_UPGRADE_TEST_INVALIDATE_MOUNT_PHASE="${TS_UPGRADE_TEST_INVALIDATE_MOUNT_PHASE:-none}" \
        TS_UPGRADE_TEST_TAMPER_DURABLE_AFTER_CLI="${TS_UPGRADE_TEST_TAMPER_DURABLE_AFTER_CLI:-0}" \
        TS_UPGRADE_TEST_SWAP_STORAGE_PHASE="${TS_UPGRADE_TEST_SWAP_STORAGE_PHASE:-none}" \
        TS_UPGRADE_TEST_HOLD_LOCK_FILE="${TS_UPGRADE_TEST_HOLD_LOCK_FILE:-}" \
        TS_TEST_PYTHON="$PYTHON_BIN" \
        TS_TEST_CONTROL_DIR="$CONTROL" \
        sh "$UPGRADER" "$@" > "$output" 2>&1
}

run_upgrade() {
    output="$1"
    arch="${2:-aarch64}"
    run_upgrade_command "$output" "$arch"
}

run_recovery_upgrade() {
    output="$1"
    digest="$2"
    run_upgrade_command "$output" aarch64 \
        --recover-empty-needs-login-state-sha256 "$digest"
}

setup_recovery_case() {
    setup_case NeedsLogin
    : > "$CONTROL/stable-id"
    RECOVERY_DIGEST="$(
        sha256_file "$ROOT/etc/tailscale/tailscaled.state"
    )"
}

assert_no_secret_output() {
    output="$1"
    ! grep -Fq "SUPER_SECRET_STATE" "$output" &&
        ! grep -Fq "SUPER_SECRET_AUTH_URL" "$output"
}

assert_no_forbidden_action() {
    ! grep -Eq '(^|[[:space:]])(up|down|logout|login)([[:space:]]|$)' \
        "$CONTROL/actions"
}

installed_version() {
    TS_TEST_CONTROL_DIR="$CONTROL" \
        "$ROOT/usr/sbin/tailscale" version 2>/dev/null
}

durable_recovery_root_is_empty() {
    recovery_root="$ROOT/mnt/data/.jammonitor-tailscale-upgrade"
    [ -d "$recovery_root" ] && [ ! -L "$recovery_root" ] || return 1
    for recovery_entry in \
        "$recovery_root"/.[!.]* \
        "$recovery_root"/..?* \
        "$recovery_root"/*
    do
        [ -e "$recovery_entry" ] || [ -L "$recovery_entry" ] || continue
        return 1
    done
    return 0
}

test_secret_output_assertion_rejects_each_secret() {
    setup_case Running
    LAST_OUTPUT=""
    for secret_value in SUPER_SECRET_STATE SUPER_SECRET_AUTH_URL; do
        injected_output="$TEST_ROOT/injected-secret"
        printf '%s\n' "$secret_value" > "$injected_output"
        if assert_no_secret_output "$injected_output"; then
            fail "secret-output assertion accepted injected secret material"
            return
        fi
    done
    pass "secret-output assertion rejects state and AuthURL independently"
}

test_running_success() {
    setup_case Running
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       grep -Eq '^[0-9]+$' "$CONTROL/observed-marker" &&
       [ "$(file_mode "$CONTROL/observed-marker")" = "600" ] &&
       [ -f "$CONTROL/authorized-fence-start" ] &&
       [ ! -e "$ROOT/etc/jammonitor/tailscale-upgrade-fence" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ] &&
       ! find "$ROOT/var/run/jammonitor" \
            -name 'tailscale-maintenance.tmp.*' -print -quit | grep -q . &&
       durable_recovery_root_is_empty &&
       assert_file_contains "$output" "strict delivery checks remained Running" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "Running upgrades and preserves state"
    else
        fail "Running upgrades and preserves state"
    fi
}

test_needs_login_success() {
    setup_case NeedsLogin
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ] &&
       assert_file_contains "$output" "operator authentication is still required" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "NeedsLogin remains an operator condition"
    else
        fail "NeedsLogin remains an operator condition"
    fi
}

test_needs_login_expired_identity_success() {
    setup_case NeedsLogin
    : > "$CONTROL/expire-identity-on-new"
    output="$TEST_ROOT/output"
    expected_cli_sha="$(
        sha256_file "$TEST_ROOT/package-build/$TARGET_DIRECTORY/tailscale"
    )"
    expected_daemon_sha="$(
        sha256_file "$TEST_ROOT/package-build/$TARGET_DIRECTORY/tailscaled"
    )"
    if run_upgrade "$output" &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ -f "$ROOT/etc/tailscale/tailscaled.state" ] &&
       [ ! -L "$ROOT/etc/tailscale/tailscaled.state" ] &&
       [ -s "$ROOT/etc/tailscale/tailscaled.state" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = \
         "EXPIRED_KEY_REGENERATED_STATE" ] &&
       [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" = "$expected_cli_sha" ] &&
       [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" = \
         "$expected_daemon_sha" ] &&
       assert_file_contains "$output" \
           "BackendState remains NeedsLogin and operator authentication is still required" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "expired NeedsLogin may regenerate to an empty Self.ID"
    else
        fail "expired NeedsLogin may regenerate to an empty Self.ID"
    fi
}

test_needs_login_empty_identity_rollback() {
    setup_case NeedsLogin
    : > "$CONTROL/expire-identity-on-new"
    : > "$CONTROL/fail-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ -f "$ROOT/etc/tailscale/tailscaled.state" ] &&
       [ ! -L "$ROOT/etc/tailscale/tailscaled.state" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = \
         "SUPER_SECRET_STATE" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "NeedsLogin rollback accepts an empty regenerated Self.ID"
    else
        fail "NeedsLogin rollback accepts an empty regenerated Self.ID"
    fi
}

test_needs_login_changed_identity_rollback() {
    setup_case NeedsLogin
    : > "$CONTROL/change-identity-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ "$(cat "$CONTROL/stable-id")" = "node-stable-123" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = \
         "SUPER_SECRET_STATE" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "post-upgrade BackendState or daemon version verification failed" &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "NeedsLogin rejects a different nonempty StableID"
    else
        fail "NeedsLogin rejects a different nonempty StableID"
    fi
}

test_needs_login_empty_identity_requires_auth_url() {
    setup_case NeedsLogin
    : > "$CONTROL/expire-identity-on-new"
    : > "$CONTROL/remove-auth-url-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ -s "$CONTROL/auth-url" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = \
         "SUPER_SECRET_STATE" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "post-upgrade BackendState or daemon version verification failed" &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "empty NeedsLogin target identity also requires AuthURL"
    else
        fail "empty NeedsLogin target identity also requires AuthURL"
    fi
}

test_needs_login_empty_rollback_requires_auth_url() {
    setup_case NeedsLogin
    : > "$CONTROL/expire-identity-on-new"
    : > "$CONTROL/fail-new"
    : > "$CONTROL/remove-auth-url-on-rollback"
    output="$TEST_ROOT/output"
    evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ ! -s "$CONTROL/auth-url" ] &&
       [ -s "$evidence" ] &&
       assert_file_contains "$output" \
           "previous service identity/state was not restored" &&
       assert_file_contains "$output" \
           "CRITICAL: Tailscale rollback is incomplete" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "empty NeedsLogin rollback without AuthURL is incomplete"
    else
        fail "empty NeedsLogin rollback without AuthURL is incomplete"
    fi
}

test_empty_needs_login_recovery_success() {
    setup_recovery_case
    output="$TEST_ROOT/output"
    if run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "BackendState remains NeedsLogin and operator authentication is still required" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "operator-authorized empty NeedsLogin recovery preserves exact state"
    else
        fail "operator-authorized empty NeedsLogin recovery preserves exact state"
    fi
}

test_empty_needs_login_recovery_requires_auth_url() {
    setup_recovery_case
    : > "$CONTROL/auth-url"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       ! grep -Fq "stop" "$CONTROL/actions" &&
       assert_file_contains "$output" "requires a pending authentication URL" &&
       assert_no_secret_output "$output"; then
        pass "empty NeedsLogin recovery requires a nonempty AuthURL"
    else
        fail "empty NeedsLogin recovery requires a nonempty AuthURL"
    fi
}

test_empty_needs_login_recovery_rejects_wrong_preconditions() {
    for backend in Running NeedsLogin; do
        setup_case "$backend"
        digest="$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")"
        output="$TEST_ROOT/output-$backend"
        if run_recovery_upgrade "$output" "$digest" ||
           grep -Fq "stop" "$CONTROL/actions" ||
           ! assert_file_contains "$output" \
               "empty-identity recovery requires NeedsLogin with no StableID"; then
            fail "recovery flag accepted $backend with a nonempty StableID"
            return
        fi
    done
    pass "recovery flag is rejected outside empty-ID NeedsLogin"
}

test_empty_needs_login_recovery_argument_guards() {
    setup_recovery_case
    output="$TEST_ROOT/output-malformed"
    if run_upgrade_command "$output" aarch64 \
           --recover-empty-needs-login-state-sha256 not-a-digest ||
       ! assert_file_contains "$output" "recovery state checksum is malformed" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "malformed recovery digest was accepted"
        return
    fi

    setup_recovery_case
    output="$TEST_ROOT/output-arity"
    if run_upgrade_command "$output" aarch64 \
           --recover-empty-needs-login-state-sha256 ||
       ! assert_file_contains "$output" "invalid recovery arguments" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "incomplete recovery arguments were accepted"
        return
    fi

    setup_recovery_case
    output="$TEST_ROOT/output-extra"
    if run_upgrade_command "$output" aarch64 \
           --recover-empty-needs-login-state-sha256 "$RECOVERY_DIGEST" extra ||
       ! assert_file_contains "$output" "invalid recovery arguments" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "extra recovery arguments were accepted"
        return
    fi

    setup_recovery_case
    output="$TEST_ROOT/output-unknown"
    if run_upgrade_command "$output" aarch64 \
           --unknown-recovery-option "$RECOVERY_DIGEST" ||
       ! assert_file_contains "$output" "invalid recovery arguments" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "unknown recovery arguments were accepted"
        return
    fi
    pass "recovery CLI rejects malformed digest, arity, and option names"
}

test_empty_needs_login_recovery_requires_exact_current_hash() {
    setup_recovery_case
    wrong_digest="0000000000000000000000000000000000000000000000000000000000000000"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$wrong_digest" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       ! grep -Fq "stop" "$CONTROL/actions" &&
       assert_file_contains "$output" \
           "does not match the operator-authorized checksum" &&
       assert_no_secret_output "$output"; then
        pass "recovery digest must match current state before stop"
    else
        fail "recovery digest must match current state before stop"
    fi
}

test_empty_needs_login_recovery_restores_stop_flush() {
    setup_recovery_case
    : > "$CONTROL/flush-state-on-stop"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "quiescent Tailscale state does not match the operator-authorized checksum" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "recovery restores authorized state if stop flushes different bytes"
    else
        fail "recovery restores authorized state if stop flushes different bytes"
    fi
}

test_empty_needs_login_recovery_rejects_target_state_rewrite() {
    setup_recovery_case
    : > "$CONTROL/mutate-state-on-new"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "target state rewrite triggers exact recovery rollback"
    else
        fail "target state rewrite triggers exact recovery rollback"
    fi
}

test_empty_needs_login_recovery_rejects_target_identity() {
    setup_recovery_case
    : > "$CONTROL/nonempty-identity-on-new"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "target cannot surface a StableID during empty-ID recovery"
    else
        fail "target cannot surface a StableID during empty-ID recovery"
    fi
}

test_empty_needs_login_recovery_rejects_target_running() {
    setup_recovery_case
    : > "$CONTROL/running-on-new"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "target Running state is forbidden during empty-ID recovery"
    else
        fail "target Running state is forbidden during empty-ID recovery"
    fi
}

test_empty_needs_login_recovery_detects_rollback_rewrite() {
    setup_recovery_case
    : > "$CONTROL/mutate-state-on-new"
    : > "$CONTROL/mutate-state-on-rollback"
    output="$TEST_ROOT/output"
    evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ -s "$evidence" ] &&
       assert_file_contains "$output" \
           "previous service identity/state was not restored" &&
       assert_file_contains "$output" \
           "CRITICAL: Tailscale rollback is incomplete" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "rollback daemon state rewrite is reported as incomplete recovery"
    else
        fail "rollback daemon state rewrite is reported as incomplete recovery"
    fi
}

test_empty_needs_login_recovery_target_requires_auth_url() {
    setup_recovery_case
    : > "$CONTROL/remove-auth-url-on-new"
    output="$TEST_ROOT/output"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ -s "$CONTROL/auth-url" ] &&
       [ "$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")" = \
         "$RECOVERY_DIGEST" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "post-upgrade BackendState or daemon version verification failed" &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "recovery target empty identity also requires AuthURL"
    else
        fail "recovery target empty identity also requires AuthURL"
    fi
}

test_empty_needs_login_recovery_rollback_requires_auth_url() {
    setup_recovery_case
    : > "$CONTROL/mutate-state-on-new"
    : > "$CONTROL/remove-auth-url-on-rollback"
    output="$TEST_ROOT/output"
    evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
    if ! run_recovery_upgrade "$output" "$RECOVERY_DIGEST" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "NeedsLogin" ] &&
       [ ! -s "$CONTROL/stable-id" ] &&
       [ ! -s "$CONTROL/auth-url" ] &&
       [ -s "$evidence" ] &&
       assert_file_contains "$output" \
           "previous service identity/state was not restored" &&
       assert_file_contains "$output" \
           "CRITICAL: Tailscale rollback is incomplete" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "recovery rollback empty identity without AuthURL is incomplete"
    else
        fail "recovery rollback empty identity without AuthURL is incomplete"
    fi
}

test_checksum_failure() {
    setup_case Running
    output="$TEST_ROOT/output"
    printf '%064d\n' 0 > "$TEST_ROOT/packages/$TARGET_ARCHIVE.sha256"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       ! grep -Fq "stop" "$CONTROL/actions" &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ]; then
        pass "checksum mismatch fails before service mutation"
    else
        fail "checksum mismatch fails before service mutation"
    fi
}

test_fetch_and_archive_resource_bounds() {
    setup_case Running
    archive="$TEST_ROOT/packages/$TARGET_ARCHIVE"
    dd if=/dev/zero of="$archive" bs=1 count=0 seek=68157440 \
        2>/dev/null
    output="$TEST_ROOT/output-oversized-archive"
    if run_upgrade "$output" || grep -Fqx stop "$CONTROL/actions"; then
        fail "oversized archive stream escaped the kernel file-size cap"
        return
    fi

    setup_case Running
    checksum="$TEST_ROOT/packages/$TARGET_ARCHIVE.sha256"
    dd if=/dev/zero of="$checksum" bs=5000 count=1 2>/dev/null
    output="$TEST_ROOT/output-oversized-checksum"
    if run_upgrade "$output" || grep -Fqx stop "$CONTROL/actions"; then
        fail "oversized checksum stream escaped the kernel file-size cap"
        return
    fi

    setup_case Running
    package_dir="$TEST_ROOT/package-build/$TARGET_DIRECTORY"
    member_index=1
    while [ "$member_index" -le 20 ]; do
        printf '%s\n' "$member_index" \
            > "$package_dir/extra-$member_index"
        member_index=$((member_index + 1))
    done
    tar czf "$TEST_ROOT/packages/$TARGET_ARCHIVE" \
        -C "$TEST_ROOT/package-build" "$TARGET_DIRECTORY"
    refresh_package_pin
    output="$TEST_ROOT/output-member-count"
    if run_upgrade "$output" ||
       ! assert_file_contains "$output" "too many members" ||
       grep -Fqx stop "$CONTROL/actions"; then
        fail "archive member-count bomb reached extraction or service mutation"
        return
    fi

    setup_case Running
    package_dir="$TEST_ROOT/package-build/$TARGET_DIRECTORY"
    dd if=/dev/zero of="$package_dir/expanded-bomb" \
        bs=1 count=0 seek=135266304 2>/dev/null
    tar czf "$TEST_ROOT/packages/$TARGET_ARCHIVE" \
        -C "$TEST_ROOT/package-build" "$TARGET_DIRECTORY"
    refresh_package_pin
    output="$TEST_ROOT/output-expanded-size"
    if run_upgrade "$output" ||
       ! assert_file_contains "$output" \
           "metadata exceeds the bounded extraction contract" ||
       grep -Fqx stop "$CONTROL/actions"; then
        fail "archive expanded-size bomb reached extraction or service mutation"
        return
    fi

    setup_case Running
    package_dir="$TEST_ROOT/package-build/$TARGET_DIRECTORY"
    ln -s tailscale "$package_dir/linked-member"
    tar czf "$TEST_ROOT/packages/$TARGET_ARCHIVE" \
        -C "$TEST_ROOT/package-build" "$TARGET_DIRECTORY"
    refresh_package_pin
    output="$TEST_ROOT/output-linked-member"
    if run_upgrade "$output" ||
       ! assert_file_contains "$output" \
           "metadata exceeds the bounded extraction contract" ||
       grep -Fqx stop "$CONTROL/actions"; then
        fail "archive link member reached extraction or service mutation"
        return
    fi
    pass "fetch, listing, member-count, link, and expanded-size bounds fail closed"
}

test_architecture_guard() {
    setup_case Running
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" x86_64 &&
       assert_file_contains "$output" "refused x86_64" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "non-aarch64 host is refused"
    else
        fail "non-aarch64 host is refused"
    fi
}

test_production_override_guard() {
    for override in \
        TS_UPGRADE_STATUS_ATTEMPTS=1 \
        TS_UPGRADE_FETCH_TIMEOUT=1 \
        TS_UPGRADE_SYNC_CMD=/bin/false \
        TS_UPGRADE_SYNC_TIMEOUT=1 \
        TS_UPGRADE_FLOCK_CMD=/bin/false \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_CLI=1 \
        TS_UPGRADE_TEST_INTERRUPT_AFTER_LIVE_SYNC=1 \
        TS_UPGRADE_TEST_RESTART_DAEMON_AFTER_CLI=1 \
        TS_UPGRADE_TEST_INVALIDATE_MOUNT_PHASE=before-cli \
        TS_UPGRADE_TEST_TAMPER_DURABLE_AFTER_CLI=1 \
        TS_UPGRADE_TEST_HOLD_LOCK_FILE=/tmp/forbidden-lock-hook
    do
        setup_case Running
        output="$TEST_ROOT/output"
        if env "$override" sh "$UPGRADER" > "$output" 2>&1 ||
           ! assert_file_contains "$output" \
               "test-only command or timing override refused" ||
           grep -Fq "stop" "$CONTROL/actions"; then
            fail "production accepted test override: $override"
            return
        fi
    done
    pass "test overrides are refused outside the test harness"
}

test_unsafe_init_guard() {
    setup_case Running
    make_unsafe_init "$ROOT/etc/init.d/tailscale"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "persistent control action" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "unsafe tailscale down init is refused"
    else
        fail "unsafe tailscale down init is refused"
    fi
}

test_initial_running_preflight_is_bounded_and_exact() {
    for failure_mode in running-hang running-rc2; do
        setup_case Running
        : > "$CONTROL/$failure_mode"
        output="$TEST_ROOT/output-$failure_mode"
        if run_upgrade "$output" ||
           grep -Fq stop "$CONTROL/actions" ||
           ! assert_file_contains "$output" \
               "running preflight did not return exact success"; then
            fail "initial running preflight accepted $failure_mode"
            return
        fi
        if [ "$failure_mode" = "running-hang" ] &&
           [ ! -f "$CONTROL/running-timeout-intercepted" ]; then
            fail "initial running hang bypassed the bounded timeout wrapper"
            return
        fi
    done
    pass "initial running preflight is bounded and accepts only exact rc 0"
}

test_postcheck_rollback() {
    setup_case Running
    : > "$CONTROL/fail-new"
    : > "$CONTROL/mutate-state-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$CONTROL/backend")" = "Running" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ] &&
       durable_recovery_root_is_empty &&
       assert_file_contains "$output" "restoring the previous verified state" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "failed post-check restores old binaries and service"
    else
        fail "failed post-check restores old binaries and service"
    fi
}

test_missing_state_rollback() {
    setup_case Running
    : > "$CONTROL/delete-state-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ]; then
        pass "missing state is restored only during rollback"
    else
        fail "missing state is restored only during rollback"
    fi
}

test_identity_change_rollback() {
    setup_case Running
    : > "$CONTROL/change-identity-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       [ "$(cat "$CONTROL/stable-id")" = "node-stable-123" ] &&
       assert_file_contains "$output" "post-upgrade BackendState or daemon version verification failed" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "identity change restores the original state and binaries"
    else
        fail "identity change restores the original state and binaries"
    fi
}

test_preexisting_maintenance_marker() {
    setup_case Running
    marker_value="$(( $(date +%s) + 2000 ))"
    printf '%s\n' "$marker_value" \
        > "$ROOT/var/run/jammonitor/tailscale-maintenance"
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(cat "$ROOT/var/run/jammonitor/tailscale-maintenance")" = \
         "$marker_value" ]; then
        pass "preexisting maintenance marker is retained"
    else
        fail "preexisting maintenance marker is retained"
    fi
}

test_expired_maintenance_marker_refused() {
    setup_case Running
    printf '%s\n' "$(( $(date +%s) - 1 ))" \
        > "$ROOT/var/run/jammonitor/tailscale-maintenance"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "cannot cover the calculated" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "expired maintenance marker is refused before mutation"
    else
        fail "expired maintenance marker is refused before mutation"
    fi
}

test_malformed_maintenance_marker_refused() {
    setup_case Running
    printf '%s\n' "not-an-expiry" \
        > "$ROOT/var/run/jammonitor/tailscale-maintenance"
    output="$TEST_ROOT/output"
    if run_upgrade "$output" ||
       ! assert_file_contains "$output" "maintenance marker is malformed" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "malformed maintenance marker is refused before mutation"
        return
    fi

    setup_case Running
    {
        printf '%s\n' "$(( $(date +%s) + 3500 ))"
        printf '\n'
    } > "$ROOT/var/run/jammonitor/tailscale-maintenance"
    output="$TEST_ROOT/output-multiline"
    if run_upgrade "$output" ||
       ! assert_file_contains "$output" "not an exact one-line lease" ||
       grep -Fq "stop" "$CONTROL/actions"; then
        fail "multiline maintenance marker was accepted"
        return
    fi

    pass "malformed maintenance marker is refused before mutation"
}

test_idempotent_target_version() {
    setup_case Running "$TARGET_VERSION"
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       assert_file_contains "$output" "already installed" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "target version is an idempotent no-op"
    else
        fail "target version is an idempotent no-op"
    fi
}

test_same_version_wrong_bytes_are_replaced() {
    setup_case Running "$TARGET_VERSION"
    printf '# substituted cli bytes\n' >> "$ROOT/usr/sbin/tailscale"
    printf '# substituted daemon bytes\n' >> "$ROOT/usr/sbin/tailscaled"
    output="$TEST_ROOT/output"
    expected_cli_sha="$(
        sha256_file "$TEST_ROOT/package-build/$TARGET_DIRECTORY/tailscale"
    )"
    expected_daemon_sha="$(
        sha256_file "$TEST_ROOT/package-build/$TARGET_DIRECTORY/tailscaled"
    )"
    if run_upgrade "$output" &&
       grep -Fqx stop "$CONTROL/actions" &&
       [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" = "$expected_cli_sha" ] &&
       [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" = \
         "$expected_daemon_sha" ] &&
       ! assert_file_contains "$output" "already installed"; then
        pass "same-version binaries require exact authenticated hashes"
    else
        fail "same-version binaries require exact authenticated hashes"
    fi
}

test_downgrade_guard() {
    setup_case Running "1.100.0"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "refusing to downgrade" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "newer version is not downgraded"
    else
        fail "newer version is not downgraded"
    fi
}

test_mixed_newer_daemon_downgrade_guard() {
    setup_case Running "1.92.3"
    printf '%s\n' "1.100.0" > "$CONTROL/runtime-version"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       assert_file_contains "$output" \
           "refusing to downgrade a newer running tailscaled daemon" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "older CLI cannot downgrade a newer running daemon"
    else
        fail "older CLI cannot downgrade a newer running daemon"
    fi
}

test_nonzero_status_is_rejected() {
    setup_case Running
    : > "$CONTROL/status-nonzero"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       assert_file_contains "$output" \
           "could not read the pre-upgrade Tailscale BackendState" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "nonzero LocalAPI CLI status fails closed despite parseable JSON"
    else
        fail "nonzero LocalAPI CLI status fails closed despite parseable JSON"
    fi
}

test_stop_flush_state_is_authoritative() {
    setup_case Running
    : > "$CONTROL/flush-state-on-stop"
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "QUIESCENT_STATE" ] &&
       [ "$(installed_version)" = "$TARGET_VERSION" ]; then
        pass "state flushed during stop becomes the authoritative backup state"
    else
        fail "state flushed during stop becomes the authoritative backup state"
    fi
}

test_stop_flush_state_rolls_back_exactly() {
    setup_case Running
    : > "$CONTROL/flush-state-on-stop"
    : > "$CONTROL/fail-new"
    : > "$CONTROL/mutate-state-on-new"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "QUIESCENT_STATE" ] &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ]; then
        pass "rollback restores the exact post-quiescence state"
    else
        fail "rollback restores the exact post-quiescence state"
    fi
}

test_stop_timeout_is_prebackup() {
    setup_case Running
    : > "$CONTROL/stop-timeout"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       [ "$(grep -c '^stop$' "$CONTROL/actions")" -eq 1 ] &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" "did not stop within the bounded timeout"; then
        pass "stop timeout never restores or overwrites unbacked state"
    else
        fail "stop timeout never restores or overwrites unbacked state"
    fi
}

test_live_daemon_blocks_backup() {
    setup_case Running
    : > "$CONTROL/daemon-stays-live"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       [ "$(grep -c '^stop$' "$CONTROL/actions")" -eq 1 ] &&
       assert_file_contains "$output" "daemon or LocalAPI socket remained live"; then
        pass "live daemon or socket prevents state backup and binary mutation"
    else
        fail "live daemon or socket prevents state backup and binary mutation"
    fi
}

test_short_maintenance_lease_refused() {
    setup_case Running
    printf '%s\n' "$(( $(date +%s) + 300 ))" \
        > "$ROOT/var/run/jammonitor/tailscale-maintenance"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "cannot cover the calculated" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "preexisting lease must cover worst-case upgrade and rollback"
    else
        fail "preexisting lease must cover worst-case upgrade and rollback"
    fi
}

test_missing_stable_id_refused() {
    for backend in Running NeedsLogin; do
        setup_case "$backend"
        : > "$CONTROL/stable-id"
        output="$TEST_ROOT/output-$backend"
        if run_upgrade "$output" ||
           ! assert_file_contains "$output" "lacks StableID" ||
           grep -Fq "stop" "$CONTROL/actions"; then
            fail "empty pre-upgrade StableID was accepted for $backend"
            return
        fi
    done
    pass "empty pre-upgrade StableID fails before mutation"
}

test_valid_tailscale_ipv6_running() {
    for tailnet_address in \
        'fd7a:115c:a1e0::4901:ba87' \
        'fd7a:115c:a1e0:0000:0000:0000:4901:ba87' \
        'FD7A:115C:A1E0:0:0::1' \
        'fd7a:115c:a1e0::'
    do
        setup_case Running
        printf '%s\n' "$tailnet_address" > "$CONTROL/tailnet-ip"
        output="$TEST_ROOT/output"
        if ! run_upgrade "$output" ||
           [ "$(installed_version)" != "$TARGET_VERSION" ] ||
           ! assert_file_contains "$output" \
               "strict delivery checks remained Running" ||
           ! assert_no_secret_output "$output" ||
           ! assert_no_forbidden_action; then
            fail "valid Tailscale IPv6 address was rejected: $tailnet_address"
            return
        fi
    done
    pass "valid compressed and full Tailscale IPv6 addresses are accepted"
}

test_invalid_tailscale_ipv6_running_refused() {
    for tailnet_address in \
        'fd7a:115c:a1e0::zzzz' \
        'fd7a:115c:a1e0::00000' \
        'fd7a:115c:a1e0:0:0:0:0:0:1' \
        'fd7a:115c:a1e0:0:0:0:1' \
        'fd7a:115c:a1e0::1::2' \
        'fd7a:115c:a1e0:::1' \
        'fd7a:115c:a1e0:' \
        'fd7a:115c:a1e0:0::1:' \
        'fd7a:115c:a1e0::1%tailscale0' \
        'fd7a:115c:a1e0::192.0.2.1' \
        'fd7b:115c:a1e0::1' \
        'fd7a:115c:a1e1::1' \
        'fd7a:115c:a1e0::0:0:0:0:0' \
        'fd7a:115c:a1e0:0::1::' \
        'fd7a:115c:a1e0:0:0::1:2:3:4'
    do
        setup_case Running
        printf '%s\n' "$tailnet_address" > "$CONTROL/tailnet-ip"
        output="$TEST_ROOT/output"
        if run_upgrade "$output" ||
           grep -Fq "stop" "$CONTROL/actions" ||
           ! assert_file_contains "$output" "required delivery semantics"; then
            fail "malformed or out-of-prefix IPv6 was accepted: $tailnet_address"
            return
        fi
    done
    pass "malformed and out-of-prefix Tailscale IPv6 addresses are refused"
}

test_tailscale_ipv4_range_boundaries() {
    for tailnet_address in '100.64.0.0' '100.127.255.255'; do
        setup_case Running
        printf '%s\n' "$tailnet_address" > "$CONTROL/tailnet-ip"
        output="$TEST_ROOT/output"
        if ! run_upgrade "$output" ||
           [ "$(installed_version)" != "$TARGET_VERSION" ]; then
            fail "valid Tailscale IPv4 boundary was rejected: $tailnet_address"
            return
        fi
    done

    for tailnet_address in \
        '100.63.255.255' \
        '100.128.0.0' \
        '100.064.0.1' \
        '100.64.00.1' \
        '100.64.0.01' \
        '100.64..1' \
        '100.64.0.1.'
    do
        setup_case Running
        printf '%s\n' "$tailnet_address" > "$CONTROL/tailnet-ip"
        output="$TEST_ROOT/output"
        if run_upgrade "$output" || grep -Fq "stop" "$CONTROL/actions"; then
            fail "out-of-range Tailscale IPv4 was accepted: $tailnet_address"
            return
        fi
    done
    pass "Tailscale IPv4 acceptance is canonical and confined to 100.64.0.0/10"
}

test_degraded_running_refused() {
    for field in tun tailnet-ip; do
        setup_case Running
        case "$field" in
            tun) printf 'false\n' > "$CONTROL/tun" ;;
            tailnet-ip) printf '8.8.8.8\n' > "$CONTROL/tailnet-ip" ;;
        esac
        output="$TEST_ROOT/output-$field"
        if run_upgrade "$output" ||
           ! assert_file_contains "$output" "required delivery semantics" ||
           grep -Fq "stop" "$CONTROL/actions"; then
            fail "degraded Running fails closed ($field)"
            return
        fi
    done
    pass "Running requires TUN and a real tailnet address"
}

test_self_in_engine_is_not_a_running_gate() {
    setup_case Running
    printf 'false\n' > "$CONTROL/in-engine"
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = \
         "SUPER_SECRET_STATE" ] &&
       assert_file_contains "$output" "strict delivery checks remained Running" &&
       assert_no_secret_output "$output" &&
       assert_no_forbidden_action; then
        pass "Self.InEngine is not treated as local engine readiness"
    else
        fail "Self.InEngine is not treated as local engine readiness"
    fi
}

test_installed_hash_mismatch_rolls_back() {
    setup_case Running
    : > "$CONTROL/tamper-installed-daemon"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(installed_version)" = "1.92.3" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       assert_file_contains "$output" "post-upgrade BackendState or daemon version verification failed"; then
        pass "exact installed binary hashes are part of success"
    else
        fail "exact installed binary hashes are part of success"
    fi
}

test_additional_unsafe_init_guards() {
    for payload in \
        '/usr/sbin/tailscale login' \
        'rm -f "$STATE_FILE"' \
        ': > "$STATE_FILE"'
    do
        setup_case Running
        printf '%s\n' "$payload" >> "$ROOT/etc/init.d/tailscale"
        output="$TEST_ROOT/output"
        if run_upgrade "$output" || grep -Fq "stop" "$CONTROL/actions"; then
            fail "unsafe init payload was accepted: $payload"
            return
        fi
    done
    pass "init validation rejects login and persistent state mutation"
}

test_escaped_init_cli_spelling_fails_manifest_authentication() {
    setup_case Running
    printf '%s\n' '/usr/sbin/tailscal\e d\own' \
        >> "$ROOT/etc/init.d/tailscale"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" \
           "installed Tailscale init failed manifest authentication" &&
       [ ! -s "$CONTROL/actions" ]; then
        pass "escaped stateful init spelling cannot bypass manifest authentication"
    else
        fail "escaped stateful init spelling reached an init invocation"
    fi
}

test_init_drift_after_stop_blocks_every_later_invocation() {
    setup_case Running
    : > "$CONTROL/tamper-init-after-stop"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ "$(grep -c '^stop$' "$CONTROL/actions" || true)" -eq 1 ] &&
       ! grep -Fqx start "$CONTROL/actions" &&
       assert_file_contains "$output" \
           "installed Tailscale init failed manifest authentication" &&
       [ -d "$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending" ]; then
        pass "init drift after stop blocks start, rollback execution, and WAL cleanup"
    else
        fail "late init drift reached a later init invocation or lost recovery evidence"
    fi
}

test_persistent_mount_guard() {
    for mount_case in \
        read-only \
        wrong-filesystem \
        conflicting-options \
        duplicate-valid \
        duplicate-conflicting
    do
        setup_case Running
        case "$mount_case" in
            read-only)
                printf '%s %s ext4 ro,relatime 0 0\n' \
                    "$ROOT/dev/sda1" "$ROOT/mnt/data" \
                    > "$ROOT/proc/mounts"
                ;;
            wrong-filesystem)
                printf '%s %s exfat rw,noatime,nosuid,nodev,noexec 0 0\n' \
                    "$ROOT/dev/sda1" "$ROOT/mnt/data" \
                    > "$ROOT/proc/mounts"
                ;;
            conflicting-options)
                printf '%s %s ext4 rw,ro,relatime 0 0\n' \
                    "$ROOT/dev/sda1" "$ROOT/mnt/data" \
                    > "$ROOT/proc/mounts"
                ;;
            duplicate-valid)
                {
                    printf '%s %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
                        "$ROOT/dev/sda1" "$ROOT/mnt/data"
                    printf '%s %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
                        "$ROOT/dev/sda1" "$ROOT/mnt/data"
                } > "$ROOT/proc/mounts"
                ;;
            duplicate-conflicting)
                {
                    printf '%s %s ext4 rw,noatime,nosuid,nodev,noexec 0 0\n' \
                        "$ROOT/dev/sda1" "$ROOT/mnt/data"
                    printf 'otherdev %s ext4 ro,relatime 0 0\n' \
                        "$ROOT/mnt/data"
                } > "$ROOT/proc/mounts"
                ;;
        esac
        output="$TEST_ROOT/output-$mount_case"
        if run_upgrade "$output" ||
           grep -Fq stop "$CONTROL/actions" ||
           ! assert_file_contains "$output" \
               "storage authority is unsafe or ambiguous"; then
            fail "unsafe persistent mount was accepted: $mount_case"
            return
        fi
    done
    pass "binary mutation requires the exact read-write ext4 persistent mount"
}

test_storage_authority_contract() {
    setup_case Running
    {
        printf '%s\n' "fstab.@mount[0]=mount"
        printf '%s\n' "fstab.@mount[0].target='/mnt/data'"
        printf '%s\n' "fstab.@mount[0].uuid='TEST-USB-UUID'"
        printf '%s\n' "fstab.@mount[0].enabled='1'"
        printf '%s\n' \
            "fstab.@mount[0].options='rw,noatime,nosuid,nodev,noexec'"
    } > "$CONTROL/fstab-show"
    output="$TEST_ROOT/output-anonymous"
    if ! run_upgrade "$output" ||
       [ "$(installed_version)" != "$TARGET_VERSION" ]; then
        fail "live anonymous UCI authority with block ext4/rw proof was rejected"
        return
    fi

    for authority_case in duplicate-target wrong-fstype wrong-options \
        writable-root duplicate-uuid
    do
        setup_case Running
        case "$authority_case" in
            duplicate-target)
                {
                    cat "$CONTROL/fstab-show"
                    printf '%s\n' "fstab.other=mount"
                    printf '%s\n' "fstab.other.target='/mnt/data'"
                    printf '%s\n' "fstab.other.uuid='OTHER-UUID'"
                    printf '%s\n' "fstab.other.enabled='1'"
                } > "$CONTROL/fstab-show.new"
                mv "$CONTROL/fstab-show.new" "$CONTROL/fstab-show"
                ;;
            wrong-fstype)
                printf '%s\n' "fstab.jammonitor.fstype='exfat'" \
                    >> "$CONTROL/fstab-show"
                ;;
            wrong-options)
                printf '%s\n' "fstab.jammonitor.options='ro'" \
                    >> "$CONTROL/fstab-show"
                ;;
            writable-root)
                chmod 0777 "$ROOT/mnt/data"
                ;;
            duplicate-uuid)
                mkdir -p "$ROOT/sys/class/block/sdb1" \
                    "$ROOT/sys/class/block/sdb"
                printf '1\n' > "$ROOT/sys/class/block/sdb1/partition"
                printf '1\n' > "$ROOT/sys/class/block/sdb/removable"
                : > "$ROOT/dev/sdb1"
                printf 'TEST-USB-UUID\n' > "$CONTROL/block-uuid-sdb1"
                ;;
        esac
        output="$TEST_ROOT/output-$authority_case"
        if run_upgrade "$output" ||
           grep -Fqx stop "$CONTROL/actions" ||
           ! assert_file_contains "$output" \
               "storage authority is unsafe or ambiguous"; then
            fail "unsafe storage authority was accepted: $authority_case"
            return
        fi
    done
    pass "storage authority joins one UCI target, removable partition, UUID, and safe root"
}

test_pinned_storage_identity_blocks_path_swaps() {
    for swap_kind in mount-root source; do
        setup_case Running
        output="$TEST_ROOT/output-$swap_kind"
        if TS_UPGRADE_TEST_SWAP_STORAGE_PHASE="${swap_kind}-before-cli" \
           run_upgrade "$output" ||
           [ "$(installed_version)" != "1.92.3" ] ||
           ! assert_file_contains "$output" \
               "persistent recovery mount changed immediately before binary replacement"; then
            fail "pinned storage identity missed path replacement: $swap_kind"
            return
        fi
    done
    pass "pinned device and mount identities are rejoined at binary boundaries"
}

test_unresolved_durable_evidence_blocks_retry() {
    for evidence_name in pending .staging.999 unexpected; do
        setup_case Running
        recovery_root="$ROOT/mnt/data/.jammonitor-tailscale-upgrade"
        mkdir -p "$recovery_root/$evidence_name"
        printf '%s\n' unresolved > "$recovery_root/$evidence_name/evidence"
        output="$TEST_ROOT/output-$evidence_name"
        if run_upgrade "$output" ||
           grep -Fq stop "$CONTROL/actions" ||
           [ ! -f "$recovery_root/$evidence_name/evidence" ] ||
           ! assert_file_contains "$output" \
               "unresolved durable Tailscale upgrade evidence"; then
            fail "durable evidence did not block retry: $evidence_name"
            return
        fi
    done

    setup_case Running
    recovery_root="$ROOT/mnt/data/.jammonitor-tailscale-upgrade"
    mkdir -p "$recovery_root" "$CONTROL/external-evidence"
    printf '%s\n' unresolved > "$CONTROL/external-evidence/evidence"
    ln -s "$CONTROL/external-evidence" "$recovery_root/pending"
    output="$TEST_ROOT/output-symlink"
    if run_upgrade "$output" ||
       grep -Fq stop "$CONTROL/actions" ||
       [ ! -L "$recovery_root/pending" ] ||
       [ ! -f "$CONTROL/external-evidence/evidence" ] ||
       ! assert_file_contains "$output" \
           "unresolved durable Tailscale upgrade evidence"; then
        fail "symlinked durable evidence was accepted or deleted"
        return
    fi

    pass "every unresolved durable artifact blocks retry without deletion"
}

test_persistent_flock_serializes_and_releases_stale_holder() {
    setup_case Running
    hold_file="$CONTROL/hold-upgrader-lock"
    holder_output="$TEST_ROOT/holder-output"
    : > "$hold_file"

    (
        TS_UPGRADE_TEST_HOLD_LOCK_FILE="$hold_file"
        export TS_UPGRADE_TEST_HOLD_LOCK_FILE
        run_upgrade "$holder_output"
    ) &
    holder_job=$!

    attempts=100
    while [ "$attempts" -gt 0 ] &&
          [ ! -s "$hold_file.acquired" ]; do
        sleep 0.1
        attempts=$((attempts - 1))
    done
    if [ ! -s "$hold_file.acquired" ]; then
        kill "$holder_job" 2>/dev/null || true
        wait "$holder_job" 2>/dev/null || true
        fail "flock holder did not publish acquisition"
        return
    fi

    lock_file="$ROOT/var/run/jammonitor/router-install.lock"
    holder_script_pid="$(cat "$hold_file.acquired")"
    lock_inode_before="$(ls -id "$lock_file" | awk '{print $1}')"
    contender_output="$TEST_ROOT/contender-output"
    if run_upgrade "$contender_output" ||
       ! assert_file_contains "$contender_output" \
           "another JamMonitor install or Tailscale upgrade is running"; then
        kill -KILL "$holder_script_pid" 2>/dev/null || true
        wait "$holder_job" 2>/dev/null || true
        fail "live flock holder did not exclude a simultaneous contender"
        return
    fi

    kill -KILL "$holder_script_pid"
    if wait "$holder_job" 2>/dev/null; then
        rm -f -- "$hold_file"
        fail "hard-killed flock holder unexpectedly exited successfully"
        return
    fi
    # The holder can be killed while its one-second test wait child still has
    # descriptor 9 inherited. Wait for that bounded child to close the shared
    # open-file description before proving that no stale lock survives.
    sleep 2
    rm -f -- "$hold_file" "$hold_file.acquired"

    successor_output="$TEST_ROOT/successor-output"
    if ! run_upgrade "$successor_output" ||
       [ ! -f "$lock_file" ] ||
       [ -L "$lock_file" ] ||
       [ "$(ls -id "$lock_file" | awk '{print $1}')" != \
         "$lock_inode_before" ] ||
       ! assert_file_contains "$successor_output" \
           "strict delivery checks remained Running"; then
        fail "dead flock holder left stale exclusion or replaced the lock inode"
        return
    fi

    pass "persistent flock inode excludes live contenders and releases on death"
}

test_hard_kill_between_binary_replacements() {
    setup_case Running
    old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
    old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
    old_state_sha="$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")"
    output="$TEST_ROOT/output"

    if TS_UPGRADE_TEST_INTERRUPT_AFTER_CLI=1 run_upgrade "$output"; then
        fail "hard-kill interruption unexpectedly returned success"
        return
    else
        interrupted_rc=$?
    fi

    recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
    boot_fence="$ROOT/etc/jammonitor/tailscale-upgrade-fence"
    sync_count="$(grep -c '^sync$' "$CONTROL/actions" || true)"
    if [ "$interrupted_rc" -le 128 ] ||
       [ "$(installed_version)" != "$TARGET_VERSION" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "1.92.3" ] ||
       [ ! -d "$recovery_bundle" ] ||
       [ ! -f "$boot_fence" ] ||
       [ -L "$recovery_bundle" ] ||
       [ "$(file_mode "$boot_fence")" != "600" ] ||
       ! grep -Fqx \
           'format=jammonitor-tailscale-upgrade-fence-v1' "$boot_fence" ||
       ! grep -Fqx \
           'phase=ready_for_binary_mutation' "$boot_fence" ||
       [ "$(sha256_file "$recovery_bundle/tailscale")" != "$old_cli_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled")" != "$old_daemon_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled.state")" != \
         "$old_state_sha" ] ||
       ! grep -Fqx 'phase=ready_for_binary_mutation' \
           "$recovery_bundle/manifest" ||
       [ "$sync_count" -lt 4 ]; then
        fail "hard kill did not leave a complete durable write-ahead bundle"
        return
    fi

    retry_output="$TEST_ROOT/retry-output"
    if run_upgrade "$retry_output" ||
       ! assert_file_contains "$retry_output" \
           "unresolved prior Tailscale upgrade boot fence" ||
       [ ! -f "$boot_fence" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscale")" != "$old_cli_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled")" != "$old_daemon_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled.state")" != \
         "$old_state_sha" ]; then
        fail "interrupted mixed-version install was not durably interlocked"
        return
    fi

    pass "SIGKILL between binary renames preserves recovery and blocks retry"
}

test_hard_kill_at_every_binary_mutation_boundary() {
    for boundary in before-first after-second; do
        setup_case Running
        output="$TEST_ROOT/output-$boundary"
        case "$boundary" in
            before-first)
                TS_UPGRADE_TEST_INTERRUPT_AFTER_FENCE=1 \
                    run_upgrade "$output" && interrupted_success=1 ||
                    interrupted_success=0
                expected_cli=1.92.3
                expected_daemon=1.92.3
                ;;
            after-second)
                TS_UPGRADE_TEST_INTERRUPT_AFTER_DAEMON=1 \
                    run_upgrade "$output" && interrupted_success=1 ||
                    interrupted_success=0
                expected_cli="$TARGET_VERSION"
                expected_daemon="$TARGET_VERSION"
                ;;
        esac
        pending="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
        fence="$ROOT/etc/jammonitor/tailscale-upgrade-fence"
        if [ "$interrupted_success" -eq 1 ] ||
           [ "$(installed_version)" != "$expected_cli" ] ||
           [ "$("$ROOT/usr/sbin/tailscaled" --version)" != \
             "$expected_daemon" ] ||
           [ ! -d "$pending" ] ||
           [ ! -f "$fence" ] ||
           [ "$(file_mode "$fence")" != "600" ] ||
           ! grep -Fqx 'phase=ready_for_binary_mutation' \
               "$pending/manifest"; then
            fail "SIGKILL did not preserve exact recovery authority at $boundary"
            return
        fi
        retry="$TEST_ROOT/retry-$boundary"
        if run_upgrade "$retry" ||
           ! assert_file_contains "$retry" \
               "unresolved prior Tailscale upgrade boot fence"; then
            fail "SIGKILL recovery fence did not block retry at $boundary"
            return
        fi
    done
    pass "every pre/after binary boundary leaves a durable boot fence and WAL"
}

test_write_ahead_sync_barrier_fails_closed() {
    setup_case Running
    old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
    old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
    printf '%s\n' 4 > "$CONTROL/sync-fail-at"
    output="$TEST_ROOT/output"

    if run_upgrade "$output" ||
       [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" != "$old_cli_sha" ] ||
       [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" != "$old_daemon_sha" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       ! durable_recovery_root_is_empty ||
       ! assert_file_contains "$output" \
           "could not complete the write-ahead recovery barrier"; then
        fail "failed write-ahead sync did not stop before binary mutation"
        return
    fi

    pass "failed final sync barrier restores service without binary mutation"
}

test_verified_live_sync_failure_rolls_back() {
    setup_case Running
    printf '%s\n' 6 > "$CONTROL/sync-fail-at"
    output="$TEST_ROOT/output"

    if run_upgrade "$output" ||
       [ "$(installed_version)" != "1.92.3" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "1.92.3" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       ! durable_recovery_root_is_empty ||
       ! assert_file_contains "$output" \
           "could not durably flush the verified live Tailscale target"; then
        fail "failed verified-live sync did not roll back the target"
        return
    fi

    pass "verified-live sync failure rolls back before clearing evidence"
}

test_hard_kill_after_verified_live_sync_preserves_evidence() {
    setup_case Running
    old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
    old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
    old_state_sha="$(sha256_file "$ROOT/etc/tailscale/tailscaled.state")"
    output="$TEST_ROOT/output"

    if TS_UPGRADE_TEST_INTERRUPT_AFTER_LIVE_SYNC=1 \
       run_upgrade "$output"; then
        fail "post-live-sync hard-kill interruption unexpectedly succeeded"
        return
    else
        interrupted_rc=$?
    fi

    recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
    boot_fence="$ROOT/etc/jammonitor/tailscale-upgrade-fence"
    if [ "$interrupted_rc" -le 128 ] ||
       [ "$(installed_version)" != "$TARGET_VERSION" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "$TARGET_VERSION" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       [ ! -d "$recovery_bundle" ] ||
       [ ! -f "$boot_fence" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscale")" != "$old_cli_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled")" != "$old_daemon_sha" ] ||
       [ "$(sha256_file "$recovery_bundle/tailscaled.state")" != \
         "$old_state_sha" ] ||
       [ "$(cat "$CONTROL/sync-count")" -lt 5 ]; then
        fail "post-live-sync hard kill did not preserve durable evidence"
        return
    fi

    retry_output="$TEST_ROOT/retry-output"
    if run_upgrade "$retry_output" ||
       ! assert_file_contains "$retry_output" \
           "unresolved prior Tailscale upgrade boot fence" ||
       [ ! -d "$recovery_bundle" ]; then
        fail "retry cleared post-live-sync interruption evidence"
        return
    fi

    pass "hard kill after verified-live sync leaves durable pending evidence"
}

test_power_loss_across_commit_cleanup_boundaries() {
    for boundary in fence-clear usb-clear; do
        setup_case Running
        output="$TEST_ROOT/output-$boundary"
        case "$boundary" in
            fence-clear)
                selector=TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE
                ;;
            usb-clear)
                selector=TS_UPGRADE_TEST_INTERRUPT_AFTER_USB_CLEAR
                ;;
        esac
        if [ "$selector" = "TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE" ]; then
            TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE=1 \
                run_upgrade "$output" && interrupted_success=1 ||
                interrupted_success=0
        else
            TS_UPGRADE_TEST_INTERRUPT_AFTER_USB_CLEAR=1 \
                run_upgrade "$output" && interrupted_success=1 ||
                interrupted_success=0
        fi
        pending="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
        fence="$ROOT/etc/jammonitor/tailscale-upgrade-fence"
        if [ "$interrupted_success" -eq 1 ] ||
           [ "$(installed_version)" != "$TARGET_VERSION" ] ||
           [ "$("$ROOT/usr/sbin/tailscaled" --version)" != \
             "$TARGET_VERSION" ] ||
           [ "$(cat "$CONTROL/backend")" != "Running" ] ||
           [ ! -f "$CONTROL/running" ] ||
           [ -e "$fence" ] || [ -L "$fence" ]; then
            fail "verified commit was not boot-authoritative at $boundary"
            return
        fi
        case "$boundary" in
            fence-clear)
                [ -d "$pending" ] || {
                    fail "post-fence crash did not retain retry-blocking USB evidence"
                    return
                }
                retry="$TEST_ROOT/retry-$boundary"
                if run_upgrade "$retry" ||
                   ! assert_file_contains "$retry" \
                       "unresolved durable Tailscale upgrade evidence"; then
                    fail "post-fence residue did not block another mutation"
                    return
                fi
                ;;
            usb-clear)
                durable_recovery_root_is_empty || {
                    fail "post-USB crash did not leave exact empty recovery root"
                    return
                }
                ;;
        esac
    done
    pass "power loss after fence-first commit cleanup preserves boot and mutation safety"
}

test_maintenance_expiry_across_sync_blocks_first_replacement() {
    setup_case Running
    printf '%s\n' 4 > "$CONTROL/expire-maintenance-at-sync"
    output="$TEST_ROOT/output"
    marker="$ROOT/var/run/jammonitor/tailscale-maintenance"

    if run_upgrade "$output" ||
       [ "$(installed_version)" != "1.92.3" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "1.92.3" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ "$(cat "$marker")" != "0" ] ||
       ! durable_recovery_root_is_empty ||
       ! assert_file_contains "$output" \
           "maintenance lease ownership or validity was lost"; then
        fail "expired maintenance lease did not block first replacement"
        return
    fi

    pass "maintenance expiry across sync is detected before first replacement"
}

test_daemon_restart_across_sync_blocks_first_replacement() {
    setup_case Running
    printf '%s\n' 4 > "$CONTROL/restart-daemon-at-sync"
    output="$TEST_ROOT/output"

    if run_upgrade "$output" ||
       [ "$(installed_version)" != "1.92.3" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "1.92.3" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       ! durable_recovery_root_is_empty ||
       ! assert_file_contains "$output" \
           "Tailscale quiescence was lost before binary replacement"; then
        fail "daemon restart across sync did not block first replacement"
        return
    fi

    pass "daemon restart across sync is detected before first replacement"
}

test_daemon_restart_between_replacements_rolls_back() {
    setup_case Running
    output="$TEST_ROOT/output"

    if TS_UPGRADE_TEST_RESTART_DAEMON_AFTER_CLI=1 \
       run_upgrade "$output" ||
       [ "$(installed_version)" != "1.92.3" ] ||
       [ "$("$ROOT/usr/sbin/tailscaled" --version)" != "1.92.3" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       ! durable_recovery_root_is_empty ||
       ! assert_file_contains "$output" \
           "lost maintenance ownership or quiescence before installing tailscaled"; then
        fail "daemon restart between replacements did not roll back"
        return
    fi

    pass "daemon restart between replacements is detected and rolled back"
}

test_mount_change_before_mutation_fails_closed() {
    setup_case Running
    old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
    old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
    printf '%s\n' 4 > "$CONTROL/invalidate-mount-at-sync"
    output="$TEST_ROOT/output"
    recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
    evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"

    if run_upgrade "$output" ||
       [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" != "$old_cli_sha" ] ||
       [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" != "$old_daemon_sha" ] ||
       [ "$(cat "$CONTROL/backend")" != "Running" ] ||
       [ ! -f "$CONTROL/running" ] ||
       [ ! -d "$recovery_bundle" ] ||
       [ ! -f "$recovery_bundle/RECOVERY_REQUIRED" ] ||
       [ ! -s "$evidence" ] ||
       ! assert_file_contains "$output" \
           "persistent recovery mount changed before binary mutation"; then
        fail "persistent mount change did not stop before binary mutation"
        return
    fi

    pass "mount change before mutation preserves bundle and restores service"
}

test_incomplete_rollback_preserves_recovery() {
    setup_case Running
    : > "$CONTROL/fail-new"
    : > "$CONTROL/fail-rollback-restore"
    output="$TEST_ROOT/output"
    evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
    if ! run_upgrade "$output" &&
       [ -s "$evidence" ] &&
       bundle="$(sed -n 's/^recovery_bundle=//p' "$evidence")" &&
       [ -d "$bundle" ] &&
       [ -f "$bundle/ROLLBACK_INCOMPLETE" ] &&
       [ -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ] &&
       assert_file_contains "$output" "could not restore the previous tailscale binary" &&
       assert_file_contains "$output" "could not restore the previous Tailscale state" &&
       assert_file_contains "$output" "CRITICAL: Tailscale rollback is incomplete"; then
        pass "rollback aggregates failures and preserves evidence plus recovery bundle"
    else
        fail "rollback aggregates failures and preserves evidence plus recovery bundle"
    fi
}

test_installer_recovery_evidence_blocks_before_staging() {
    for evidence_case in active UNRESOLVED unexpected symlink-root; do
        setup_case Running
        recovery_root="$ROOT/etc/jammonitor/recovery"
        external_root="$CONTROL/external-installer-recovery"
        case "$evidence_case" in
            active|unexpected)
                mkdir -p "$recovery_root/$evidence_case"
                evidence_path="$recovery_root/$evidence_case/evidence"
                printf '%s\n' "installer-$evidence_case" > "$evidence_path"
                ;;
            UNRESOLVED)
                mkdir -p "$recovery_root"
                evidence_path="$recovery_root/UNRESOLVED"
                printf '%s\n' installer-unresolved > "$evidence_path"
                ;;
            symlink-root)
                mkdir -p "$external_root"
                evidence_path="$external_root/evidence"
                printf '%s\n' installer-symlink > "$evidence_path"
                ln -s "$external_root" "$recovery_root"
                ;;
        esac
        evidence_inode="$(ls -id "$evidence_path" | awk '{print $1}')"
        evidence_sha="$(sha256_file "$evidence_path")"
        output="$TEST_ROOT/output-$evidence_case"
        if run_upgrade "$output" ||
           grep -Fq stop "$CONTROL/actions" ||
           [ -e "$ROOT/mnt/data/.jammonitor-tailscale-upgrade" ] ||
           [ "$(ls -id "$evidence_path" | awk '{print $1}')" != \
             "$evidence_inode" ] ||
           [ "$(sha256_file "$evidence_path")" != "$evidence_sha" ] ||
           ! assert_file_contains "$output" "installer recovery"; then
            fail "installer recovery evidence was accepted or changed: $evidence_case"
            return
        fi
    done
    pass "installer recovery evidence blocks upgrade before staging without mutation"
}

test_raw_status_output_is_bounded_before_mutation() {
    for status_mode in status-oversized status-infinite; do
        setup_case Running
        : > "$CONTROL/$status_mode"
        old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
        old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
        output="$TEST_ROOT/output-$status_mode"
        if run_upgrade "$output" ||
           [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" != "$old_cli_sha" ] ||
           [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" != "$old_daemon_sha" ] ||
           grep -Fq stop "$CONTROL/actions" ||
           ! durable_recovery_root_is_empty ||
           ! assert_file_contains "$output" \
               "could not read the pre-upgrade Tailscale BackendState"; then
            fail "unbounded LocalAPI output reached mutation: $status_mode"
            return
        fi
        if [ "$status_mode" = "status-infinite" ] &&
           [ ! -f "$CONTROL/status-timeout-intercepted" ]; then
            fail "infinite LocalAPI fixture bypassed the bounded command wrapper"
            return
        fi
    done
    pass "oversized and infinite LocalAPI output fail closed before mutation"
}

test_status_json_requires_exact_types() {
    for wrong_type in backend version id auth tun ips member; do
        setup_case Running
        case "$wrong_type" in
            backend)
                json='{"BackendState":true,"Version":"1.92.3","TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":["100.104.78.42"]},"AuthURL":""}'
                ;;
            version)
                json='{"BackendState":"Running","Version":1923,"TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":["100.104.78.42"]},"AuthURL":""}'
                ;;
            id)
                json='{"BackendState":"Running","Version":"1.92.3","TUN":true,"Self":{"ID":123,"TailscaleIPs":["100.104.78.42"]},"AuthURL":""}'
                ;;
            auth)
                json='{"BackendState":"Running","Version":"1.92.3","TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":["100.104.78.42"]},"AuthURL":false}'
                ;;
            tun)
                json='{"BackendState":"Running","Version":"1.92.3","TUN":"true","Self":{"ID":"node-stable-123","TailscaleIPs":["100.104.78.42"]},"AuthURL":""}'
                ;;
            ips)
                json='{"BackendState":"Running","Version":"1.92.3","TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":"100.104.78.42"},"AuthURL":""}'
                ;;
            member)
                json='{"BackendState":"Running","Version":"1.92.3","TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":[100]},"AuthURL":""}'
                ;;
        esac
        printf '%s\n' "$json" > "$CONTROL/status-json-file"
        output="$TEST_ROOT/output-$wrong_type"
        if run_upgrade "$output" ||
           grep -Fq stop "$CONTROL/actions" ||
           ! assert_file_contains "$output" \
               "could not read the pre-upgrade Tailscale BackendState"; then
            fail "LocalAPI schema accepted wrong JSON type: $wrong_type"
            return
        fi
    done
    pass "LocalAPI acceptance requires exact string, boolean, and array types"
}

test_live_guard_rechecks_mount_and_bundle_before_each_rename() {
    for phase in before-cli after-cli; do
        setup_case Running
        old_cli_sha="$(sha256_file "$ROOT/usr/sbin/tailscale")"
        old_daemon_sha="$(sha256_file "$ROOT/usr/sbin/tailscaled")"
        output="$TEST_ROOT/output-$phase"
        recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
        evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
        if TS_UPGRADE_TEST_INVALIDATE_MOUNT_PHASE="$phase" \
           run_upgrade "$output" ||
           [ "$(sha256_file "$ROOT/usr/sbin/tailscale")" != "$old_cli_sha" ] ||
           [ "$(sha256_file "$ROOT/usr/sbin/tailscaled")" != "$old_daemon_sha" ] ||
           [ ! -f "$recovery_bundle/RECOVERY_REQUIRED" ] ||
           [ ! -s "$evidence" ] ||
           ! assert_file_contains "$output" \
               "persistent recovery mount changed immediately before binary replacement"; then
            fail "live mount guard missed forward rename boundary: $phase"
            return
        fi
    done

    setup_case Running
    output="$TEST_ROOT/output-tampered-bundle"
    recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
    if TS_UPGRADE_TEST_TAMPER_DURABLE_AFTER_CLI=1 run_upgrade "$output" ||
       [ ! -d "$recovery_bundle" ] ||
       ! grep -Fq tampered "$recovery_bundle/manifest" ||
       ! assert_file_contains "$output" \
           "durable recovery bundle changed immediately before binary replacement" ||
       ! assert_file_contains "$output" \
           "refusing automatic rollback restore"; then
        fail "live bundle guard did not preserve tampered write-ahead evidence"
        return
    fi
    pass "mount and durable bundle are re-proven before every binary rename"
}

test_rollback_sync_barriers_preserve_uncertain_evidence() {
    for failure_sync in 6 8; do
        setup_case Running
        : > "$CONTROL/fail-new"
        printf '%s\n' "$failure_sync" > "$CONTROL/sync-fail-at"
        output="$TEST_ROOT/output-$failure_sync"
        recovery_bundle="$ROOT/mnt/data/.jammonitor-tailscale-upgrade/pending"
        evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
        if run_upgrade "$output" ||
           [ ! -d "$recovery_bundle" ] ||
           [ ! -f "$recovery_bundle/RECOVERY_REQUIRED" ] ||
           [ ! -s "$evidence" ]; then
            fail "rollback sync fault did not preserve recovery evidence: $failure_sync"
            return
        fi
        case "$failure_sync" in
            6)
                assert_file_contains "$output" \
                    "durable sync barrier" || {
                    fail "live restore sync failure was not reported"
                    return
                }
                ;;
            8)
                assert_file_contains "$output" \
                    "could not durably clear" || {
                    fail "post-delete sync failure was not reported"
                    return
                }
                ;;
        esac
    done
    pass "rollback sync and post-delete barriers retain persistent uncertainty evidence"
}

test_delayed_stop_timeout_is_reasserted_before_wal_clear() {
    setup_case Running
    : > "$CONTROL/delayed-stop-timeout"
    printf '%s\n' 3 > "$CONTROL/release-delayed-stop-at-sync"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       [ -f "$CONTROL/delayed-stop-completed" ] &&
       [ -f "$CONTROL/running" ] &&
       [ -f "$ROOT/proc/4242/comm" ] &&
       [ -e "$ROOT/var/run/tailscale/tailscaled.sock" ] &&
       [ "$(grep -c '^start$' "$CONTROL/actions")" -ge 2 ] &&
       durable_recovery_root_is_empty &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed" ] &&
       assert_file_contains "$output" \
           "did not stop within the bounded timeout"; then
        pass "late stop completion is reasserted and rechecked before WAL clear"
    else
        fail "late stop completion raced past rollback WAL cleanup"
    fi
}

test_critical_peer_is_required_for_running_acceptance() {
    for peer_case in missing malformed self-secondary target-fail rollback-fail; do
        setup_case Running
        case "$peer_case" in
            missing)
                rm -f "$ROOT/etc/jammonitor/tailscale-critical-peer"
                ;;
            malformed)
                printf '%s\n' not-an-ip \
                    > "$ROOT/etc/jammonitor/tailscale-critical-peer"
                ;;
            self-secondary)
                printf '%s\n' 'FD7A:115C:A1E0:0:0:0:0:1' \
                    > "$ROOT/etc/jammonitor/tailscale-critical-peer"
                printf '%s\n' \
                    '{"BackendState":"Running","Version":"1.92.3","TUN":true,"Self":{"ID":"node-stable-123","TailscaleIPs":["100.104.78.42","fd7a:115c:a1e0::1"]},"AuthURL":""}' \
                    > "$CONTROL/status-json-file"
                ;;
            target-fail)
                : > "$CONTROL/peer-fail-new"
                ;;
            rollback-fail)
                : > "$CONTROL/fail-new"
                : > "$CONTROL/peer-fail-rollback"
                ;;
        esac
        output="$TEST_ROOT/output-$peer_case"
        evidence="$ROOT/var/run/jammonitor/tailscale-upgrade-rollback-failed"
        if run_upgrade "$output"; then
            fail "Running upgrade accepted critical-peer failure: $peer_case"
            return
        fi
        case "$peer_case" in
            missing|malformed|self-secondary)
                if grep -Fq stop "$CONTROL/actions" ||
                   ! assert_file_contains "$output" \
                       "requires one exact non-self critical-peer"; then
                    fail "invalid critical-peer config reached mutation: $peer_case"
                    return
                fi
                ;;
            target-fail)
                if [ "$(installed_version)" != "1.92.3" ] ||
                   ! durable_recovery_root_is_empty ||
                   ! assert_file_contains "$output" \
                       "post-upgrade critical Tailscale peer verification failed"; then
                    fail "target peer failure did not roll back cleanly"
                    return
                fi
                ;;
            rollback-fail)
                if [ ! -s "$evidence" ] ||
                   ! assert_file_contains "$output" \
                       "critical Tailscale peer was not reachable after rollback"; then
                    fail "rollback peer failure did not preserve evidence"
                    return
                fi
                ;;
        esac
    done

    setup_case NeedsLogin
    output="$TEST_ROOT/output-needs-login"
    if run_upgrade "$output" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ]; then
        pass "Running requires TSMP peer proof while NeedsLogin defers it"
    else
        fail "NeedsLogin did not explicitly defer critical-peer acceptance"
    fi
}

test_killed_fetch_parent_does_not_orphan_shared_flock() {
    setup_case Running
    archive="$TEST_ROOT/packages/$TARGET_ARCHIVE"
    archive_real="$archive.real"
    mv "$archive" "$archive_real"
    mkfifo "$archive"
    hold_file="$CONTROL/hold-fetch-lock"
    : > "$hold_file"
    : > "$CONTROL/capture-fetch-child"
    output="$TEST_ROOT/fetch-holder-output"
    (
        TS_UPGRADE_TEST_HOLD_LOCK_FILE="$hold_file"
        TS_UPGRADE_FETCH_TIMEOUT=30
        export TS_UPGRADE_TEST_HOLD_LOCK_FILE TS_UPGRADE_FETCH_TIMEOUT
        run_upgrade "$output"
    ) &
    holder_job=$!
    attempts=100
    while [ "$attempts" -gt 0 ] && [ ! -s "$hold_file.acquired" ]; do
        sleep 0.05
        attempts=$((attempts - 1))
    done
    if [ ! -s "$hold_file.acquired" ]; then
        kill "$holder_job" 2>/dev/null || true
        wait "$holder_job" 2>/dev/null || true
        fail "fetch holder never acquired the shared lock"
        return
    fi
    lock_file="$ROOT/var/run/jammonitor/router-install.lock"
    lock_inode="$(ls -id "$lock_file" | awk '{print $1}')"
    holder_script_pid="$(cat "$hold_file.acquired")"
    rm -f "$hold_file"
    attempts=100
    while [ "$attempts" -gt 0 ] &&
          [ ! -s "$CONTROL/fetch-child-pid" ]; do
        sleep 0.05
        attempts=$((attempts - 1))
    done
    if [ ! -s "$CONTROL/fetch-child-pid" ]; then
        kill -KILL "$holder_script_pid" 2>/dev/null || true
        wait "$holder_job" 2>/dev/null || true
        rm -f "$archive"
        mv "$archive_real" "$archive"
        fail "bounded fetch child did not reach the hanging fixture"
        return
    fi
    fetch_child_pid="$(cat "$CONTROL/fetch-child-pid")"
    kill -KILL "$holder_script_pid"
    wait "$holder_job" 2>/dev/null || true

    if (
        exec 9>>"$lock_file"
        TS_TEST_PYTHON="$PYTHON_BIN" "$TOOLS/flock" -n 9
    ); then
        acquired_after_kill=1
    else
        acquired_after_kill=0
    fi
    kill -KILL "$fetch_child_pid" 2>/dev/null || true
    rm -f "$archive"
    mv "$archive_real" "$archive"
    if [ "$acquired_after_kill" -eq 1 ] &&
       [ "$(ls -id "$lock_file" | awk '{print $1}')" = "$lock_inode" ]; then
        pass "killed fetch parent cannot leave an orphaned shared flock"
    else
        fail "fetch child inherited the shared flock across parent SIGKILL"
    fi
}

test_busybox_sync_requires_no_optional_flags() {
    if grep -Eq '"\\$SYNC_CMD"[[:space:]]+-[A-Za-z]' "$UPGRADER"; then
        fail "upgrader requires an optional BusyBox sync flag"
    else
        pass "durability barriers use target-compatible plain BusyBox sync"
    fi
}

test_repo_init_refuses_unattended_transaction_artifacts() {
    init_script="$REPO_ROOT/router/tailscale.init"
    for artifact in install-fence upgrade-fence symlink; do
        setup_case Running
        gate_root="$TEST_ROOT/init-gate"
        mkdir -p "$gate_root/recovery" "$gate_root/external"
        case "$artifact" in
            install-fence)
                printf 'malformed\n' > "$gate_root/install-transaction"
                ;;
            upgrade-fence)
                printf 'malformed\n' > "$gate_root/tailscale-upgrade-fence"
                ;;
            symlink)
                printf 'external\n' > "$gate_root/external/fence"
                ln -s "$gate_root/external/fence" \
                    "$gate_root/install-transaction"
                ;;
        esac
        if (
            # shellcheck source=/dev/null
            . "$init_script"
            INSTALL_FENCE="$gate_root/install-transaction"
            INSTALL_RECOVERY_ACTIVE="$gate_root/recovery/active"
            INSTALL_RECOVERY_UNRESOLVED="$gate_root/recovery/UNRESOLVED"
            UPGRADE_FENCE="$gate_root/tailscale-upgrade-fence"
            boot_fences_allow_start
        ); then
            fail "repo Tailscale init accepted unattended artifact: $artifact"
            return
        fi
    done

    for residue in empty active unresolved; do
        setup_case Running
        gate_root="$TEST_ROOT/init-gate-$residue"
        mkdir -p "$gate_root/recovery"
        case "$residue" in
            active) mkdir "$gate_root/recovery/active" ;;
            unresolved)
                printf 'unresolved\n' > "$gate_root/recovery/UNRESOLVED"
                ;;
        esac
        if ! (
            # shellcheck source=/dev/null
            . "$REPO_ROOT/router/tailscale.init"
            INSTALL_FENCE="$gate_root/install-transaction"
            INSTALL_RECOVERY_ACTIVE="$gate_root/recovery/active"
            INSTALL_RECOVERY_UNRESOLVED="$gate_root/recovery/UNRESOLVED"
            UPGRADE_FENCE="$gate_root/tailscale-upgrade-fence"
            boot_fences_allow_start
        ); then
            fail "repo Tailscale init rejected safe post-fence residue: $residue"
            return
        fi
    done
    pass "repo Tailscale init blocks active fences but permits post-fence residue"
}

test_repo_init_cleanup_is_bounded() {
    cleanup_log="$TEST_ROOT/init-cleanup-timeout"
    if (
        # shellcheck source=/dev/null
        . "$REPO_ROOT/router/tailscale.init"
        TAILSCALED="/test/tailscaled"
        timeout() {
            printf '%s\n' "$*" > "$cleanup_log"
            return 124
        }
        if bounded_tailscaled_cleanup; then
            exit 1
        fi
        grep -Fqx -- \
            '-s TERM -k 2 10 /test/tailscaled --cleanup' "$cleanup_log"
    ); then
        pass "repo Tailscale cleanup has a TERM and kill-after deadline"
    else
        fail "repo Tailscale cleanup is unbounded or ignores timeout failure"
    fi
}

test_repo_init_bounded_capture_preserves_command_argv() {
    capture_file="$TEST_ROOT/init-bounded-capture.output"
    argv_file="$TEST_ROOT/init-bounded-capture.argv"
    producer="$TEST_ROOT/init-bounded-capture-producer"
    cat > "$producer" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$JAMMONITOR_INIT_CAPTURE_ARGV"
printf '%s\n' bounded-capture-payload
EOF
    chmod 0755 "$producer"
    if (
        # shellcheck source=/dev/null
        . "$REPO_ROOT/router/tailscale.init"
        JAMMONITOR_INIT_CAPTURE_ARGV="$argv_file"
        export JAMMONITOR_INIT_CAPTURE_ARGV
        timeout() {
            [ "$1:$2:$3:$4:$5" = "-s:TERM:-k:2:5" ] || return 64
            shift 5
            "$@"
        }
        bounded_capture "$capture_file" "$producer" first second &&
            [ "$(cat "$capture_file")" = "bounded-capture-payload" ] &&
            [ "$(cat "$argv_file")" = "first second" ]
    ); then
        pass "repo Tailscale fence capture preserves executable and argv"
    else
        fail "repo Tailscale fence capture discarded its executable or argv"
    fi
}

test_storage_fd_identity_requires_explicit_link_following() {
    setup_case Running
    storage_target="$ROOT/mnt/data"
    target_identity="$("$TOOLS/stat" -c '%d:%i' "$storage_target")"
    if ! (
        exec 7<"$storage_target"
        nofollow_identity="$("$TOOLS/stat" -c '%d:%i' /dev/fd/7)"
        followed_identity="$("$TOOLS/stat" -L -c '%d:%i' /dev/fd/7)"
        [ "$nofollow_identity" != "$target_identity" ] &&
            [ "$followed_identity" = "$target_identity" ]
    ); then
        fail "stat mock does not reproduce BusyBox descriptor-link semantics"
        return
    fi

    fd_identity_count="$(
        grep -F '"$FD_ROOT/' "$UPGRADER" | wc -l | tr -d ' '
    )"
    fd_follow_count="$(
        grep -F '"$STAT_CMD" -L -c' "$UPGRADER" |
            grep -F '"$FD_ROOT/' |
            wc -l |
            tr -d ' '
    )"
    [ "$fd_identity_count" = "4" ] &&
        [ "$fd_follow_count" = "$fd_identity_count" ] || {
            fail "not every persistent descriptor identity check follows links"
            return
        }
    pass "persistent descriptor identities explicitly follow BusyBox fd links"
}

test_secret_output_assertion_rejects_each_secret
test_running_success
test_needs_login_success
test_needs_login_expired_identity_success
test_needs_login_empty_identity_rollback
test_needs_login_changed_identity_rollback
test_needs_login_empty_identity_requires_auth_url
test_needs_login_empty_rollback_requires_auth_url
test_empty_needs_login_recovery_success
test_empty_needs_login_recovery_requires_auth_url
test_empty_needs_login_recovery_rejects_wrong_preconditions
test_empty_needs_login_recovery_argument_guards
test_empty_needs_login_recovery_requires_exact_current_hash
test_empty_needs_login_recovery_restores_stop_flush
test_empty_needs_login_recovery_rejects_target_state_rewrite
test_empty_needs_login_recovery_rejects_target_identity
test_empty_needs_login_recovery_rejects_target_running
test_empty_needs_login_recovery_detects_rollback_rewrite
test_empty_needs_login_recovery_target_requires_auth_url
test_empty_needs_login_recovery_rollback_requires_auth_url
test_checksum_failure
test_fetch_and_archive_resource_bounds
test_architecture_guard
test_production_override_guard
test_unsafe_init_guard
test_initial_running_preflight_is_bounded_and_exact
test_postcheck_rollback
test_missing_state_rollback
test_identity_change_rollback
test_preexisting_maintenance_marker
test_expired_maintenance_marker_refused
test_malformed_maintenance_marker_refused
test_idempotent_target_version
test_same_version_wrong_bytes_are_replaced
test_downgrade_guard
test_mixed_newer_daemon_downgrade_guard
test_nonzero_status_is_rejected
test_stop_flush_state_is_authoritative
test_stop_flush_state_rolls_back_exactly
test_stop_timeout_is_prebackup
test_live_daemon_blocks_backup
test_short_maintenance_lease_refused
test_missing_stable_id_refused
test_valid_tailscale_ipv6_running
test_invalid_tailscale_ipv6_running_refused
test_tailscale_ipv4_range_boundaries
test_degraded_running_refused
test_self_in_engine_is_not_a_running_gate
test_installed_hash_mismatch_rolls_back
test_additional_unsafe_init_guards
test_escaped_init_cli_spelling_fails_manifest_authentication
test_init_drift_after_stop_blocks_every_later_invocation
test_persistent_mount_guard
test_storage_authority_contract
test_pinned_storage_identity_blocks_path_swaps
test_unresolved_durable_evidence_blocks_retry
test_persistent_flock_serializes_and_releases_stale_holder
test_hard_kill_between_binary_replacements
test_hard_kill_at_every_binary_mutation_boundary
test_write_ahead_sync_barrier_fails_closed
test_verified_live_sync_failure_rolls_back
test_hard_kill_after_verified_live_sync_preserves_evidence
test_power_loss_across_commit_cleanup_boundaries
test_maintenance_expiry_across_sync_blocks_first_replacement
test_daemon_restart_across_sync_blocks_first_replacement
test_daemon_restart_between_replacements_rolls_back
test_mount_change_before_mutation_fails_closed
test_incomplete_rollback_preserves_recovery
test_installer_recovery_evidence_blocks_before_staging
test_raw_status_output_is_bounded_before_mutation
test_status_json_requires_exact_types
test_storage_fd_identity_requires_explicit_link_following
test_live_guard_rechecks_mount_and_bundle_before_each_rename
test_rollback_sync_barriers_preserve_uncertain_evidence
test_delayed_stop_timeout_is_reasserted_before_wal_clear
test_critical_peer_is_required_for_running_acceptance
test_killed_fetch_parent_does_not_orphan_shared_flock
test_busybox_sync_requires_no_optional_flags
test_repo_init_refuses_unattended_transaction_artifacts
test_repo_init_bounded_capture_preserves_command_argv
test_repo_init_cleanup_is_bounded

cleanup_case
printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
