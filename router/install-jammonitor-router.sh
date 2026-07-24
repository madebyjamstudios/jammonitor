#!/bin/sh
#
# Transactional JamMonitor router installer.
#
# Remote installs require an immutable 40-character Git commit and the
# expected SHA256 of router/router-files.sha256. Local installs use a staged
# directory and can pin its manifest SHA256 explicitly.

set -eu

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
REPOSITORY="madebyjamstudios/jammonitor"
RAW_BASE="https://raw.githubusercontent.com/${REPOSITORY}"
MANIFEST_REL="router/router-files.sha256"

PAYLOADS='
jammonitor.lua|/usr/lib/lua/luci/controller/jammonitor.lua|0644
jammonitor.htm|/usr/lib/lua/luci/view/jammonitor.htm|0644
jammonitor.js|/www/luci-static/resources/jammonitor.js|0644
jammonitor-i18n.js|/www/luci-static/resources/jammonitor-i18n.js|0644
router/jammonitor-collect|/usr/bin/jammonitor-collect|0755
router/jammonitor-history.init|/etc/init.d/jammonitor-history|0755
router/jammonitor-tailscale-watchdog|/usr/bin/jammonitor-tailscale-watchdog|0755
router/jammonitor-tailscale-watchdog.init|/etc/init.d/jammonitor-tailscale-watchdog|0755
router/tailscale.init|/etc/init.d/tailscale|0755
router/upgrade-tailscale-arm64.sh|/usr/bin/jammonitor-tailscale-upgrade|0755
router/install-jammonitor-router.sh|/usr/bin/jammonitor-router-install|0755
'

PRESERVE_PATHS='
/etc/tailscale/
/usr/sbin/tailscale
/usr/sbin/tailscaled
/etc/init.d/tailscale
/etc/rc.d/S95tailscale
/etc/rc.d/K10tailscale
/usr/lib/lua/luci/controller/jammonitor.lua
/usr/lib/lua/luci/view/jammonitor.htm
/www/luci-static/resources/jammonitor.js
/www/luci-static/resources/jammonitor-i18n.js
/www/luci-static/resources/jammonitor.version
/usr/bin/jammonitor-collect
/etc/init.d/jammonitor-history
/etc/rc.d/S99jammonitor-history
/etc/rc.d/K20jammonitor-history
/usr/bin/jammonitor-tailscale-watchdog
/etc/init.d/jammonitor-tailscale-watchdog
/etc/rc.d/S96jammonitor-tailscale-watchdog
/etc/rc.d/K01jammonitor-tailscale-watchdog
/etc/jammonitor/tailscale-critical-peer
/etc/jammonitor_clients.json
/etc/jammonitor_wans
/usr/bin/jammonitor-tailscale-upgrade
/usr/bin/jammonitor-router-install
/usr/share/jammonitor/router-files.sha256
/usr/share/jammonitor/router-files.sha256.sha256
/usr/share/jammonitor/source-ref
/etc/init.d/jammonitor-collect
/etc/rc.d/S99jammonitor-collect
'

MODE="install"
MODE_EXPLICIT=0
REF=""
MANIFEST_SHA256=""
VERIFIED_MANIFEST_SHA256=""
SOURCE_DIR=""
WORK_DIR=""
STAGE_ROOT=""
BACKUP_ROOT=""
BACKUP_INDEX=""
TRANSACTION_ACTIVE=0
TRANSACTION_COMMITTED=0
BACKUP_READY=0
MUTATION_STARTED=0
MAINTENANCE_CREATED=0
MAINTENANCE_FILE="/var/run/jammonitor/tailscale-maintenance"
SERVICE_TIMEOUT=30
# Eleven bounded forward service operations, eighteen bounded rollback
# state/action/state operations (including a transient migration daemon),
# five minutes for the small local
# copies/checks, and a three-minute watchdog buffer.
MAINTENANCE_FILE_BUDGET=300
MAINTENANCE_BUFFER=180
MAINTENANCE_REQUIRED_REMAINING=$(( \
    (11 + 18) * SERVICE_TIMEOUT + \
    MAINTENANCE_FILE_BUDGET + MAINTENANCE_BUFFER \
))
LEGACY_WAS_RUNNING=0
LEGACY_WAS_PRESENT=0
HISTORY_WAS_RUNNING=0
HISTORY_WAS_PRESENT=0
WATCHDOG_WAS_RUNNING=0
WATCHDOG_WAS_PRESENT=0
TAILSCALE_WAS_RUNNING=0
TAILSCALE_WAS_PRESENT=0
UHTTPD_WAS_RUNNING=0
UHTTPD_WAS_PRESENT=0
TARGET_TEMP=""
INSTALL_LOCK="/var/run/jammonitor/router-install.lock"
INSTALL_LOCK_HELD=0
INIT_DIR="/etc/init.d"
ROLLBACK_INCOMPLETE=0
PRESERVE_WORK_DIR=0
RECOVERY_EVIDENCE="/var/run/jammonitor/router-install-rollback-failed"
INSTALLER_TESTING="${JAMMONITOR_INSTALL_TESTING:-0}"
INSTALLER_LIB_ONLY="${JAMMONITOR_INSTALL_LIB_ONLY:-0}"

case "$INSTALLER_TESTING:$INSTALLER_LIB_ONLY" in
    0:0|1:0|1:1)
        ;;
    *)
        printf '%s\n' \
            "ERROR: installer library mode is available only to the test harness" >&2
        exit 1
        ;;
esac

usage() {
    cat <<'EOF'
Usage:
  install-jammonitor-router.sh --ref <40-hex-commit> \
      --manifest-sha256 <64-hex-sha256>
  install-jammonitor-router.sh --source-dir <staged-directory> \
      [--manifest-sha256 <64-hex-sha256>]
  install-jammonitor-router.sh --validate-source <staged-directory> \
      [--manifest-sha256 <64-hex-sha256>]
  install-jammonitor-router.sh --verify-installed
  install-jammonitor-router.sh --repair-services

Remote mode refuses branch names, tags, abbreviated commits, and moving refs.
Local mode copies files from the source into a private staging directory
before validation or installation. Its manifest proves payload consistency,
not provenance, unless its SHA256 came through a separate trusted path.
EOF
}

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

