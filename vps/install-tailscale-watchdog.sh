#!/bin/sh
#
# Transactional local installer for the Debian VPS Tailscale watchdog.
#
# The source manifest digest is mandatory and must be supplied from a separate
# trusted review record. This installer performs no network fetch and never
# changes tailscaled.service, Tailscale authentication, or Tailscale node
# state.

set -eu
umask 077

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR"
MANIFEST_SHA256=""
MODE="install"
START_REQUESTED=0

usage() {
    cat >&2 <<'EOF'
Usage:
  install-tailscale-watchdog.sh --source-dir DIR \
    --manifest-sha256 64_HEX [--start]
  install-tailscale-watchdog.sh --validate-source DIR \
    --manifest-sha256 64_HEX

--start starts the timer after a successful new installation or upgrade.
Without --start, a new timer is enabled but left stopped. An upgrade preserves
the prior enabled and active states.
EOF
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --source-dir)
            [ "$#" -ge 2 ] || usage
            SOURCE_DIR="$2"
            MODE="install"
            shift 2
            ;;
        --validate-source)
            [ "$#" -ge 2 ] || usage
            SOURCE_DIR="$2"
            MODE="validate"
            shift 2
            ;;
        --manifest-sha256)
            [ "$#" -ge 2 ] || usage
            MANIFEST_SHA256="$2"
            shift 2
            ;;
        --start)
            START_REQUESTED=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

[ -n "$MANIFEST_SHA256" ] || usage
case "$MANIFEST_SHA256" in
    *[!0-9A-Fa-f]*|"") usage ;;
esac
[ "${#MANIFEST_SHA256}" -eq 64 ] || usage

SOURCE_DIR="$(CDPATH= cd -- "$SOURCE_DIR" && pwd)"
MANIFEST="${SOURCE_DIR}/vps-files.sha256"

if command -v sha256sum >/dev/null 2>&1; then
    SHA256_TOOL="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
    SHA256_TOOL="shasum"
else
    echo "sha256sum or shasum is required" >&2
    exit 1
fi

hash_file() {
    if [ "$SHA256_TOOL" = "sha256sum" ]; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

manifest_hash_for() {
    _manifest_name="$1"
    awk -v wanted="$_manifest_name" '
        $2 == wanted && NF == 2 {
            print $1
            found++
        }
        END {
            if (found != 1) {
                exit 1
            }
        }
    ' "$MANIFEST"
}

validate_manifest_shape() {
    _seen_installer=0
    _seen_watchdog=0
    _seen_service=0
    _seen_timer=0
    _seen_readme=0
    _count=0

    while IFS= read -r _line || [ -n "$_line" ]; do
        _hash="${_line%% *}"
        _name="${_line#*  }"
        [ "$_line" = "${_hash}  ${_name}" ] || return 1
        case "$_hash" in
            *[!0-9A-Fa-f]*|"") return 1 ;;
        esac
        [ "${#_hash}" -eq 64 ] || return 1

        case "$_name" in
            install-tailscale-watchdog.sh)
                [ "$_seen_installer" -eq 0 ] || return 1
                _seen_installer=1
                ;;
            jammonitor-tailscale-watchdog)
                [ "$_seen_watchdog" -eq 0 ] || return 1
                _seen_watchdog=1
                ;;
            jammonitor-tailscale-watchdog.service)
                [ "$_seen_service" -eq 0 ] || return 1
                _seen_service=1
                ;;
            jammonitor-tailscale-watchdog.timer)
                [ "$_seen_timer" -eq 0 ] || return 1
                _seen_timer=1
                ;;
            README.md)
                [ "$_seen_readme" -eq 0 ] || return 1
                _seen_readme=1
                ;;
            *)
                return 1
                ;;
        esac
        _count=$((_count + 1))
    done <"$MANIFEST"

    [ "$_count" -eq 5 ] &&
        [ "$_seen_installer" -eq 1 ] &&
        [ "$_seen_watchdog" -eq 1 ] &&
        [ "$_seen_service" -eq 1 ] &&
        [ "$_seen_timer" -eq 1 ] &&
        [ "$_seen_readme" -eq 1 ]
}

validate_source() {
    [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
        echo "manifest is missing or is a symlink" >&2
        return 1
    }

    _expected_manifest_sha256="$(printf '%s' "$MANIFEST_SHA256" |
        tr 'A-F' 'a-f')"
    _actual_manifest_sha256="$(hash_file "$MANIFEST")"
    [ "$_expected_manifest_sha256" = "$_actual_manifest_sha256" ] || {
        echo "manifest digest mismatch" >&2
        return 1
    }

    validate_manifest_shape || {
        echo "manifest does not match the fixed VPS payload allowlist" >&2
        return 1
    }

    for _payload in \
        install-tailscale-watchdog.sh \
        jammonitor-tailscale-watchdog \
        jammonitor-tailscale-watchdog.service \
        jammonitor-tailscale-watchdog.timer \
        README.md
    do
        [ -f "${SOURCE_DIR}/${_payload}" ] &&
            [ ! -L "${SOURCE_DIR}/${_payload}" ] || {
            echo "payload is missing, not regular, or is a symlink: ${_payload}" >&2
            return 1
        }
        _payload_expected="$(manifest_hash_for "$_payload")" || return 1
        _payload_actual="$(hash_file "${SOURCE_DIR}/${_payload}")"
        [ "$_payload_expected" = "$_payload_actual" ] || {
            echo "payload digest mismatch: ${_payload}" >&2
            return 1
        }
    done

    sh -n "${SOURCE_DIR}/jammonitor-tailscale-watchdog"
    dash -n "${SOURCE_DIR}/jammonitor-tailscale-watchdog"
}

validate_source

if [ "$MODE" = "validate" ]; then
    echo "VPS watchdog source validation passed"
    exit 0
fi

# Absolute-path and ownership overrides exist only for the unprivileged,
# fake-root transaction tests. Production invocation rejects every override.
TESTING="${JM_VPS_INSTALLER_TESTING:-0}"
case "$TESTING" in
    0|1) ;;
    *)
        echo "invalid installer testing mode" >&2
        exit 1
        ;;
esac

if [ "$TESTING" -ne 1 ]; then
    if [ -n "${JM_VPS_INSTALLER_ROOT:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_SYSTEMCTL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_SYSTEMD_ANALYZE:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_STAT:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_SLEEP:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_TIMEOUT:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FLOCK:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_SYNC:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_EXPECTED_UID:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_EXPECTED_GID:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_BACKUP_LABEL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_RESTORE_LABEL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_POST_VERIFY:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_SYNC_LABEL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_KILL_AT_LABEL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_HOLD_AFTER_LOCK_FILE:-}" ]; then
        echo "installer test overrides are refused outside test mode" >&2
        exit 1
    fi
