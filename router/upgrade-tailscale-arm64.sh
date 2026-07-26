#!/bin/sh
#
# Pinned standalone Tailscale binary upgrade for OpenMPTCProuter/aarch64.
#
# This script never authenticates, logs out, disconnects, or removes state.
# It preserves the pre-upgrade BackendState. Running must return to Running;
# NeedsLogin must remain NeedsLogin until an operator explicitly authenticates.

set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

TARGET_VERSION="1.98.9"
TARGET_ARCHIVE="tailscale_${TARGET_VERSION}_arm64.tgz"
TARGET_DIRECTORY="tailscale_${TARGET_VERSION}_arm64"
OFFICIAL_BASE_URL="https://pkgs.tailscale.com/stable"
PINNED_SHA256="fa554ee808d7d07ee8e3ebbc0215ea087157e2a0abbf408e6e18ea7532554db6"

TESTING="${TS_UPGRADE_TESTING:-0}"
ROOT_PREFIX="${TS_UPGRADE_ROOT:-}"
PACKAGE_SOURCE_DIR="${TS_UPGRADE_PACKAGE_SOURCE_DIR:-}"
EXPECTED_SHA256="${TS_UPGRADE_EXPECTED_SHA256:-$PINNED_SHA256}"
UNAME_OVERRIDE="${TS_UPGRADE_UNAME_OVERRIDE:-}"
TIMEOUT_CMD="${TS_UPGRADE_TIMEOUT_CMD:-timeout}"
JSONFILTER_CMD="${TS_UPGRADE_JSONFILTER_CMD:-jsonfilter}"
SYNC_CMD="${TS_UPGRADE_SYNC_CMD:-sync}"
SYNC_TIMEOUT="${TS_UPGRADE_SYNC_TIMEOUT:-30}"
FLOCK_CMD="${TS_UPGRADE_FLOCK_CMD:-flock}"
STAT_CMD="${TS_UPGRADE_STAT_CMD:-stat}"
UCI_CMD="${TS_UPGRADE_UCI_CMD:-uci}"
BLOCK_CMD="${TS_UPGRADE_BLOCK_CMD:-/sbin/block}"
EXPECTED_ROOT_UID="${TS_UPGRADE_EXPECTED_ROOT_UID:-0}"
EXPECTED_ROOT_GID="${TS_UPGRADE_EXPECTED_ROOT_GID:-0}"
STATUS_ATTEMPTS="${TS_UPGRADE_STATUS_ATTEMPTS:-20}"
STATUS_DELAY="${TS_UPGRADE_STATUS_DELAY:-2}"
STATUS_TIMEOUT="${TS_UPGRADE_STATUS_TIMEOUT:-5}"
FETCH_TIMEOUT="${TS_UPGRADE_FETCH_TIMEOUT:-120}"
PEER_COMMAND_TIMEOUT="${TS_UPGRADE_PEER_COMMAND_TIMEOUT:-5}"
SERVICE_TIMEOUT="${TS_UPGRADE_SERVICE_TIMEOUT:-30}"
QUIESCE_ATTEMPTS="${TS_UPGRADE_QUIESCE_ATTEMPTS:-10}"
QUIESCE_DELAY="${TS_UPGRADE_QUIESCE_DELAY:-1}"
TMP_BASE="${TS_UPGRADE_TMPDIR:-/tmp}"
PROC_ROOT="${TS_UPGRADE_PROC_ROOT:-/proc}"
SYS_CLASS_BLOCK="${TS_UPGRADE_SYS_CLASS_BLOCK:-${ROOT_PREFIX}/sys/class/block}"
FSTAB_CONFIG_DIR="${TS_UPGRADE_FSTAB_CONFIG_DIR:-${ROOT_PREFIX}/etc/config}"
FD_ROOT="${TS_UPGRADE_FD_ROOT:-/proc/self/fd}"
TEST_INTERRUPT_AFTER_CLI="${TS_UPGRADE_TEST_INTERRUPT_AFTER_CLI:-0}"
TEST_INTERRUPT_AFTER_FENCE="${TS_UPGRADE_TEST_INTERRUPT_AFTER_FENCE:-0}"
TEST_INTERRUPT_AFTER_DAEMON="${TS_UPGRADE_TEST_INTERRUPT_AFTER_DAEMON:-0}"
TEST_INTERRUPT_AFTER_LIVE_SYNC="${TS_UPGRADE_TEST_INTERRUPT_AFTER_LIVE_SYNC:-0}"
TEST_INTERRUPT_AFTER_COMMIT_FENCE="${TS_UPGRADE_TEST_INTERRUPT_AFTER_COMMIT_FENCE:-0}"
TEST_INTERRUPT_AFTER_USB_CLEAR="${TS_UPGRADE_TEST_INTERRUPT_AFTER_USB_CLEAR:-0}"
TEST_RESTART_DAEMON_AFTER_CLI="${TS_UPGRADE_TEST_RESTART_DAEMON_AFTER_CLI:-0}"
TEST_HOLD_LOCK_FILE="${TS_UPGRADE_TEST_HOLD_LOCK_FILE:-}"
TEST_INVALIDATE_MOUNT_PHASE="${TS_UPGRADE_TEST_INVALIDATE_MOUNT_PHASE:-none}"
TEST_TAMPER_DURABLE_AFTER_CLI="${TS_UPGRADE_TEST_TAMPER_DURABLE_AFTER_CLI:-0}"
TEST_SWAP_STORAGE_PHASE="${TS_UPGRADE_TEST_SWAP_STORAGE_PHASE:-none}"
# POSIX ulimit -f uses 512-byte blocks. Keep raw LocalAPI output at 64 KiB.
STATUS_FILE_BLOCKS=128
STORAGE_CAPTURE_BLOCKS=128
ARCHIVE_FILE_BLOCKS=131072
CHECKSUM_FILE_BLOCKS=8
ARCHIVE_LISTING_BLOCKS=256
ARCHIVE_MAX_BYTES=67108864
ARCHIVE_MAX_MEMBERS=16
ARCHIVE_MAX_EXPANDED_BYTES=134217728

if [ "$TESTING" != "1" ]; then
    [ -z "$ROOT_PREFIX$PACKAGE_SOURCE_DIR$UNAME_OVERRIDE" ] ||
        {
            printf '%s\n' "ERROR: test-only path or architecture override refused" >&2
            exit 1
        }
    [ "$EXPECTED_SHA256" = "$PINNED_SHA256" ] ||
        {
            printf '%s\n' "ERROR: checksum override refused outside test mode" >&2
            exit 1
        }
    [ "$TIMEOUT_CMD" = "timeout" ] &&
    [ "$JSONFILTER_CMD" = "jsonfilter" ] &&
    [ "$SYNC_CMD" = "sync" ] &&
    [ "$SYNC_TIMEOUT" = "30" ] &&
    [ "$FLOCK_CMD" = "flock" ] &&
    [ "$STAT_CMD" = "stat" ] &&
    [ "$UCI_CMD" = "uci" ] &&
    [ "$BLOCK_CMD" = "/sbin/block" ] &&
    [ "$EXPECTED_ROOT_UID" = "0" ] &&
    [ "$EXPECTED_ROOT_GID" = "0" ] &&
    [ "$STATUS_ATTEMPTS" = "20" ] &&
    [ "$STATUS_DELAY" = "2" ] &&
    [ "$STATUS_TIMEOUT" = "5" ] &&
    [ "$FETCH_TIMEOUT" = "120" ] &&
    [ "$PEER_COMMAND_TIMEOUT" = "5" ] &&
    [ "$SERVICE_TIMEOUT" = "30" ] &&
    [ "$QUIESCE_ATTEMPTS" = "10" ] &&
    [ "$QUIESCE_DELAY" = "1" ] &&
    [ "$PROC_ROOT" = "/proc" ] &&
    [ "$SYS_CLASS_BLOCK" = "/sys/class/block" ] &&
    [ "$FSTAB_CONFIG_DIR" = "/etc/config" ] &&
    [ "$FD_ROOT" = "/proc/self/fd" ] &&
    [ "$TMP_BASE" = "/tmp" ] &&
    [ "$TEST_INTERRUPT_AFTER_CLI" = "0" ] &&
    [ "$TEST_INTERRUPT_AFTER_FENCE" = "0" ] &&
    [ "$TEST_INTERRUPT_AFTER_DAEMON" = "0" ] &&
    [ "$TEST_INTERRUPT_AFTER_LIVE_SYNC" = "0" ] &&
    [ "$TEST_INTERRUPT_AFTER_COMMIT_FENCE" = "0" ] &&
    [ "$TEST_INTERRUPT_AFTER_USB_CLEAR" = "0" ] &&
    [ "$TEST_RESTART_DAEMON_AFTER_CLI" = "0" ] &&
    [ "$TEST_INVALIDATE_MOUNT_PHASE" = "none" ] &&
    [ "$TEST_TAMPER_DURABLE_AFTER_CLI" = "0" ] &&
    [ "$TEST_SWAP_STORAGE_PHASE" = "none" ] &&
    [ -z "$TEST_HOLD_LOCK_FILE" ] ||
        {
            printf '%s\n' "ERROR: test-only command or timing override refused" >&2
            exit 1
        }
fi

rooted() {
    printf '%s%s' "$ROOT_PREFIX" "$1"
}

TAILSCALE_BIN="$(rooted /usr/sbin/tailscale)"
TAILSCALED_BIN="$(rooted /usr/sbin/tailscaled)"
INIT_SCRIPT="$(rooted /etc/init.d/tailscale)"
ROUTER_MANIFEST="$(rooted /usr/share/jammonitor/router-files.sha256)"
ROUTER_MANIFEST_DIGEST="$(rooted /usr/share/jammonitor/router-files.sha256.sha256)"
STATE_FILE="$(rooted /etc/tailscale/tailscaled.state)"
SOCKET_FILE="$(rooted /var/run/tailscale/tailscaled.sock)"
RUNTIME_DIR="$(rooted /var/run/jammonitor)"
MAINTENANCE_FILE="$RUNTIME_DIR/tailscale-maintenance"
INSTALL_LOCK="$RUNTIME_DIR/router-install.lock"
INSTALLER_RECOVERY_PARENT="$(rooted /etc/jammonitor)"
INSTALLER_RECOVERY_ROOT="$INSTALLER_RECOVERY_PARENT/recovery"
PERSISTENT_MOUNT="$(rooted /mnt/data)"
DURABLE_ROOT="$PERSISTENT_MOUNT/.jammonitor-tailscale-upgrade"
DURABLE_PENDING="$DURABLE_ROOT/pending"
DURABLE_STAGING=""
UPGRADE_FENCE="$(rooted /etc/jammonitor/tailscale-upgrade-fence)"
UPGRADE_FENCE_TEMP=""
UPGRADE_FENCE_TOKEN=""
UPGRADE_FENCE_SHA256=""
UPGRADE_FENCE_CREATED=0
UPGRADE_FENCE_PHASE=""
STORAGE_CAPTURE=""
STORAGE_PINNED=0
STORAGE_SOURCE_LOGICAL=""
STORAGE_SOURCE_PATH=""
STORAGE_SOURCE_IDENTITY=""
STORAGE_MOUNT_IDENTITY=""
STORAGE_UUID=""
STORAGE_PARTITION_PATH=""
STORAGE_PARENT_PATH=""

WORK_DIR=""
BACKUP_DIR=""
TARGET_TEMP=""
INSTALL_LOCK_HELD=0
MAINTENANCE_CREATED=0
MAINTENANCE_EXPECTED_EXPIRY=""
MAINTENANCE_TEMP=""
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
PRE_BACKEND_STATE=""
PRE_DAEMON_VERSION=""
PRE_STABLE_ID=""
PRE_CLI_SHA256=""
PRE_DAEMON_SHA256=""
PRE_STATE_SHA256=""
NEW_CLI_SHA256=""
NEW_DAEMON_SHA256=""
RECOVER_EMPTY_NEEDS_LOGIN=0
RECOVERY_STATE_SHA256=""
RECOVERY_STATE_BACKUP=""
RECOVERY_STATE_BACKUP_READY=0
STOP_REQUESTED=0
QUIESCENCE_PROVEN=0
BACKUP_READY=0
MUTATION_STARTED=0
ROLLBACK_INCOMPLETE=0
PRESERVE_WORK_DIR=0
PRE_STOP_STATE_SHA256=""
ATOMIC_INSTALL_GUARD_FAILED=0
SERVICE_RUNNING_STATE=""
SERVICE_RUNNING_RC=""
RECOVERY_EVIDENCE="$RUNTIME_DIR/tailscale-upgrade-rollback-failed"
CRITICAL_PEER_FILE="$(rooted /etc/jammonitor/tailscale-critical-peer)"
CRITICAL_PEER=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

is_uint() {
    case "${1:-}" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_sha256() {
    [ "${#1}" -eq 64 ] || return 1
    case "$1" in
        *[!0-9A-Fa-f]*) return 1 ;;
    esac
}

ipv6_hextet_count() {
    ipv6_sequence="${1:-}"
    if [ -z "$ipv6_sequence" ]; then
        printf '%s\n' 0
        return 0
    fi
    case "$ipv6_sequence" in
        :*|*:|*::*|*[!0123456789ABCDEFabcdef:]*)
            return 1
            ;;
    esac

    ipv6_old_ifs="$IFS"
    IFS=:
    set -- $ipv6_sequence
    IFS="$ipv6_old_ifs"
    for ipv6_hextet in "$@"; do
        [ "${#ipv6_hextet}" -ge 1 ] &&
            [ "${#ipv6_hextet}" -le 4 ] ||
            return 1
        case "$ipv6_hextet" in
            *[!0123456789ABCDEFabcdef]*) return 1 ;;
        esac
    done
    printf '%s\n' "$#"
}

is_tailscale_ipv6() {
    ipv6_candidate="$(printf '%s' "${1:-}" | tr 'ABCDEF' 'abcdef')"
    case "$ipv6_candidate" in
        *%*|*.*|*:::*)
            return 1
            ;;
        fd7a:115c:a1e0:*)
            ;;
        *)
            return 1
            ;;
    esac

    case "$ipv6_candidate" in
        *::*)
            ipv6_left="${ipv6_candidate%%::*}"
            ipv6_right="${ipv6_candidate#*::}"
            case "$ipv6_right" in
                *::*) return 1 ;;
            esac
            if ipv6_left_count="$(ipv6_hextet_count "$ipv6_left")" &&
               ipv6_right_count="$(ipv6_hextet_count "$ipv6_right")"; then
                :
            else
                return 1
            fi
            ipv6_explicit_count=$((ipv6_left_count + ipv6_right_count))
            [ "$ipv6_explicit_count" -lt 8 ]
            ;;
        *)
            if ipv6_full_count="$(ipv6_hextet_count "$ipv6_candidate")"; then
                [ "$ipv6_full_count" -eq 8 ]
            else
                return 1
            fi
            ;;
    esac
}