is_hex_length() {
    value="$1"
    length="$2"
    [ "${#value}" -eq "$length" ] || return 1
    case "$value" in
        *[!0-9A-Fa-f]*) return 1 ;;
    esac
}

require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "required command is unavailable: $1"
}

target_for_source() {
    case "$1" in
        jammonitor.lua)
            printf '%s' "/usr/lib/lua/luci/controller/jammonitor.lua"
            ;;
        jammonitor.htm)
            printf '%s' "/usr/lib/lua/luci/view/jammonitor.htm"
            ;;
        jammonitor.js)
            printf '%s' "/www/luci-static/resources/jammonitor.js"
            ;;
        jammonitor-i18n.js)
            printf '%s' "/www/luci-static/resources/jammonitor-i18n.js"
            ;;
        router/jammonitor-collect)
            printf '%s' "/usr/bin/jammonitor-collect"
            ;;
        router/jammonitor-history.init)
            printf '%s' "/etc/init.d/jammonitor-history"
            ;;
        router/jammonitor-tailscale-watchdog)
            printf '%s' "/usr/bin/jammonitor-tailscale-watchdog"
            ;;
        router/jammonitor-tailscale-watchdog.init)
            printf '%s' "/etc/init.d/jammonitor-tailscale-watchdog"
            ;;
        router/tailscale.init)
            printf '%s' "/etc/init.d/tailscale"
            ;;
        router/upgrade-tailscale-arm64.sh)
            printf '%s' "/usr/bin/jammonitor-tailscale-upgrade"
            ;;
        router/install-jammonitor-router.sh)
            printf '%s' "/usr/bin/jammonitor-router-install"
            ;;
        *)
            return 1
            ;;
    esac
}

expected_mode_for_source() {
    case "$1" in
        jammonitor.lua|jammonitor.htm|jammonitor.js|jammonitor-i18n.js)
            printf '%s' "0644"
            ;;
        router/jammonitor-collect|router/jammonitor-history.init|\
        router/jammonitor-tailscale-watchdog|\
        router/jammonitor-tailscale-watchdog.init|router/tailscale.init|\
        router/upgrade-tailscale-arm64.sh|\
        router/install-jammonitor-router.sh)
            printf '%s' "0755"
            ;;
        *)
            return 1
            ;;
    esac
}

verify_installed_file_metadata() {
    file="$1"
    expected_mode="$2"
    expected_mode="${expected_mode#0}"

    [ -f "$file" ] && [ ! -L "$file" ] ||
        die "installed path is not a regular non-symlink file: $file"
    metadata="$(stat -c '%a:%u:%g' "$file" 2>/dev/null)" ||
        die "could not read installed file metadata: $file"
    [ "$metadata" = "$expected_mode:0:0" ] ||
        die "installed file mode or ownership is incorrect: $file"
}

manifest_file_count() {
    printf '%s\n' "$PAYLOADS" | awk -F'|' 'NF == 3 { count++ } END { print count + 0 }'
}

validate_internal_payload_map() {
    printf '%s\n' "$PAYLOADS" |
        while IFS='|' read -r source target mode; do
            [ -n "$source" ] || continue
            mapped_target="$(target_for_source "$source")" ||
                die "internal payload map has an unknown source: $source"
            mapped_mode="$(expected_mode_for_source "$source")" ||
                die "internal payload map has no mode for: $source"
            [ "$target" = "$mapped_target" ] ||
                die "internal target mapping differs for: $source"
            [ "$mode" = "$mapped_mode" ] ||
                die "internal mode mapping differs for: $source"
        done
}

fetch_file() {
    url="$1"
    output="$2"

    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --proto '=https' --tlsv1.2 "$url" -o "$output"
    else
        die "uclient-fetch, wget, or curl is required for remote mode"
    fi
}

safe_remove_work_dir() {
    [ -n "$WORK_DIR" ] || return 0
    [ "$PRESERVE_WORK_DIR" -eq 0 ] || return 0
    case "$WORK_DIR" in
        /tmp/jammonitor-install.*)
            rm -rf -- "$WORK_DIR"
            ;;
        *)
            warn "refusing to remove unexpected work directory: $WORK_DIR"
            ;;
    esac
}

path_matches_proof() {
    proof_path="$1"
    proof_type="$2"
    proof_fingerprint="$3"
    proof_metadata="$4"

    case "$proof_type" in
        file)
            [ -f "$proof_path" ] && [ ! -L "$proof_path" ] || return 1
            actual_fingerprint="$(sha256sum "$proof_path" | awk '{print $1}')" ||
                return 1
            ;;
        symlink)
            [ -L "$proof_path" ] || return 1
            actual_fingerprint="$(readlink "$proof_path")" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    [ "$actual_fingerprint" = "$proof_fingerprint" ] || return 1
    actual_metadata="$(stat -c '%a:%u:%g' "$proof_path" 2>/dev/null)" ||
        return 1
    [ "$actual_metadata" = "$proof_metadata" ]
}

restore_target() {
    kind="$1"
    target="$2"
    proof_type="${3:-}"
    proof_fingerprint="${4:-}"
    proof_metadata="${5:-}"
    backup="$BACKUP_ROOT$target"

    case "$kind" in
        present)
            path_matches_proof \
                "$backup" "$proof_type" "$proof_fingerprint" "$proof_metadata" ||
                return 1
            if [ -d "$target" ] && [ ! -L "$target" ]; then
                return 1
            fi
            restore_directory="$(dirname -- "$target")"
            mkdir -p "$restore_directory" || return 1
            TARGET_TEMP="$(
                mktemp "$restore_directory/.jammonitor-restore.XXXXXX"
            )" || return 1
            if ! rm -f -- "$TARGET_TEMP"; then
                TARGET_TEMP=""
                return 1
            fi
            if ! cp -a -- "$backup" "$TARGET_TEMP"; then
                rm -f -- "$TARGET_TEMP" 2>/dev/null || true
                TARGET_TEMP=""
                return 1
            fi
            if ! path_matches_proof \
                "$TARGET_TEMP" "$proof_type" \
                "$proof_fingerprint" "$proof_metadata"; then
                rm -f -- "$TARGET_TEMP" 2>/dev/null || true
                TARGET_TEMP=""
                return 1
            fi
            if ! mv -f -- "$TARGET_TEMP" "$target"; then
                rm -f -- "$TARGET_TEMP" 2>/dev/null || true
                TARGET_TEMP=""
                return 1
            fi
            TARGET_TEMP=""
            path_matches_proof \
                "$target" "$proof_type" "$proof_fingerprint" "$proof_metadata"
            ;;
        absent)
            [ -d "$target" ] && [ ! -L "$target" ] && return 1
            rm -f -- "$target" || return 1
            [ ! -e "$target" ] && [ ! -L "$target" ]
            ;;
        *)
            warn "unknown rollback record for $target"
            return 1
            ;;
    esac
}