fi

if [ "$TESTING" -eq 1 ]; then
    ROOT_PREFIX="${JM_VPS_INSTALLER_ROOT:-}"
    [ -n "$ROOT_PREFIX" ] || {
        echo "test root is required in installer testing mode" >&2
        exit 1
    }
    ROOT_PREFIX="$(CDPATH= cd -- "$ROOT_PREFIX" && pwd)"
    [ "$ROOT_PREFIX" != "/" ] || {
        echo "test root must not be the host root" >&2
        exit 1
    }
    SYSTEMCTL_CMD="${JM_VPS_INSTALLER_SYSTEMCTL:-/usr/bin/systemctl}"
    SYSTEMD_ANALYZE_CMD="${JM_VPS_INSTALLER_SYSTEMD_ANALYZE:-/usr/bin/systemd-analyze}"
    STAT_CMD="${JM_VPS_INSTALLER_STAT:-stat}"
    SLEEP_CMD="${JM_VPS_INSTALLER_SLEEP:-/usr/bin/sleep}"
    TIMEOUT_CMD="${JM_VPS_INSTALLER_TIMEOUT:-/usr/bin/timeout}"
    FLOCK_CMD="${JM_VPS_INSTALLER_FLOCK:-/usr/bin/flock}"
    SYNC_CMD="${JM_VPS_INSTALLER_SYNC:-/bin/sync}"
    EXPECTED_UID="${JM_VPS_INSTALLER_EXPECTED_UID:-$(id -u)}"
    EXPECTED_GID="${JM_VPS_INSTALLER_EXPECTED_GID:-$(id -g)}"
else
    [ "$(id -u)" -eq 0 ] || {
        echo "installation requires root" >&2
        exit 1
    }
    ROOT_PREFIX=""
    SYSTEMCTL_CMD="/usr/bin/systemctl"
    SYSTEMD_ANALYZE_CMD="/usr/bin/systemd-analyze"
    STAT_CMD="/usr/bin/stat"
    SLEEP_CMD="/usr/bin/sleep"
    TIMEOUT_CMD="/usr/bin/timeout"
    FLOCK_CMD="/usr/bin/flock"
    SYNC_CMD="/bin/sync"
    EXPECTED_UID=0
    EXPECTED_GID=0
fi

case "$EXPECTED_UID" in ""|*[!0-9]*) exit 1 ;; esac
case "$EXPECTED_GID" in ""|*[!0-9]*) exit 1 ;; esac

rooted() {
    printf '%s%s' "$ROOT_PREFIX" "$1"
}

stat_triplet() {
    "$STAT_CMD" -c '%u|%g|%a' "$1"
}

mode_is_group_world_readonly() {
    _mode_value="$1"
    case "$_mode_value" in
        ""|*[!0-7]*) return 1 ;;
    esac
    _mode_without_world="${_mode_value%?}"
    _world_mode="${_mode_value#"$_mode_without_world"}"
    _mode_without_group="${_mode_without_world%?}"
    _group_mode="${_mode_without_world#"$_mode_without_group"}"
    case "${_group_mode}${_world_mode}" in
        *[2367]*) return 1 ;;
        *) return 0 ;;
    esac
}

verify_owner_and_readonly() {
    _trusted_path="$1"
    _trusted_description="$2"
    _trusted_stat="$(stat_triplet "$_trusted_path")" || {
        echo "cannot inspect ${_trusted_description}" >&2
        return 1
    }
    _trusted_uid="${_trusted_stat%%|*}"
    _trusted_remainder="${_trusted_stat#*|}"
    _trusted_gid="${_trusted_remainder%%|*}"
    _trusted_mode="${_trusted_remainder#*|}"
    [ "$_trusted_uid" = "$EXPECTED_UID" ] &&
        [ "$_trusted_gid" = "$EXPECTED_GID" ] || {
        echo "${_trusted_description} must be root-owned" >&2
        return 1
    }
    mode_is_group_world_readonly "$_trusted_mode" || {
        echo "${_trusted_description} must not be group/world writable" >&2
        return 1
    }
}

verify_trusted_source() {
    verify_owner_and_readonly "$SOURCE_DIR" "installation source directory"
    verify_owner_and_readonly "$MANIFEST" "installation source manifest"
    for _trusted_payload in \
        install-tailscale-watchdog.sh \
        jammonitor-tailscale-watchdog \
        jammonitor-tailscale-watchdog.service \
        jammonitor-tailscale-watchdog.timer \
        README.md
    do
        verify_owner_and_readonly "${SOURCE_DIR}/${_trusted_payload}" \
            "installation source payload ${_trusted_payload}"
    done
}

ensure_install_directory() {
    _directory_path="$1"
    _directory_mode="$2"
    _directory_description="$3"
    if [ -L "$_directory_path" ]; then
        echo "${_directory_description} must not be a symlink" >&2
        return 1
    fi
    if [ -e "$_directory_path" ]; then
        [ -d "$_directory_path" ] || {
            echo "${_directory_description} is not a directory" >&2
            return 1
        }
        verify_owner_and_readonly "$_directory_path" \
            "$_directory_description"
    else
        install -d -m "$_directory_mode" -o "$EXPECTED_UID" \
            -g "$EXPECTED_GID" "$_directory_path"
    fi
}

for _tool in \
    awk chmod chown cp dash id install kill mkdir mktemp mv rm rmdir sed sh tr wc
do
    command -v "$_tool" >/dev/null 2>&1 || {
        echo "required installer command is missing: ${_tool}" >&2
        exit 1
    }
done
[ -x "$SYSTEMCTL_CMD" ] || {
    echo "required installer command is not executable: ${SYSTEMCTL_CMD}" >&2
    exit 1
}
[ -x "$SYSTEMD_ANALYZE_CMD" ] || {
    echo "required installer command is not executable: ${SYSTEMD_ANALYZE_CMD}" >&2
    exit 1
}
[ -x "$STAT_CMD" ] || command -v "$STAT_CMD" >/dev/null 2>&1 || {
    echo "required installer command is not executable: ${STAT_CMD}" >&2
    exit 1
}
[ -x "$SLEEP_CMD" ] || {
    echo "required installer command is not executable: ${SLEEP_CMD}" >&2
    exit 1
}
[ -x "$TIMEOUT_CMD" ] || {
    echo "required installer command is not executable: ${TIMEOUT_CMD}" >&2
    exit 1
}
[ -x "$FLOCK_CMD" ] || {
    echo "required installer command is not executable: ${FLOCK_CMD}" >&2
    exit 1
}
[ -x "$SYNC_CMD" ] || {
    echo "required installer command is not executable: ${SYNC_CMD}" >&2
    exit 1
}