is_ipv4_octet() {
    case "${1:-}" in
        0|[1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_tailscale_ipv4() {
    ipv4_address="${1:-}"
    ipv4_a="${ipv4_address%%.*}"
    ipv4_rest="${ipv4_address#*.}"
    [ "$ipv4_rest" != "$ipv4_address" ] || return 1
    ipv4_b="${ipv4_rest%%.*}"
    ipv4_next="${ipv4_rest#*.}"
    [ "$ipv4_next" != "$ipv4_rest" ] || return 1
    ipv4_c="${ipv4_next%%.*}"
    ipv4_d="${ipv4_next#*.}"
    [ "$ipv4_d" != "$ipv4_next" ] || return 1
    case "$ipv4_d" in
        *.*) return 1 ;;
    esac

    is_ipv4_octet "$ipv4_a" &&
        is_ipv4_octet "$ipv4_b" &&
        is_ipv4_octet "$ipv4_c" &&
        is_ipv4_octet "$ipv4_d" ||
        return 1
    [ "$ipv4_a" -eq 100 ] &&
        [ "$ipv4_b" -ge 64 ] &&
        [ "$ipv4_b" -le 127 ]
}

is_tailscale_ip() {
    candidate="${1:-}"
    case "$candidate" in
        *:*)
            is_tailscale_ipv6 "$candidate"
            ;;
        *.*)
            is_tailscale_ipv4 "$candidate"
            ;;
        *)
            return 1
            ;;
    esac
}

append_normalized_ipv6_part() {
    normalize_part="${1:-}"
    [ -n "$normalize_part" ] || return 0
    normalize_old_ifs="$IFS"
    IFS=:
    set -- $normalize_part
    IFS="$normalize_old_ifs"
    for normalize_hextet in "$@"; do
        case "${#normalize_hextet}" in
            1) normalize_padded="000$normalize_hextet" ;;
            2) normalize_padded="00$normalize_hextet" ;;
            3) normalize_padded="0$normalize_hextet" ;;
            4) normalize_padded="$normalize_hextet" ;;
            *) return 1 ;;
        esac
        NORMALIZED_IPV6="${NORMALIZED_IPV6}${normalize_padded}:"
    done
}

tailscale_ip_key() {
    key_candidate="${1:-}"
    is_tailscale_ip "$key_candidate" || return 1
    case "$key_candidate" in
        *.*)
            printf '%s' "$key_candidate"
            return 0
            ;;
    esac

    key_candidate="$(printf '%s' "$key_candidate" | tr 'A-F' 'a-f')"
    NORMALIZED_IPV6=""
    case "$key_candidate" in
        *::*)
            key_left="${key_candidate%%::*}"
            key_right="${key_candidate#*::}"
            key_left_count="$(ipv6_hextet_count "$key_left")" || return 1
            key_right_count="$(ipv6_hextet_count "$key_right")" || return 1
            key_missing=$((8 - key_left_count - key_right_count))
            append_normalized_ipv6_part "$key_left" || return 1
            while [ "$key_missing" -gt 0 ]; do
                NORMALIZED_IPV6="${NORMALIZED_IPV6}0000:"
                key_missing=$((key_missing - 1))
            done
            append_normalized_ipv6_part "$key_right" || return 1
            ;;
        *)
            append_normalized_ipv6_part "$key_candidate" || return 1
            ;;
    esac
    printf '%s' "${NORMALIZED_IPV6%:}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command is unavailable: $1"
}

compare_versions() {
    awk -v left="$1" -v right="$2" '
        function valid(value, parts, count, part_index) {
            count = split(value, parts, ".")
            if (count != 3) {
                return 0
            }
            for (part_index = 1; part_index <= 3; part_index++) {
                if (parts[part_index] !~ /^[0-9]+$/) {
                    return 0
                }
            }
            return 1
        }
        BEGIN {
            if (!valid(left, l) || !valid(right, r)) {
                exit 2
            }
            for (i = 1; i <= 3; i++) {
                if ((l[i] + 0) > (r[i] + 0)) {
                    print 1
                    exit
                }
                if ((l[i] + 0) < (r[i] + 0)) {
                    print -1
                    exit
                }
            }
            print 0
        }
    '
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif [ "$TESTING" = "1" ] && command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "sha256sum is required"
    fi
}

safe_remove_work_dir() {
    [ -n "$WORK_DIR" ] || return 0
    case "$WORK_DIR" in
        "$TMP_BASE"/tailscale-upgrade.*)
            rm -rf -- "$WORK_DIR"
            ;;
        *)
            warn "refusing to remove unexpected work directory"
            ;;
    esac
}

run_bounded_capture() {
    capture_output="$1"
    capture_blocks="$2"
    shift 2
    : > "$capture_output" || return 1
    (
        exec 7>&- 9>&-
        "$TIMEOUT_CMD" -s TERM -k 2 "$STATUS_TIMEOUT" \
            /bin/sh -c \
            'ulimit -f "$1" || exit 125; shift; exec "$@"' \
            jammonitor-bounded-capture "$capture_blocks" "$@"
    ) > "$capture_output" 2>/dev/null
}

safe_directory_mode() {
    directory_mode="${1:-}"
    case "$directory_mode" in
        [0-7][0-7][0-7]) ;;
        *) return 1 ;;
    esac
    group_digit="${directory_mode#?}"
    group_digit="${group_digit%?}"
    other_digit="${directory_mode#??}"
    case "$group_digit:$other_digit" in
        *[2367]:*|*:*[2367]) return 1 ;;
    esac
}

logical_device_path() {
    physical_device="$1"
    if [ -n "$ROOT_PREFIX" ]; then
        case "$physical_device" in
            "$ROOT_PREFIX"/dev/*)
                printf '/dev/%s\n' "${physical_device#"$ROOT_PREFIX/dev/"}"
                ;;
            *)
                return 1
                ;;
        esac
    else
        printf '%s\n' "$physical_device"
    fi
}

read_storage_authority() {
    mount_table="$PROC_ROOT/mounts"
    [ -r "$mount_table" ] || return 1
    storage_mount_record="$(
        awk -v expected="$PERSISTENT_MOUNT" '
            $2 == expected {
                matches++
                source = $1
                fstype = $3
                options_text = $4
            }
            END {
                if (matches != 1) {
                    exit 1
                }
                has_rw = 0
                has_ro = 0
                has_noatime = 0
                has_nosuid = 0
                has_nodev = 0
                has_noexec = 0
                rw_count = 0
                noatime_count = 0
                nosuid_count = 0
                nodev_count = 0
                noexec_count = 0
                option_count = split(options_text, options, ",")
                for (i = 1; i <= option_count; i++) {
                    if (options[i] == "rw") {
                        has_rw = 1
                        rw_count++
                    }
                    if (options[i] == "ro") has_ro = 1
                    if (options[i] == "noatime") {
                        has_noatime = 1
                        noatime_count++
                    }
                    if (options[i] == "nosuid") {
                        has_nosuid = 1
                        nosuid_count++
                    }
                    if (options[i] == "nodev") {
                        has_nodev = 1
                        nodev_count++
                    }
                    if (options[i] == "noexec") {
                        has_noexec = 1
                        noexec_count++
                    }
                }
                if (fstype != "ext4" || has_rw != 1 || has_ro != 0 ||
                    has_noatime != 1 || has_nosuid != 1 ||
                    has_nodev != 1 || has_noexec != 1 ||
                    option_count != 5 || rw_count != 1 ||
                    noatime_count != 1 || nosuid_count != 1 ||
                    nodev_count != 1 || noexec_count != 1) {
                    exit 1
                }
                print source
            }
        ' "$mount_table"
    )" || return 1
    case "$storage_mount_record" in
        *'
'*|"") return 1 ;;
    esac

    storage_logical_source="$(logical_device_path "$storage_mount_record")" ||
        return 1
    case "$storage_logical_source" in
        /dev/sd[a-z][1-9]|/dev/sd[a-z][1-9][0-9]*)
            ;;
        *)
            return 1
            ;;
    esac
    storage_partition_name="${storage_logical_source#/dev/}"
    storage_partition_number="$(
        printf '%s\n' "$storage_partition_name" |
            sed 's/^sd[a-z]//'
    )"
    storage_parent_name="$(
        printf '%s\n' "$storage_partition_name" |
            sed 's/[0-9][0-9]*$//'
    )"
    is_uint "$storage_partition_number" &&
        [ "$storage_partition_number" -gt 0 ] ||
        return 1

    [ -f "$SYS_CLASS_BLOCK/$storage_partition_name/partition" ] ||
        return 1
    [ -f "$SYS_CLASS_BLOCK/$storage_parent_name/removable" ] ||
        return 1
    storage_sys_partition="$(
        tr -d ' \r\n' \
            < "$SYS_CLASS_BLOCK/$storage_partition_name/partition"
    )" || return 1
    storage_sys_removable="$(
        tr -d ' \r\n' \
            < "$SYS_CLASS_BLOCK/$storage_parent_name/removable"
    )" || return 1
    [ "$storage_sys_partition" = "$storage_partition_number" ] &&
        [ "$storage_sys_removable" = "1" ] ||
        return 1
    storage_partition_real="$(
        readlink -f "$SYS_CLASS_BLOCK/$storage_partition_name"
    )" || return 1
    storage_parent_real="$(
        readlink -f "$SYS_CLASS_BLOCK/$storage_parent_name"
    )" || return 1
    [ -n "$storage_partition_real" ] &&
        [ -n "$storage_parent_real" ] ||
        return 1

    storage_source_path="${ROOT_PREFIX}${storage_logical_source}"
    [ ! -L "$storage_source_path" ] || return 1
    if [ "$TESTING" = "1" ]; then
        [ -f "$storage_source_path" ] || return 1
    else
        [ -b "$storage_source_path" ] || return 1
    fi
    storage_source_identity="$(
        "$STAT_CMD" -c '%d:%i:%t:%T' "$storage_source_path" 2>/dev/null
    )" || return 1
    case "$storage_source_identity" in
        *[!0-9A-Fa-f:]*|"") return 1 ;;
    esac

    [ -d "$PERSISTENT_MOUNT" ] && [ ! -L "$PERSISTENT_MOUNT" ] ||
        return 1
    storage_mount_metadata="$(
        "$STAT_CMD" -c '%d:%i:%u:%g:%a' "$PERSISTENT_MOUNT" 2>/dev/null
    )" || return 1
    old_ifs="$IFS"
    IFS=:
    set -- $storage_mount_metadata
    IFS="$old_ifs"
    [ "$#" -eq 5 ] ||
        return 1
    [ "$3" = "$EXPECTED_ROOT_UID" ] &&
        [ "$4" = "$EXPECTED_ROOT_GID" ] &&
        safe_directory_mode "$5" ||
        return 1
    storage_mount_identity="$1:$2"

    STORAGE_CAPTURE="$RUNTIME_DIR/.storage-authority.$$"
    run_bounded_capture "$STORAGE_CAPTURE" "$STORAGE_CAPTURE_BLOCKS" \
        "$UCI_CMD" -q -c "$FSTAB_CONFIG_DIR" show fstab ||
        return 1
    storage_fstab_uuid="$(
        awk '
            function unquote(value) {
                if (value !~ /^\047[^\047]*\047$/) return ""
                return substr(value, 2, length(value) - 2)
            }
            {
                split($0, fields, "=")
                key = fields[1]
                value = substr($0, length(key) + 2)
                plain = unquote(value)
                if (key ~ /^fstab\.[^.]+$/ ||
                    key ~ /^fstab\.@mount\[[0-9]+\]$/) {
                    type_count[key]++
                    type_value[key] = value
                }
                if (key ~ /^fstab\..*\.target$/ &&
                    plain == "/mnt/data") {
                    all_target_count++
                    authority = key
                    sub(/\.target$/, "", authority)
                }
                values[key] = plain
                counts[key]++
            }
            END {
                if (all_target_count != 1 ||
                    type_count[authority] != 1 ||
                    type_value[authority] != "mount" ||
                    counts[authority ".target"] != 1 ||
                    counts[authority ".uuid"] != 1 ||
                    values[authority ".uuid"] == "" ||
                    counts[authority ".enabled"] != 1 ||
                    values[authority ".enabled"] != "1") exit 1

                fstype_count = counts[authority ".fstype"] + 0
                if (fstype_count > 1 ||
                    (fstype_count == 1 &&
                     values[authority ".fstype"] != "ext4")) exit 1

                options_count = counts[authority ".options"] + 0
                if (options_count != 1 ||
                    values[authority ".options"] != "rw,noatime,nosuid,nodev,noexec") exit 1
                print values[authority ".uuid"]
            }
        ' "$STORAGE_CAPTURE"
    )" || return 1
    case "$storage_fstab_uuid" in
        *'
'*|*[!0-9A-Za-z-]*|"") return 1 ;;
    esac
    [ "${#storage_fstab_uuid}" -le 128 ] || return 1

    run_bounded_capture "$STORAGE_CAPTURE" "$STORAGE_CAPTURE_BLOCKS" \
        "$BLOCK_CMD" info "$storage_source_path" ||
        return 1
    storage_block_record="$(
        awk -v expected="$storage_source_path" '
            NR > 1 { exit 2 }
            {
                if ($1 != expected ":") exit 2
                for (i = 2; i <= NF; i++) {
                    if ($i ~ /^UUID="[^"]+"$/) {
                        uuid_count++
                        uuid = substr($i, 7, length($i) - 7)
                    } else if ($i ~ /^MOUNT="[^"]*"$/) {
                        mount_count++
                        mount_value = substr($i, 8, length($i) - 8)
                    } else if ($i ~ /^TYPE="[^"]+"$/) {
                        type_count++
                        type_value = substr($i, 7, length($i) - 7)
                    }
                }
            }
            END {
                if (NR != 1 || uuid_count != 1 ||
                    mount_count != 1 || mount_value != "/mnt/data" ||
                    type_count != 1 || type_value != "ext4") exit 1
                print uuid
            }
        ' "$STORAGE_CAPTURE"
    )" || return 1
    [ "$storage_block_record" = "$storage_fstab_uuid" ] ||
        return 1

    storage_candidate_count=0
    for storage_candidate_class in \
        "$SYS_CLASS_BLOCK"/sd[a-z][1-9] \
        "$SYS_CLASS_BLOCK"/sd[a-z][1-9][0-9]*
    do
        [ -e "$storage_candidate_class" ] ||
            [ -L "$storage_candidate_class" ] || continue
        storage_candidate_name="${storage_candidate_class##*/}"
        case "$storage_candidate_name" in
            sd[a-z][1-9]|sd[a-z][1-9][0-9]*) ;;
            *) return 1 ;;
        esac
        storage_candidate_partition="$(
            printf '%s\n' "$storage_candidate_name" |
                sed 's/^sd[a-z]//'
        )"
        storage_candidate_parent="$(
            printf '%s\n' "$storage_candidate_name" |
                sed 's/[0-9][0-9]*$//'
        )"
        [ "$(tr -d ' \r\n' \
            < "$SYS_CLASS_BLOCK/$storage_candidate_name/partition")" = \
          "$storage_candidate_partition" ] ||
            return 1
        [ "$(tr -d ' \r\n' \
            < "$SYS_CLASS_BLOCK/$storage_candidate_parent/removable")" = \
          "1" ] || continue
        storage_candidate_count=$((storage_candidate_count + 1))
        [ "$storage_candidate_count" -le 64 ] || return 1
        storage_candidate_path="${ROOT_PREFIX}/dev/$storage_candidate_name"
        [ ! -L "$storage_candidate_path" ] || return 1
        if [ "$TESTING" = "1" ]; then
            [ -f "$storage_candidate_path" ] || return 1
        else
            [ -b "$storage_candidate_path" ] || return 1
        fi
        run_bounded_capture "$STORAGE_CAPTURE" "$STORAGE_CAPTURE_BLOCKS" \
            "$BLOCK_CMD" info "$storage_candidate_path" ||
            return 1
        storage_candidate_uuid="$(
            awk -v expected="$storage_candidate_path" '
                NR > 1 { exit 2 }
                {
                    if ($1 != expected ":") exit 2
                    for (i = 2; i <= NF; i++) {
                        if ($i ~ /^UUID="[^"]+"$/) {
                            count++
                            uuid = substr($i, 7, length($i) - 7)
                        }
                    }
                }
                END {
                    if (NR != 1 || count != 1) exit 1
                    print uuid
                }
            ' "$STORAGE_CAPTURE"
        )" || return 1
        if [ "$storage_candidate_uuid" = "$storage_fstab_uuid" ] &&
           [ "$storage_candidate_path" != "$storage_source_path" ]; then
            return 1
        fi
    done
    [ "$storage_candidate_count" -ge 1 ] || return 1

    CURRENT_STORAGE_SOURCE_LOGICAL="$storage_logical_source"
    CURRENT_STORAGE_SOURCE_PATH="$storage_source_path"
    CURRENT_STORAGE_SOURCE_IDENTITY="$storage_source_identity"
    CURRENT_STORAGE_MOUNT_IDENTITY="$storage_mount_identity"
    CURRENT_STORAGE_UUID="$storage_fstab_uuid"
    CURRENT_STORAGE_PARTITION_PATH="$storage_partition_real"
    CURRENT_STORAGE_PARENT_PATH="$storage_parent_real"
}

