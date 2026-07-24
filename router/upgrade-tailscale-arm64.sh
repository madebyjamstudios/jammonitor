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
STATUS_ATTEMPTS="${TS_UPGRADE_STATUS_ATTEMPTS:-20}"
STATUS_DELAY="${TS_UPGRADE_STATUS_DELAY:-2}"
STATUS_TIMEOUT="${TS_UPGRADE_STATUS_TIMEOUT:-5}"
SERVICE_TIMEOUT="${TS_UPGRADE_SERVICE_TIMEOUT:-30}"
QUIESCE_ATTEMPTS="${TS_UPGRADE_QUIESCE_ATTEMPTS:-10}"
QUIESCE_DELAY="${TS_UPGRADE_QUIESCE_DELAY:-1}"
TMP_BASE="${TS_UPGRADE_TMPDIR:-/tmp}"
PROC_ROOT="${TS_UPGRADE_PROC_ROOT:-/proc}"

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
    [ "$STATUS_ATTEMPTS" = "20" ] &&
    [ "$STATUS_DELAY" = "2" ] &&
    [ "$STATUS_TIMEOUT" = "5" ] &&
    [ "$SERVICE_TIMEOUT" = "30" ] &&
    [ "$QUIESCE_ATTEMPTS" = "10" ] &&
    [ "$QUIESCE_DELAY" = "1" ] &&
    [ "$PROC_ROOT" = "/proc" ] &&
    [ "$TMP_BASE" = "/tmp" ] ||
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
STATE_FILE="$(rooted /etc/tailscale/tailscaled.state)"
SOCKET_FILE="$(rooted /var/run/tailscale/tailscaled.sock)"
RUNTIME_DIR="$(rooted /var/run/jammonitor)"
MAINTENANCE_FILE="$RUNTIME_DIR/tailscale-maintenance"
INSTALL_LOCK="$RUNTIME_DIR/router-install.lock"

WORK_DIR=""
BACKUP_DIR=""
TARGET_TEMP=""
INSTALL_LOCK_HELD=0
MAINTENANCE_CREATED=0
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
STOP_REQUESTED=0
QUIESCENCE_PROVEN=0
BACKUP_READY=0
MUTATION_STARTED=0
ROLLBACK_INCOMPLETE=0
PRESERVE_WORK_DIR=0
RECOVERY_EVIDENCE="$RUNTIME_DIR/tailscale-upgrade-rollback-failed"

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

is_tailscale_ip() {
    candidate="${1:-}"
    case "$candidate" in
        *:*)
            candidate="$(printf '%s' "$candidate" | tr 'A-F' 'a-f')"
            case "$candidate" in
                fd7a:115c:a1e0:*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *.*)
            old_ifs="$IFS"
            IFS=.
            set -- $candidate
            IFS="$old_ifs"
            [ "$#" -eq 4 ] || return 1
            for octet in "$@"; do
                is_uint "$octet" && [ "$octet" -le 255 ] || return 1
            done
            [ "$1" -eq 100 ] &&
                [ "$2" -ge 64 ] &&
                [ "$2" -le 127 ]
            ;;
        *)
            return 1
            ;;
    esac
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

json_value() {
    file="$1"
    expression="$2"
    "$JSONFILTER_CMD" -i "$file" -e "$expression" 2>/dev/null |
        head -n 1
}

query_status() {
    output="$1"
    : > "$output"
    if "$TIMEOUT_CMD" "$STATUS_TIMEOUT" "$TAILSCALE_BIN" \
        --socket="$SOCKET_FILE" status --json --peers=false \
        >"$output" 2>/dev/null; then
        status_rc=0
    else
        status_rc=$?
    fi

    case "$status_rc" in
        124|137|143) return 1 ;;
    esac
    [ "$status_rc" -eq 0 ] || return 1
    [ -s "$output" ] || return 1

    OBSERVED_BACKEND="$(json_value "$output" '@.BackendState')"
    OBSERVED_VERSION="$(json_value "$output" '@.Version')"
    OBSERVED_STABLE_ID="$(json_value "$output" '@.Self.ID')"
    OBSERVED_TUN="$(json_value "$output" '@.TUN')"
    OBSERVED_IN_ENGINE="$(json_value "$output" '@.Self.InEngine')"
    OBSERVED_TAILSCALE_IP="$(json_value "$output" '@.Self.TailscaleIPs[0]')"
    [ -n "$OBSERVED_BACKEND" ] || return 1
}