verify_trusted_source

# These paths are embedded in the installed service and watchdog. Check each
# one before creating a lock, recovery directory, or installation target.
for _runtime_path in \
    /usr/bin/tailscale \
    /usr/bin/timeout \
    /usr/bin/jq \
    /usr/bin/logger \
    /usr/bin/flock \
    /usr/bin/mv \
    /usr/bin/dd \
    /usr/bin/systemctl
do
    _rooted_runtime="$(rooted "$_runtime_path")"
    [ -f "$_rooted_runtime" ] &&
        [ ! -L "$_rooted_runtime" ] &&
        [ -x "$_rooted_runtime" ] || {
        echo "required watchdog runtime is missing or not executable: ${_runtime_path}" >&2
        exit 1
    }
done

SYSTEMCTL_TIMEOUT_SECONDS=8
SYSTEMD_ANALYZE_TIMEOUT_SECONDS=8

run_systemctl() {
    "$TIMEOUT_CMD" -s TERM -k 2 "$SYSTEMCTL_TIMEOUT_SECONDS" \
        "$SYSTEMCTL_CMD" "$@"
}

TAILSCALED_LOAD_STATE="$(run_systemctl show tailscaled.service \
    --property=LoadState --value 2>/dev/null)" || {
    echo "required tailscaled.service is not present" >&2
    exit 1
}
case "$TAILSCALED_LOAD_STATE" in
    loaded|masked) ;;
    *)
        echo "required tailscaled.service is not present" >&2
        exit 1
        ;;
esac

SYSTEMD_UNIT_DIR="$(rooted /etc/systemd/system)"
WATCHDOG_TARGET="$(rooted /usr/local/libexec/jammonitor-tailscale-watchdog)"
SERVICE_TARGET="${SYSTEMD_UNIT_DIR}/jammonitor-tailscale-watchdog.service"
TIMER_TARGET="${SYSTEMD_UNIT_DIR}/jammonitor-tailscale-watchdog.timer"
README_TARGET="$(rooted /usr/share/doc/jammonitor-tailscale-watchdog/README.md)"
TIMER_UNIT="jammonitor-tailscale-watchdog.timer"
SERVICE_UNIT="jammonitor-tailscale-watchdog.service"
RECOVERY_BASE="$(rooted /var/lib/jammonitor-tailscale-watchdog)"
LOCK_FILE="${RECOVERY_BASE}/install.lock"
ROLLBACK_EVIDENCE="${RECOVERY_BASE}/INSTALL-ROLLBACK-INCOMPLETE"

for _target in \
    "$WATCHDOG_TARGET" "$SERVICE_TARGET" "$TIMER_TARGET" "$README_TARGET"
do
    [ ! -L "$_target" ] || {
        echo "refusing to replace symlink target: ${_target}" >&2
        exit 1
    }
    if [ -e "$_target" ] && [ ! -f "$_target" ]; then
        echo "refusing to replace non-regular target: ${_target}" >&2
        exit 1
    fi
done

LOCK_ACQUIRED=0
TRANSACTION_ACTIVE=0
BACKUP_READY=0
MUTATION_STARTED=0
CURRENT_TEMP=""
BACKUP_DIR=""
TIMER_WAS_ENABLED=0
TIMER_WAS_ACTIVE=0

release_lock() {
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        "$FLOCK_CMD" -u 9 >/dev/null 2>&1 || true
        exec 9>&-
        LOCK_ACQUIRED=0
    fi
}

acquire_lock() {
    [ ! -L "$LOCK_FILE" ] || {
        echo "installer lock must not be a symlink: ${LOCK_FILE}" >&2
        return 1
    }
    if [ -e "$LOCK_FILE" ]; then
        [ -f "$LOCK_FILE" ] || {
            echo "installer lock is not a regular file: ${LOCK_FILE}" >&2
            return 1
        }
        verify_owner_and_readonly "$LOCK_FILE" "installer lock file" ||
            return 1
    fi

    # Keep this inode permanently. The open descriptor, not a PID file or
    # removable path, owns the kernel lock and closes automatically on crash.
    exec 9>"$LOCK_FILE"
    chmod 0600 "$LOCK_FILE"
    chown "$EXPECTED_UID:$EXPECTED_GID" "$LOCK_FILE"
    if ! "$FLOCK_CMD" -n 9; then
        exec 9>&-
        echo "another VPS watchdog installation holds ${LOCK_FILE}" >&2
        return 1
    fi
    LOCK_ACQUIRED=1
}

fault_point() {
    _fault_label="$1"
    if [ "${JM_VPS_INSTALLER_KILL_AT_LABEL:-}" = "$_fault_label" ]; then
        kill -KILL "$$"
    fi
}

sync_barrier() {
    _sync_label="$1"
    _sync_path="$2"
    if [ "${JM_VPS_INSTALLER_FAIL_SYNC_LABEL:-}" = "$_sync_label" ]; then
        echo "injected durability sync failure at ${_sync_label}" >&2
        return 1
    fi
    "$SYNC_CMD" -f "$_sync_path" || {
        echo "durability sync failed at ${_sync_label}" >&2
        return 1
    }
    fault_point "${_sync_label}-durable"
}

remove_transaction_dir() {
    _remove_dir="$1"
    case "$_remove_dir" in
        "$RECOVERY_BASE"/transaction.*)
            rm -rf "$_remove_dir"
            ;;
        *)
            echo "refusing unsafe recovery-directory removal: ${_remove_dir}" >&2
            return 1
            ;;
    esac
}

write_incomplete_evidence() {
    _evidence_temp="$(mktemp "${RECOVERY_BASE}/.rollback-evidence.XXXXXX")" ||
        return 1
    chmod 0600 "$_evidence_temp" || {
        rm -f "$_evidence_temp"
        return 1
    }
    chown "$EXPECTED_UID:$EXPECTED_GID" "$_evidence_temp" || {
        rm -f "$_evidence_temp"
        return 1
    }
    {
        printf '%s\n' 'ROLLBACK INCOMPLETE'
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
            printf 'recovery_bundle=%s\n' "$BACKUP_DIR"
            printf '%s\n' 'Do not rerun the installer until an operator verifies and clears this evidence.'
        else
            printf '%s\n' 'recovery_bundle=unavailable'
            printf '%s\n' 'Recovery evidence cleanup could not be made durable; inspect the verified live state before clearing this blocker.'
        fi
    } >"$_evidence_temp" || {
        rm -f "$_evidence_temp"
        return 1
    }
    mv -f "$_evidence_temp" "$ROLLBACK_EVIDENCE" || {
        rm -f "$_evidence_temp"
        return 1
    }
    sync_barrier rollback-incomplete-evidence "$RECOVERY_BASE"
}