pin_storage_authority() {
    read_storage_authority ||
        die "persistent recovery storage authority is unsafe or ambiguous"
    STORAGE_SOURCE_LOGICAL="$CURRENT_STORAGE_SOURCE_LOGICAL"
    STORAGE_SOURCE_PATH="$CURRENT_STORAGE_SOURCE_PATH"
    STORAGE_SOURCE_IDENTITY="$CURRENT_STORAGE_SOURCE_IDENTITY"
    STORAGE_MOUNT_IDENTITY="$CURRENT_STORAGE_MOUNT_IDENTITY"
    STORAGE_UUID="$CURRENT_STORAGE_UUID"
    STORAGE_PARTITION_PATH="$CURRENT_STORAGE_PARTITION_PATH"
    STORAGE_PARENT_PATH="$CURRENT_STORAGE_PARENT_PATH"

    exec 6<"$STORAGE_SOURCE_PATH" ||
        die "could not pin the persistent recovery block device"
    exec 8<"$PERSISTENT_MOUNT" ||
        die "could not pin the persistent recovery mount root"
    [ "$("$STAT_CMD" -c '%d:%i:%t:%T' "$FD_ROOT/6" 2>/dev/null)" = \
      "$STORAGE_SOURCE_IDENTITY" ] &&
        [ "$("$STAT_CMD" -c '%d:%i' "$FD_ROOT/8" 2>/dev/null)" = \
          "$STORAGE_MOUNT_IDENTITY" ] ||
        die "persistent recovery descriptors did not join the verified paths"
    STORAGE_PINNED=1
}

storage_authority_matches_pin() {
    [ "$STORAGE_PINNED" -eq 1 ] || return 1
    read_storage_authority || return 1
    [ "$CURRENT_STORAGE_SOURCE_LOGICAL" = "$STORAGE_SOURCE_LOGICAL" ] &&
        [ "$CURRENT_STORAGE_SOURCE_PATH" = "$STORAGE_SOURCE_PATH" ] &&
        [ "$CURRENT_STORAGE_SOURCE_IDENTITY" = \
          "$STORAGE_SOURCE_IDENTITY" ] &&
        [ "$CURRENT_STORAGE_MOUNT_IDENTITY" = \
          "$STORAGE_MOUNT_IDENTITY" ] &&
        [ "$CURRENT_STORAGE_UUID" = "$STORAGE_UUID" ] &&
        [ "$CURRENT_STORAGE_PARTITION_PATH" = \
          "$STORAGE_PARTITION_PATH" ] &&
        [ "$CURRENT_STORAGE_PARENT_PATH" = "$STORAGE_PARENT_PATH" ] &&
        [ "$("$STAT_CMD" -c '%d:%i:%t:%T' "$FD_ROOT/6" 2>/dev/null)" = \
          "$STORAGE_SOURCE_IDENTITY" ] &&
        [ "$("$STAT_CMD" -c '%d:%i' "$FD_ROOT/8" 2>/dev/null)" = \
          "$STORAGE_MOUNT_IDENTITY" ]
}

persistent_mount_is_ext4_rw() {
    if [ "$STORAGE_PINNED" -eq 1 ]; then
        storage_authority_matches_pin
    else
        read_storage_authority
    fi
}

recovery_root_has_entries() {
    for recovery_entry in \
        "$DURABLE_ROOT"/.[!.]* \
        "$DURABLE_ROOT"/..?* \
        "$DURABLE_ROOT"/*
    do
        [ -e "$recovery_entry" ] || [ -L "$recovery_entry" ] || continue
        return 0
    done
    return 1
}

installer_recovery_root_has_entries() {
    for installer_recovery_entry in \
        "$INSTALLER_RECOVERY_ROOT"/.[!.]* \
        "$INSTALLER_RECOVERY_ROOT"/..?* \
        "$INSTALLER_RECOVERY_ROOT"/*
    do
        [ -e "$installer_recovery_entry" ] ||
            [ -L "$installer_recovery_entry" ] || continue
        return 0
    done
    return 1
}

preflight_locked_installer_recovery_evidence() {
    [ "$INSTALL_LOCK_HELD" -eq 1 ] ||
        die "shared installer lock is required before recovery preflight"
    [ "$INSTALLER_RECOVERY_PARENT" != "/" ] ||
        die "JamMonitor installer recovery parent is unsafe"
    [ "$INSTALLER_RECOVERY_ROOT" = "$INSTALLER_RECOVERY_PARENT/recovery" ] ||
        die "JamMonitor installer recovery root is outside the exact protected path"

    if [ ! -e "$INSTALLER_RECOVERY_PARENT" ] &&
       [ ! -L "$INSTALLER_RECOVERY_PARENT" ]; then
        return 0
    fi
    [ -d "$INSTALLER_RECOVERY_PARENT" ] &&
        [ ! -L "$INSTALLER_RECOVERY_PARENT" ] &&
        [ -r "$INSTALLER_RECOVERY_PARENT" ] &&
        [ -x "$INSTALLER_RECOVERY_PARENT" ] ||
        die "JamMonitor installer recovery parent is unsafe or ambiguous"

    if [ ! -e "$INSTALLER_RECOVERY_ROOT" ] &&
       [ ! -L "$INSTALLER_RECOVERY_ROOT" ]; then
        return 0
    fi
    [ -d "$INSTALLER_RECOVERY_ROOT" ] &&
        [ ! -L "$INSTALLER_RECOVERY_ROOT" ] &&
        [ -r "$INSTALLER_RECOVERY_ROOT" ] &&
        [ -x "$INSTALLER_RECOVERY_ROOT" ] ||
        die "JamMonitor installer recovery root is unsafe or ambiguous"

    if installer_recovery_root_has_entries; then
        die "unresolved JamMonitor installer recovery evidence blocks Tailscale upgrade"
    fi
}

prepare_durable_root() {
    pin_storage_authority
    storage_authority_matches_pin ||
        die "persistent recovery storage changed before recovery-root preparation"

    if [ -e "$DURABLE_ROOT" ] || [ -L "$DURABLE_ROOT" ]; then
        [ -d "$DURABLE_ROOT" ] && [ ! -L "$DURABLE_ROOT" ] ||
            die "durable recovery root is not a regular directory"
    else
        mkdir "$DURABLE_ROOT" ||
            die "could not create the durable recovery root"
    fi
    if [ "$TESTING" != "1" ]; then
        chown 0:0 "$DURABLE_ROOT" ||
            die "could not assign the durable recovery root to root"
    fi
    chmod 0700 "$DURABLE_ROOT" ||
        die "could not protect the durable recovery root"
    [ "$("$STAT_CMD" -c '%u:%g:%a' "$DURABLE_ROOT" 2>/dev/null)" = \
      "${EXPECTED_ROOT_UID}:${EXPECTED_ROOT_GID}:700" ] ||
        die "durable recovery root metadata is unsafe"
    storage_authority_matches_pin ||
        die "persistent recovery storage changed during recovery-root preparation"

    if recovery_root_has_entries; then
        die "unresolved durable Tailscale upgrade evidence requires operator recovery"
    fi
}

sync_durable_storage() {
    (
        exec 7>&- 9>&-
        "$TIMEOUT_CMD" -s TERM -k 2 "$SYNC_TIMEOUT" "$SYNC_CMD"
    )
}

remove_exact_durable_directory() {
    remove_path="$1"
    expected_path="$2"
    [ "$remove_path" = "$expected_path" ] || {
        warn "refusing to remove an unexpected durable recovery path"
        return 1
    }
    storage_authority_matches_pin || return 1
    [ -d "$PERSISTENT_MOUNT" ] && [ ! -L "$PERSISTENT_MOUNT" ] || return 1
    [ -d "$DURABLE_ROOT" ] && [ ! -L "$DURABLE_ROOT" ] || return 1
    if [ ! -e "$remove_path" ] && [ ! -L "$remove_path" ]; then
        return 0
    fi
    [ -d "$remove_path" ] && [ ! -L "$remove_path" ] || return 1
    storage_authority_matches_pin || return 1
    rm -rf -- "$remove_path" || return 1
    [ ! -e "$remove_path" ] && [ ! -L "$remove_path" ] || return 1
    if sync_durable_storage && storage_authority_matches_pin; then
        return 0
    fi

    # A failed post-delete flush makes the on-disk outcome unknowable. Publish
    # fresh persistent evidence at the exact owned path so a reboot cannot turn
    # that uncertainty into an automatic retry.
    if mkdir "$remove_path" 2>/dev/null; then
        printf '%s\n' \
            "Recovery cleanup could not be durably verified; operator inspection is required." \
            > "$remove_path/RECOVERY_REQUIRED" 2>/dev/null || true
        chmod 0700 "$remove_path" 2>/dev/null || true
        chmod 0600 "$remove_path/RECOVERY_REQUIRED" 2>/dev/null || true
        sync_durable_storage >/dev/null 2>&1 || true
    fi
    return 1
}

clear_owned_durable_bundle() {
    clear_failed=0

    if [ -n "$DURABLE_STAGING" ]; then
        remove_exact_durable_directory \
            "$DURABLE_STAGING" "$DURABLE_ROOT/.staging.$$" ||
            clear_failed=1
    fi
    if [ -e "$DURABLE_PENDING" ] || [ -L "$DURABLE_PENDING" ]; then
        remove_exact_durable_directory \
            "$DURABLE_PENDING" "$DURABLE_ROOT/pending" ||
            clear_failed=1
    fi

    [ "$clear_failed" -eq 0 ]
}

json_value() {
    file="$1"
    expression="$2"
    "$JSONFILTER_CMD" -i "$file" -e "$expression" 2>/dev/null |
        head -n 1
}

json_type() {
    file="$1"
    expression="$2"
    "$JSONFILTER_CMD" -i "$file" -t "$expression" 2>/dev/null |
        head -n 1
}

tailscale_ip_array_has_only_string_members() {
    file="$1"
    ip_types="$(
        "$JSONFILTER_CMD" -i "$file" \
            -t '@.Self.TailscaleIPs[*]' 2>/dev/null
    )" || return 1
    IP_MEMBER_COUNT=0
    while [ -n "$ip_types" ]; do
        case "$ip_types" in
            string)
                IP_MEMBER_COUNT=$((IP_MEMBER_COUNT + 1))
                ip_types=""
                ;;
            string\\\ *)
                IP_MEMBER_COUNT=$((IP_MEMBER_COUNT + 1))
                ip_types="${ip_types#string\\ }"
                ;;
            *)
                return 1
                ;;
        esac
        [ "$IP_MEMBER_COUNT" -le 100 ] || return 1
    done
}

query_status() {
    output="$1"
    : > "$output"
    if (
        exec 7>&- 9>&-
        "$TIMEOUT_CMD" -s TERM -k 2 "$STATUS_TIMEOUT" \
            /bin/sh -c \
            'ulimit -f "$1" || exit 125; shift; exec "$@"' \
            jammonitor-status-limit "$STATUS_FILE_BLOCKS" "$TAILSCALE_BIN" \
            --socket="$SOCKET_FILE" status --json --peers=false
    ) >"$output" 2>/dev/null; then
        status_rc=0
    else
        status_rc=$?
    fi

    case "$status_rc" in
        124|137|143) return 1 ;;
    esac
    [ "$status_rc" -eq 0 ] || return 1
    [ -s "$output" ] || return 1
    status_size="$(wc -c < "$output" 2>/dev/null | tr -d ' \r\n')" ||
        return 1
    is_uint "$status_size" && [ "$status_size" -le 65536 ] || return 1

    [ "$(json_type "$output" '@.BackendState')" = "string" ] &&
        [ "$(json_type "$output" '@.Version')" = "string" ] &&
        [ "$(json_type "$output" '@.Self.ID')" = "string" ] &&
        [ "$(json_type "$output" '@.AuthURL')" = "string" ] &&
        [ "$(json_type "$output" '@.TUN')" = "boolean" ] &&
        [ "$(json_type "$output" '@.Self.TailscaleIPs')" = "array" ] &&
        tailscale_ip_array_has_only_string_members "$output" ||
        return 1

    OBSERVED_BACKEND="$(json_value "$output" '@.BackendState')"
    OBSERVED_VERSION="$(json_value "$output" '@.Version')"
    OBSERVED_STABLE_ID="$(json_value "$output" '@.Self.ID')"
    OBSERVED_TUN="$(json_value "$output" '@.TUN')"
    OBSERVED_TAILSCALE_IP="$(json_value "$output" '@.Self.TailscaleIPs[0]')"
    OBSERVED_AUTH_URL="$(json_value "$output" '@.AuthURL')"
    [ -n "$OBSERVED_BACKEND" ] || return 1
    if [ "$OBSERVED_BACKEND" = "Running" ]; then
        [ "$IP_MEMBER_COUNT" -gt 0 ] &&
            [ "$(json_type "$output" '@.Self.TailscaleIPs[0]')" = "string" ] ||
            return 1
    fi
}

status_has_required_semantics() {
    expected="$1"
    case "$expected" in
        Running)
            [ "$OBSERVED_BACKEND" = "Running" ] &&
                [ "$OBSERVED_TUN" = "true" ] &&
                is_tailscale_ip "$OBSERVED_TAILSCALE_IP"
            ;;
        NeedsLogin)
            [ "$OBSERVED_BACKEND" = "NeedsLogin" ]
            ;;
        *)
            return 1
            ;;
    esac
}

observed_identity_matches_expected() {
    expected="$1"
    case "$expected" in
        Running)
            [ -n "$OBSERVED_STABLE_ID" ] &&
                [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ]
            ;;
        NeedsLogin)
            # An expired node key can be regenerated while the backend remains
            # NeedsLogin. Until an operator authenticates it, Self.ID can then
            # legitimately be absent, but only while tailscaled also exposes a
            # pending authentication URL. A different nonempty identity is never
            # accepted.
            if [ -z "$OBSERVED_STABLE_ID" ]; then
                [ -n "$OBSERVED_AUTH_URL" ]
            elif [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
                return 1
            else
                [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ]
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

load_required_critical_peer() {
    status_file="$1"
    CRITICAL_PEER=""
    [ -e "$CRITICAL_PEER_FILE" ] || [ -L "$CRITICAL_PEER_FILE" ] ||
        return 1
    [ -f "$CRITICAL_PEER_FILE" ] &&
        [ ! -L "$CRITICAL_PEER_FILE" ] &&
        [ -r "$CRITICAL_PEER_FILE" ] ||
        return 1

    critical_peer_size="$(
        wc -c < "$CRITICAL_PEER_FILE" 2>/dev/null | tr -d ' \r\n'
    )" || return 1
    is_uint "$critical_peer_size" &&
        [ "$critical_peer_size" -gt 0 ] &&
        [ "$critical_peer_size" -le 40 ] ||
        return 1
    invalid_peer_bytes="$(
        LC_ALL=C tr -d '0123456789abcdefABCDEF:.\n' \
            < "$CRITICAL_PEER_FILE" 2>/dev/null |
            wc -c | tr -d ' \r\n'
    )" || return 1
    [ "$invalid_peer_bytes" = "0" ] || return 1
    critical_peer="$(head -n 1 "$CRITICAL_PEER_FILE" 2>/dev/null)" ||
        return 1
    is_tailscale_ip "$critical_peer" || return 1
    if [ "$critical_peer_size" -ne "${#critical_peer}" ] &&
       [ "$critical_peer_size" -ne $((${#critical_peer} + 1)) ]; then
        return 1
    fi
    [ -f "$CRITICAL_PEER_FILE" ] &&
        [ ! -L "$CRITICAL_PEER_FILE" ] &&
        [ -r "$CRITICAL_PEER_FILE" ] ||
        return 1
    critical_peer_key="$(tailscale_ip_key "$critical_peer")" || return 1
    if "$JSONFILTER_CMD" -i "$status_file" \
        -e '@.Self.TailscaleIPs[*]' 2>/dev/null |
        (
            while IFS= read -r self_ip; do
                self_ip_key="$(tailscale_ip_key "$self_ip")" || continue
                [ "$self_ip_key" = "$critical_peer_key" ] && exit 0
            done
            exit 1
        )
    then
        return 1
    fi
    CRITICAL_PEER="$critical_peer"
}

critical_peer_is_reachable() {
    [ -n "$CRITICAL_PEER" ] || return 1
    (
        exec 7>&- 9>&-
        "$TIMEOUT_CMD" -s TERM -k 2 "$PEER_COMMAND_TIMEOUT" \
            "$TAILSCALE_BIN" --socket="$SOCKET_FILE" ping \
            --tsmp --c=1 --timeout=3s --until-direct=false -- \
            "$CRITICAL_PEER"
    ) >/dev/null 2>&1
}

state_file_is_safe() {
    [ -f "$STATE_FILE" ] &&
        [ ! -L "$STATE_FILE" ] &&
        [ -s "$STATE_FILE" ]
}

recovery_state_matches_authorized_hash() {
    [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 0 ] && return 0
    state_file_is_safe &&
        [ "$(sha256_file "$STATE_FILE")" = "$RECOVERY_STATE_SHA256" ]
}

installed_file_metadata_matches() {
    metadata_path="$1"
    metadata_mode="$2"
    [ -f "$metadata_path" ] && [ ! -L "$metadata_path" ] || return 1
    metadata="$("$STAT_CMD" -c '%u:%g:%a' "$metadata_path" 2>/dev/null)" ||
        return 1
    [ "$metadata" = \
      "${EXPECTED_ROOT_UID}:${EXPECTED_ROOT_GID}:${metadata_mode}" ]
}

verify_installed_init_integrity() {
    is_uint "$EXPECTED_ROOT_UID" && is_uint "$EXPECTED_ROOT_GID" || return 1
    installed_file_metadata_matches "$ROUTER_MANIFEST" 644 || return 1
    installed_file_metadata_matches "$ROUTER_MANIFEST_DIGEST" 644 || return 1
    installed_file_metadata_matches "$INIT_SCRIPT" 755 || return 1

    manifest_size="$(wc -c < "$ROUTER_MANIFEST" 2>/dev/null |
        tr -d ' \r\n')"
    is_uint "$manifest_size" &&
        [ "$manifest_size" -gt 0 ] &&
        [ "$manifest_size" -le 65536 ] || return 1
    digest_size="$(wc -c < "$ROUTER_MANIFEST_DIGEST" 2>/dev/null |
        tr -d ' \r\n')"
    [ "$digest_size" = "65" ] || return 1
    IFS= read -r saved_manifest_sha < "$ROUTER_MANIFEST_DIGEST" ||
        return 1
    is_sha256 "$saved_manifest_sha" || return 1
    [ "$(sha256_file "$ROUTER_MANIFEST")" = "$saved_manifest_sha" ] ||
        return 1

    init_manifest_matches=0
    expected_init_sha=""
    while IFS=' ' read -r manifest_sha manifest_source manifest_extra
    do
        [ "$manifest_source" = "router/tailscale.init" ] || continue
        [ -z "$manifest_extra" ] && is_sha256 "$manifest_sha" || return 1
        init_manifest_matches=$((init_manifest_matches + 1))
        [ "$init_manifest_matches" -eq 1 ] || return 1
        expected_init_sha="$manifest_sha"
    done < "$ROUTER_MANIFEST"
    [ "$init_manifest_matches" -eq 1 ] &&
        [ -n "$expected_init_sha" ] || return 1

    # Join the trust files and init across a second metadata/hash observation.
    # The shared installer lock prevents a legitimate concurrent replacement;
    # any other drift fails closed before the init is executed.
    installed_file_metadata_matches "$ROUTER_MANIFEST" 644 || return 1
    installed_file_metadata_matches "$ROUTER_MANIFEST_DIGEST" 644 || return 1
    installed_file_metadata_matches "$INIT_SCRIPT" 755 || return 1
    [ "$(sha256_file "$ROUTER_MANIFEST")" = "$saved_manifest_sha" ] ||
        return 1
    [ "$(sha256_file "$INIT_SCRIPT")" = "$expected_init_sha" ]
}

service_command() {
    action="$1"
    if ! verify_installed_init_integrity; then
        warn "installed Tailscale init failed manifest authentication"
        return 125
    fi
    if [ "$action" = "start" ] && [ "$UPGRADE_FENCE_CREATED" -eq 1 ]; then
        upgrade_fence_matches_expected || {
            warn "Tailscale upgrade fence changed before authorized service start"
            return 125
        }
        (
            exec 7>&- 9>&-
            JAMMONITOR_TAILSCALE_UPGRADE_FENCE_TOKEN="$UPGRADE_FENCE_TOKEN" \
                "$TIMEOUT_CMD" -s TERM -k 2 "$SERVICE_TIMEOUT" \
                "$INIT_SCRIPT" "$action"
        ) >/dev/null 2>&1
    else
        (
            exec 7>&- 9>&-
            "$TIMEOUT_CMD" -s TERM -k 2 "$SERVICE_TIMEOUT" \
                "$INIT_SCRIPT" "$action"
        ) >/dev/null 2>&1
    fi
}

inspect_service_running_state() {
    SERVICE_RUNNING_STATE="error"
    SERVICE_RUNNING_RC=0
    if service_command running; then
        SERVICE_RUNNING_RC=0
    else
        SERVICE_RUNNING_RC=$?
    fi

    case "$SERVICE_RUNNING_RC" in
        0)
            SERVICE_RUNNING_STATE="running"
            ;;
        1)
            SERVICE_RUNNING_STATE="inactive"
            ;;
        *)
            SERVICE_RUNNING_STATE="error"
            ;;
    esac
}

service_reports_inactive() {
    inspect_service_running_state
    if [ "$SERVICE_RUNNING_STATE" = "inactive" ]; then
        return 0
    fi
    return 1
}

tailscaled_process_is_live() {
    for comm_file in "$PROC_ROOT"/[0-9]*/comm; do
        [ -r "$comm_file" ] || continue
        process_name=""
        IFS= read -r process_name < "$comm_file" || continue
        [ "$process_name" = "tailscaled" ] && return 0
    done
    return 1
}