status_has_required_semantics() {
    expected="$1"
    [ -n "$OBSERVED_STABLE_ID" ] || return 1
    case "$expected" in
        Running)
            [ "$OBSERVED_BACKEND" = "Running" ] &&
                [ "$OBSERVED_TUN" = "true" ] &&
                [ "$OBSERVED_IN_ENGINE" = "true" ] &&
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

service_command() {
    action="$1"
    "$TIMEOUT_CMD" "$SERVICE_TIMEOUT" "$INIT_SCRIPT" "$action" \
        >/dev/null 2>&1
}

service_reports_inactive() {
    if service_command running; then
        return 1
    else
        service_rc=$?
    fi
    [ "$service_rc" -eq 1 ]
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
    target_dir="$(dirname -- "$target")"

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
        if query_status "$status_file" &&
           status_has_required_semantics "$expected" &&
           [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ]; then
            case "$OBSERVED_VERSION" in
                "$TARGET_VERSION"|"$TARGET_VERSION"-*)
                    [ "$(sha256_file "$TAILSCALE_BIN")" = "$NEW_CLI_SHA256" ] &&
                        [ "$(sha256_file "$TAILSCALED_BIN")" = "$NEW_DAEMON_SHA256" ] &&
                        return 0
                    ;;
            esac
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
        if query_status "$status_file" &&
           status_has_required_semantics "$expected" &&
           [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ]; then
            if [ -z "$PRE_DAEMON_VERSION" ] ||
               [ "$OBSERVED_VERSION" = "$PRE_DAEMON_VERSION" ]; then
                [ "$(sha256_file "$TAILSCALE_BIN")" = "$PRE_CLI_SHA256" ] &&
                    [ "$(sha256_file "$TAILSCALED_BIN")" = "$PRE_DAEMON_SHA256" ] &&
                    return 0
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