unit_enabled() {
    run_systemctl is-enabled --quiet "$1" >/dev/null 2>&1
    _unit_query_status=$?
    case "$_unit_query_status" in
        0) return 0 ;;
        1) return 1 ;;
        *)
            echo "systemctl is-enabled failed for $1 (status ${_unit_query_status})" >&2
            return 2
            ;;
    esac
}

timer_unit_file_state() {
    _unit_file_state="$(run_systemctl show "$TIMER_UNIT" \
        --property=UnitFileState --value 2>/dev/null)" || {
        echo "cannot prove watchdog timer unit-file state" >&2
        return 2
    }
    case "$_unit_file_state" in
        enabled|disabled)
            printf '%s' "$_unit_file_state"
            ;;
        *)
            echo "unsupported watchdog timer unit-file state: ${_unit_file_state:-empty}" >&2
            return 2
            ;;
    esac
}

unit_active() {
    run_systemctl is-active --quiet "$1" >/dev/null 2>&1
    _unit_query_status=$?
    case "$_unit_query_status" in
        0) return 0 ;;
        1|3|4) return 1 ;;
        *)
            echo "systemctl is-active failed for $1 (status ${_unit_query_status})" >&2
            return 2
            ;;
    esac
}

quiesce_watchdog_units() {
    _service_existed="$1"
    _timer_existed="$2"
    _attempt=0

    run_systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true
    run_systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true

    while [ "$_attempt" -lt 10 ]; do
        if ! _timer_state="$(run_systemctl show "$TIMER_UNIT" \
            --property=ActiveState --value 2>/dev/null)"; then
            echo "cannot prove watchdog timer quiescence" >&2
            return 1
        fi
        if ! _service_state="$(run_systemctl show "$SERVICE_UNIT" \
            --property=ActiveState --value 2>/dev/null)"; then
            echo "cannot prove watchdog service quiescence" >&2
            return 1
        fi
        if ! _service_pid="$(run_systemctl show "$SERVICE_UNIT" \
            --property=MainPID --value 2>/dev/null)"; then
            echo "cannot prove watchdog service process exit" >&2
            return 1
        fi

        _timer_quiet=0
        _service_quiet=0
        case "$_timer_state" in
            inactive|failed) _timer_quiet=1 ;;
            "")
                [ "$_timer_existed" -eq 0 ] && _timer_quiet=1
                ;;
        esac
        case "$_service_state" in
            inactive|failed)
                [ "$_service_pid" = "0" ] && _service_quiet=1
                ;;
            "")
                [ "$_service_existed" -eq 0 ] && _service_quiet=1
                ;;
        esac

        if [ "$_timer_quiet" -eq 1 ] && [ "$_service_quiet" -eq 1 ]; then
            return 0
        fi
        _attempt=$((_attempt + 1))
        [ "$_attempt" -lt 10 ] && "$SLEEP_CMD" 1
    done

    echo "watchdog timer/service did not become quiescent before mutation" >&2
    return 1
}

verify_regular_file() {
    _verify_target="$1"
    _verify_hash="$2"
    _verify_mode="$3"
    _verify_uid="$4"
    _verify_gid="$5"

    [ -f "$_verify_target" ] && [ ! -L "$_verify_target" ] || return 1
    [ "$(hash_file "$_verify_target")" = "$_verify_hash" ] || return 1
    _verify_stat="$(stat_triplet "$_verify_target")" || return 1
    _verify_actual_uid="${_verify_stat%%|*}"
    _verify_remainder="${_verify_stat#*|}"
    _verify_actual_gid="${_verify_remainder%%|*}"
    _verify_actual_mode="${_verify_remainder#*|}"
    _verify_expected_mode="${_verify_mode#0}"
    [ "$_verify_actual_uid" = "$_verify_uid" ] &&
        [ "$_verify_actual_gid" = "$_verify_gid" ] &&
        [ "$_verify_actual_mode" = "$_verify_expected_mode" ]
}

backup_target() {
    _backup_label="$1"
    _backup_target="$2"
    _backup_meta="${BACKUP_DIR}/${_backup_label}.meta"

    if [ "${JM_VPS_INSTALLER_FAIL_BACKUP_LABEL:-}" = \
        "$_backup_label" ]; then
        echo "injected backup failure for ${_backup_label}" >&2
        return 1
    fi

    if [ -e "$_backup_target" ]; then
        [ -f "$_backup_target" ] && [ ! -L "$_backup_target" ] || return 1
        _backup_stat="$(stat_triplet "$_backup_target")" || return 1
        _backup_uid="${_backup_stat%%|*}"
        _backup_remainder="${_backup_stat#*|}"
        _backup_gid="${_backup_remainder%%|*}"
        _backup_mode="${_backup_remainder#*|}"
        _backup_hash="$(hash_file "$_backup_target")" || return 1
        cp "$_backup_target" "${BACKUP_DIR}/${_backup_label}" || return 1
        chmod 0600 "${BACKUP_DIR}/${_backup_label}" || return 1
        chown "$EXPECTED_UID:$EXPECTED_GID" \
            "${BACKUP_DIR}/${_backup_label}" || return 1
        [ "$(hash_file "${BACKUP_DIR}/${_backup_label}")" = \
            "$_backup_hash" ] || return 1
        printf 'present|%s|%s|%s|%s\n' \
            "$_backup_hash" "$_backup_mode" "$_backup_uid" "$_backup_gid" \
            >"$_backup_meta"
    else
        printf '%s\n' 'missing||||' >"$_backup_meta"
    fi
    chmod 0600 "$_backup_meta"
    chown "$EXPECTED_UID:$EXPECTED_GID" "$_backup_meta"
}