is_quiescent() {
    service_reports_inactive &&
        ! tailscaled_process_is_live &&
        [ ! -e "$SOCKET_FILE" ] &&
        [ ! -L "$SOCKET_FILE" ]
}

wait_for_quiescence() {
    attempts="$QUIESCE_ATTEMPTS"
    while [ "$attempts" -gt 0 ]; do
        if is_quiescent; then
            QUIESCENCE_PROVEN=1
            return 0
        fi
        attempts=$((attempts - 1))
        [ "$attempts" -gt 0 ] || break
        sleep "$QUIESCE_DELAY"
    done
    return 1
}

atomic_install() {
    source="$1"
    target="$2"
    mode="$3"
    mutation_guard="${4:-}"
    target_dir="$(dirname -- "$target")"
    ATOMIC_INSTALL_GUARD_FAILED=0

    mkdir -p "$target_dir" || return 1
    TARGET_TEMP="$(mktemp "$target_dir/.tailscale-upgrade.XXXXXX")" ||
        return 1
    if ! cp -- "$source" "$TARGET_TEMP"; then
        rm -f -- "$TARGET_TEMP"
        TARGET_TEMP=""
        return 1
    fi
    if ! chmod "$mode" "$TARGET_TEMP"; then
        rm -f -- "$TARGET_TEMP"
        TARGET_TEMP=""
        return 1
    fi
    if [ "$TESTING" != "1" ]; then
        if ! chown 0:0 "$TARGET_TEMP" 2>/dev/null; then
            rm -f -- "$TARGET_TEMP"
            TARGET_TEMP=""
            return 1
        fi
    fi
    if [ "$mutation_guard" = "live-binary" ] &&
       ! prove_live_mutation_guard; then
        ATOMIC_INSTALL_GUARD_FAILED=1
        rm -f -- "$TARGET_TEMP"
        TARGET_TEMP=""
        return 1
    fi
    if ! mv -f -- "$TARGET_TEMP" "$target"; then
        rm -f -- "$TARGET_TEMP"
        TARGET_TEMP=""
        return 1
    fi
    TARGET_TEMP=""
}

wait_for_expected_state() {
    expected="$1"
    attempts="$STATUS_ATTEMPTS"
    status_file="$WORK_DIR/post-status.json"

    while [ "$attempts" -gt 0 ]; do
        if query_status "$status_file"; then
            if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
                [ -z "$OBSERVED_STABLE_ID" ] || return 1
                recovery_state_matches_authorized_hash || return 1
                case "$OBSERVED_BACKEND" in
                    NeedsLogin)
                        ;;
                    Starting)
                        attempts=$((attempts - 1))
                        [ "$attempts" -gt 0 ] || break
                        sleep "$STATUS_DELAY"
                        continue
                        ;;
                    *)
                        return 1
                        ;;
                esac
            fi
            if status_has_required_semantics "$expected" &&
               observed_identity_matches_expected "$expected" &&
               state_file_is_safe &&
               recovery_state_matches_authorized_hash; then
                case "$OBSERVED_VERSION" in
                    "$TARGET_VERSION"|"$TARGET_VERSION"-*)
                        [ "$(sha256_file "$TAILSCALE_BIN")" = "$NEW_CLI_SHA256" ] &&
                            [ "$(sha256_file "$TAILSCALED_BIN")" = "$NEW_DAEMON_SHA256" ] &&
                            return 0
                        ;;
                esac
            fi
        fi
        attempts=$((attempts - 1))
        [ "$attempts" -gt 0 ] || break
        sleep "$STATUS_DELAY"
    done
    return 1
}

wait_for_rollback_state() {
    expected="$1"
    attempts=5
    status_file="$WORK_DIR/rollback-status.json"

    while [ "$attempts" -gt 0 ]; do
        if query_status "$status_file"; then
            if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
                [ -z "$OBSERVED_STABLE_ID" ] || return 1
                recovery_state_matches_authorized_hash || return 1
                case "$OBSERVED_BACKEND" in
                    NeedsLogin)
                        ;;
                    Starting)
                        attempts=$((attempts - 1))
                        [ "$attempts" -gt 0 ] || break
                        sleep 1
                        continue
                        ;;
                    *)
                        return 1
                        ;;
                esac
            fi
            if status_has_required_semantics "$expected" &&
               observed_identity_matches_expected "$expected" &&
               state_file_is_safe &&
               recovery_state_matches_authorized_hash; then
                if [ -z "$PRE_DAEMON_VERSION" ] ||
                   [ "$OBSERVED_VERSION" = "$PRE_DAEMON_VERSION" ]; then
                    [ "$(sha256_file "$TAILSCALE_BIN")" = "$PRE_CLI_SHA256" ] &&
                        [ "$(sha256_file "$TAILSCALED_BIN")" = "$PRE_DAEMON_SHA256" ] &&
                        return 0
                fi
            fi
        fi
        attempts=$((attempts - 1))
        [ "$attempts" -gt 0 ] || break
        sleep 1
    done
    return 1
}

restore_previous_state() {
    atomic_install "$BACKUP_DIR/tailscaled.state" "$STATE_FILE" 0600
}

write_durable_manifest() {
    manifest_phase="$1"
    manifest_state_sha256="$2"
    manifest_tmp="$DURABLE_PENDING/.manifest.tmp.$$"

    {
        printf 'format=jammonitor-tailscale-upgrade-recovery-v1\n'
        printf 'phase=%s\n' "$manifest_phase"
        printf 'tailscale_path=/usr/sbin/tailscale\n'
        printf 'tailscaled_path=/usr/sbin/tailscaled\n'
        printf 'state_path=/etc/tailscale/tailscaled.state\n'
        printf 'pre_backend_state=%s\n' "$PRE_BACKEND_STATE"
        printf 'pre_daemon_version=%s\n' "$PRE_DAEMON_VERSION"
        printf 'pre_cli_sha256=%s\n' "$PRE_CLI_SHA256"
        printf 'pre_daemon_sha256=%s\n' "$PRE_DAEMON_SHA256"
        printf 'pre_stop_state_sha256=%s\n' "$PRE_STOP_STATE_SHA256"
        printf 'quiescent_state_sha256=%s\n' "$manifest_state_sha256"
    } > "$manifest_tmp" ||
        return 1
    chmod 0600 "$manifest_tmp" ||
        return 1
    mv -f -- "$manifest_tmp" "$DURABLE_PENDING/manifest"
}

