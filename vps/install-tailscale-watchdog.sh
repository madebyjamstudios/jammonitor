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
       [ -n "${JM_VPS_INSTALLER_EXPECTED_UID:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_EXPECTED_GID:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_RESTORE_LABEL:-}" ] ||
       [ -n "${JM_VPS_INSTALLER_FAIL_POST_VERIFY:-}" ]; then
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
    awk chmod chown cp dash id install kill mkdir mktemp mv rm rmdir sed sh tr
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

verify_trusted_source

# These paths are embedded in the installed service and watchdog. Check each
# one before creating a lock, recovery directory, or installation target.
for _runtime_path in \
    /usr/bin/tailscale \
    /usr/bin/timeout \
    /usr/bin/jq \
    /usr/bin/logger \
    /usr/bin/flock \
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

TAILSCALED_LOAD_STATE="$("$SYSTEMCTL_CMD" show tailscaled.service \
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

WATCHDOG_TARGET="$(rooted /usr/local/libexec/jammonitor-tailscale-watchdog)"
SERVICE_TARGET="$(rooted /etc/systemd/system/jammonitor-tailscale-watchdog.service)"
TIMER_TARGET="$(rooted /etc/systemd/system/jammonitor-tailscale-watchdog.timer)"
README_TARGET="$(rooted /usr/share/doc/jammonitor-tailscale-watchdog/README.md)"
TIMER_UNIT="jammonitor-tailscale-watchdog.timer"
SERVICE_UNIT="jammonitor-tailscale-watchdog.service"
LOCK_PARENT="$(rooted /run/lock)"
LOCK_DIR="${LOCK_PARENT}/jammonitor-tailscale-watchdog-install.lock"
RECOVERY_BASE="$(rooted /var/lib/jammonitor-tailscale-watchdog)"
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
CURRENT_TEMP=""
BACKUP_DIR=""
TIMER_WAS_ENABLED=0
TIMER_WAS_ACTIVE=0

release_lock() {
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rm -f "$LOCK_DIR/pid"
        rmdir "$LOCK_DIR" 2>/dev/null || true
        LOCK_ACQUIRED=0
    fi
}

acquire_lock() {
    if [ -L "$LOCK_PARENT" ]; then
        echo "installer lock parent must not be a symlink: ${LOCK_PARENT}" >&2
        return 1
    fi
    if [ ! -e "$LOCK_PARENT" ]; then
        install -d -m 0755 -o "$EXPECTED_UID" -g "$EXPECTED_GID" \
            "$LOCK_PARENT"
    elif [ ! -d "$LOCK_PARENT" ]; then
        echo "installer lock parent is not a directory: ${LOCK_PARENT}" >&2
        return 1
    fi
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        chmod 0700 "$LOCK_DIR"
        chown "$EXPECTED_UID:$EXPECTED_GID" "$LOCK_DIR"
        printf '%s\n' "$$" >"$LOCK_DIR/pid"
        chmod 0600 "$LOCK_DIR/pid"
        chown "$EXPECTED_UID:$EXPECTED_GID" "$LOCK_DIR/pid"
        LOCK_ACQUIRED=1
        return 0
    fi

    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || {
        echo "installer lock is not a private directory: ${LOCK_DIR}" >&2
        return 1
    }
    verify_owner_and_readonly "$LOCK_DIR" "installer lock directory" ||
        return 1
    if [ -e "$LOCK_DIR/pid" ] || [ -L "$LOCK_DIR/pid" ]; then
        [ -f "$LOCK_DIR/pid" ] && [ ! -L "$LOCK_DIR/pid" ] || {
            echo "installer lock pid is not a regular file" >&2
            return 1
        }
        verify_owner_and_readonly "$LOCK_DIR/pid" "installer lock pid" ||
            return 1
    fi
    _lock_pid="$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)"
    case "$_lock_pid" in
        ""|*[!0-9]*) ;;
        *)
            if kill -0 "$_lock_pid" 2>/dev/null; then
                echo "another VPS watchdog installation holds ${LOCK_DIR}" >&2
                return 1
            fi
            ;;
    esac

    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || {
        echo "stale installer lock contains unexpected files: ${LOCK_DIR}" >&2
        return 1
    }
    mkdir "$LOCK_DIR"
    chmod 0700 "$LOCK_DIR"
    chown "$EXPECTED_UID:$EXPECTED_GID" "$LOCK_DIR"
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    chmod 0600 "$LOCK_DIR/pid"
    chown "$EXPECTED_UID:$EXPECTED_GID" "$LOCK_DIR/pid"
    LOCK_ACQUIRED=1
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
        printf 'recovery_bundle=%s\n' "$BACKUP_DIR"
        printf '%s\n' 'Do not rerun the installer until an operator verifies and clears this evidence.'
    } >"$_evidence_temp" || {
        rm -f "$_evidence_temp"
        return 1
    }
    mv -f "$_evidence_temp" "$ROLLBACK_EVIDENCE" || {
        rm -f "$_evidence_temp"
        return 1
    }
}