service_file() {
    printf '%s/%s' "$INIT_DIR" "$1"
}

run_service_action() {
    service="$1"
    action="$2"
    init_script="$(service_file "$service")"
    [ -x "$init_script" ] || return 1
    timeout "$SERVICE_TIMEOUT" "$init_script" "$action"
}

SERVICE_STATE=""
read_service_state() {
    service="$1"
    init_script="$(service_file "$service")"
    [ -x "$init_script" ] || return 1
    if timeout "$SERVICE_TIMEOUT" "$init_script" running \
        >/dev/null 2>&1; then
        SERVICE_STATE="running"
        return 0
    else
        state_rc=$?
    fi
    if [ "$state_rc" -eq 1 ]; then
        SERVICE_STATE="stopped"
        return 0
    fi
    SERVICE_STATE="unknown"
    return 1
}

restore_service_runtime() {
    service="$1"
    was_present="$2"
    was_running="$3"
    force_reload="$4"

    [ "$was_present" -eq 1 ] || return 0
    read_service_state "$service" || return 1
    if [ "$was_running" -eq 1 ]; then
        if [ "$force_reload" -eq 1 ]; then
            run_service_action "$service" restart || return 1
        elif [ "$SERVICE_STATE" != "running" ]; then
            run_service_action "$service" start || return 1
        fi
        read_service_state "$service" || return 1
        [ "$SERVICE_STATE" = "running" ]
        return
    fi

    if [ "$SERVICE_STATE" = "running" ]; then
        run_service_action "$service" stop || return 1
    fi
    read_service_state "$service" || return 1
    [ "$SERVICE_STATE" = "stopped" ]
}

stop_transient_service() {
    service="$1"
    read_service_state "$service" || return 1
    if [ "$SERVICE_STATE" = "running" ]; then
        run_service_action "$service" stop || return 1
    fi
    read_service_state "$service" || return 1
    [ "$SERVICE_STATE" = "stopped" ]
}

mark_rollback_incomplete() {
    ROLLBACK_INCOMPLETE=1
    PRESERVE_WORK_DIR=1
    bundle_evidence="$WORK_DIR/ROLLBACK_INCOMPLETE"
    {
        printf 'status=rollback_incomplete\n'
        printf 'recovery_bundle=%s\n' "$WORK_DIR"
        printf 'backup_index=%s\n' "$BACKUP_INDEX"
        printf 'maintenance_marker=%s\n' "$MAINTENANCE_FILE"
        printf 'created_epoch=%s\n' \
            "$(date +%s 2>/dev/null || printf unknown)"
    } > "$bundle_evidence" 2>/dev/null || true
    chmod 0600 "$bundle_evidence" 2>/dev/null || true
    evidence_directory="$(dirname -- "$RECOVERY_EVIDENCE")"
    evidence_tmp=""
    if mkdir -p "$evidence_directory" 2>/dev/null &&
       evidence_tmp="$(
           mktemp "$evidence_directory/.router-install-rollback.XXXXXX"
       )"; then
        cp -- "$bundle_evidence" "$evidence_tmp" &&
            chmod 0600 "$evidence_tmp" &&
            mv -f -- "$evidence_tmp" "$RECOVERY_EVIDENCE" ||
            rm -f -- "$evidence_tmp" 2>/dev/null || true
    fi
    printf 'CRITICAL: JamMonitor rollback is incomplete. Recovery bundle preserved at %s\n' \
        "$WORK_DIR" >&2
    printf 'CRITICAL: Do not remove %s until every recorded target and service is recovered.\n' \
        "$RECOVERY_EVIDENCE" >&2
}

refuse_unresolved_recovery_evidence() {
    if [ -e "$RECOVERY_EVIDENCE" ] || [ -L "$RECOVERY_EVIDENCE" ]; then
        die "an unresolved prior installer rollback failure requires operator recovery"
    fi
}