durable_bundle_is_safe() {
    expected_phase="$1"
    [ "$DURABLE_PENDING" = "$DURABLE_ROOT/pending" ] &&
        [ -d "$DURABLE_PENDING" ] &&
        [ ! -L "$DURABLE_PENDING" ] ||
        return 1

    for durable_file in \
        "$DURABLE_PENDING/tailscale" \
        "$DURABLE_PENDING/tailscaled" \
        "$DURABLE_PENDING/tailscaled.state.before-stop" \
        "$DURABLE_PENDING/manifest" \
        "$DURABLE_PENDING/RECOVERY_REQUIRED"
    do
        [ -f "$durable_file" ] && [ ! -L "$durable_file" ] ||
            return 1
    done

    [ "$(sha256_file "$DURABLE_PENDING/tailscale")" = "$PRE_CLI_SHA256" ] &&
        [ "$(sha256_file "$DURABLE_PENDING/tailscaled")" = "$PRE_DAEMON_SHA256" ] &&
        [ "$(sha256_file "$DURABLE_PENDING/tailscaled.state.before-stop")" = \
          "$PRE_STOP_STATE_SHA256" ] ||
        return 1

    grep -Fqx 'format=jammonitor-tailscale-upgrade-recovery-v1' \
        "$DURABLE_PENDING/manifest" &&
        grep -Fqx "phase=$expected_phase" "$DURABLE_PENDING/manifest" ||
        return 1

    if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
        [ -f "$DURABLE_PENDING/recovery-authorized-tailscaled.state" ] &&
            [ ! -L "$DURABLE_PENDING/recovery-authorized-tailscaled.state" ] &&
            [ "$(sha256_file \
                "$DURABLE_PENDING/recovery-authorized-tailscaled.state")" = \
              "$RECOVERY_STATE_SHA256" ] ||
            return 1
    fi

    if [ "$expected_phase" = "ready_for_binary_mutation" ]; then
        [ -f "$DURABLE_PENDING/tailscaled.state" ] &&
            [ ! -L "$DURABLE_PENDING/tailscaled.state" ] &&
            [ "$(sha256_file "$DURABLE_PENDING/tailscaled.state")" = \
              "$PRE_STATE_SHA256" ] &&
            grep -Fqx "quiescent_state_sha256=$PRE_STATE_SHA256" \
                "$DURABLE_PENDING/manifest" ||
            return 1
    fi
}

prepare_durable_write_ahead_bundle() {
    DURABLE_STAGING="$DURABLE_ROOT/.staging.$$"
    [ ! -e "$DURABLE_STAGING" ] && [ ! -L "$DURABLE_STAGING" ] ||
        die "durable recovery staging path already exists"
    mkdir "$DURABLE_STAGING" ||
        die "could not create durable recovery staging"
    chmod 0700 "$DURABLE_STAGING" ||
        die "could not protect durable recovery staging"

    cp -p -- "$TAILSCALE_BIN" "$DURABLE_STAGING/tailscale" &&
        cp -p -- "$TAILSCALED_BIN" "$DURABLE_STAGING/tailscaled" &&
        cp -p -- "$STATE_FILE" \
            "$DURABLE_STAGING/tailscaled.state.before-stop" ||
        die "could not create the durable pre-stop recovery copy"
    chmod 0700 \
        "$DURABLE_STAGING/tailscale" \
        "$DURABLE_STAGING/tailscaled" ||
        die "could not protect durable recovery binaries"
    chmod 0600 "$DURABLE_STAGING/tailscaled.state.before-stop" ||
        die "could not protect durable recovery state"

    PRE_STOP_STATE_SHA256="$(
        sha256_file "$DURABLE_STAGING/tailscaled.state.before-stop"
    )"
    is_sha256 "$PRE_STOP_STATE_SHA256" ||
        die "could not hash the durable pre-stop state"
    [ "$(sha256_file "$DURABLE_STAGING/tailscale")" = "$PRE_CLI_SHA256" ] &&
        [ "$(sha256_file "$DURABLE_STAGING/tailscaled")" = \
          "$PRE_DAEMON_SHA256" ] ||
        die "durable pre-stop binary copy verification failed"

    if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
        [ "$PRE_STOP_STATE_SHA256" = "$RECOVERY_STATE_SHA256" ] &&
            recovery_state_matches_authorized_hash ||
            die "Tailscale state changed before the recovery transaction"
        cp -p -- "$DURABLE_STAGING/tailscaled.state.before-stop" \
            "$DURABLE_STAGING/recovery-authorized-tailscaled.state" ||
            die "could not preserve the operator-authorized recovery state"
        chmod 0600 \
            "$DURABLE_STAGING/recovery-authorized-tailscaled.state" ||
            die "could not protect the operator-authorized recovery state"
    fi

    {
        printf 'format=jammonitor-tailscale-upgrade-recovery-v1\n'
        printf 'phase=prepared_before_stop\n'
        printf 'tailscale_path=/usr/sbin/tailscale\n'
        printf 'tailscaled_path=/usr/sbin/tailscaled\n'
        printf 'state_path=/etc/tailscale/tailscaled.state\n'
        printf 'pre_backend_state=%s\n' "$PRE_BACKEND_STATE"
        printf 'pre_daemon_version=%s\n' "$PRE_DAEMON_VERSION"
        printf 'pre_cli_sha256=%s\n' "$PRE_CLI_SHA256"
        printf 'pre_daemon_sha256=%s\n' "$PRE_DAEMON_SHA256"
        printf 'pre_stop_state_sha256=%s\n' "$PRE_STOP_STATE_SHA256"
        printf 'quiescent_state_sha256=\n'
    } > "$DURABLE_STAGING/manifest" ||
        die "could not write the durable recovery manifest"
    printf '%s\n' \
        'An interrupted Tailscale upgrade requires explicit operator recovery.' \
        > "$DURABLE_STAGING/RECOVERY_REQUIRED" ||
        die "could not write the durable recovery marker"
    chmod 0600 \
        "$DURABLE_STAGING/manifest" \
        "$DURABLE_STAGING/RECOVERY_REQUIRED" ||
        die "could not protect durable recovery metadata"

    sync_durable_storage ||
        die "could not durably flush the pre-stop recovery bundle"
    [ ! -e "$DURABLE_PENDING" ] && [ ! -L "$DURABLE_PENDING" ] ||
        die "durable recovery pending path unexpectedly exists"
    mv -- "$DURABLE_STAGING" "$DURABLE_PENDING" ||
        die "could not publish the durable recovery bundle"
    DURABLE_STAGING=""
    BACKUP_DIR="$DURABLE_PENDING"
    if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
        RECOVERY_STATE_BACKUP="$DURABLE_PENDING/recovery-authorized-tailscaled.state"
        RECOVERY_STATE_BACKUP_READY=1
    fi
    sync_durable_storage ||
        die "could not durably publish the recovery bundle"
    durable_bundle_is_safe prepared_before_stop ||
        die "published durable recovery bundle failed verification"
}

finalize_durable_quiescent_backup() {
    state_tmp="$DURABLE_PENDING/.tailscaled.state.tmp.$$"
    cp -p -- "$STATE_FILE" "$state_tmp" ||
        die "could not copy quiescent state into durable recovery"
    chmod 0600 "$state_tmp" ||
        die "could not protect the durable quiescent state"
    [ "$(sha256_file "$state_tmp")" = "$PRE_STATE_SHA256" ] ||
        die "durable quiescent state copy verification failed"
    mv -f -- "$state_tmp" "$DURABLE_PENDING/tailscaled.state" ||
        die "could not publish the durable quiescent state"
    write_durable_manifest ready_for_binary_mutation "$PRE_STATE_SHA256" ||
        die "could not publish the durable recovery manifest"
    sync_durable_storage ||
        die "could not durably flush the quiescent recovery bundle"
    durable_bundle_is_safe ready_for_binary_mutation ||
        die "durable recovery bundle is incomplete before binary mutation"
    sync_durable_storage ||
        die "could not complete the write-ahead recovery barrier"
    [ -d "$PERSISTENT_MOUNT" ] && [ ! -L "$PERSISTENT_MOUNT" ] &&
        persistent_mount_is_ext4_rw ||
        die "persistent recovery mount changed before binary mutation"
    durable_bundle_is_safe ready_for_binary_mutation ||
        die "durable recovery bundle changed before binary mutation"
    BACKUP_READY=1
}

generate_fence_token() {
    token_seed="$RUNTIME_DIR/.tailscale-upgrade-token.$$"
    [ ! -e "$token_seed" ] && [ ! -L "$token_seed" ] || return 1
    (
        umask 077
        dd if=/dev/urandom of="$token_seed" bs=32 count=1 2>/dev/null
    ) || return 1
    [ "$(wc -c < "$token_seed" 2>/dev/null | tr -d ' ')" = "32" ] ||
        return 1
    UPGRADE_FENCE_TOKEN="$(sha256_file "$token_seed")"
    rm -f -- "$token_seed"
    is_sha256 "$UPGRADE_FENCE_TOKEN" || return 1
    UPGRADE_FENCE_TOKEN="$(printf '%s' "$UPGRADE_FENCE_TOKEN" |
        tr 'A-F' 'a-f')"
}

upgrade_fence_matches_expected() {
    [ "$UPGRADE_FENCE_CREATED" -eq 1 ] &&
        [ "$UPGRADE_FENCE_PHASE" = "ready_for_binary_mutation" ] &&
        is_sha256 "$UPGRADE_FENCE_TOKEN" &&
        [ -f "$UPGRADE_FENCE" ] &&
        [ ! -L "$UPGRADE_FENCE" ] ||
        return 1
    [ "$("$STAT_CMD" -c '%u:%g:%a:%h' "$UPGRADE_FENCE" 2>/dev/null)" = \
      "${EXPECTED_ROOT_UID}:${EXPECTED_ROOT_GID}:600:1" ] ||
        return 1
    [ "$(wc -l < "$UPGRADE_FENCE" 2>/dev/null | tr -d ' ')" = "9" ] ||
        return 1
    fence_size="$(wc -c < "$UPGRADE_FENCE" 2>/dev/null |
        tr -d ' \r\n')" || return 1
    is_uint "$fence_size" && [ "$fence_size" -le 1024 ] || return 1
    storage_authority_matches_pin || return 1
    [ -d "$DURABLE_PENDING" ] && [ ! -L "$DURABLE_PENDING" ] ||
        return 1
    fence_bundle_identity="$(
        "$STAT_CMD" -c '%d:%i' "$DURABLE_PENDING" 2>/dev/null
    )" || return 1
    fence_manifest_sha="$(sha256_file "$DURABLE_PENDING/manifest")" ||
        return 1
    is_sha256 "$fence_manifest_sha" || return 1

    expected_fence="$RUNTIME_DIR/.expected-upgrade-fence.$$"
    {
        printf 'format=jammonitor-tailscale-upgrade-fence-v1\n'
        printf 'token=%s\n' "$UPGRADE_FENCE_TOKEN"
        printf 'source=%s\n' "$STORAGE_SOURCE_LOGICAL"
        printf 'source_identity=%s\n' "$STORAGE_SOURCE_IDENTITY"
        printf 'uuid=%s\n' "$STORAGE_UUID"
        printf 'bundle=/mnt/data/.jammonitor-tailscale-upgrade/pending\n'
        printf 'bundle_identity=%s\n' "$fence_bundle_identity"
        printf 'bundle_manifest_sha256=%s\n' "$fence_manifest_sha"
        printf 'phase=ready_for_binary_mutation\n'
    } > "$expected_fence" || return 1
    if cmp -s "$expected_fence" "$UPGRADE_FENCE"; then
        fence_matches=0
    else
        fence_matches=1
    fi
    rm -f -- "$expected_fence"
    [ "$fence_matches" -eq 0 ]
}

publish_upgrade_fence() {
    [ "$BACKUP_READY" -eq 1 ] &&
        durable_bundle_is_safe ready_for_binary_mutation &&
        storage_authority_matches_pin ||
        die "trusted USB recovery bundle is unavailable for the boot fence"
    [ ! -e "$UPGRADE_FENCE" ] && [ ! -L "$UPGRADE_FENCE" ] ||
        die "an existing Tailscale upgrade boot fence requires operator recovery"
    generate_fence_token ||
        die "could not create the Tailscale upgrade fence token"
    fence_bundle_identity="$(
        "$STAT_CMD" -c '%d:%i' "$DURABLE_PENDING" 2>/dev/null
    )" || die "could not identify the trusted USB recovery bundle"
    fence_manifest_sha="$(sha256_file "$DURABLE_PENDING/manifest")"
    is_sha256 "$fence_manifest_sha" ||
        die "could not hash the trusted USB recovery manifest"

    UPGRADE_FENCE_TEMP="${UPGRADE_FENCE}.tmp.$$"
    [ ! -e "$UPGRADE_FENCE_TEMP" ] && [ ! -L "$UPGRADE_FENCE_TEMP" ] ||
        die "Tailscale upgrade fence temporary path already exists"
    (
        set -C
        umask 077
        {
            printf 'format=jammonitor-tailscale-upgrade-fence-v1\n'
            printf 'token=%s\n' "$UPGRADE_FENCE_TOKEN"
            printf 'source=%s\n' "$STORAGE_SOURCE_LOGICAL"
            printf 'source_identity=%s\n' "$STORAGE_SOURCE_IDENTITY"
            printf 'uuid=%s\n' "$STORAGE_UUID"
            printf 'bundle=/mnt/data/.jammonitor-tailscale-upgrade/pending\n'
            printf 'bundle_identity=%s\n' "$fence_bundle_identity"
            printf 'bundle_manifest_sha256=%s\n' "$fence_manifest_sha"
            printf 'phase=ready_for_binary_mutation\n'
        } > "$UPGRADE_FENCE_TEMP"
    ) || die "could not stage the Tailscale upgrade boot fence"
    chmod 0600 "$UPGRADE_FENCE_TEMP" ||
        die "could not protect the Tailscale upgrade boot fence"
    if [ "$TESTING" != "1" ]; then
        chown 0:0 "$UPGRADE_FENCE_TEMP" ||
            die "could not assign the Tailscale upgrade fence to root"
    fi
    storage_authority_matches_pin ||
        die "persistent recovery authority changed before fence publication"
    mv -f -- "$UPGRADE_FENCE_TEMP" "$UPGRADE_FENCE" ||
        die "could not publish the Tailscale upgrade boot fence"
    UPGRADE_FENCE_TEMP=""
    UPGRADE_FENCE_CREATED=1
    UPGRADE_FENCE_PHASE="ready_for_binary_mutation"
    upgrade_fence_matches_expected ||
        die "published Tailscale upgrade boot fence failed exact verification"
    UPGRADE_FENCE_SHA256="$(sha256_file "$UPGRADE_FENCE")"
    is_sha256 "$UPGRADE_FENCE_SHA256" ||
        die "could not fingerprint the published Tailscale upgrade boot fence"
    sync_durable_storage ||
        die "could not durably publish the Tailscale upgrade boot fence"
    upgrade_fence_matches_expected ||
        die "Tailscale upgrade boot fence changed after synchronization"
}

clear_upgrade_fence() {
    [ "$UPGRADE_FENCE_CREATED" -eq 1 ] || return 0
    storage_authority_matches_pin || return 1
    durable_bundle_is_safe ready_for_binary_mutation &&
        upgrade_fence_matches_expected ||
        return 1
    rm -f -- "$UPGRADE_FENCE" || return 1
    [ ! -e "$UPGRADE_FENCE" ] && [ ! -L "$UPGRADE_FENCE" ] || return 1
    sync_durable_storage || return 1
    UPGRADE_FENCE_CREATED=0
    UPGRADE_FENCE_PHASE=""
    UPGRADE_FENCE_TOKEN=""
    UPGRADE_FENCE_SHA256=""
}