unit_enabled() {
    "$SYSTEMCTL_CMD" is-enabled --quiet "$1" >/dev/null 2>&1
}

unit_active() {
    "$SYSTEMCTL_CMD" is-active --quiet "$1" >/dev/null 2>&1
}

quiesce_watchdog_units() {
    _service_existed="$1"
    _timer_existed="$2"
    _attempt=0

    "$SYSTEMCTL_CMD" stop "$TIMER_UNIT" >/dev/null 2>&1 || true
    "$SYSTEMCTL_CMD" stop "$SERVICE_UNIT" >/dev/null 2>&1 || true

    while [ "$_attempt" -lt 10 ]; do
        _timer_state="$("$SYSTEMCTL_CMD" show "$TIMER_UNIT" \
            --property=ActiveState --value 2>/dev/null || true)"
        _service_state="$("$SYSTEMCTL_CMD" show "$SERVICE_UNIT" \
            --property=ActiveState --value 2>/dev/null || true)"
        _service_pid="$("$SYSTEMCTL_CMD" show "$SERVICE_UNIT" \
            --property=MainPID --value 2>/dev/null || true)"

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
    unit_enabled "$TIMER_UNIT" && _actual_enabled=1
    unit_active "$TIMER_UNIT" && _actual_active=1
    [ "$_actual_enabled" -eq "$_expected_enabled" ] &&
        [ "$_actual_active" -eq "$_expected_active" ]
}

apply_timer_state() {
    _desired_enabled="$1"
    _desired_active="$2"

    if [ "$_desired_enabled" -eq 1 ]; then
        "$SYSTEMCTL_CMD" enable "$TIMER_UNIT"
    else
        "$SYSTEMCTL_CMD" disable "$TIMER_UNIT"
    fi
    if [ "$_desired_active" -eq 1 ]; then
        "$SYSTEMCTL_CMD" start "$TIMER_UNIT"
    else
        "$SYSTEMCTL_CMD" stop "$TIMER_UNIT" >/dev/null 2>&1 || true
    fi
    verify_timer_state "$_desired_enabled" "$_desired_active"
}

force_fail_safe_stopped() {
    _failsafe_failures=0
    "$SYSTEMCTL_CMD" stop "$TIMER_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    "$SYSTEMCTL_CMD" stop "$SERVICE_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    "$SYSTEMCTL_CMD" disable "$TIMER_UNIT" >/dev/null 2>&1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    quiesce_watchdog_units 1 1 ||
        _failsafe_failures=$((_failsafe_failures + 1))
    unit_active "$TIMER_UNIT" &&
        _failsafe_failures=$((_failsafe_failures + 1))
    unit_active "$SERVICE_UNIT" &&
        _failsafe_failures=$((_failsafe_failures + 1))
    [ "$_failsafe_failures" -eq 0 ]
}