verify_backup_record() {
    _record_label="$1"
    _record_meta="${BACKUP_DIR}/${_record_label}.meta"
    [ -f "$_record_meta" ] && [ ! -L "$_record_meta" ] || return 1
    IFS='|' read -r _record_presence _record_hash _record_mode \
        _record_uid _record_gid <"$_record_meta" || return 1
    case "$_record_presence" in
        missing)
            [ -z "$_record_hash" ] && [ -z "$_record_mode" ] &&
                [ -z "$_record_uid" ] && [ -z "$_record_gid" ] &&
                [ ! -e "${BACKUP_DIR}/${_record_label}" ] &&
                [ ! -L "${BACKUP_DIR}/${_record_label}" ]
            ;;
        present)
            case "$_record_hash" in
                *[!0-9A-Fa-f]*|"") return 1 ;;
            esac
            [ "${#_record_hash}" -eq 64 ] || return 1
            case "$_record_mode" in ""|*[!0-7]*) return 1 ;; esac
            case "$_record_uid" in ""|*[!0-9]*) return 1 ;; esac
            case "$_record_gid" in ""|*[!0-9]*) return 1 ;; esac
            verify_regular_file "${BACKUP_DIR}/${_record_label}" \
                "$_record_hash" 0600 "$EXPECTED_UID" "$EXPECTED_GID"
            ;;
        *) return 1 ;;
    esac
}

verify_backup_bundle() {
    for _bundle_label in watchdog service timer readme; do
        verify_backup_record "$_bundle_label" || return 1
    done
    [ -f "${BACKUP_DIR}/prior-timer-state" ] &&
        [ ! -L "${BACKUP_DIR}/prior-timer-state" ] || return 1
    [ "$(sed -n '1p' "${BACKUP_DIR}/prior-timer-state")" = \
        "enabled=${TIMER_WAS_ENABLED}" ] || return 1
    [ "$(sed -n '2p' "${BACKUP_DIR}/prior-timer-state")" = \
        "active=${TIMER_WAS_ACTIVE}" ] || return 1
    [ -z "$(sed -n '3p' "${BACKUP_DIR}/prior-timer-state")" ] ||
        return 1
}

seal_value() {
    _seal_key="$1"
    awk -F= -v wanted="$_seal_key" '
        $1 == wanted {
            print substr($0, length($1) + 2)
            found++
        }
        END {
            if (found != 1) {
                exit 1
            }
        }
    ' "${BACKUP_DIR}/BACKUP-READY"
}

verify_backup_seal() {
    _seal_file="${BACKUP_DIR}/BACKUP-READY"
    [ -f "$_seal_file" ] && [ ! -L "$_seal_file" ] || return 1
    [ "$(sed -n '1p' "$_seal_file")" = \
        'jammonitor-vps-watchdog-backup-v1' ] || return 1
    [ "$(wc -l <"$_seal_file" | tr -d ' ')" -eq 10 ] || return 1
    for _sealed_label in watchdog service timer readme; do
        _sealed_meta_hash="$(seal_value "${_sealed_label}.meta")" ||
            return 1
        [ "$_sealed_meta_hash" = \
            "$(hash_file "${BACKUP_DIR}/${_sealed_label}.meta")" ] ||
            return 1
        _sealed_payload_hash="$(seal_value "$_sealed_label")" || return 1
        if [ -f "${BACKUP_DIR}/${_sealed_label}" ]; then
            [ "$_sealed_payload_hash" = \
                "$(hash_file "${BACKUP_DIR}/${_sealed_label}")" ] ||
                return 1
        else
            [ "$_sealed_payload_hash" = "missing" ] || return 1
        fi
    done
    _sealed_timer_hash="$(seal_value prior-timer-state)" || return 1
    [ "$_sealed_timer_hash" = \
        "$(hash_file "${BACKUP_DIR}/prior-timer-state")" ]
}

seal_backup_bundle() {
    verify_backup_bundle || {
        echo "backup bundle verification failed before sealing" >&2
        return 1
    }
    _seal_temp="$(mktemp "${BACKUP_DIR}/.backup-ready.XXXXXX")" ||
        return 1
    {
        printf '%s\n' 'jammonitor-vps-watchdog-backup-v1'
        for _seal_label in watchdog service timer readme; do
            printf '%s.meta=%s\n' "$_seal_label" \
                "$(hash_file "${BACKUP_DIR}/${_seal_label}.meta")"
            if [ -f "${BACKUP_DIR}/${_seal_label}" ]; then
                printf '%s=%s\n' "$_seal_label" \
                    "$(hash_file "${BACKUP_DIR}/${_seal_label}")"
            else
                printf '%s=missing\n' "$_seal_label"
            fi
        done
        printf 'prior-timer-state=%s\n' \
            "$(hash_file "${BACKUP_DIR}/prior-timer-state")"
    } >"$_seal_temp" || {
        rm -f "$_seal_temp"
        return 1
    }
    chmod 0600 "$_seal_temp" || {
        rm -f "$_seal_temp"
        return 1
    }
    chown "$EXPECTED_UID:$EXPECTED_GID" "$_seal_temp" || {
        rm -f "$_seal_temp"
        return 1
    }
    mv -f "$_seal_temp" "${BACKUP_DIR}/BACKUP-READY" || {
        rm -f "$_seal_temp"
        return 1
    }
    [ -f "${BACKUP_DIR}/BACKUP-READY" ] &&
        [ ! -L "${BACKUP_DIR}/BACKUP-READY" ] || return 1
    sync_barrier backup-bundle "$BACKUP_DIR"
    sync_barrier backup-parent "$RECOVERY_BASE"
    verify_backup_bundle &&
        verify_backup_seal
}

sync_live_targets() {
    _live_phase="$1"
    for _live_target in \
        "$WATCHDOG_TARGET" "$SERVICE_TARGET" "$TIMER_TARGET" "$README_TARGET"
    do
        if [ -e "$_live_target" ]; then
            sync_barrier "${_live_phase}-target" "$_live_target" || return 1
        else
            sync_barrier "${_live_phase}-parent" \
                "${_live_target%/*}" || return 1
        fi
    done
    sync_barrier "${_live_phase}-complete" "$RECOVERY_BASE"
}