restore_recovery_authorized_state() {
    [ "$RECOVERY_STATE_BACKUP_READY" -eq 1 ] || return 1
    [ -f "$RECOVERY_STATE_BACKUP" ] &&
        [ ! -L "$RECOVERY_STATE_BACKUP" ] &&
        [ "$(sha256_file "$RECOVERY_STATE_BACKUP")" = "$RECOVERY_STATE_SHA256" ] ||
        return 1
    atomic_install "$RECOVERY_STATE_BACKUP" "$STATE_FILE" 0600 &&
        recovery_state_matches_authorized_hash
}

mark_rollback_incomplete() {
    ROLLBACK_INCOMPLETE=1
    PRESERVE_WORK_DIR=1
    recovery_bundle="$WORK_DIR"
    if [ -d "$DURABLE_PENDING" ] && [ ! -L "$DURABLE_PENDING" ]; then
        recovery_bundle="$DURABLE_PENDING"
    fi
    bundle_evidence="$recovery_bundle/ROLLBACK_INCOMPLETE"
    {
        printf 'status=rollback_incomplete\n'
        printf 'recovery_bundle=%s\n' "$recovery_bundle"
        printf 'mutation_started=%s\n' "$MUTATION_STARTED"
        printf 'backup_ready=%s\n' "$BACKUP_READY"
    } > "$bundle_evidence" 2>/dev/null || true
    chmod 0600 "$bundle_evidence" 2>/dev/null || true
    evidence_tmp=""
    if mkdir -p "$RUNTIME_DIR" &&
       evidence_tmp="$(mktemp "$RUNTIME_DIR/.tailscale-rollback-failed.XXXXXX")"; then
        cp -- "$bundle_evidence" "$evidence_tmp" &&
            chmod 0600 "$evidence_tmp" &&
            mv -f -- "$evidence_tmp" "$RECOVERY_EVIDENCE" ||
            rm -f -- "$evidence_tmp" 2>/dev/null || true
    fi
    printf 'CRITICAL: Tailscale rollback is incomplete. Recovery bundle preserved at %s\n' \
        "$recovery_bundle" >&2
    printf 'CRITICAL: Do not retry automatically; inspect %s\n' \
        "$RECOVERY_EVIDENCE" >&2
}

preupgrade_service_is_restored() {
    status_file="$WORK_DIR/preupgrade-restored.json"
    query_status "$status_file" &&
        status_has_required_semantics "$PRE_BACKEND_STATE" &&
        observed_identity_matches_expected "$PRE_BACKEND_STATE" &&
        state_file_is_safe &&
        recovery_state_matches_authorized_hash &&
        [ "$OBSERVED_VERSION" = "$PRE_DAEMON_VERSION" ] &&
        [ "$(sha256_file "$TAILSCALE_BIN")" = "$PRE_CLI_SHA256" ] &&
        [ "$(sha256_file "$TAILSCALED_BIN")" = "$PRE_DAEMON_SHA256" ]
}

sync_and_verify_restored_live_targets() {
    if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
        expected_live_state_sha256="$RECOVERY_STATE_SHA256"
    elif [ -n "$PRE_STATE_SHA256" ]; then
        expected_live_state_sha256="$PRE_STATE_SHA256"
    else
        state_file_is_safe || return 1
        expected_live_state_sha256="$(sha256_file "$STATE_FILE")"
    fi
    is_sha256 "$expected_live_state_sha256" || return 1

    # BusyBox may be built without FEATURE_SYNC_FANCY, so do not rely on
    # per-file flags. A successful global sync is the independent persistence
    # barrier for all three restored live targets.
    sync_durable_storage ||
        return 1

    [ -f "$TAILSCALE_BIN" ] && [ ! -L "$TAILSCALE_BIN" ] &&
        [ "$(sha256_file "$TAILSCALE_BIN")" = "$PRE_CLI_SHA256" ] &&
        [ -f "$TAILSCALED_BIN" ] && [ ! -L "$TAILSCALED_BIN" ] &&
        [ "$(sha256_file "$TAILSCALED_BIN")" = "$PRE_DAEMON_SHA256" ] &&
        state_file_is_safe &&
        [ "$(sha256_file "$STATE_FILE")" = "$expected_live_state_sha256" ]
}

force_preupgrade_service_state() {
    service_command start || return 1
    wait_for_rollback_state "$PRE_BACKEND_STATE"
}

rollback_upgrade() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ "$TRANSACTION_COMMITTED" -eq 0 ] || return 0

    warn "upgrade transaction failed; restoring the previous verified state"
    rollback_failed=0

    if [ "$MUTATION_STARTED" -eq 1 ]; then
        if ! durable_bundle_is_safe ready_for_binary_mutation; then
            warn "durable recovery bundle is unsafe; refusing automatic rollback restore"
            rollback_failed=1
        fi
        QUIESCENCE_PROVEN=0
        if [ "$rollback_failed" -ne 0 ]; then
            :
        elif ! service_command stop || ! wait_for_quiescence; then
            warn "could not prove quiescence before rollback restore"
            rollback_failed=1
        else
            if ! atomic_install "$BACKUP_DIR/tailscale" "$TAILSCALE_BIN" 0755; then
                warn "could not restore the previous tailscale binary"
                rollback_failed=1
            fi
            if ! atomic_install "$BACKUP_DIR/tailscaled" "$TAILSCALED_BIN" 0755; then
                warn "could not restore the previous tailscaled binary"
                rollback_failed=1
            fi
            if ! restore_previous_state; then
                warn "could not restore the previous Tailscale state"
                rollback_failed=1
            fi

            [ -f "$TAILSCALE_BIN" ] &&
                [ "$(sha256_file "$TAILSCALE_BIN")" = "$PRE_CLI_SHA256" ] || {
                    warn "restored tailscale binary hash verification failed"
                    rollback_failed=1
                }
            [ -f "$TAILSCALED_BIN" ] &&
                [ "$(sha256_file "$TAILSCALED_BIN")" = "$PRE_DAEMON_SHA256" ] || {
                    warn "restored tailscaled binary hash verification failed"
                    rollback_failed=1
                }
            [ -f "$STATE_FILE" ] &&
                [ "$(sha256_file "$STATE_FILE")" = "$PRE_STATE_SHA256" ] || {
                    warn "restored state hash verification failed"
                    rollback_failed=1
                }
        fi
    fi

    if [ "$MUTATION_STARTED" -eq 0 ] &&
       [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ] &&
       [ "$RECOVERY_STATE_BACKUP_READY" -eq 1 ] &&
       is_quiescent &&
       ! recovery_state_matches_authorized_hash; then
        if ! restore_recovery_authorized_state; then
            warn "could not restore the operator-authorized Tailscale state"
            rollback_failed=1
        fi
    fi

    if [ "$MUTATION_STARTED" -eq 0 ] || [ "$rollback_failed" -eq 0 ]; then
        if [ "$STOP_REQUESTED" -eq 1 ]; then
            # A bounded stop can time out while an asynchronous stop finishes
            # later. Reassert the pre-upgrade running service even if the first
            # status observation still looks Running.
            force_preupgrade_service_state || {
                warn "previous service identity/state was not restored"
                rollback_failed=1
            }
        elif is_quiescent; then
            service_command start || {
                warn "previous Tailscale service could not be restarted"
                rollback_failed=1
            }
        fi
        if [ "$rollback_failed" -eq 0 ] &&
           ! wait_for_rollback_state "$PRE_BACKEND_STATE"; then
            warn "previous service identity/state was not restored"
            rollback_failed=1
        fi
    fi

    if [ "$rollback_failed" -eq 0 ] &&
       ! sync_and_verify_restored_live_targets; then
        warn "restored live Tailscale targets did not pass the durable sync barrier"
        rollback_failed=1
    fi

    if [ "$rollback_failed" -eq 0 ] && [ "$STOP_REQUESTED" -eq 1 ]; then
        # This second start and exact status check are intentionally adjacent
        # to WAL removal. They close the late-stop race after the first
        # successful rollback observation.
        if ! force_preupgrade_service_state ||
           ! sync_and_verify_restored_live_targets ||
           ! preupgrade_service_is_restored; then
            warn "final pre-upgrade running state could not be proven before recovery cleanup"
            rollback_failed=1
        fi
    fi

    if [ "$rollback_failed" -eq 0 ] &&
       [ "$PRE_BACKEND_STATE" = "Running" ] &&
       ! critical_peer_is_reachable; then
        warn "critical Tailscale peer was not reachable after rollback"
        rollback_failed=1
    fi

    if [ "$rollback_failed" -ne 0 ]; then
        mark_rollback_incomplete
        return 1
    fi
    if ! clear_upgrade_fence; then
        warn "could not durably clear the verified Tailscale boot fence"
        mark_rollback_incomplete
        return 1
    fi
    if ! clear_owned_durable_bundle; then
        warn "could not durably clear the verified recovery bundle"
        mark_rollback_incomplete
        return 1
    fi
    rm -f -- "$RECOVERY_EVIDENCE"
    return 0
}

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    rollback_upgrade || true
    if [ "$MAINTENANCE_CREATED" -eq 1 ] &&
       [ "$ROLLBACK_INCOMPLETE" -eq 0 ]; then
        remove_owned_maintenance_marker || true
    fi
    if [ -n "$MAINTENANCE_TEMP" ]; then
        rm -f -- "$MAINTENANCE_TEMP"
        MAINTENANCE_TEMP=""
    fi
    if [ -n "$UPGRADE_FENCE_TEMP" ]; then
        rm -f -- "$UPGRADE_FENCE_TEMP"
        UPGRADE_FENCE_TEMP=""
    fi
    if [ -n "$STORAGE_CAPTURE" ]; then
        rm -f -- "$STORAGE_CAPTURE"
        STORAGE_CAPTURE=""
    fi
    if [ -n "$TARGET_TEMP" ]; then
        rm -f -- "$TARGET_TEMP"
    fi
    if [ "$INSTALL_LOCK_HELD" -eq 1 ]; then
        # Closing descriptor 9 is the only ownership transition. The shared
        # inode must remain for installer and upgrader contenders.
        exec 9>&-
        INSTALL_LOCK_HELD=0
    fi
    if [ "$STORAGE_PINNED" -eq 1 ]; then
        exec 6>&-
        exec 8>&-
        STORAGE_PINNED=0
    fi
    if [ "$PRESERVE_WORK_DIR" -eq 0 ]; then
        safe_remove_work_dir
    fi
    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_install_lock() {
    lock_parent="${INSTALL_LOCK%/*}"
    [ "$lock_parent" != "$INSTALL_LOCK" ] ||
        die "shared installer lock must have an explicit parent"
    if [ -e "$lock_parent" ] || [ -L "$lock_parent" ]; then
        [ -d "$lock_parent" ] && [ ! -L "$lock_parent" ] ||
            die "shared installer lock parent is not a real directory"
    else
        mkdir -p "$lock_parent" ||
            die "could not create the shared installer lock parent"
    fi
    if [ "$TESTING" != "1" ]; then
        chown 0:0 "$lock_parent" ||
            die "could not assign the runtime directory to root"
    fi
    chmod 0700 "$lock_parent" ||
        die "could not protect the shared installer lock parent"

    if [ -e "$INSTALL_LOCK" ] || [ -L "$INSTALL_LOCK" ]; then
        [ -f "$INSTALL_LOCK" ] && [ ! -L "$INSTALL_LOCK" ] ||
            die "shared installer lock inode is not a regular file"
    else
        : > "$INSTALL_LOCK" ||
            die "could not create the shared installer lock inode"
    fi
    if [ "$TESTING" != "1" ]; then
        chown 0:0 "$INSTALL_LOCK" ||
            die "could not assign the shared installer lock inode to root"
    fi
    chmod 0600 "$INSTALL_LOCK" ||
        die "could not protect the shared installer lock inode"

    if exec 9>>"$INSTALL_LOCK"; then
        :
    else
        die "could not open the shared installer lock descriptor"
    fi
    if "$FLOCK_CMD" -n 9 >/dev/null 2>&1; then
        INSTALL_LOCK_HELD=1
    else
        exec 9>&-
        die "another JamMonitor install or Tailscale upgrade is running"
    fi

    if [ -n "$TEST_HOLD_LOCK_FILE" ]; then
        [ "$TESTING" = "1" ] ||
            die "lock hold hook is available only to the test harness"
        printf '%s\n' "$$" > "$TEST_HOLD_LOCK_FILE.acquired" ||
            die "could not publish the test lock acquisition"
        while [ -e "$TEST_HOLD_LOCK_FILE" ] ||
              [ -L "$TEST_HOLD_LOCK_FILE" ]; do
            sleep 1 7>&- 9>&-
        done
    fi
}

create_maintenance_marker() {
    now_epoch="$(date +%s)" || die "could not read the current time"
    is_uint "$now_epoch" || die "current time is not a Unix epoch"
    quiesce_budget=$((QUIESCE_ATTEMPTS * (SERVICE_TIMEOUT + QUIESCE_DELAY)))
    postcheck_budget=$((STATUS_ATTEMPTS * (STATUS_TIMEOUT + STATUS_DELAY)))
    rollback_status_budget=$((5 * (STATUS_TIMEOUT + 1)))
    required_remaining=$(( \
        SERVICE_TIMEOUT + quiesce_budget + postcheck_budget + \
        SERVICE_TIMEOUT + quiesce_budget + SERVICE_TIMEOUT + \
        rollback_status_budget + 120 \
    ))
    [ "$required_remaining" -le 3600 ] ||
        die "calculated maintenance window exceeds the watchdog safety limit"

    if [ -e "$MAINTENANCE_FILE" ] || [ -L "$MAINTENANCE_FILE" ]; then
        [ -f "$MAINTENANCE_FILE" ] && [ ! -L "$MAINTENANCE_FILE" ] ||
            die "preexisting maintenance marker is not a regular file"
        existing_expiry="$(cat "$MAINTENANCE_FILE" 2>/dev/null || true)"
        is_uint "$existing_expiry" ||
            die "preexisting maintenance marker is malformed; verify no maintenance is active, then remove it"
        remaining=$((existing_expiry - now_epoch))
        [ "$remaining" -ge "$required_remaining" ] &&
            [ "$remaining" -le 3600 ] ||
            die "preexisting maintenance marker cannot cover the calculated upgrade and rollback window"
        MAINTENANCE_EXPECTED_EXPIRY="$existing_expiry"
        maintenance_marker_matches_expected ||
            die "preexisting maintenance marker is not an exact one-line lease"
        return 0
    fi

    expires_epoch=$((now_epoch + required_remaining))
    MAINTENANCE_TEMP="${MAINTENANCE_FILE}.tmp.$$.$now_epoch"
    [ ! -e "$MAINTENANCE_TEMP" ] && [ ! -L "$MAINTENANCE_TEMP" ] ||
        die "maintenance marker temporary path already exists"
    (
        set -C
        umask 077
        printf '%s\n' "$expires_epoch" > "$MAINTENANCE_TEMP"
    ) || die "could not create the maintenance marker temporary file"
    chmod 0600 "$MAINTENANCE_TEMP" ||
        die "could not protect the maintenance marker temporary file"
    [ "$("$STAT_CMD" -c '%u:%g:%a' "$MAINTENANCE_TEMP" 2>/dev/null)" = \
      "${EXPECTED_ROOT_UID}:${EXPECTED_ROOT_GID}:600" ] ||
        die "maintenance marker temporary file metadata is unsafe"
    [ "$(cat "$MAINTENANCE_TEMP" 2>/dev/null)" = "$expires_epoch" ] ||
        die "maintenance marker temporary file readback failed"
    mv -f -- "$MAINTENANCE_TEMP" "$MAINTENANCE_FILE" ||
        die "could not atomically publish the maintenance marker"
    MAINTENANCE_TEMP=""
    MAINTENANCE_CREATED=1
    MAINTENANCE_EXPECTED_EXPIRY="$expires_epoch"
    maintenance_marker_matches_expected ||
        die "created maintenance marker failed exact verification"
}