rollback_transaction() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ "$TRANSACTION_COMMITTED" -eq 0 ] || return 0
    [ "$MUTATION_STARTED" -eq 1 ] || return 0

    printf 'Installation failed. Restoring previous router files.\n' >&2
    rollback_failed=0
    history_transient_stop_failed=0

    # A running legacy collector can cause the forward transaction to start a
    # newly installed canonical history service. If that init file did not
    # exist before the transaction, stop the transient daemon while its control
    # script still exists. On failure, preserve that script as a recovery tool
    # instead of unlinking the only remaining way to stop the process.
    if [ "$HISTORY_WAS_PRESENT" -eq 0 ] &&
       [ "$LEGACY_WAS_RUNNING" -eq 1 ]; then
        if ! stop_transient_service jammonitor-history; then
            warn "transient history service could not be stopped before rollback"
            rollback_failed=1
            history_transient_stop_failed=1
        fi
    fi

    if [ "$BACKUP_READY" -eq 1 ] && [ -f "$BACKUP_INDEX" ]; then
        while IFS='|' read -r kind target proof_type proof_fingerprint \
            proof_metadata extra; do
            [ -n "$kind" ] || continue
            if [ "$history_transient_stop_failed" -eq 1 ] &&
               [ "$kind" = "absent" ] &&
               [ "$target" = "$(service_file jammonitor-history)" ]; then
                warn "preserving the transient history init file for manual recovery"
                continue
            fi
            if [ -n "${extra:-}" ] ||
               ! restore_target "$kind" "$target" "$proof_type" \
                   "$proof_fingerprint" "$proof_metadata"; then
                warn "could not restore $target"
                rollback_failed=1
            fi
        done < "$BACKUP_INDEX"
    else
        warn "complete rollback backup is unavailable"
        rollback_failed=1
    fi

    if ! restore_service_runtime tailscale \
        "$TAILSCALE_WAS_PRESENT" "$TAILSCALE_WAS_RUNNING" 0; then
        warn "Tailscale runtime state could not be restored after rollback"
        rollback_failed=1
    fi
    if ! restore_service_runtime jammonitor-history \
        "$HISTORY_WAS_PRESENT" "$HISTORY_WAS_RUNNING" \
        "$HISTORY_WAS_RUNNING"; then
        warn "history service state could not be restored after rollback"
        rollback_failed=1
    fi
    if ! restore_service_runtime jammonitor-collect \
        "$LEGACY_WAS_PRESENT" "$LEGACY_WAS_RUNNING" 0; then
        warn "legacy collector state could not be restored after rollback"
        rollback_failed=1
    fi
    if ! restore_service_runtime jammonitor-tailscale-watchdog \
        "$WATCHDOG_WAS_PRESENT" "$WATCHDOG_WAS_RUNNING" \
        "$WATCHDOG_WAS_RUNNING"; then
        warn "watchdog service state could not be restored after rollback"
        rollback_failed=1
    fi
    if ! restore_service_runtime uhttpd \
        "$UHTTPD_WAS_PRESENT" "$UHTTPD_WAS_RUNNING" \
        "$UHTTPD_WAS_RUNNING"; then
        warn "uhttpd state could not be restored after rollback"
        rollback_failed=1
    fi

    if [ "$rollback_failed" -ne 0 ]; then
        mark_rollback_incomplete
        return 1
    fi
    printf '%s\n' "Previous router files and service states were restored." >&2
    return 0
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    rollback_transaction || true
    if [ "$MAINTENANCE_CREATED" -eq 1 ] &&
       [ "$ROLLBACK_INCOMPLETE" -eq 0 ]; then
        rm -f -- "$MAINTENANCE_FILE"
    fi
    if [ -n "$TARGET_TEMP" ]; then
        rm -f -- "$TARGET_TEMP"
    fi
    if [ "$INSTALL_LOCK_HELD" -eq 1 ]; then
        rm -f -- "$INSTALL_LOCK/pid"
        rmdir "$INSTALL_LOCK" 2>/dev/null || true
    fi
    safe_remove_work_dir
    exit "$status"
}

if [ "$INSTALLER_LIB_ONLY" -eq 0 ]; then
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

backup_target() {
    target="$1"
    if grep -F "|$target|" "$BACKUP_INDEX" >/dev/null 2>&1; then
        return 0
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        if [ -L "$target" ]; then
            proof_type="symlink"
            proof_fingerprint="$(readlink "$target")" ||
                die "could not read rollback symlink: $target"
        elif [ -f "$target" ]; then
            proof_type="file"
            proof_fingerprint="$(sha256sum "$target" | awk '{print $1}')" ||
                die "could not hash rollback target: $target"
        else
            die "rollback target has an unsupported file type: $target"
        fi
        case "$proof_fingerprint" in
            *"|"*|*"
"*)
                die "rollback proof contains an unsupported delimiter: $target"
                ;;
        esac
        proof_metadata="$(stat -c '%a:%u:%g' "$target" 2>/dev/null)" ||
            die "could not read rollback metadata: $target"
        mkdir -p "$BACKUP_ROOT$(dirname -- "$target")"
        cp -a -- "$target" "$BACKUP_ROOT$target"
        path_matches_proof "$BACKUP_ROOT$target" "$proof_type" \
            "$proof_fingerprint" "$proof_metadata" ||
            die "rollback backup verification failed: $target"
        printf 'present|%s|%s|%s|%s\n' \
            "$target" "$proof_type" "$proof_fingerprint" "$proof_metadata" \
            >> "$BACKUP_INDEX"
    else
        printf 'absent|%s|||\n' "$target" >> "$BACKUP_INDEX"
    fi
}

verify_manifest_shape() {
    manifest="$1"
    seen="$WORK_DIR/manifest.seen"
    : > "$seen"
    count=0

    while IFS=' ' read -r digest marker path extra; do
        [ -n "$digest" ] || continue

        # The generated text-mode format has exactly a digest and one path.
        # IFS whitespace collapsing assigns that path to marker.
        [ -z "${path:-}" ] ||
            die "manifest path contains whitespace"
        [ -z "${extra:-}" ] || die "manifest path contains whitespace"
        path="$marker"
        is_hex_length "$digest" 64 ||
            die "manifest contains an invalid SHA256 digest"
        target_for_source "$path" >/dev/null ||
            die "manifest contains an unowned path: $path"
        if grep -Fqx "$path" "$seen"; then
            die "manifest contains a duplicate path: $path"
        fi
        printf '%s\n' "$path" >> "$seen"
        count=$((count + 1))
    done < "$manifest"

    expected_count="$(manifest_file_count)"
    [ "$count" -eq "$expected_count" ] ||
        die "manifest has $count payloads, expected $expected_count"

    printf '%s\n' "$PAYLOADS" |
        while IFS='|' read -r source target mode; do
            [ -n "$source" ] || continue
            grep -Fqx "$source" "$seen" ||
                die "manifest is missing required path: $source"
        done
}

verify_staged_payloads() {
    manifest="$STAGE_ROOT/$MANIFEST_REL"
    verify_manifest_shape "$manifest"
    (
        cd "$STAGE_ROOT"
        sha256sum -c "$MANIFEST_REL"
    ) || die "one or more staged files failed checksum verification"
    VERIFIED_MANIFEST_SHA256="$(sha256sum "$manifest" | awk '{print $1}')"
}

validate_shell_file() {
    file="$1"
    sh -n "$file" || die "shell syntax validation failed: $file"
}

validate_init_order() {
    file="$1"
    expected_start="$2"
    expected_stop="$3"
    grep -Fqx "START=$expected_start" "$file" ||
        die "unexpected START value in $file"
    grep -Fqx "STOP=$expected_stop" "$file" ||
        die "unexpected STOP value in $file"
}