mark_rollback_incomplete() {
    ROLLBACK_INCOMPLETE=1
    PRESERVE_WORK_DIR=1
    bundle_evidence="$WORK_DIR/ROLLBACK_INCOMPLETE"
    {
        printf 'status=rollback_incomplete\n'
        printf 'recovery_bundle=%s\n' "$WORK_DIR"
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
        "$WORK_DIR" >&2
    printf 'CRITICAL: Do not retry automatically; inspect %s\n' \
        "$RECOVERY_EVIDENCE" >&2
}

preupgrade_service_is_restored() {
    status_file="$WORK_DIR/preupgrade-restored.json"
    query_status "$status_file" &&
        status_has_required_semantics "$PRE_BACKEND_STATE" &&
        [ "$OBSERVED_STABLE_ID" = "$PRE_STABLE_ID" ] &&
        [ "$OBSERVED_VERSION" = "$PRE_DAEMON_VERSION" ]
}

rollback_upgrade() {
    [ "$TRANSACTION_ACTIVE" -eq 1 ] || return 0
    [ "$TRANSACTION_COMMITTED" -eq 0 ] || return 0

    warn "upgrade transaction failed; restoring the previous verified state"
    rollback_failed=0

    if [ "$MUTATION_STARTED" -eq 1 ]; then
        QUIESCENCE_PROVEN=0
        if ! service_command stop || ! wait_for_quiescence; then
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

    if [ "$MUTATION_STARTED" -eq 0 ] || [ "$rollback_failed" -eq 0 ]; then
        if is_quiescent; then
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

    if [ "$rollback_failed" -ne 0 ]; then
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
        rm -f -- "$MAINTENANCE_FILE"
    fi
    if [ -n "$TARGET_TEMP" ]; then
        rm -f -- "$TARGET_TEMP"
    fi
    if [ "$INSTALL_LOCK_HELD" -eq 1 ]; then
        rm -f -- "$INSTALL_LOCK/pid"
        rmdir "$INSTALL_LOCK" 2>/dev/null || true
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
    mkdir -p "$RUNTIME_DIR"
    chmod 0700 "$RUNTIME_DIR"
    if mkdir "$INSTALL_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$INSTALL_LOCK/pid"
        INSTALL_LOCK_HELD=1
        return 0
    fi

    lock_pid="$(cat "$INSTALL_LOCK/pid" 2>/dev/null || true)"
    if is_uint "$lock_pid" && kill -0 "$lock_pid" 2>/dev/null; then
        die "another JamMonitor install or Tailscale upgrade is running"
    fi

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
        return 0
    fi

    expires_epoch=$((now_epoch + required_remaining))
    printf '%s\n' "$expires_epoch" > "$MAINTENANCE_FILE" ||
        die "could not create the maintenance marker"
    MAINTENANCE_CREATED=1
    chmod 0600 "$MAINTENANCE_FILE" ||
        die "could not protect the maintenance marker"
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

    if [ -n "$PACKAGE_SOURCE_DIR" ]; then
        cp -- "$PACKAGE_SOURCE_DIR/$(basename -- "$url")" "$output"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -q -O "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --proto '=https' --tlsv1.2 "$url" -o "$output"
    else
        die "uclient-fetch, wget, or curl is required"
    fi
}

validate_archive_listing() {
    listing="$WORK_DIR/archive.list"
    tar tzf "$WORK_DIR/$TARGET_ARCHIVE" > "$listing" ||
        die "could not inspect the Tailscale archive"

    while IFS= read -r member; do
        [ -n "$member" ] || continue
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
}

validate_new_binaries() {
    new_cli="$WORK_DIR/extract/$TARGET_DIRECTORY/tailscale"
    new_daemon="$WORK_DIR/extract/$TARGET_DIRECTORY/tailscaled"
    [ -f "$new_cli" ] && [ ! -L "$new_cli" ] ||
        die "extracted tailscale is not a regular file"
    [ -f "$new_daemon" ] && [ ! -L "$new_daemon" ] ||
        die "extracted tailscaled is not a regular file"
    chmod 0755 "$new_cli" "$new_daemon"

    if new_cli_version="$("$TIMEOUT_CMD" 10 "$new_cli" version 2>/dev/null |
        head -n 1 | tr -d '\r\n')"; then
        :
    else
        die "new tailscale binary could not execute"
    fi
    if new_daemon_version="$("$TIMEOUT_CMD" 10 "$new_daemon" --version 2>/dev/null |
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
    fetch_file "$OFFICIAL_BASE_URL/$TARGET_ARCHIVE" "$archive" ||
        die "could not download the pinned Tailscale archive"
    fetch_file "$OFFICIAL_BASE_URL/$TARGET_ARCHIVE.sha256" "$checksum" ||
        die "could not download the official checksum"

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

[ "$#" -eq 0 ] || die "this pinned upgrader accepts no arguments"
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
is_uint "$SERVICE_TIMEOUT" && [ "$SERVICE_TIMEOUT" -gt 0 ] ||
    die "service timeout must be a positive integer"
is_uint "$QUIESCE_ATTEMPTS" && [ "$QUIESCE_ATTEMPTS" -gt 0 ] ||
    die "quiescence attempts must be a positive integer"
is_uint "$QUIESCE_DELAY" ||
    die "quiescence delay must be a nonnegative integer"

require_command "$TIMEOUT_CMD"
require_command "$JSONFILTER_CMD"
require_command awk
require_command grep
require_command tar
require_command mktemp

[ -f "$TAILSCALE_BIN" ] && [ ! -L "$TAILSCALE_BIN" ] &&
[ -x "$TAILSCALE_BIN" ] || die "current tailscale binary is missing or unsafe"
[ -f "$TAILSCALED_BIN" ] && [ ! -L "$TAILSCALED_BIN" ] &&
[ -x "$TAILSCALED_BIN" ] || die "current tailscaled binary is missing or unsafe"
[ -x "$INIT_SCRIPT" ] || die "Tailscale init script is missing"
[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
[ -s "$STATE_FILE" ] || die "Tailscale state file is missing, empty, or unsafe"

umask 077
WORK_DIR="$(mktemp -d "$TMP_BASE/tailscale-upgrade.XXXXXX")"
BACKUP_DIR="$WORK_DIR/backup"
mkdir -p "$BACKUP_DIR"

acquire_install_lock
[ ! -e "$RECOVERY_EVIDENCE" ] && [ ! -L "$RECOVERY_EVIDENCE" ] ||
    die "an unresolved prior rollback failure requires operator recovery"
validate_safe_init

if ! "$INIT_SCRIPT" running >/dev/null 2>&1; then
    die "Tailscale service is not running"
fi

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
[ -n "$PRE_DAEMON_VERSION" ] ||
    die "pre-upgrade daemon version is missing"
PRE_CLI_SHA256="$(sha256_file "$TAILSCALE_BIN")"
PRE_DAEMON_SHA256="$(sha256_file "$TAILSCALED_BIN")"
is_sha256 "$PRE_CLI_SHA256" &&
    is_sha256 "$PRE_DAEMON_SHA256" ||
    die "could not hash the pre-upgrade binaries"

if current_cli_version="$("$TIMEOUT_CMD" 10 "$TAILSCALE_BIN" version 2>/dev/null |
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
    "$TIMEOUT_CMD" 10 "$TAILSCALED_BIN" --version 2>/dev/null |
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
cp -p -- "$TAILSCALE_BIN" "$BACKUP_DIR/tailscale"
cp -p -- "$TAILSCALED_BIN" "$BACKUP_DIR/tailscaled"
cp -p -- "$STATE_FILE" "$BACKUP_DIR/tailscaled.state"
chmod 0700 "$BACKUP_DIR/tailscale" "$BACKUP_DIR/tailscaled"
chmod 0600 "$BACKUP_DIR/tailscaled.state"
[ "$(sha256_file "$BACKUP_DIR/tailscale")" = "$PRE_CLI_SHA256" ] &&
    [ "$(sha256_file "$BACKUP_DIR/tailscaled")" = "$PRE_DAEMON_SHA256" ] &&
    [ "$(sha256_file "$BACKUP_DIR/tailscaled.state")" = "$PRE_STATE_SHA256" ] ||
    die "verified pre-upgrade backup could not be created"
BACKUP_READY=1

MUTATION_STARTED=1
atomic_install "$WORK_DIR/extract/$TARGET_DIRECTORY/tailscale" \
    "$TAILSCALE_BIN" 0755 ||
    die "could not atomically install tailscale"
atomic_install "$WORK_DIR/extract/$TARGET_DIRECTORY/tailscaled" \
    "$TAILSCALED_BIN" 0755 ||
    die "could not atomically install tailscaled"
[ "$(sha256_file "$TAILSCALE_BIN")" = "$NEW_CLI_SHA256" ] &&
    [ "$(sha256_file "$TAILSCALED_BIN")" = "$NEW_DAEMON_SHA256" ] ||
    die "installed Tailscale binary hashes differ from the verified package"

service_command start ||
    die "Tailscale service did not start within the bounded timeout"
wait_for_expected_state "$PRE_BACKEND_STATE" ||
    die "post-upgrade BackendState or daemon version verification failed"

[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] && [ -s "$STATE_FILE" ] ||
    die "Tailscale state file disappeared during upgrade"
[ -n "$OBSERVED_STABLE_ID" ] ||
    die "post-upgrade StableID is missing"
if [ "$OBSERVED_STABLE_ID" != "$PRE_STABLE_ID" ]; then
    die "Tailscale stable node identity changed during upgrade"
fi

TRANSACTION_COMMITTED=1
if [ "$PRE_BACKEND_STATE" = "Running" ]; then
    printf 'Tailscale %s installed; strict delivery checks remained Running.\n' \
        "$TARGET_VERSION"
else
    printf 'Tailscale %s installed; BackendState remains NeedsLogin and operator authentication is still required.\n' \
        "$TARGET_VERSION"
fi