maintenance_marker_matches_expected() {
    [ -n "$MAINTENANCE_EXPECTED_EXPIRY" ] &&
        [ -f "$MAINTENANCE_FILE" ] &&
        [ ! -L "$MAINTENANCE_FILE" ] ||
        return 1
    [ "$("$STAT_CMD" -c '%u:%g:%a' "$MAINTENANCE_FILE" 2>/dev/null)" = \
      "${EXPECTED_ROOT_UID}:${EXPECTED_ROOT_GID}:600" ] ||
        return 1
    marker_size="$(wc -c < "$MAINTENANCE_FILE" 2>/dev/null |
        tr -d ' \r\n')" || return 1
    is_uint "$marker_size" || return 1
    expected_marker_size=$((${#MAINTENANCE_EXPECTED_EXPIRY} + 1))
    [ "$marker_size" -eq "$expected_marker_size" ] || return 1
    current_marker="$(cat "$MAINTENANCE_FILE" 2>/dev/null)" || return 1
    [ "$current_marker" = "$MAINTENANCE_EXPECTED_EXPIRY" ]
}

maintenance_lease_is_owned_and_live() {
    maintenance_marker_matches_expected || return 1
    lease_now="$(date +%s)" || return 1
    is_uint "$lease_now" || return 1
    [ "$MAINTENANCE_EXPECTED_EXPIRY" -gt "$lease_now" ]
}

remove_owned_maintenance_marker() {
    maintenance_marker_matches_expected || {
        warn "maintenance marker ownership changed; preserving it"
        return 1
    }
    rm -f -- "$MAINTENANCE_FILE"
}

prove_live_mutation_guard() {
    if [ ! -d "$PERSISTENT_MOUNT" ] ||
       [ -L "$PERSISTENT_MOUNT" ] ||
       ! persistent_mount_is_ext4_rw; then
        warn "persistent recovery mount changed immediately before binary replacement"
        return 1
    fi
    if ! durable_bundle_is_safe ready_for_binary_mutation; then
        warn "durable recovery bundle changed immediately before binary replacement"
        return 1
    fi
    if ! is_quiescent; then
        warn "Tailscale quiescence was lost before binary replacement"
        return 1
    fi
    if ! maintenance_lease_is_owned_and_live; then
        warn "maintenance lease ownership or validity was lost before binary replacement"
        return 1
    fi
}

run_test_binary_boundary_hook() {
    hook_phase="$1"
    [ "$TESTING" = "1" ] || return 0
    if [ "$TEST_SWAP_STORAGE_PHASE" = "mount-root-$hook_phase" ]; then
        mv -- "$PERSISTENT_MOUNT" "$PERSISTENT_MOUNT.replaced"
        mkdir "$PERSISTENT_MOUNT"
        chmod 0700 "$PERSISTENT_MOUNT"
    fi
    if [ "$TEST_SWAP_STORAGE_PHASE" = "source-$hook_phase" ]; then
        mv -- "$STORAGE_SOURCE_PATH" "$STORAGE_SOURCE_PATH.replaced"
        : > "$STORAGE_SOURCE_PATH"
    fi
    if [ "$TEST_INVALIDATE_MOUNT_PHASE" = "$hook_phase" ]; then
        printf 'otherdev /elsewhere ext4 rw,relatime 0 0\n' \
            > "$PROC_ROOT/mounts"
    fi
    if [ "$hook_phase" = "after-cli" ] &&
       [ "$TEST_TAMPER_DURABLE_AFTER_CLI" = "1" ]; then
        printf '%s\n' tampered > "$DURABLE_PENDING/manifest"
    fi
}

validate_safe_init() {
    active_init="$WORK_DIR/tailscale-init.active"
    awk -v testing="$TESTING" '
        function flush() {
            if (logical != "") {
                print logical
                logical = ""
            }
        }
        {
            line = $0
            sub(/\r$/, "", line)
            if (testing == "1" && line == "# TEST-HARNESS-BEGIN") {
                in_test_harness = 1
                next
            }
            if (testing == "1" && line == "# TEST-HARNESS-END") {
                in_test_harness = 0
                next
            }
            if (in_test_harness) {
                next
            }
            sub(/^[ \t]+/, "", line)
            if (line == "" || line ~ /^#/) {
                next
            }
            continuation = (line ~ /\\[ \t]*$/)
            sub(/\\[ \t]*$/, "", line)
            logical = logical " " line
            if (!continuation) {
                flush()
            }
        }
        END { flush() }
    ' "$INIT_SCRIPT" > "$active_init"

    if grep -Eq '(^|[^[:alnum:]_])(up|down|login|logout)([^[:alnum:]_]|$)' \
        "$active_init"; then
        die "unsafe Tailscale init contains a persistent control action"
    fi
    if grep -Eq '/usr/sbin/tailscale([^d[:alnum:]_]|$)' "$active_init"; then
        die "unsafe Tailscale init invokes the stateful tailscale CLI"
    fi
    if grep -Ei '(rm|unlink|truncate|tee|dd|mv|cp|install|sed[[:space:]]+-i).*(STATE_FILE|tailscaled\.state|/etc/tailscale)' \
        "$active_init" ||
       grep -Ei '(STATE_FILE|tailscaled\.state|/etc/tailscale).*(rm|unlink|truncate|tee|dd|mv|cp|install|sed[[:space:]]+-i)' \
        "$active_init" ||
       grep -Eq '(<|>|>>).*(STATE_FILE|tailscaled\.state)' "$active_init"; then
        die "unsafe Tailscale init can persistently mutate or delete node state"
    fi
    grep -Fq -- '--cleanup' "$active_init" ||
        die "Tailscale init does not contain the required cleanup action"
    grep -Eq 'procd_set_param[[:space:]]+command' "$active_init" ||
        die "Tailscale init does not delegate daemon ownership to procd"
    grep -Fq -- '--state=' "$active_init" ||
        die "Tailscale init does not configure the persistent state path"
    grep -Fq -- '--socket=' "$active_init" ||
        die "Tailscale init does not configure the LocalAPI socket"
    grep -Fq -- '--tun=' "$active_init" ||
        die "Tailscale init does not configure the tunnel device"
    grep -Eq 'stop_service[[:space:]]*\(\)' "$active_init" ||
        die "Tailscale init has no explicit cleanup-only stop handler"
}

fetch_file() {
    url="$1"
    output="$2"
    file_blocks="$3"

    if [ -n "$PACKAGE_SOURCE_DIR" ]; then
        (
            exec 7>&- 9>&-
            "$TIMEOUT_CMD" -s TERM -k 2 "$FETCH_TIMEOUT" \
                /bin/sh -c \
                'ulimit -f "$1" || exit 125; shift; exec "$@"' \
                jammonitor-fetch-limit "$file_blocks" cp -- \
                "$PACKAGE_SOURCE_DIR/$(basename -- "$url")" "$output"
        )
    elif command -v uclient-fetch >/dev/null 2>&1; then
        (
            exec 7>&- 9>&-
            "$TIMEOUT_CMD" -s TERM -k 2 "$FETCH_TIMEOUT" \
                /bin/sh -c \
                'ulimit -f "$1" || exit 125; shift; exec "$@"' \
                jammonitor-fetch-limit "$file_blocks" \
                uclient-fetch -q -O "$output" "$url"
        )
    elif command -v wget >/dev/null 2>&1; then
        (
            exec 7>&- 9>&-
            "$TIMEOUT_CMD" -s TERM -k 2 "$FETCH_TIMEOUT" \
                /bin/sh -c \
                'ulimit -f "$1" || exit 125; shift; exec "$@"' \
                jammonitor-fetch-limit "$file_blocks" \
                wget -q -T "$FETCH_TIMEOUT" -O "$output" "$url"
        )
    elif command -v curl >/dev/null 2>&1; then
        (
            exec 7>&- 9>&-
            "$TIMEOUT_CMD" -s TERM -k 2 "$FETCH_TIMEOUT" \
                /bin/sh -c \
                'ulimit -f "$1" || exit 125; shift; exec "$@"' \
                jammonitor-fetch-limit "$file_blocks" curl \
                --fail --silent --show-error --location \
                --connect-timeout 15 --max-time "$FETCH_TIMEOUT" \
                --proto '=https' --tlsv1.2 "$url" -o "$output"
        )
    else
        die "uclient-fetch, wget, or curl is required"
    fi
}

validate_archive_listing() {
    listing="$WORK_DIR/archive.list"
    verbose_listing="$WORK_DIR/archive.verbose"
    (
        ulimit -f "$ARCHIVE_LISTING_BLOCKS" || exit 125
        exec tar tzf "$WORK_DIR/$TARGET_ARCHIVE"
    ) > "$listing" ||
        die "could not inspect the Tailscale archive"
    (
        ulimit -f "$ARCHIVE_LISTING_BLOCKS" || exit 125
        exec tar tvzf "$WORK_DIR/$TARGET_ARCHIVE"
    ) > "$verbose_listing" ||
        die "could not inspect Tailscale archive metadata"

    archive_member_count=0
    while IFS= read -r member; do
        [ -n "$member" ] || continue
        archive_member_count=$((archive_member_count + 1))
        [ "$archive_member_count" -le "$ARCHIVE_MAX_MEMBERS" ] ||
            die "archive contains too many members"
        case "$member" in
            *[!A-Za-z0-9._/-]*)
                die "archive member contains unsupported characters"
                ;;
        esac
        case "$member" in
            "$TARGET_DIRECTORY"|"$TARGET_DIRECTORY"/*)
                ;;
            *)
                die "archive contains a path outside the expected directory"
                ;;
        esac
        case "$member" in
            /*|*"/../"*|../*|*/..)
                die "archive contains an unsafe path"
                ;;
        esac
    done < "$listing"

    grep -Fqx "$TARGET_DIRECTORY/tailscale" "$listing" ||
        die "archive is missing tailscale"
    grep -Fqx "$TARGET_DIRECTORY/tailscaled" "$listing" ||
        die "archive is missing tailscaled"

    archive_size_summary="$(
        awk -v max_total="$ARCHIVE_MAX_EXPANDED_BYTES" \
            -v max_members="$ARCHIVE_MAX_MEMBERS" '
            {
                members++
                if (members > max_members) exit 2
                type = substr($1, 1, 1)
                if (type != "-" && type != "d") exit 2
                if ($3 ~ /^[0-9]+$/) {
                    size = $3
                } else if ($5 ~ /^[0-9]+$/) {
                    size = $5
                } else {
                    exit 2
                }
                total += size
                if (total > max_total) exit 2
            }
            END {
                if (members < 3 || total > max_total) exit 1
                print members ":" total
            }
        ' "$verbose_listing"
    )" || die "archive metadata exceeds the bounded extraction contract"
    case "$archive_size_summary" in
        *[!0-9:]*|"") die "archive size summary is malformed" ;;
    esac
}

validate_new_binaries() {
    new_cli="$WORK_DIR/extract/$TARGET_DIRECTORY/tailscale"
    new_daemon="$WORK_DIR/extract/$TARGET_DIRECTORY/tailscaled"
    [ -f "$new_cli" ] && [ ! -L "$new_cli" ] ||
        die "extracted tailscale is not a regular file"
    [ -f "$new_daemon" ] && [ ! -L "$new_daemon" ] ||
        die "extracted tailscaled is not a regular file"
    chmod 0755 "$new_cli" "$new_daemon"

    if new_cli_version="$(
        "$TIMEOUT_CMD" -s TERM -k 2 10 "$new_cli" version 2>/dev/null |
        head -n 1 | tr -d '\r\n')"; then
        :
    else
        die "new tailscale binary could not execute"
    fi
    if new_daemon_version="$(
        "$TIMEOUT_CMD" -s TERM -k 2 10 "$new_daemon" --version 2>/dev/null |
        head -n 1 | tr -d '\r\n')"; then
        :
    else
        die "new tailscaled binary could not execute"
    fi
    [ "$new_cli_version" = "$TARGET_VERSION" ] ||
        die "new tailscale binary has an unexpected version"
    [ "$new_daemon_version" = "$TARGET_VERSION" ] ||
        die "new tailscaled binary has an unexpected version"
    NEW_CLI_SHA256="$(sha256_file "$new_cli")"
    NEW_DAEMON_SHA256="$(sha256_file "$new_daemon")"
    is_sha256 "$NEW_CLI_SHA256" && is_sha256 "$NEW_DAEMON_SHA256" ||
        die "could not calculate exact hashes for new binaries"
}

prepare_package() {
    archive="$WORK_DIR/$TARGET_ARCHIVE"
    checksum="$WORK_DIR/$TARGET_ARCHIVE.sha256"
    fetch_file "$OFFICIAL_BASE_URL/$TARGET_ARCHIVE" "$archive" \
        "$ARCHIVE_FILE_BLOCKS" ||
        die "could not download the pinned Tailscale archive"
    fetch_file "$OFFICIAL_BASE_URL/$TARGET_ARCHIVE.sha256" "$checksum" \
        "$CHECKSUM_FILE_BLOCKS" ||
        die "could not download the official checksum"
    archive_bytes="$(wc -c < "$archive" 2>/dev/null | tr -d ' ')" ||
        die "could not size the downloaded Tailscale archive"
    is_uint "$archive_bytes" &&
        [ "$archive_bytes" -gt 0 ] &&
        [ "$archive_bytes" -le "$ARCHIVE_MAX_BYTES" ] ||
        die "downloaded Tailscale archive is outside the exact size bound"
    checksum_bytes="$(wc -c < "$checksum" 2>/dev/null | tr -d ' ')" ||
        die "could not size the downloaded checksum"
    is_uint "$checksum_bytes" &&
        [ "$checksum_bytes" -ge 64 ] &&
        [ "$checksum_bytes" -le 256 ] ||
        die "downloaded checksum is outside the exact size bound"

    official_sha="$(tr -d '\r\n ' < "$checksum")"
    is_sha256 "$official_sha" ||
        die "official checksum file is malformed"
    official_sha="$(printf '%s' "$official_sha" | tr 'A-F' 'a-f')"
    expected_sha="$(printf '%s' "$EXPECTED_SHA256" | tr 'A-F' 'a-f')"
    [ "$official_sha" = "$expected_sha" ] ||
        die "official checksum does not match the repository pin"
    actual_sha="$(sha256_file "$archive")"
    [ "$actual_sha" = "$expected_sha" ] ||
        die "Tailscale archive checksum mismatch"

    validate_archive_listing
    mkdir -p "$WORK_DIR/extract"
    tar xzf "$archive" -C "$WORK_DIR/extract" ||
        die "could not extract the Tailscale archive"
    validate_new_binaries
}