rollback_transaction() {
    set +e
    _rollback_failures=0
    echo "installation failed; beginning verified rollback" >&2

    quiesce_watchdog_units 1 1 ||
        _rollback_failures=$((_rollback_failures + 1))

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
        "$SYSTEMCTL_CMD" daemon-reload ||
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
    if [ "$_rollback_failures" -ne 0 ]; then
        force_fail_safe_stopped ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        remove_transaction_dir "$BACKUP_DIR" ||
            _rollback_failures=$((_rollback_failures + 1))
    fi

    if [ "$_rollback_failures" -eq 0 ]; then
        echo "verified rollback restored every prior file and timer state" >&2
    else
        write_incomplete_evidence || true
        echo "ROLLBACK INCOMPLETE: recovery bundle preserved at ${BACKUP_DIR}" >&2
        echo "ROLLBACK INCOMPLETE: evidence at ${ROLLBACK_EVIDENCE}" >&2
    fi
    TRANSACTION_ACTIVE=0
    set -e
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
        rollback_transaction
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

if [ -e "$ROLLBACK_EVIDENCE" ] || [ -L "$ROLLBACK_EVIDENCE" ]; then
    echo "unresolved incomplete rollback evidence blocks installation: ${ROLLBACK_EVIDENCE}" >&2
    exit 1
fi
for _orphan_bundle in "$RECOVERY_BASE"/transaction.*; do
    [ -e "$_orphan_bundle" ] || continue
    echo "unresolved recovery bundle blocks installation: ${_orphan_bundle}" >&2
    exit 1
done

acquire_lock

# Recheck the entire provenance and trust boundary after acquiring the lock.
validate_source
verify_trusted_source

if unit_enabled "$TIMER_UNIT"; then
    TIMER_WAS_ENABLED=1
fi
if unit_active "$TIMER_UNIT"; then
    TIMER_WAS_ACTIVE=1
fi

WATCHDOG_EXISTED=0
SERVICE_EXISTED=0
TIMER_EXISTED=0
README_EXISTED=0
[ -e "$WATCHDOG_TARGET" ] && WATCHDOG_EXISTED=1
[ -e "$SERVICE_TARGET" ] && SERVICE_EXISTED=1
[ -e "$TIMER_TARGET" ] && TIMER_EXISTED=1
[ -e "$README_TARGET" ] && README_EXISTED=1

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

# No installation target is mutated until both watchdog units are proven
# inactive and the oneshot service has no remaining main process.
quiesce_watchdog_units "$SERVICE_EXISTED" "$TIMER_EXISTED"

ensure_install_directory "$(rooted /usr/local/libexec)" 0755 \
    "watchdog target directory"
ensure_install_directory "$(rooted /etc/systemd/system)" 0755 \
    "systemd target directory"
ensure_install_directory \
    "$(rooted /usr/share/doc/jammonitor-tailscale-watchdog)" 0755 \
    "watchdog documentation directory"

install_atomic jammonitor-tailscale-watchdog "$WATCHDOG_TARGET" 0755
install_atomic jammonitor-tailscale-watchdog.service "$SERVICE_TARGET" 0644
install_atomic jammonitor-tailscale-watchdog.timer "$TIMER_TARGET" 0644
install_atomic README.md "$README_TARGET" 0644

"$SYSTEMD_ANALYZE_CMD" verify "$SERVICE_TARGET" "$TIMER_TARGET"
verify_installed_files
if [ "${JM_VPS_INSTALLER_FAIL_POST_VERIFY:-0}" = "1" ]; then
    echo "injected installed-file verification failure" >&2
    exit 1
fi

"$SYSTEMCTL_CMD" daemon-reload

if [ "$INSTALL_KIND" = "new" ]; then
    DESIRED_ENABLED=1
    DESIRED_ACTIVE="$START_REQUESTED"
else
    DESIRED_ENABLED="$TIMER_WAS_ENABLED"
    DESIRED_ACTIVE="$TIMER_WAS_ACTIVE"
    [ "$START_REQUESTED" -eq 1 ] && DESIRED_ACTIVE=1
fi

apply_timer_state "$DESIRED_ENABLED" "$DESIRED_ACTIVE"
verify_installed_files

TRANSACTION_ACTIVE=0
remove_transaction_dir "$BACKUP_DIR"
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