restore_target() {
    _restore_label="$1"
    _restore_target="$2"
    _restore_meta="${BACKUP_DIR}/${_restore_label}.meta"

    if [ "${JM_VPS_INSTALLER_FAIL_RESTORE_LABEL:-}" = \
        "$_restore_label" ]; then
        echo "injected restore failure for ${_restore_label}" >&2
        return 1
    fi

    if [ -n "$CURRENT_TEMP" ]; then
        rm -f "$CURRENT_TEMP"
        CURRENT_TEMP=""
    fi

    [ -f "$_restore_meta" ] && [ ! -L "$_restore_meta" ] || return 1
    IFS='|' read -r _restore_presence _restore_hash _restore_mode \
        _restore_uid _restore_gid <"$_restore_meta" || return 1

    if [ "$_restore_presence" = "missing" ]; then
        rm -f "$_restore_target" || return 1
        [ ! -e "$_restore_target" ] && [ ! -L "$_restore_target" ]
        return
    fi
    [ "$_restore_presence" = "present" ] || return 1
    [ -f "${BACKUP_DIR}/${_restore_label}" ] || return 1

    _restore_parent="${_restore_target%/*}"
    CURRENT_TEMP="$(mktemp "${_restore_parent}/.jammonitor-restore.XXXXXX")" ||
        return 1
    cp "${BACKUP_DIR}/${_restore_label}" "$CURRENT_TEMP" || return 1
    chown "${_restore_uid}:${_restore_gid}" "$CURRENT_TEMP" || return 1
    chmod "$_restore_mode" "$CURRENT_TEMP" || return 1
    verify_regular_file "$CURRENT_TEMP" "$_restore_hash" "$_restore_mode" \
        "$_restore_uid" "$_restore_gid" || return 1
    mv -f "$CURRENT_TEMP" "$_restore_target" || return 1
    CURRENT_TEMP=""
    verify_regular_file "$_restore_target" "$_restore_hash" "$_restore_mode" \
        "$_restore_uid" "$_restore_gid"
}

verify_backup_state() {
    _verify_label="$1"
    _verify_old_target="$2"
    _verify_meta="${BACKUP_DIR}/${_verify_label}.meta"
    [ -f "$_verify_meta" ] || return 1
    IFS='|' read -r _verify_presence _verify_hash _verify_mode \
        _verify_uid _verify_gid <"$_verify_meta" || return 1
    if [ "$_verify_presence" = "missing" ]; then
        [ ! -e "$_verify_old_target" ] && [ ! -L "$_verify_old_target" ]
    else
        [ "$_verify_presence" = "present" ] &&
            verify_regular_file "$_verify_old_target" "$_verify_hash" \
                "$_verify_mode" "$_verify_uid" "$_verify_gid"
    fi
}

install_atomic() {
    _install_name="$1"
    _install_target="$2"
    _install_mode="$3"
    _install_source="${SOURCE_DIR}/${_install_name}"
    _install_hash="$(manifest_hash_for "$_install_name")" || return 1

    [ "$(hash_file "$_install_source")" = "$_install_hash" ] || {
        echo "source changed during installation: ${_install_name}" >&2
        return 1
    }
    _install_parent="${_install_target%/*}"
    CURRENT_TEMP="$(mktemp "${_install_parent}/.jammonitor-install.XXXXXX")" ||
        return 1
    cp "$_install_source" "$CURRENT_TEMP" || return 1
    chown "$EXPECTED_UID:$EXPECTED_GID" "$CURRENT_TEMP" || return 1
    chmod "$_install_mode" "$CURRENT_TEMP" || return 1
    verify_regular_file "$CURRENT_TEMP" "$_install_hash" "$_install_mode" \
        "$EXPECTED_UID" "$EXPECTED_GID" || return 1
    mv -f "$CURRENT_TEMP" "$_install_target" || return 1
    CURRENT_TEMP=""
    verify_regular_file "$_install_target" "$_install_hash" "$_install_mode" \
        "$EXPECTED_UID" "$EXPECTED_GID"
}

verify_installed_files() {
    verify_regular_file "$WATCHDOG_TARGET" \
        "$(manifest_hash_for jammonitor-tailscale-watchdog)" 0755 \
        "$EXPECTED_UID" "$EXPECTED_GID" &&
    verify_regular_file "$SERVICE_TARGET" \
        "$(manifest_hash_for jammonitor-tailscale-watchdog.service)" 0644 \
        "$EXPECTED_UID" "$EXPECTED_GID" &&
    verify_regular_file "$TIMER_TARGET" \
        "$(manifest_hash_for jammonitor-tailscale-watchdog.timer)" 0644 \
        "$EXPECTED_UID" "$EXPECTED_GID" &&
    verify_regular_file "$README_TARGET" \
        "$(manifest_hash_for README.md)" 0644 \
        "$EXPECTED_UID" "$EXPECTED_GID"
}

verify_timer_state() {
    _expected_enabled="$1"
    _expected_active="$2"
    _actual_enabled=0
    _actual_active=0
    if unit_enabled "$TIMER_UNIT"; then
        _actual_enabled=1
    else
        _query_status=$?
        [ "$_query_status" -eq 1 ] || return 1
    fi
    if unit_active "$TIMER_UNIT"; then
        _actual_active=1
    else
        _query_status=$?
        [ "$_query_status" -eq 1 ] || return 1
    fi
    [ "$_actual_enabled" -eq "$_expected_enabled" ] &&
        [ "$_actual_active" -eq "$_expected_active" ]
}

disable_timer_durably() {
    _disable_phase="$1"

    if unit_enabled "$TIMER_UNIT"; then
        run_systemctl disable "$TIMER_UNIT"
    else
        _disable_query_status=$?
        [ "$_disable_query_status" -eq 1 ] || return 1
    fi
    verify_timer_state 0 0 || {
        echo "cannot prove disabled and inactive watchdog timer" >&2
        return 1
    }
    # `systemctl disable` removes a wants-link, so syncing only the unit file
    # is insufficient. `sync -f` on the systemd unit directory flushes the
    # filesystem containing both the unit and its enablement links.
    sync_barrier "${_disable_phase}-timer-disabled" "$SYSTEMD_UNIT_DIR"
}

apply_timer_state() {
    _desired_enabled="$1"
    _desired_active="$2"

    if [ "$_desired_enabled" -eq 1 ]; then
        run_systemctl enable "$TIMER_UNIT"
    else
        run_systemctl disable "$TIMER_UNIT"
    fi
    if [ "$_desired_active" -eq 1 ]; then
        run_systemctl start "$TIMER_UNIT"
    else
        run_systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true
    fi
    verify_timer_state "$_desired_enabled" "$_desired_active"
}

force_fail_safe_stopped() {
    _failsafe_failures=0
    run_systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    run_systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    run_systemctl disable "$TIMER_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    quiesce_watchdog_units 1 1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    if unit_active "$TIMER_UNIT"; then
        _failsafe_failures=$((_failsafe_failures + 1))
    else
        _failsafe_query_status=$?
        [ "$_failsafe_query_status" -eq 1 ] ||
            _failsafe_failures=$((_failsafe_failures + 1))
    fi
    if unit_active "$SERVICE_UNIT"; then
        _failsafe_failures=$((_failsafe_failures + 1))
    else
        _failsafe_query_status=$?
        [ "$_failsafe_query_status" -eq 1 ] ||
            _failsafe_failures=$((_failsafe_failures + 1))
    fi
    sync_barrier failsafe-timer-disabled "$SYSTEMD_UNIT_DIR" ||
        _failsafe_failures=$((_failsafe_failures + 1))
    [ "$_failsafe_failures" -eq 0 ]
}