case "$#" in
    0)
        ;;
    2)
        [ "$1" = "--recover-empty-needs-login-state-sha256" ] ||
            die "invalid recovery arguments"
        is_sha256 "$2" ||
            die "recovery state checksum is malformed"
        RECOVER_EMPTY_NEEDS_LOGIN=1
        RECOVERY_STATE_SHA256="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
        ;;
    *)
        die "invalid recovery arguments"
        ;;
esac
if [ "$TESTING" != "1" ]; then
    [ "$(id -u)" -eq 0 ] || die "Tailscale upgrade must run as root"
fi

machine_arch="${UNAME_OVERRIDE:-$(uname -m)}"
[ "$machine_arch" = "aarch64" ] ||
    die "this updater is pinned to aarch64 and refused $machine_arch"
is_sha256 "$EXPECTED_SHA256" ||
    die "pinned checksum is malformed"
is_uint "$STATUS_ATTEMPTS" && [ "$STATUS_ATTEMPTS" -gt 0 ] ||
    die "status attempts must be a positive integer"
is_uint "$STATUS_DELAY" ||
    die "status delay must be a nonnegative integer"
is_uint "$STATUS_TIMEOUT" && [ "$STATUS_TIMEOUT" -gt 0 ] ||
    die "status timeout must be a positive integer"
is_uint "$FETCH_TIMEOUT" && [ "$FETCH_TIMEOUT" -gt 0 ] ||
    die "fetch timeout must be a positive integer"
is_uint "$SYNC_TIMEOUT" && [ "$SYNC_TIMEOUT" -gt 0 ] ||
    die "sync timeout must be a positive integer"
is_uint "$PEER_COMMAND_TIMEOUT" && [ "$PEER_COMMAND_TIMEOUT" -gt 0 ] ||
    die "peer command timeout must be a positive integer"
is_uint "$SERVICE_TIMEOUT" && [ "$SERVICE_TIMEOUT" -gt 0 ] ||
    die "service timeout must be a positive integer"
is_uint "$QUIESCE_ATTEMPTS" && [ "$QUIESCE_ATTEMPTS" -gt 0 ] ||
    die "quiescence attempts must be a positive integer"
is_uint "$QUIESCE_DELAY" ||
    die "quiescence delay must be a nonnegative integer"
case "$TEST_INTERRUPT_AFTER_CLI:$TEST_INTERRUPT_AFTER_FENCE:$TEST_INTERRUPT_AFTER_DAEMON:$TEST_INTERRUPT_AFTER_LIVE_SYNC:$TEST_INTERRUPT_AFTER_COMMIT_FENCE:$TEST_INTERRUPT_AFTER_USB_CLEAR:$TEST_RESTART_DAEMON_AFTER_CLI:$TEST_TAMPER_DURABLE_AFTER_CLI" in
    [01]:[01]:[01]:[01]:[01]:[01]:[01]:[01])
        ;;
    *)
        die "test-only selector is invalid"
        ;;
esac
case "$TEST_INVALIDATE_MOUNT_PHASE" in
    none|before-cli|after-cli)
        ;;
    *)
        die "test-only mount selector is invalid"
        ;;
esac
case "$TEST_SWAP_STORAGE_PHASE" in
    none|mount-root-before-cli|source-before-cli)
        ;;
    *)
        die "test-only storage-swap selector is invalid"
        ;;
esac

require_command "$TIMEOUT_CMD"
require_command "$JSONFILTER_CMD"
require_command "$SYNC_CMD"
require_command "$FLOCK_CMD"
require_command "$UCI_CMD"
require_command "$BLOCK_CMD"
require_command awk
require_command cmp
require_command dd
require_command grep
require_command tar
require_command mktemp
require_command readlink
require_command sed
require_command wc
require_command "$STAT_CMD"
require_command tr

umask 077
acquire_install_lock
preflight_locked_installer_recovery_evidence
[ ! -e "$RECOVERY_EVIDENCE" ] && [ ! -L "$RECOVERY_EVIDENCE" ] ||
    die "an unresolved prior rollback failure requires operator recovery"
[ ! -e "$UPGRADE_FENCE" ] && [ ! -L "$UPGRADE_FENCE" ] ||
    die "an unresolved prior Tailscale upgrade boot fence requires operator recovery"
prepare_durable_root
WORK_DIR="$(mktemp -d "$TMP_BASE/tailscale-upgrade.XXXXXX")"

[ -f "$TAILSCALE_BIN" ] && [ ! -L "$TAILSCALE_BIN" ] &&
[ -x "$TAILSCALE_BIN" ] || die "current tailscale binary is missing or unsafe"
[ -f "$TAILSCALED_BIN" ] && [ ! -L "$TAILSCALED_BIN" ] &&
[ -x "$TAILSCALED_BIN" ] || die "current tailscaled binary is missing or unsafe"
[ -x "$INIT_SCRIPT" ] || die "Tailscale init script is missing"
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
[ -s "$STATE_FILE" ] || die "Tailscale state file is missing, empty, or unsafe"

validate_safe_init

inspect_service_running_state
case "$SERVICE_RUNNING_STATE" in
    running)
        ;;
    inactive)
        die "Tailscale service is not running"
        ;;
    *)
        die "Tailscale service running preflight did not return exact success"
        ;;
esac

pre_status="$WORK_DIR/pre-status.json"
query_status "$pre_status" ||
    die "could not read the pre-upgrade Tailscale BackendState"
PRE_BACKEND_STATE="$OBSERVED_BACKEND"
PRE_DAEMON_VERSION="$OBSERVED_VERSION"
PRE_STABLE_ID="$OBSERVED_STABLE_ID"
case "$PRE_BACKEND_STATE" in
    Running|NeedsLogin)
        ;;
    *)
        die "pre-upgrade BackendState is not eligible for automatic upgrade"
        ;;
esac
status_has_required_semantics "$PRE_BACKEND_STATE" ||
    die "pre-upgrade Tailscale state lacks StableID or required delivery semantics"
if [ "$PRE_BACKEND_STATE" = "Running" ]; then
    load_required_critical_peer "$pre_status" ||
        die "Running upgrade requires one exact non-self critical-peer Tailscale IP"
fi
if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
    [ "$PRE_BACKEND_STATE" = "NeedsLogin" ] &&
        [ -z "$PRE_STABLE_ID" ] ||
        die "empty-identity recovery requires NeedsLogin with no StableID"
    [ -n "$OBSERVED_AUTH_URL" ] ||
        die "empty-identity recovery requires a pending authentication URL"
    recovery_state_matches_authorized_hash ||
        die "current Tailscale state does not match the operator-authorized checksum"
elif [ -z "$PRE_STABLE_ID" ]; then
    die "pre-upgrade Tailscale state lacks StableID or required delivery semantics"
fi
[ -n "$PRE_DAEMON_VERSION" ] ||
    die "pre-upgrade daemon version is missing"
PRE_CLI_SHA256="$(sha256_file "$TAILSCALE_BIN")"
PRE_DAEMON_SHA256="$(sha256_file "$TAILSCALED_BIN")"
is_sha256 "$PRE_CLI_SHA256" &&
    is_sha256 "$PRE_DAEMON_SHA256" ||
    die "could not hash the pre-upgrade binaries"

if current_cli_version="$(
    "$TIMEOUT_CMD" -s TERM -k 2 10 "$TAILSCALE_BIN" version 2>/dev/null |
    head -n 1 | tr -d '\r\n')"; then
    :
else
    die "current tailscale version could not be read"
fi
current_cli_version_base="${current_cli_version%%-*}"
if cli_version_order="$(
    compare_versions "$current_cli_version_base" "$TARGET_VERSION"
)"; then
    :
else
    die "current tailscale version is not a supported semantic version"
fi

if installed_daemon_version="$(
    "$TIMEOUT_CMD" -s TERM -k 2 10 "$TAILSCALED_BIN" --version 2>/dev/null |
        head -n 1 | tr -d '\r\n'
)"; then
    :
else
    die "installed tailscaled version could not be read"
fi
installed_daemon_version_base="${installed_daemon_version%%-*}"
if installed_daemon_version_order="$(
    compare_versions "$installed_daemon_version_base" "$TARGET_VERSION"
)"; then
    :
else
    die "installed tailscaled version is not a supported semantic version"
fi

running_daemon_version_base="${PRE_DAEMON_VERSION%%-*}"
if running_daemon_version_order="$(
    compare_versions "$running_daemon_version_base" "$TARGET_VERSION"
)"; then
    :
else
    die "running tailscaled version is not a supported semantic version"
fi

if [ "$cli_version_order" -gt 0 ]; then
    die "refusing to downgrade a newer Tailscale CLI"
fi
if [ "$installed_daemon_version_order" -gt 0 ]; then
    die "refusing to downgrade a newer installed tailscaled binary"
fi
if [ "$running_daemon_version_order" -gt 0 ]; then
    die "refusing to downgrade a newer running tailscaled daemon"
fi
case "$OBSERVED_VERSION" in
    "$TARGET_VERSION"|"$TARGET_VERSION"-*)
        daemon_is_target=1
        ;;
    *)
        daemon_is_target=0
        ;;
esac

# The archive pin, archive contents, and exact binary hashes are authenticated
# before an idempotent result is allowed. Version strings alone are not proof
# that the installed executables are the repository-pinned release.
prepare_package

if [ "$cli_version_order" -eq 0 ] && [ "$daemon_is_target" -eq 1 ] &&
   [ "$PRE_CLI_SHA256" = "$NEW_CLI_SHA256" ] &&
   [ "$PRE_DAEMON_SHA256" = "$NEW_DAEMON_SHA256" ]; then
    printf 'Tailscale %s is already installed; BackendState is %s.\n' \
        "$TARGET_VERSION" "$PRE_BACKEND_STATE"
    exit 0
fi

create_maintenance_marker

TRANSACTION_ACTIVE=1
prepare_durable_write_ahead_bundle
STOP_REQUESTED=1
service_command stop ||
    die "Tailscale service did not stop within the bounded timeout"
wait_for_quiescence ||
    die "Tailscale daemon or LocalAPI socket remained live after stop"

# State is copied only after the daemon and socket are independently proven
# quiescent, so the backup is a stable point-in-time recovery artifact.
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] && [ -s "$STATE_FILE" ] ||
    die "Tailscale state became missing, empty, or unsafe during shutdown"
PRE_STATE_SHA256="$(sha256_file "$STATE_FILE")"
is_sha256 "$PRE_STATE_SHA256" ||
    die "could not hash the quiescent pre-upgrade Tailscale state"
if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
    [ "$PRE_STATE_SHA256" = "$RECOVERY_STATE_SHA256" ] ||
        die "quiescent Tailscale state does not match the operator-authorized checksum"
fi
finalize_durable_quiescent_backup

publish_upgrade_fence
if [ "$TEST_INTERRUPT_AFTER_FENCE" = "1" ]; then
    kill -KILL "$$"
    die "test fence interruption did not terminate the upgrader"
fi
MUTATION_STARTED=1
run_test_binary_boundary_hook before-cli
if ! atomic_install "$WORK_DIR/extract/$TARGET_DIRECTORY/tailscale" \
    "$TAILSCALE_BIN" 0755 live-binary; then
    if [ "$ATOMIC_INSTALL_GUARD_FAILED" -eq 1 ]; then
        die "lost maintenance ownership or quiescence before installing tailscale"
    fi
    die "could not atomically install tailscale"
fi
if [ "$TEST_INTERRUPT_AFTER_CLI" = "1" ]; then
    kill -KILL "$$"
    die "test interruption did not terminate the upgrader"
fi
if [ "$TEST_RESTART_DAEMON_AFTER_CLI" = "1" ]; then
    service_command start ||
        die "test daemon restart hook could not start Tailscale"
fi
run_test_binary_boundary_hook after-cli
if ! atomic_install "$WORK_DIR/extract/$TARGET_DIRECTORY/tailscaled" \
    "$TAILSCALED_BIN" 0755 live-binary; then
    if [ "$ATOMIC_INSTALL_GUARD_FAILED" -eq 1 ]; then
        die "lost maintenance ownership or quiescence before installing tailscaled"
    fi
    die "could not atomically install tailscaled"
fi
if [ "$TEST_INTERRUPT_AFTER_DAEMON" = "1" ]; then
    kill -KILL "$$"
    die "test daemon interruption did not terminate the upgrader"
fi
[ "$(sha256_file "$TAILSCALE_BIN")" = "$NEW_CLI_SHA256" ] &&
    [ "$(sha256_file "$TAILSCALED_BIN")" = "$NEW_DAEMON_SHA256" ] ||
    die "installed Tailscale binary hashes differ from the verified package"

service_command start ||
    die "Tailscale service did not start within the bounded timeout"
wait_for_expected_state "$PRE_BACKEND_STATE" ||
    die "post-upgrade BackendState or daemon version verification failed"
if [ "$PRE_BACKEND_STATE" = "Running" ] &&
   ! critical_peer_is_reachable; then
    die "post-upgrade critical Tailscale peer verification failed"
fi

state_file_is_safe ||
    die "Tailscale state file disappeared during upgrade"
if [ "$RECOVER_EMPTY_NEEDS_LOGIN" -eq 1 ]; then
    [ "$OBSERVED_BACKEND" = "NeedsLogin" ] &&
        [ -z "$OBSERVED_STABLE_ID" ] &&
        [ -n "$OBSERVED_AUTH_URL" ] &&
        recovery_state_matches_authorized_hash ||
        die "empty-identity recovery invariants changed during upgrade"
elif [ "$PRE_BACKEND_STATE" = "Running" ]; then
    [ -n "$OBSERVED_STABLE_ID" ] ||
        die "post-upgrade StableID is missing"
    [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ] ||
        die "Tailscale stable node identity changed during upgrade"
fi

sync_durable_storage ||
    die "could not durably flush the verified live Tailscale target"
[ -d "$PERSISTENT_MOUNT" ] && [ ! -L "$PERSISTENT_MOUNT" ] &&
    persistent_mount_is_ext4_rw &&
    durable_bundle_is_safe ready_for_binary_mutation ||
    die "durable recovery evidence changed before live commit"
if [ "$TEST_INTERRUPT_AFTER_LIVE_SYNC" = "1" ]; then
    kill -KILL "$$"
    die "test live-sync interruption did not terminate the upgrader"
fi

clear_upgrade_fence ||
    die "upgrade committed but the durable boot fence could not be cleared"
TRANSACTION_COMMITTED=1
if [ "$TEST_INTERRUPT_AFTER_COMMIT_FENCE" = "1" ]; then
    kill -KILL "$$"
    die "test fence-clear interruption did not terminate the upgrader"
fi
clear_owned_durable_bundle ||
    die "upgrade committed but durable recovery evidence could not be cleared"
if [ "$TEST_INTERRUPT_AFTER_USB_CLEAR" = "1" ]; then
    kill -KILL "$$"
    die "test USB-cleanup interruption did not terminate the upgrader"
fi
if [ "$PRE_BACKEND_STATE" = "Running" ]; then
    printf 'Tailscale %s installed; strict delivery checks remained Running.\n' \
        "$TARGET_VERSION"
else
    printf 'Tailscale %s installed; BackendState remains NeedsLogin and operator authentication is still required.\n' \
        "$TARGET_VERSION"
fi