validate_staged_payloads() {
    validate_shell_file "$STAGE_ROOT/router/jammonitor-collect"
    validate_shell_file "$STAGE_ROOT/router/jammonitor-history.init"
    validate_shell_file "$STAGE_ROOT/router/jammonitor-tailscale-watchdog"
    validate_shell_file "$STAGE_ROOT/router/jammonitor-tailscale-watchdog.init"
    validate_shell_file "$STAGE_ROOT/router/tailscale.init"
    validate_shell_file "$STAGE_ROOT/router/upgrade-tailscale-arm64.sh"
    validate_shell_file "$STAGE_ROOT/router/install-jammonitor-router.sh"

    grep -Fqx '#!/bin/sh /etc/rc.common' \
        "$STAGE_ROOT/router/jammonitor-history.init" ||
        die "history init script has an invalid rc.common header"
    grep -Fqx '#!/bin/sh /etc/rc.common' \
        "$STAGE_ROOT/router/jammonitor-tailscale-watchdog.init" ||
        die "watchdog init script has an invalid rc.common header"
    grep -Fqx '#!/bin/sh /etc/rc.common' \
        "$STAGE_ROOT/router/tailscale.init" ||
        die "Tailscale init script has an invalid rc.common header"
    validate_init_order "$STAGE_ROOT/router/tailscale.init" 95 10
    validate_init_order \
        "$STAGE_ROOT/router/jammonitor-tailscale-watchdog.init" 96 01
    validate_init_order "$STAGE_ROOT/router/jammonitor-history.init" 99 20

    if command -v luac >/dev/null 2>&1; then
        luac -p "$STAGE_ROOT/jammonitor.lua" ||
            die "Lua syntax validation failed"
    elif command -v lua >/dev/null 2>&1; then
        JM_LUA_FILE="$STAGE_ROOT/jammonitor.lua" \
            lua -e 'assert(loadfile(os.getenv("JM_LUA_FILE")))' ||
            die "Lua syntax validation failed"
    else
        warn "luac/lua is unavailable, so Lua syntax validation was skipped"
    fi

    if command -v node >/dev/null 2>&1; then
        node --check "$STAGE_ROOT/jammonitor.js" >/dev/null ||
            die "JavaScript syntax validation failed: jammonitor.js"
        node --check "$STAGE_ROOT/jammonitor-i18n.js" >/dev/null ||
            die "JavaScript syntax validation failed: jammonitor-i18n.js"
    else
        warn "node is unavailable, so JavaScript syntax validation was skipped"
    fi

    [ -s "$STAGE_ROOT/jammonitor.htm" ] ||
        die "jammonitor.htm is empty"
}

copy_local_payloads() {
    source_root="$1"
    [ -f "$source_root/$MANIFEST_REL" ] ||
        die "local source is missing $MANIFEST_REL"
    [ ! -L "$source_root/$MANIFEST_REL" ] ||
        die "local checksum manifest must not be a symbolic link"
    mkdir -p "$STAGE_ROOT/router"
    cp -- "$source_root/$MANIFEST_REL" "$STAGE_ROOT/$MANIFEST_REL"

    printf '%s\n' "$PAYLOADS" |
        while IFS='|' read -r source target mode; do
            [ -n "$source" ] || continue
            [ -f "$source_root/$source" ] ||
                die "local source is missing $source"
            [ ! -L "$source_root/$source" ] ||
                die "local payload must not be a symbolic link: $source"
            mkdir -p "$STAGE_ROOT$(dirname -- "/$source")"
            cp -- "$source_root/$source" "$STAGE_ROOT/$source"
        done
}

verify_local_manifest_pin() {
    [ -n "$MANIFEST_SHA256" ] || return 0
    actual_manifest_sha="$(sha256sum "$STAGE_ROOT/$MANIFEST_REL" |
        awk '{print $1}')"
    [ "$actual_manifest_sha" = "$MANIFEST_SHA256" ] ||
        die "staged manifest SHA256 does not match the trusted value"
}

download_remote_payloads() {
    mkdir -p "$STAGE_ROOT/router"
    manifest="$STAGE_ROOT/$MANIFEST_REL"
    fetch_file "$RAW_BASE/$REF/$MANIFEST_REL" "$manifest" ||
        die "could not download checksum manifest"

    actual_manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
    [ "$actual_manifest_sha" = "$MANIFEST_SHA256" ] ||
        die "checksum manifest SHA256 does not match the trusted value"

    printf '%s\n' "$PAYLOADS" |
        while IFS='|' read -r source target mode; do
            [ -n "$source" ] || continue
            mkdir -p "$STAGE_ROOT$(dirname -- "/$source")"
            fetch_file "$RAW_BASE/$REF/$source" "$STAGE_ROOT/$source" ||
                die "could not download $source"
        done
}

atomic_install() {
    source="$1"
    target="$2"
    mode="$3"
    directory="$(dirname -- "$target")"

    mkdir -p "$directory"
    TARGET_TEMP="$(mktemp "$directory/.jammonitor-install.XXXXXX")"
    cp -- "$source" "$TARGET_TEMP"
    chmod "$mode" "$TARGET_TEMP"
    chown 0:0 "$TARGET_TEMP" 2>/dev/null ||
        die "could not set root ownership on $target"
    mv -f -- "$TARGET_TEMP" "$target"
    TARGET_TEMP=""
}

merge_sysupgrade_preservation() {
    target="/etc/sysupgrade.conf"
    directory="/etc"
    TARGET_TEMP="$(mktemp "$directory/.jammonitor-sysupgrade.XXXXXX")"

    if [ -f "$target" ]; then
        cp -- "$target" "$TARGET_TEMP"
    else
        : > "$TARGET_TEMP"
    fi

    printf '%s\n' "$PRESERVE_PATHS" |
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            if ! grep -Fqx "$path" "$TARGET_TEMP"; then
                printf '%s\n' "$path" >> "$TARGET_TEMP"
            fi
        done

    chmod 0644 "$TARGET_TEMP"
    chown 0:0 "$TARGET_TEMP" 2>/dev/null ||
        die "could not set root ownership on $target"
    mv -f -- "$TARGET_TEMP" "$target"
    TARGET_TEMP=""
}