rollback_transaction() {
    set +e
    _rollback_failures=0
    echo "installation failed; beginning verified rollback" >&2

    [ "$BACKUP_READY" -eq 1 ] ||
        _rollback_failures=$((_rollback_failures + 1))
    [ -f "${BACKUP_DIR}/BACKUP-READY" ] &&
        verify_backup_bundle &&
        verify_backup_seal ||
        _rollback_failures=$((_rollback_failures + 1))

    quiesce_watchdog_units 1 1 ||
        _rollback_failures=$((_rollback_failures + 1))
    if [ "$_rollback_failures" -eq 0 ]; then
        disable_timer_durably rollback ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        restore_target watchdog "$WATCHDOG_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        restore_target service "$SERVICE_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        restore_target timer "$TIMER_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        restore_target readme "$README_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))

        verify_backup_state watchdog "$WATCHDOG_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        verify_backup_state service "$SERVICE_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        verify_backup_state timer "$TIMER_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        verify_backup_state readme "$README_TARGET" ||
            _rollback_failures=$((_rollback_failures + 1))
        sync_live_targets rollback ||
            _rollback_failures=$((_rollback_failures + 1))
    else
        echo "rollback cannot mutate files while watchdog units remain active" >&2
    fi

    if [ -n "$CURRENT_TEMP" ]; then
        rm -f "$CURRENT_TEMP" ||
            _rollback_failures=$((_rollback_failures + 1))
        CURRENT_TEMP=""
    fi

    # Never reactivate a timer against a mixed old/new payload. Prior state is
    # eligible for restoration only after every old file is exact and systemd
    # has successfully reloaded those exact units.
    if [ "$_rollback_failures" -eq 0 ]; then
        run_systemctl daemon-reload ||
            _rollback_failures=$((_rollback_failures + 1))
    fi
    if [ "$_rollback_failures" -eq 0 ]; then
        apply_timer_state "$TIMER_WAS_ENABLED" "$TIMER_WAS_ACTIVE" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi
    if [ "$_rollback_failures" -eq 0 ]; then
        verify_timer_state "$TIMER_WAS_ENABLED" "$TIMER_WAS_ACTIVE" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi
    if [ "$_rollback_failures" -eq 0 ]; then
        sync_barrier rollback-timer-state "$SYSTEMD_UNIT_DIR" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi
    if [ "$_rollback_failures" -ne 0 ]; then
        force_fail_safe_stopped ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        sync_barrier rollback-pre-clear "$RECOVERY_BASE" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        remove_transaction_dir "$BACKUP_DIR" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi
    if [ "$_rollback_failures" -eq 0 ]; then
        # Once the only backup has been removed, never attempt a second
        # rollback from a nonexistent bundle. A deletion-sync failure leaves
        # the already restored live state in place and writes a blocker.
        BACKUP_READY=0
        MUTATION_STARTED=0
        TRANSACTION_ACTIVE=0
        sync_barrier rollback-evidence-deleted "$RECOVERY_BASE" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        echo "verified rollback restored every prior file and timer state" >&2
    else
        write_incomplete_evidence || true
        if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
            echo "ROLLBACK INCOMPLETE: recovery bundle preserved at ${BACKUP_DIR}" >&2
        else
            echo "ROLLBACK INCOMPLETE: recovery bundle is unavailable after cleanup" >&2
        fi
        echo "ROLLBACK INCOMPLETE: evidence at ${ROLLBACK_EVIDENCE}" >&2
    fi
    TRANSACTION_ACTIVE=0
    BACKUP_READY=0
    MUTATION_STARTED=0
    set -e
}

discard_unready_transaction() {
    # No unit or owned target has been touched. Cleanup is therefore allowed,
    # but it must never quiesce or disable a previously healthy installation.
    [ "$MUTATION_STARTED" -eq 0 ] || return 1
    if [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ]; then
        remove_transaction_dir "$BACKUP_DIR" || return 1
        sync_barrier pre-mutation-evidence-deleted "$RECOVERY_BASE" ||
            return 1
    fi
    TRANSACTION_ACTIVE=0
    BACKUP_READY=0
}

on_exit() {
    _exit_status=$?
    trap - EXIT HUP INT TERM
    set +e

    if [ -n "$CURRENT_TEMP" ]; then
        rm -f "$CURRENT_TEMP"
        CURRENT_TEMP=""
    fi
    if [ "$TRANSACTION_ACTIVE" -eq 1 ]; then
        if [ "$MUTATION_STARTED" -eq 1 ]; then
            rollback_transaction
        else
            discard_unready_transaction || {
                echo "pre-mutation recovery bundle cleanup incomplete: ${BACKUP_DIR}" >&2
                TRANSACTION_ACTIVE=0
            }
        fi
    fi
    release_lock
    exit "$_exit_status"
}

handle_signal() {
    exit 143
}

trap on_exit EXIT
trap handle_signal HUP INT TERM

if [ -L "$RECOVERY_BASE" ]; then
    echo "recovery path must not be a symlink: ${RECOVERY_BASE}" >&2
    exit 1
fi
if [ -e "$RECOVERY_BASE" ]; then
    [ -d "$RECOVERY_BASE" ] || {
        echo "recovery path is not a directory: ${RECOVERY_BASE}" >&2
        exit 1
    }
    verify_owner_and_readonly "$RECOVERY_BASE" "recovery directory"
    chmod 0700 "$RECOVERY_BASE"
else
    install -d -m 0700 -o "$EXPECTED_UID" -g "$EXPECTED_GID" \
        "$RECOVERY_BASE"
fi

acquire_lock

# Every evidence check belongs under the persistent inode lock.
if [ -e "$ROLLBACK_EVIDENCE" ] || [ -L "$ROLLBACK_EVIDENCE" ]; then
    echo "unresolved incomplete rollback evidence blocks installation: ${ROLLBACK_EVIDENCE}" >&2
    exit 1
fi
for _orphan_bundle in "$RECOVERY_BASE"/transaction.*; do
    [ -e "$_orphan_bundle" ] || continue
    echo "unresolved recovery bundle blocks installation: ${_orphan_bundle}" >&2
    exit 1
done