legacy_service_is_known() {
    legacy="$(service_file jammonitor-collect)"
    [ -e "$legacy" ] || return 0
    [ -f "$legacy" ] ||
        die "legacy service path exists but is not a regular file: $legacy"
    legacy_sha="$(sha256sum "$legacy" | awk '{print $1}')"

    # This is the exact legacy service shipped before the canonical
    # jammonitor-history name was adopted.
    if [ "$legacy_sha" = \
         "cb9b0c1f67e14cbf48dffceb0d69421af1b0a049eac0f3cbc2e6bd527af53736" ]; then
        return 0
    fi

    # A byte-identical alias of the validated staged or installed canonical
    # service is also safe to migrate.
    if [ -n "$STAGE_ROOT" ] &&
       [ -f "$STAGE_ROOT/router/jammonitor-history.init" ]; then
        canonical_sha="$(sha256sum \
            "$STAGE_ROOT/router/jammonitor-history.init" | awk '{print $1}')"
        [ "$legacy_sha" = "$canonical_sha" ] && return 0
    fi
    canonical_history="$(service_file jammonitor-history)"
    if [ -f "$canonical_history" ]; then
        canonical_sha="$(sha256sum "$canonical_history" |
            awk '{print $1}')"
        [ "$legacy_sha" = "$canonical_sha" ] && return 0
    fi

    die "legacy jammonitor-collect service is custom; migrate it manually"
}

capture_one_service_state() {
    service="$1"
    present_variable="$2"
    running_variable="$3"
    init_script="$(service_file "$service")"
    if [ ! -e "$init_script" ] && [ ! -L "$init_script" ]; then
        eval "$present_variable=0"
        eval "$running_variable=0"
        return 0
    fi
    [ -x "$init_script" ] ||
        die "service state cannot be read from a non-executable init file: $service"
    eval "$present_variable=1"
    read_service_state "$service" ||
        die "service state query failed or timed out: $service"
    if [ "$SERVICE_STATE" = "running" ]; then
        eval "$running_variable=1"
    else
        eval "$running_variable=0"
    fi
}

capture_service_state() {
    capture_one_service_state \
        jammonitor-collect LEGACY_WAS_PRESENT LEGACY_WAS_RUNNING
    capture_one_service_state \
        jammonitor-history HISTORY_WAS_PRESENT HISTORY_WAS_RUNNING
    capture_one_service_state \
        jammonitor-tailscale-watchdog \
        WATCHDOG_WAS_PRESENT WATCHDOG_WAS_RUNNING
    capture_one_service_state \
        tailscale TAILSCALE_WAS_PRESENT TAILSCALE_WAS_RUNNING
    capture_one_service_state \
        uhttpd UHTTPD_WAS_PRESENT UHTTPD_WAS_RUNNING
}

backup_transaction_targets() {
    : > "$BACKUP_INDEX"

    printf '%s\n' "$PAYLOADS" |
        while IFS='|' read -r source target mode; do
            [ -n "$source" ] || continue
            backup_target "$target"
        done

    backup_target "/www/luci-static/resources/jammonitor.version"
    backup_target "/usr/share/jammonitor/router-files.sha256"
    backup_target "/usr/share/jammonitor/router-files.sha256.sha256"
    backup_target "/usr/share/jammonitor/source-ref"
    backup_target "/etc/sysupgrade.conf"

    for path in \
        /etc/rc.d/S95tailscale \
        /etc/rc.d/K10tailscale \
        /etc/rc.d/S96jammonitor-tailscale-watchdog \
        /etc/rc.d/K01jammonitor-tailscale-watchdog \
        /etc/rc.d/S99jammonitor-history \
        /etc/rc.d/K20jammonitor-history
    do
        backup_target "$path"
    done

    for service in \
        tailscale \
        jammonitor-history \
        jammonitor-tailscale-watchdog \
        jammonitor-collect
    do
        for path in /etc/rc.d/[SK][0-9][0-9]"$service"; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                backup_target "$path"
            fi
        done
    done
}

disable_known_legacy_service() {
    legacy="$(service_file jammonitor-collect)"
    if [ ! -x "$legacy" ]; then
        for path in /etc/rc.d/[SK][0-9][0-9]jammonitor-collect; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                rm -f -- "$path"
            fi
        done
        return 0
    fi
    if [ "$LEGACY_WAS_RUNNING" -eq 1 ]; then
        run_service_action jammonitor-collect stop ||
            die "could not stop the running legacy jammonitor-collect service"
    fi
    run_service_action jammonitor-collect disable ||
        die "could not disable the legacy jammonitor-collect service"
    printf '%s\n' \
        "Legacy jammonitor-collect was disabled; its init file was retained."
}

refresh_previously_running_services() {
    if [ "$HISTORY_WAS_RUNNING" -eq 1 ] ||
       [ "$LEGACY_WAS_RUNNING" -eq 1 ]; then
        run_service_action jammonitor-history restart ||
            die "could not activate the canonical history service"
    fi
    if [ "$WATCHDOG_WAS_RUNNING" -eq 1 ]; then
        run_service_action jammonitor-tailscale-watchdog restart ||
            die "could not refresh the running Tailscale watchdog"
    fi
}

enable_canonical_services() {
    for service in tailscale jammonitor-history jammonitor-tailscale-watchdog; do
        [ -x "$(service_file "$service")" ] ||
            die "installed service is not executable: $service"
        run_service_action "$service" disable ||
            die "could not clear stale enable links for service: $service"
        run_service_action "$service" enable ||
            die "could not enable service: $service"
    done
}

check_tailscale_prerequisites() {
    [ -x /usr/sbin/tailscale ] ||
        die "/usr/sbin/tailscale is missing; install a verified binary first"
    [ -x /usr/sbin/tailscaled ] ||
        die "/usr/sbin/tailscaled is missing; install a verified binary first"
    require_command timeout
    require_command jsonfilter
}

check_runtime_prerequisites() {
    check_tailscale_prerequisites
    require_command sqlite3
    require_command conntrack
    require_command flock
}

prepare_work_dir() {
    umask 077
    WORK_DIR="$(mktemp -d /tmp/jammonitor-install.XXXXXX)"
    STAGE_ROOT="$WORK_DIR/stage"
    BACKUP_ROOT="$WORK_DIR/backup"
    BACKUP_INDEX="$WORK_DIR/backup.index"
    mkdir -p "$STAGE_ROOT" "$BACKUP_ROOT"
}

acquire_install_lock() {
    mkdir -p /var/run/jammonitor
    chmod 0700 /var/run/jammonitor
    if mkdir "$INSTALL_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$INSTALL_LOCK/pid"
        INSTALL_LOCK_HELD=1
        return 0
    fi

    lock_pid="$(cat "$INSTALL_LOCK/pid" 2>/dev/null || true)"
    case "$lock_pid" in
        ""|*[!0-9]*)
            ;;
        *)
            if kill -0 "$lock_pid" 2>/dev/null; then
                die "another JamMonitor install or repair is running"
            fi
            ;;
    esac

    rm -f -- "$INSTALL_LOCK/pid"
    rmdir "$INSTALL_LOCK" 2>/dev/null ||
        die "could not clear a stale installer lock"
    mkdir "$INSTALL_LOCK" ||
        die "could not acquire the installer lock"
    printf '%s\n' "$$" > "$INSTALL_LOCK/pid"
    INSTALL_LOCK_HELD=1
}

create_maintenance_marker() {
    now_epoch="$(date +%s)" || die "could not read the current time"
    is_uint "$now_epoch" || die "current time is not a Unix epoch"
    [ "$MAINTENANCE_REQUIRED_REMAINING" -gt 0 ] &&
       [ "$MAINTENANCE_REQUIRED_REMAINING" -le 3600 ] ||
        die "calculated maintenance window is outside the safe range"

    if [ -e "$MAINTENANCE_FILE" ] || [ -L "$MAINTENANCE_FILE" ]; then
        [ -f "$MAINTENANCE_FILE" ] && [ ! -L "$MAINTENANCE_FILE" ] ||
            die "preexisting maintenance marker is not a regular file"
        existing_expiry="$(cat "$MAINTENANCE_FILE" 2>/dev/null || true)"
        is_uint "$existing_expiry" ||
            die "preexisting maintenance marker is malformed; verify no maintenance is active, then remove it"
        remaining=$((existing_expiry - now_epoch))
        [ "$remaining" -ge "$MAINTENANCE_REQUIRED_REMAINING" ] &&
           [ "$remaining" -le 3600 ] ||
            die "preexisting maintenance marker cannot cover the calculated install and rollback window"
        return 0
    fi

    expires_epoch=$((now_epoch + MAINTENANCE_REQUIRED_REMAINING))
    printf '%s\n' "$expires_epoch" > "$MAINTENANCE_FILE" ||
        die "could not create the maintenance marker"
    MAINTENANCE_CREATED=1
    chmod 0600 "$MAINTENANCE_FILE" ||
        die "could not protect the maintenance marker"
}

install_payloads() {
    TRANSACTION_ACTIVE=1
    backup_transaction_targets
    BACKUP_READY=1

    mkdir -p /var/run/jammonitor
    chmod 0700 /var/run/jammonitor
    create_maintenance_marker

    MUTATION_STARTED=1
    for payload in $PAYLOADS; do
        source="${payload%%|*}"
        remainder="${payload#*|}"
        target="${remainder%%|*}"
        mode="${remainder##*|}"
        atomic_install "$STAGE_ROOT/$source" "$target" "$mode"
    done

    mkdir -p /usr/share/jammonitor
    atomic_install "$STAGE_ROOT/$MANIFEST_REL" \
        "/usr/share/jammonitor/router-files.sha256" 0644

    printf '%s\n' "$VERIFIED_MANIFEST_SHA256" > "$WORK_DIR/manifest-sha256"
    atomic_install "$WORK_DIR/manifest-sha256" \
        "/usr/share/jammonitor/router-files.sha256.sha256" 0644

    printf '%s\n' "$REF" > "$WORK_DIR/source-ref"
    atomic_install "$WORK_DIR/source-ref" \
        "/usr/share/jammonitor/source-ref" 0644
    atomic_install "$WORK_DIR/source-ref" \
        "/www/luci-static/resources/jammonitor.version" 0644

    verify_installed
    merge_sysupgrade_preservation
    disable_known_legacy_service
    enable_canonical_services
    refresh_previously_running_services

    if [ -x "$(service_file uhttpd)" ]; then
        rm -f -- /tmp/luci-indexcache
        run_service_action uhttpd restart ||
            die "uhttpd restart failed"
    fi

    TRANSACTION_COMMITTED=1
    printf '%s\n' "JamMonitor router files installed successfully."
    printf '%s\n' "Canonical services were enabled."
    printf '%s\n' "Previously running JamMonitor services were refreshed."
    printf '%s\n' "Tailscale was not restarted or authenticated."
}

verify_installed() {
    manifest="/usr/share/jammonitor/router-files.sha256"
    manifest_digest_file="/usr/share/jammonitor/router-files.sha256.sha256"
    source_ref_file="/usr/share/jammonitor/source-ref"
    displayed_ref_file="/www/luci-static/resources/jammonitor.version"
    verify_installed_file_metadata "$manifest" 0644
    verify_installed_file_metadata "$manifest_digest_file" 0644
    verify_installed_file_metadata "$source_ref_file" 0644
    verify_installed_file_metadata "$displayed_ref_file" 0644

    saved_manifest_sha="$(head -n 1 "$manifest_digest_file" | tr -d '\r\n')"
    is_hex_length "$saved_manifest_sha" 64 ||
        die "installed manifest digest is malformed"
    actual_manifest_sha="$(sha256sum "$manifest" | awk '{print $1}')"
    [ "$saved_manifest_sha" = "$actual_manifest_sha" ] ||
        die "installed checksum manifest has changed"

    verify_manifest_shape "$manifest"
    failed=0
    while IFS=' ' read -r expected marker source extra; do
        [ -n "$expected" ] || continue
        if [ -z "${source:-}" ]; then
            source="$marker"
        fi
        target="$(target_for_source "$source")" ||
            die "installed manifest contains an unowned path: $source"
        expected_mode="$(expected_mode_for_source "$source")" ||
            die "installed manifest has no expected mode: $source"
        verify_installed_file_metadata "$target" "$expected_mode"
        actual="$(sha256sum "$target" | awk '{print $1}')"
        if [ "$actual" != "$expected" ]; then
            printf 'MISMATCH %s\n' "$target" >&2
            failed=1
        else
            printf 'OK       %s\n' "$target"
        fi
    done < "$manifest"

    [ "$failed" -eq 0 ] || die "installed file verification failed"
    installed_ref="$(head -n 1 "$source_ref_file" 2>/dev/null |
        tr -d '\r\n')"
    displayed_ref="$(head -n 1 "$displayed_ref_file" 2>/dev/null |
        tr -d '\r\n')"
    [ -n "$installed_ref" ] ||
        die "installed source ref is missing"
    [ "$installed_ref" = "$displayed_ref" ] ||
        die "installed source ref and displayed version differ"
    printf '%s\n' "Installed JamMonitor payloads match the saved manifest."
}