if [ -n "${JM_VPS_INSTALLER_HOLD_AFTER_LOCK_FILE:-}" ]; then
    _hold_file="${JM_VPS_INSTALLER_HOLD_AFTER_LOCK_FILE}"
    printf '%s\n' "$$" >"${_hold_file}.ready"
    while [ -e "$_hold_file" ]; do
        "$SLEEP_CMD" 1
    done
fi

# Recheck the entire provenance and trust boundary after acquiring the lock.
validate_source
verify_trusted_source

WATCHDOG_EXISTED=0
SERVICE_EXISTED=0
TIMER_EXISTED=0
README_EXISTED=0
[ -e "$WATCHDOG_TARGET" ] && WATCHDOG_EXISTED=1
[ -e "$SERVICE_TARGET" ] && SERVICE_EXISTED=1
[ -e "$TIMER_TARGET" ] && TIMER_EXISTED=1
[ -e "$README_TARGET" ] && README_EXISTED=1

# A boolean `is-enabled` result cannot distinguish reboot-durable `enabled`
# from `enabled-runtime`, linked units, aliases, or masks. Upgrading one of
# those states with plain `enable` would silently change operator intent.
# Existing timer units therefore admit only exact persistent enabled/disabled
# states. A genuinely new installation must not have a stray enabled link.
if [ "$TIMER_EXISTED" -eq 1 ]; then
    TIMER_WAS_UNIT_FILE_STATE="$(timer_unit_file_state)" || exit 1
    [ "$TIMER_WAS_UNIT_FILE_STATE" = "enabled" ] &&
        TIMER_WAS_ENABLED=1
else
    if unit_enabled "$TIMER_UNIT"; then
        echo "watchdog timer is enabled without an owned timer unit file" >&2
        exit 1
    else
        _initial_query_status=$?
        [ "$_initial_query_status" -eq 1 ] || exit 1
    fi
fi
if unit_active "$TIMER_UNIT"; then
    TIMER_WAS_ACTIVE=1
else
    _initial_query_status=$?
    [ "$_initial_query_status" -eq 1 ] || exit 1
fi

INSTALL_KIND="new"
if [ "$WATCHDOG_EXISTED" -eq 1 ] ||
   [ "$SERVICE_EXISTED" -eq 1 ] ||
   [ "$TIMER_EXISTED" -eq 1 ] ||
   [ "$README_EXISTED" -eq 1 ]; then
    INSTALL_KIND="upgrade"
fi

BACKUP_DIR="$(mktemp -d "${RECOVERY_BASE}/transaction.XXXXXX")"
chmod 0700 "$BACKUP_DIR"
chown "$EXPECTED_UID:$EXPECTED_GID" "$BACKUP_DIR"
TRANSACTION_ACTIVE=1

backup_target watchdog "$WATCHDOG_TARGET"
backup_target service "$SERVICE_TARGET"
backup_target timer "$TIMER_TARGET"
backup_target readme "$README_TARGET"
printf 'enabled=%s\nactive=%s\n' \
    "$TIMER_WAS_ENABLED" "$TIMER_WAS_ACTIVE" \
    >"${BACKUP_DIR}/prior-timer-state"
chmod 0600 "${BACKUP_DIR}/prior-timer-state"
chown "$EXPECTED_UID:$EXPECTED_GID" "${BACKUP_DIR}/prior-timer-state"

seal_backup_bundle
BACKUP_READY=1
fault_point backup-ready-before-mutation

# No installation target is mutated until both watchdog units are proven
# inactive and the oneshot service has no remaining main process.
MUTATION_STARTED=1
quiesce_watchdog_units "$SERVICE_EXISTED" "$TIMER_EXISTED"
disable_timer_durably pre-mutation

ensure_install_directory "$(rooted /usr/local/libexec)" 0755 \
    "watchdog target directory"
ensure_install_directory "$SYSTEMD_UNIT_DIR" 0755 \
    "systemd target directory"
ensure_install_directory \
    "$(rooted /usr/share/doc/jammonitor-tailscale-watchdog)" 0755 \
    "watchdog documentation directory"

install_atomic jammonitor-tailscale-watchdog "$WATCHDOG_TARGET" 0755
fault_point watchdog-installed-before-service
install_atomic jammonitor-tailscale-watchdog.service "$SERVICE_TARGET" 0644
install_atomic jammonitor-tailscale-watchdog.timer "$TIMER_TARGET" 0644
install_atomic README.md "$README_TARGET" 0644

"$TIMEOUT_CMD" -s TERM -k 2 "$SYSTEMD_ANALYZE_TIMEOUT_SECONDS" \
    "$SYSTEMD_ANALYZE_CMD" verify "$SERVICE_TARGET" "$TIMER_TARGET"
verify_installed_files
if [ "${JM_VPS_INSTALLER_FAIL_POST_VERIFY:-0}" = "1" ]; then
    echo "injected installed-file verification failure" >&2
    exit 1
fi

run_systemctl daemon-reload

if [ "$INSTALL_KIND" = "new" ]; then
    DESIRED_ENABLED=1
    DESIRED_ACTIVE="$START_REQUESTED"
else
    DESIRED_ENABLED="$TIMER_WAS_ENABLED"
    DESIRED_ACTIVE="$TIMER_WAS_ACTIVE"
    [ "$START_REQUESTED" -eq 1 ] && DESIRED_ACTIVE=1
fi

verify_installed_files
sync_live_targets commit
apply_timer_state "$DESIRED_ENABLED" "$DESIRED_ACTIVE"
sync_barrier commit-timer-state "$SYSTEMD_UNIT_DIR"
verify_timer_state "$DESIRED_ENABLED" "$DESIRED_ACTIVE"
sync_barrier commit-pre-clear "$RECOVERY_BASE"

remove_transaction_dir "$BACKUP_DIR"
TRANSACTION_ACTIVE=0
BACKUP_READY=0
MUTATION_STARTED=0
if ! sync_barrier commit-evidence-deleted "$RECOVERY_BASE"; then
    write_incomplete_evidence || true
    echo "RECOVERY CLEANUP INCOMPLETE: verified committed files remain installed" >&2
    echo "RECOVERY CLEANUP INCOMPLETE: evidence at ${ROLLBACK_EVIDENCE}" >&2
    exit 1
fi
BACKUP_DIR=""
release_lock
trap - EXIT HUP INT TERM

echo "VPS watchdog installation passed"
if [ "$DESIRED_ACTIVE" -eq 0 ]; then
    if [ "$DESIRED_ENABLED" -eq 1 ]; then
        echo "timer enabled but intentionally left stopped"
    else
        echo "timer remained disabled and stopped"
    fi
fi