repair_services() {
    [ "$(id -u)" -eq 0 ] || die "--repair-services must run as root"
    refuse_unresolved_recovery_evidence
    # Sysupgrade recovery is allowed to touch enable links only after the
    # complete installed payload set authenticates against its saved manifest.
    prepare_work_dir
    verify_installed
    check_tailscale_prerequisites
    require_command flock
    require_command sqlite3
    require_command conntrack
    legacy_service_is_known
    acquire_install_lock
    capture_service_state

    for service in tailscale jammonitor-history jammonitor-tailscale-watchdog; do
        [ -x "$(service_file "$service")" ] ||
            die "service is missing after sysupgrade: $service"
    done

    TRANSACTION_ACTIVE=1
    backup_transaction_targets
    BACKUP_READY=1
    mkdir -p "$(dirname -- "$MAINTENANCE_FILE")"
    create_maintenance_marker
    MUTATION_STARTED=1
    merge_sysupgrade_preservation
    disable_known_legacy_service
    enable_canonical_services
    if [ "$LEGACY_WAS_RUNNING" -eq 1 ]; then
        run_service_action jammonitor-history restart ||
            die "could not migrate the running legacy collector"
    fi
    TRANSACTION_COMMITTED=1
    printf '%s\n' "Canonical services repaired and enabled."
    printf '%s\n' "Tailscale was not restarted and no login command was run."
}

if [ "$INSTALLER_LIB_ONLY" -eq 1 ]; then
    return 0 2>/dev/null || exit 0
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref)
            [ "$#" -ge 2 ] || die "--ref requires a value"
            [ -z "$REF" ] || die "--ref may be provided only once"
            REF="$2"
            shift 2
            ;;
        --manifest-sha256)
            [ "$#" -ge 2 ] || die "--manifest-sha256 requires a value"
            [ -z "$MANIFEST_SHA256" ] ||
                die "--manifest-sha256 may be provided only once"
            MANIFEST_SHA256="$2"
            shift 2
            ;;
        --source-dir)
            [ "$#" -ge 2 ] || die "--source-dir requires a value"
            [ -z "$SOURCE_DIR" ] ||
                die "a source directory may be provided only once"
            SOURCE_DIR="$2"
            shift 2
            ;;
        --validate-source)
            [ "$#" -ge 2 ] || die "--validate-source requires a value"
            [ "$MODE_EXPLICIT" -eq 0 ] ||
                die "only one operation mode may be selected"
            [ -z "$SOURCE_DIR" ] ||
                die "a source directory may be provided only once"
            MODE="validate"
            MODE_EXPLICIT=1
            SOURCE_DIR="$2"
            shift 2
            ;;
        --verify-installed)
            [ "$MODE_EXPLICIT" -eq 0 ] ||
                die "only one operation mode may be selected"
            MODE="verify"
            MODE_EXPLICIT=1
            shift
            ;;
        --repair-services)
            [ "$MODE_EXPLICIT" -eq 0 ] ||
                die "only one operation mode may be selected"
            MODE="repair"
            MODE_EXPLICIT=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

require_command sha256sum
require_command awk
require_command grep
require_command mktemp
require_command stat
validate_internal_payload_map

case "$MODE" in
    verify)
        [ -z "$REF$MANIFEST_SHA256$SOURCE_DIR" ] ||
            die "--verify-installed does not accept source arguments"
        prepare_work_dir
        verify_installed
        exit 0
        ;;
    repair)
        [ -z "$REF$MANIFEST_SHA256$SOURCE_DIR" ] ||
            die "--repair-services does not accept source arguments"
        repair_services
        exit 0
        ;;
    validate)
        [ -n "$SOURCE_DIR" ] ||
            die "--validate-source requires a directory"
        [ -z "$REF" ] ||
            die "--validate-source does not accept --ref"
        if [ -n "$MANIFEST_SHA256" ]; then
            is_hex_length "$MANIFEST_SHA256" 64 ||
                die "validation manifest pin must be a 64-character SHA256"
            MANIFEST_SHA256="$(printf '%s' "$MANIFEST_SHA256" |
                tr 'A-F' 'a-f')"
        fi
        SOURCE_DIR="$(CDPATH= cd -- "$SOURCE_DIR" && pwd)" ||
            die "validation source directory is not accessible"
        prepare_work_dir
        copy_local_payloads "$SOURCE_DIR"
        verify_local_manifest_pin
        verify_staged_payloads
        validate_staged_payloads
        printf '%s\n' "Staged JamMonitor source passed all available validation."
        exit 0
        ;;
    install)
        ;;
    *)
        die "invalid mode"
        ;;
esac

[ "$(id -u)" -eq 0 ] || die "installation must run as root"
refuse_unresolved_recovery_evidence
if [ -n "$SOURCE_DIR" ]; then
    [ -z "$REF" ] ||
        die "--source-dir cannot be combined with --ref"
    if [ -n "$MANIFEST_SHA256" ]; then
        is_hex_length "$MANIFEST_SHA256" 64 ||
            die "local manifest pin must be a 64-character SHA256"
        MANIFEST_SHA256="$(printf '%s' "$MANIFEST_SHA256" | tr 'A-F' 'a-f')"
    fi
    SOURCE_DIR="$(CDPATH= cd -- "$SOURCE_DIR" && pwd)" ||
        die "local source directory is not accessible"
    REF="local-staged"
else
    is_hex_length "$REF" 40 ||
        die "remote mode requires a full 40-character Git commit"
    is_hex_length "$MANIFEST_SHA256" 64 ||
        die "remote mode requires the trusted manifest SHA256"
    REF="$(printf '%s' "$REF" | tr 'A-F' 'a-f')"
    MANIFEST_SHA256="$(printf '%s' "$MANIFEST_SHA256" | tr 'A-F' 'a-f')"
fi

check_runtime_prerequisites
acquire_install_lock
prepare_work_dir

if [ -n "$SOURCE_DIR" ]; then
    copy_local_payloads "$SOURCE_DIR"
    verify_local_manifest_pin
else
    download_remote_payloads
fi

verify_staged_payloads
validate_staged_payloads
legacy_service_is_known
capture_service_state
install_payloads
