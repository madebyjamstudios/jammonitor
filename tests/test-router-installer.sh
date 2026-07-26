#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/router/install-jammonitor-router.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jammonitor-installer-test.XXXXXX")"
TEST_COUNT=0
FAIL_COUNT=0

cleanup_test_root() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup_test_root EXIT HUP INT TERM

JAMMONITOR_INSTALL_TESTING=1
JAMMONITOR_INSTALL_LIB_ONLY=1
export JAMMONITOR_INSTALL_TESTING JAMMONITOR_INSTALL_LIB_ONLY
# shellcheck source=/dev/null
. "$INSTALLER"

TEST_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_BIN"
cat >"$TEST_BIN/flock" <<'PY'
#!/usr/bin/env python3
import fcntl
import sys

if sys.argv[1:] != ["-n", "7"]:
    raise SystemExit(2)
try:
    fcntl.flock(7, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
PY
chmod 0755 "$TEST_BIN/flock"
cat >"$TEST_BIN/jsonfilter" <<'PY'
#!/usr/bin/env python3
import json
import sys

args = sys.argv[1:]
try:
    input_path = args[args.index("-i") + 1]
    if "-e" in args:
        operation = "value"
        expression = args[args.index("-e") + 1]
    else:
        operation = "type"
        expression = args[args.index("-t") + 1]
    with open(input_path, "r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not expression.startswith("@."):
        raise ValueError
    for component in expression[2:].split("."):
        value = value[component]
except (OSError, ValueError, KeyError, IndexError, json.JSONDecodeError):
    raise SystemExit(1)

if operation == "type":
    if value is None:
        print("null")
    elif isinstance(value, bool):
        print("boolean")
    elif isinstance(value, int):
        print("int")
    elif isinstance(value, str):
        print("string")
    elif isinstance(value, list):
        print("array")
    elif isinstance(value, dict):
        print("object")
    else:
        raise SystemExit(1)
elif value is None:
    print("null")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
chmod 0755 "$TEST_BIN/jsonfilter"
PATH="$TEST_BIN:$PATH"
export PATH

# The production target is BusyBox/GNU stat. Adapt its exact query for the
# BSD stat shipped on macOS so the transaction tests remain host-independent.
if ! command -v sha256sum >/dev/null 2>&1; then
    sha256sum() {
        LC_ALL=C LANG=C /usr/bin/shasum -a 256 "$@"
    }
fi
if ! /usr/bin/stat -c '%a:%u:%g' "$INSTALLER" >/dev/null 2>&1; then
    stat() {
        [ "$1" = "-c" ] || return 2
        stat_format="$2"
        shift 2
        case "$stat_format" in
            '%a:%u:%g') /usr/bin/stat -f '%Lp:%u:%g' "$1" ;;
            '%u:%g:%a:%h') /usr/bin/stat -f '%u:%g:%Lp:%l' "$1" ;;
            '%u:%g:%a') /usr/bin/stat -f '%u:%g:%Lp' "$1" ;;
            '%u:%g:%a:%h:%s:%d:%i')
                /usr/bin/stat -f '%u:%g:%Lp:%l:%z:%d:%i' "$1"
                ;;
            '%u:%g') /usr/bin/stat -f '%u:%g' "$1" ;;
            '%a') /usr/bin/stat -f '%Lp' "$1" ;;
            *) return 2 ;;
        esac
    }
fi

# Production deliberately flushes the overlay filesystem at every recovery
# boundary. Unit tests record or no-op those calls instead of syncing the host.
sync() {
    :
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    printf 'ok %s - %s\n' "$TEST_COUNT" "$1"
}

fail() {
    TEST_COUNT=$((TEST_COUNT + 1))
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'not ok %s - %s\n' "$TEST_COUNT" "$1"
}

read_backup_record_and_restore() {
    record="$(tail -n 1 "$BACKUP_INDEX")"
    old_ifs="$IFS"
    IFS='|'
    # The test paths and proofs deliberately contain no shell metacharacters
    # or whitespace. Production parsing remains the line-oriented read loop.
    set -- $record
    IFS="$old_ifs"
    restore_target "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}"
}

setup_transaction() {
    case_name="$1"
    WORK_DIR="/tmp/jammonitor-install.test-$case_name-$$"
    rm -rf -- "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    TRANSACTION_ACTIVE=0
    TRANSACTION_COMMITTED=0
    BACKUP_READY=0
    RECOVERY_BUNDLE_CREATED=0
    MUTATION_STARTED=0
    ROLLBACK_INCOMPLETE=0
    PRESERVE_WORK_DIR=0
    MAINTENANCE_CREATED=0
    MAINTENANCE_EXPECTED_EXPIRY=""
    MAINTENANCE_TEMP=""
    LEGACY_WAS_PRESENT=0
    LEGACY_WAS_RUNNING=0
    HISTORY_WAS_PRESENT=0
    HISTORY_WAS_RUNNING=0
    WATCHDOG_WAS_PRESENT=0
    WATCHDOG_WAS_RUNNING=0
    TAILSCALE_WAS_PRESENT=0
    TAILSCALE_WAS_RUNNING=0
    UHTTPD_WAS_PRESENT=0
    UHTTPD_WAS_RUNNING=0
    RECOVERY_PARENT="$TEST_ROOT/$case_name/jammonitor"
    RECOVERY_ROOT="$RECOVERY_PARENT/recovery"
    RECOVERY_BUNDLE="$RECOVERY_ROOT/active"
    RECOVERY_EVIDENCE="$RECOVERY_ROOT/UNRESOLVED"
    INSTALL_FENCE="$RECOVERY_PARENT/install-transaction"
    INSTALL_FENCE_TEMP=""
    INSTALL_FENCE_TOKEN=""
    INSTALL_FENCE_SHA256=""
    INSTALL_FENCE_CREATED=0
    RECOVERY_EXPECTED_UID="$(id -u)"
    RECOVERY_EXPECTED_GID="$(id -g)"
    MAINTENANCE_FILE="$TEST_ROOT/$case_name/maintenance"
    mkdir -p "$TEST_ROOT/$case_name/live"
    prepare_recovery_bundle
}

test_atomic_regular_restore() {
    (
        setup_transaction regular
        target="$TEST_ROOT/regular/live/payload"
        printf 'original\n' > "$target"
        chmod 0600 "$target"
        backup_target "$target"
        printf 'replacement\n' > "$target"
        chmod 0644 "$target"
        read_backup_record_and_restore
        [ "$(cat "$target")" = "original" ] &&
            [ "$(stat -c '%a:%u:%g' "$target")" = \
              "$(stat -c '%a:%u:%g' "$BACKUP_ROOT$target")" ]
    ) && pass "regular-file rollback is atomic and proof-verified" ||
        fail "regular-file rollback is atomic and proof-verified"
}

test_atomic_symlink_and_absent_restore() {
    (
        setup_transaction link
        target="$TEST_ROOT/link/live/service-link"
        ln -s ../original "$target"
        backup_target "$target"
        rm -f -- "$target"
        ln -s ../replacement "$target"
        read_backup_record_and_restore
        [ "$(readlink "$target")" = "../original" ]

        absent="$TEST_ROOT/link/live/was-absent"
        backup_target "$absent"
        printf 'new\n' > "$absent"
        read_backup_record_and_restore
        [ ! -e "$absent" ] && [ ! -L "$absent" ]
    ) && pass "symlink and originally-absent targets restore exactly" ||
        fail "symlink and originally-absent targets restore exactly"
}

test_failed_copy_preserves_current_target() {
    (
        setup_transaction copyfail
        target="$TEST_ROOT/copyfail/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        printf 'current-must-survive\n' > "$target"
        record="$(tail -n 1 "$BACKUP_INDEX")"
        old_ifs="$IFS"
        IFS='|'
        set -- $record
        IFS="$old_ifs"
        cp() {
            return 1
        }
        if restore_target "${1:-}" "${2:-}" "${3:-}" \
            "${4:-}" "${5:-}"; then
            exit 1
        fi
        [ "$(cat "$target")" = "current-must-survive" ]
    ) && pass "failed restore staging never unlinks the current target" ||
        fail "failed restore staging never unlinks the current target"
}

test_tampered_backup_is_refused() {
    (
        setup_transaction tampered
        target="$TEST_ROOT/tampered/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        printf 'current-must-survive\n' > "$target"
        printf 'corrupt\n' > "$BACKUP_ROOT$target"
        if read_backup_record_and_restore; then
            exit 1
        fi
        [ "$(cat "$target")" = "current-must-survive" ]
    ) && pass "a corrupted recovery copy cannot overwrite the live target" ||
        fail "a corrupted recovery copy cannot overwrite the live target"
}

test_rollback_aggregates_file_failures() {
    (
        setup_transaction aggregate-files
        first="$TEST_ROOT/aggregate-files/live/first"
        second="$TEST_ROOT/aggregate-files/live/second"
        printf 'first-original\n' > "$first"
        printf 'second-original\n' > "$second"
        backup_target "$first"
        backup_target "$second"
        printf 'first-new\n' > "$first"
        printf 'second-new\n' > "$second"
        rm -f -- "$BACKUP_ROOT$first"
        TRANSACTION_ACTIVE=1
        BACKUP_READY=1
        MUTATION_STARTED=1
        if rollback_transaction >"$TEST_ROOT/aggregate-files/output" 2>&1; then
            exit 1
        fi
        [ "$(cat "$first")" = "first-new" ] &&
            [ "$(cat "$second")" = "second-original" ] &&
            [ -f "$RECOVERY_EVIDENCE" ] &&
            [ -f "$RECOVERY_BUNDLE/ROLLBACK_INCOMPLETE" ] &&
            [ "$ROLLBACK_INCOMPLETE" -eq 1 ] &&
            [ "$PRESERVE_WORK_DIR" -eq 0 ] &&
            grep -Fqx "recovery_bundle=$RECOVERY_BUNDLE" \
                "$RECOVERY_EVIDENCE" &&
            grep -Fq "CRITICAL: JamMonitor rollback is incomplete" \
                "$TEST_ROOT/aggregate-files/output"
        : > "$MAINTENANCE_FILE"
        MAINTENANCE_CREATED=1
        TRANSACTION_ACTIVE=0
        (cleanup)
        [ ! -d "$WORK_DIR" ] &&
            [ -d "$RECOVERY_BUNDLE" ] &&
            [ -f "$MAINTENANCE_FILE" ]
    ) && pass "rollback continues after a target failure and preserves evidence" ||
        fail "rollback continues after a target failure and preserves evidence"
}

test_rollback_aggregates_service_failures() {
    (
        setup_transaction aggregate-services
        live_target="$TEST_ROOT/aggregate-services/live/payload"
        printf 'original\n' > "$live_target"
        backup_target "$live_target"
        printf 'new\n' > "$live_target"
        TRANSACTION_ACTIVE=1
        BACKUP_READY=1
        MUTATION_STARTED=1
        TAILSCALE_WAS_PRESENT=1
        HISTORY_WAS_PRESENT=1
        LEGACY_WAS_PRESENT=1
        WATCHDOG_WAS_PRESENT=1
        UHTTPD_WAS_PRESENT=1
        service_log="$TEST_ROOT/aggregate-services/services"
        restore_service_runtime() {
            printf '%s\n' "$1" >> "$service_log"
            case "$1" in
                tailscale|jammonitor-tailscale-watchdog)
                    return 1
                    ;;
                *)
                    return 0
                    ;;
            esac
        }
        if rollback_transaction >"$TEST_ROOT/aggregate-services/output" 2>&1; then
            exit 1
        fi
        [ "$(cat "$live_target")" = "original" ] &&
            [ "$(wc -l < "$service_log" | tr -d ' ')" -eq 5 ] &&
            grep -Fqx tailscale "$service_log" &&
            grep -Fqx jammonitor-history "$service_log" &&
            grep -Fqx jammonitor-collect "$service_log" &&
            grep -Fqx jammonitor-tailscale-watchdog "$service_log" &&
            grep -Fqx uhttpd "$service_log" &&
            [ -f "$RECOVERY_EVIDENCE" ]
    ) && pass "rollback aggregates every service restoration failure" ||
        fail "rollback aggregates every service restoration failure"
}

make_transient_history_init() {
    init_path="$1"
    state_path="$2"
    actions_path="$3"
    stop_rc="$4"
    cat > "$init_path" <<EOF
#!/bin/sh
case "\${1:-}" in
    running)
        [ "\$(cat "$state_path")" = "running" ]
        ;;
    stop)
        printf '%s\n' stop >> "$actions_path"
        [ "$stop_rc" -eq 0 ] || exit "$stop_rc"
        printf '%s\n' stopped > "$state_path"
        ;;
    *)
        exit 2
        ;;
esac
EOF
    chmod 0755 "$init_path"
}

test_transient_migration_daemon_is_fail_safe() {
    if (
        setup_transaction transient-stop
        INIT_DIR="$TEST_ROOT/transient-stop/live/init.d"
        mkdir -p "$INIT_DIR"
        transient_init="$INIT_DIR/jammonitor-history"
        transient_state="$TEST_ROOT/transient-stop/state"
        transient_actions="$TEST_ROOT/transient-stop/actions"
        backup_target "$transient_init"
        printf '%s\n' running > "$transient_state"
        : > "$transient_actions"
        make_transient_history_init \
            "$transient_init" "$transient_state" "$transient_actions" 0
        timeout() {
            [ "$1" = "-s" ] && [ "$2" = "TERM" ] &&
                [ "$3" = "-k" ] && [ "$4" = "2" ] || return 90
            shift 4
            shift
            "$@"
        }
        LEGACY_WAS_RUNNING=1
        TRANSACTION_ACTIVE=1
        BACKUP_READY=1
        MUTATION_STARTED=1
        rollback_transaction >/dev/null 2>&1
        [ "$(cat "$transient_state")" = "stopped" ] &&
            [ "$(cat "$transient_actions")" = "stop" ] &&
            [ ! -e "$transient_init" ] &&
            [ ! -e "$RECOVERY_EVIDENCE" ]
    ) && (
        setup_transaction transient-fail
        INIT_DIR="$TEST_ROOT/transient-fail/live/init.d"
        mkdir -p "$INIT_DIR"
        transient_init="$INIT_DIR/jammonitor-history"
        transient_state="$TEST_ROOT/transient-fail/state"
        transient_actions="$TEST_ROOT/transient-fail/actions"
        backup_target "$transient_init"
        printf '%s\n' running > "$transient_state"
        : > "$transient_actions"
        make_transient_history_init \
            "$transient_init" "$transient_state" "$transient_actions" 9
        timeout() {
            [ "$1" = "-s" ] && [ "$2" = "TERM" ] &&
                [ "$3" = "-k" ] && [ "$4" = "2" ] || return 90
            shift 4
            shift
            "$@"
        }
        LEGACY_WAS_RUNNING=1
        TRANSACTION_ACTIVE=1
        BACKUP_READY=1
        MUTATION_STARTED=1
        if rollback_transaction >/dev/null 2>&1; then
            exit 1
        fi
        [ -x "$transient_init" ] &&
            [ -f "$RECOVERY_EVIDENCE" ] &&
            [ -f "$RECOVERY_BUNDLE/ROLLBACK_INCOMPLETE" ]
    ); then
        pass "transient migration daemons stop first or retain a recovery control"
    else
        fail "transient migration daemons stop first or retain a recovery control"
    fi
}

test_maintenance_window_is_calculated() {
    (
        setup_transaction lease
        now="$(date +%s)"
        short_expiry=$((now + MAINTENANCE_REQUIRED_REMAINING - 1))
        printf '%s\n' "$short_expiry" > "$MAINTENANCE_FILE"
        chmod 0600 "$MAINTENANCE_FILE"
        if (create_maintenance_marker) >"$TEST_ROOT/lease/short-output" 2>&1; then
            exit 1
        fi
        grep -Fq "calculated install and rollback window" \
            "$TEST_ROOT/lease/short-output"
        rm -f -- "$MAINTENANCE_FILE"
        create_maintenance_marker
        actual_expiry="$(cat "$MAINTENANCE_FILE")"
        actual_window=$((actual_expiry - now))
        [ "$MAINTENANCE_REQUIRED_REMAINING" -gt 120 ] &&
            [ "$actual_window" -ge "$MAINTENANCE_REQUIRED_REMAINING" ] &&
            [ "$actual_window" -le $((MAINTENANCE_REQUIRED_REMAINING + 2)) ] &&
            [ "$(stat -c '%a' "$MAINTENANCE_FILE")" = "600" ] &&
            ! find "$TEST_ROOT/lease" -name 'maintenance.tmp.*' \
                -print -quit | grep -q .
    ) && pass "maintenance lease covers calculated forward and rollback budgets" ||
        fail "maintenance lease covers calculated forward and rollback budgets"
}

test_maintenance_cleanup_is_owner_checked() {
    (
        setup_transaction lease-owner
        create_maintenance_marker
        replacement="$((MAINTENANCE_EXPECTED_EXPIRY + 1))"
        printf '%s\n' "$replacement" >"$MAINTENANCE_FILE"
        chmod 0600 "$MAINTENANCE_FILE"
        if remove_owned_maintenance_marker >/dev/null 2>&1; then
            exit 1
        fi
        [ "$(cat "$MAINTENANCE_FILE")" = "$replacement" ]
    ) && pass "maintenance cleanup preserves a replaced owner lease" ||
        fail "maintenance cleanup preserves a replaced owner lease"
}

test_interrupted_transaction_persists_and_blocks_retry() {
    (
        setup_transaction interrupted
        target="$TEST_ROOT/interrupted/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        REF="0123456789012345678901234567890123456789"
        VERIFIED_MANIFEST_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        seal_recovery_bundle
        begin_live_mutation

        # Simulate an untrappable interruption: do not invoke rollback or
        # cleanup, discard every volatile transaction flag, and inspect only
        # the persistent paths a later invocation would see.
        RECOVERY_BUNDLE_CREATED=0
        TRANSACTION_ACTIVE=0
        BACKUP_READY=0
        MUTATION_STARTED=0
        [ -f "$RECOVERY_BUNDLE/READY" ] &&
            [ -f "$RECOVERY_BUNDLE/backup$target" ] &&
            grep -Fqx 'status=mutation_started' \
                "$RECOVERY_BUNDLE/STATUS" &&
            grep -Fqx "recovery_bundle=$RECOVERY_BUNDLE" \
                "$RECOVERY_EVIDENCE"
        if (refuse_unresolved_recovery_evidence) \
            >"$TEST_ROOT/interrupted/retry-output" 2>&1; then
            exit 1
        fi
        grep -Fq "unresolved prior installer transaction" \
            "$TEST_ROOT/interrupted/retry-output"
        rm -f -- "$RECOVERY_EVIDENCE"
        if (refuse_unresolved_recovery_evidence) \
            >"$TEST_ROOT/interrupted/partial-output" 2>&1; then
            exit 1
        fi
        grep -Fq "unresolved prior installer transaction" \
            "$TEST_ROOT/interrupted/partial-output"
    ) && pass "write-ahead recovery survives interruption and blocks retry" ||
        fail "write-ahead recovery survives interruption and blocks retry"
}

test_write_ahead_sync_precedes_mutation() {
    (
        sync_log="$TEST_ROOT/write-ahead-sync.log"
        sync() {
            printf 'sync\n' >> "$sync_log"
        }
        setup_transaction write-ahead
        : > "$sync_log"
        target="$TEST_ROOT/write-ahead/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        seal_recovery_bundle
        [ "$(wc -l < "$sync_log" | tr -d ' ')" -ge 2 ] &&
            [ -f "$RECOVERY_BUNDLE/READY" ] &&
            grep -Fqx 'status=ready' "$RECOVERY_BUNDLE/STATUS"
        : > "$sync_log"
        begin_live_mutation
        [ -s "$sync_log" ] &&
            grep -Fqx 'status=mutation_started' \
                "$RECOVERY_BUNDLE/STATUS"
    ) && (
        sync() {
            :
        }
        setup_transaction sync-failure
        target="$TEST_ROOT/sync-failure/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        seal_recovery_bundle
        sync() {
            return 1
        }
        if (begin_live_mutation) \
            >"$TEST_ROOT/sync-failure/output" 2>&1; then
            exit 1
        fi
        [ "$MUTATION_STARTED" -eq 0 ] &&
            [ "$(cat "$target")" = "original" ] &&
            grep -Fq "could not synchronize persistent recovery storage" \
                "$TEST_ROOT/sync-failure/output"
    ) && pass "verified recovery data is synchronized before mutation" ||
        fail "verified recovery data is synchronized before mutation"
}

test_recovery_cleanup_is_exact() {
    (
        setup_transaction exact-cleanup
        sibling="$RECOVERY_ROOT/operator-note"
        printf 'keep\n' > "$sibling"
        target="$TEST_ROOT/exact-cleanup/live/payload"
        printf 'original\n' > "$target"
        backup_target "$target"
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        seal_recovery_bundle
        clear_recovery_bundle
        [ ! -e "$RECOVERY_BUNDLE" ] &&
            [ ! -L "$RECOVERY_BUNDLE" ] &&
            [ ! -e "$RECOVERY_EVIDENCE" ] &&
            [ "$(cat "$sibling")" = "keep" ] &&
            [ -d "$RECOVERY_ROOT" ] &&
            [ ! -L "$RECOVERY_ROOT" ]
    ) && (
        sync() {
            :
        }
        setup_transaction cleanup-sync-failure
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        seal_recovery_bundle
        sync() {
            return 1
        }
        if clear_recovery_bundle; then
            exit 1
        fi
        [ -d "$RECOVERY_BUNDLE" ] &&
            [ -f "$RECOVERY_EVIDENCE" ]
    ) && pass "successful cleanup removes only the exact active bundle" ||
        fail "successful cleanup removes only the exact active bundle"
}

test_recovery_symlink_is_refused() {
    (
        case_root="$TEST_ROOT/recovery-symlink"
        mkdir -p "$case_root/real"
        ln -s "$case_root/real" "$case_root/jammonitor"
        RECOVERY_PARENT="$case_root/jammonitor"
        RECOVERY_ROOT="$RECOVERY_PARENT/recovery"
        RECOVERY_BUNDLE="$RECOVERY_ROOT/active"
        RECOVERY_EVIDENCE="$RECOVERY_ROOT/UNRESOLVED"
        RECOVERY_EXPECTED_UID="$(id -u)"
        RECOVERY_EXPECTED_GID="$(id -g)"
        if (refuse_unresolved_recovery_evidence) \
            >"$case_root/output" 2>&1; then
            exit 1
        fi
        grep -Fq "not an owned non-symlink directory" "$case_root/output"
    ) && pass "recovery storage refuses symbolic-link path components" ||
        fail "recovery storage refuses symbolic-link path components"
}

test_installer_boot_fence_is_durable_and_owner_checked() {
    if (
        setup_transaction boot-fence
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="$(
            printf '%s' manifest | sha256sum | awk '{print $1}'
        )"
        seal_recovery_bundle
        publish_install_fence
        [ -f "$INSTALL_FENCE" ] &&
            [ ! -L "$INSTALL_FENCE" ] &&
            [ "$(stat -c '%u:%g:%a:%h' "$INSTALL_FENCE")" = \
              "$(id -u):$(id -g):600:1" ] &&
            [ "$(wc -l < "$INSTALL_FENCE" | tr -d ' ')" = "7" ] &&
            grep -Fqx \
                'format=jammonitor-router-install-fence-v1' \
                "$INSTALL_FENCE" &&
            grep -Eq '^token=[0-9a-f]{64}$' "$INSTALL_FENCE" &&
            grep -Fqx 'phase=payload_mutation' "$INSTALL_FENCE" &&
            ! clear_install_fence committed &&
            write_recovery_status committed &&
            clear_install_fence committed &&
            [ ! -e "$INSTALL_FENCE" ] &&
            [ -f "$RECOVERY_EVIDENCE" ] &&
            clear_recovery_bundle
    ) && (
        setup_transaction boot-fence-owner
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="$(
            printf '%s' manifest | sha256sum | awk '{print $1}'
        )"
        seal_recovery_bundle
        publish_install_fence
        replaced="$RECOVERY_PARENT/replaced-fence"
        mv "$INSTALL_FENCE" "$replaced"
        printf 'replacement\n' > "$INSTALL_FENCE"
        chmod 0600 "$INSTALL_FENCE"
        write_recovery_status committed
        if clear_install_fence committed; then
            exit 1
        fi
        [ "$(cat "$INSTALL_FENCE")" = "replacement" ]
    ); then
        pass "installer fence is durable, exact, ordered after recovery, and owner-checked"
    else
        fail "installer fence is durable, exact, ordered after recovery, and owner-checked"
    fi
}

test_all_boot_services_enforce_the_same_install_fence() {
    if (
        setup_transaction shared-init-gate
        REF="local-staged"
        VERIFIED_MANIFEST_SHA256="$(
            printf '%s' manifest | sha256sum | awk '{print $1}'
        )"
        seal_recovery_bundle
        publish_install_fence
        begin_live_mutation
        expected_token="$INSTALL_FENCE_TOKEN"
        rewritten_fence="$INSTALL_FENCE.rewritten"
        sed "s|/etc/jammonitor/recovery/active|$RECOVERY_BUNDLE|g" \
            "$INSTALL_FENCE" > "$rewritten_fence"
        chmod 0600 "$rewritten_fence"
        mv "$rewritten_fence" "$INSTALL_FENCE"
        test_uid="$(id -u)"
        test_gid="$(id -g)"

        for init_source in \
            "$REPO_ROOT/router/tailscale.init" \
            "$REPO_ROOT/router/jammonitor-history.init" \
            "$REPO_ROOT/router/jammonitor-tailscale-watchdog.init"
        do
            transformed="$TEST_ROOT/shared-init-gate/$(basename "$init_source")"
            sed \
                -e "s/0:0:600:1/$test_uid:$test_gid:600:1/g" \
                -e "s/0:0:700/$test_uid:$test_gid:700/g" \
                -e "s|/etc/jammonitor/recovery/active|$RECOVERY_BUNDLE|g" \
                "$init_source" > "$transformed"
            (
                # shellcheck source=/dev/null
                . "$transformed"
                INSTALL_FENCE="$RECOVERY_PARENT/install-transaction"
                INSTALL_RECOVERY_ACTIVE="$RECOVERY_BUNDLE"
                INSTALL_RECOVERY_UNRESOLVED="$RECOVERY_EVIDENCE"
                JAMMONITOR_INSTALL_FENCE_TOKEN=""
                if installer_fence_allows_start; then
                    exit 1
                fi
                JAMMONITOR_INSTALL_FENCE_TOKEN="$expected_token"
                installer_fence_allows_start
            ) || exit 1

            mv "$INSTALL_FENCE" "$INSTALL_FENCE.saved"
            (
                # shellcheck source=/dev/null
                . "$transformed"
                INSTALL_FENCE="$RECOVERY_PARENT/install-transaction"
                INSTALL_RECOVERY_ACTIVE="$RECOVERY_BUNDLE"
                INSTALL_RECOVERY_UNRESOLVED="$RECOVERY_EVIDENCE"
                JAMMONITOR_INSTALL_FENCE_TOKEN=""
                installer_fence_allows_start
            ) || exit 1
            mv "$INSTALL_FENCE.saved" "$INSTALL_FENCE"
        done
    ); then
        pass "all boot services reject unattended install fences and allow post-fence residue"
    else
        fail "all boot services reject unattended install fences and allow post-fence residue"
    fi
}

test_timeout_capability_preflight() {
    if (
        timeout_log="$TEST_ROOT/timeout-capability.log"
        timeout() {
            printf '%s\n' "$*" > "$timeout_log"
            return 0
        }
        check_timeout_capability
        grep -Fqx -- '-s TERM -k 2 1 /bin/sh -c :' "$timeout_log"
    ) && (
        timeout() {
            return 2
        }
        if (check_timeout_capability) \
            >"$TEST_ROOT/timeout-capability-fail" 2>&1; then
            exit 1
        fi
        grep -Fq "required -s TERM -k 2 options" \
            "$TEST_ROOT/timeout-capability-fail"
    ); then
        pass "timeout preflight proves TERM and kill-after option support"
    else
        fail "timeout preflight proves TERM and kill-after option support"
    fi
}

test_lua_parser_is_mandatory() {
    (
        parser_path="$TEST_ROOT/no-lua-bin"
        mkdir -p "$parser_path"
        ln -s /bin/sh "$parser_path/sh"
        ln -s /usr/bin/grep "$parser_path/grep"
        STAGE_ROOT="$REPO_ROOT"
        PATH="$parser_path"
        export PATH
        if (validate_staged_payloads) \
            >"$TEST_ROOT/no-lua-output" 2>&1; then
            exit 1
        fi
        grep -Fq "luac or lua is required" "$TEST_ROOT/no-lua-output"
    ) && pass "source validation fails closed without a Lua parser" ||
        fail "source validation fails closed without a Lua parser"
}

test_repair_verifies_before_mutation() {
    failure_kind="$1"
    (
        setup_transaction "repair-$failure_kind"
        call_log="$TEST_ROOT/repair-$failure_kind/calls"
        id() {
            printf '0\n'
        }
        refuse_unresolved_recovery_evidence() {
            printf 'evidence-check\n' >> "$call_log"
        }
        require_command() {
            [ "$1" = "flock" ] || {
                printf 'MUTATION prerequisite-%s\n' "$1" >> "$call_log"
                return
            }
            printf 'require-flock\n' >> "$call_log"
        }
        prepare_work_dir() {
            printf 'prepare\n' >> "$call_log"
        }
        verify_installed() {
            printf 'verify-%s\n' "$failure_kind" >> "$call_log"
            die "injected $failure_kind installed payload"
        }
        check_tailscale_prerequisites() {
            printf 'MUTATION prerequisite\n' >> "$call_log"
        }
        legacy_service_is_known() {
            printf 'MUTATION legacy\n' >> "$call_log"
        }
        acquire_install_lock() {
            printf 'lock\n' >> "$call_log"
            INSTALL_LOCK_HELD=1
        }
        preflight_locked_recovery_evidence() {
            [ "$INSTALL_LOCK_HELD" -eq 1 ] || return 1
            printf 'cross-evidence\n' >> "$call_log"
        }
        capture_service_state() {
            printf 'MUTATION capture\n' >> "$call_log"
        }
        backup_transaction_targets() {
            printf 'MUTATION backup\n' >> "$call_log"
        }
        merge_sysupgrade_preservation() {
            printf 'MUTATION sysupgrade\n' >> "$call_log"
        }
        disable_known_legacy_service() {
            printf 'MUTATION disable\n' >> "$call_log"
        }
        enable_canonical_services() {
            printf 'MUTATION enable\n' >> "$call_log"
        }
        if (repair_services) >"$TEST_ROOT/repair-$failure_kind/output" 2>&1; then
            exit 1
        fi
        expected="$TEST_ROOT/repair-$failure_kind/expected"
        {
            printf 'evidence-check\n'
            printf 'require-flock\n'
            printf 'lock\n'
            printf 'cross-evidence\n'
            printf 'prepare\n'
            printf 'verify-%s\n' "$failure_kind"
        } > "$expected"
        cmp -s "$expected" "$call_log" &&
            ! grep -Fq MUTATION "$call_log"
    )
}

test_upgrader_evidence_blocks_installer_without_changes() {
    for evidence_case in pending staging unexpected symlink-root; do
        case_root="$TEST_ROOT/upgrade-evidence-$evidence_case"
        mount_root="$case_root/mnt/data"
        recovery_root="$mount_root/.jammonitor-tailscale-upgrade"
        external_root="$case_root/external"
        mkdir -p "$mount_root"
        case "$evidence_case" in
            pending)
                mkdir -p "$recovery_root/pending"
                evidence_path="$recovery_root/pending/RECOVERY_REQUIRED"
                printf '%s\n' pending > "$evidence_path"
                ;;
            staging)
                mkdir -p "$recovery_root/.staging.123"
                evidence_path="$recovery_root/.staging.123/RECOVERY_REQUIRED"
                printf '%s\n' staging > "$evidence_path"
                ;;
            unexpected)
                mkdir -p "$recovery_root"
                evidence_path="$recovery_root/blocker"
                printf '%s\n' unexpected > "$evidence_path"
                ;;
            symlink-root)
                mkdir -p "$external_root"
                evidence_path="$external_root/RECOVERY_REQUIRED"
                printf '%s\n' symlink > "$evidence_path"
                ln -s "$external_root" "$recovery_root"
                ;;
        esac
        evidence_inode="$(ls -id "$evidence_path" | awk '{print $1}')"
        evidence_sha="$(sha256sum "$evidence_path" | awk '{print $1}')"
        if (
            UPGRADE_PERSISTENT_MOUNT="$mount_root"
            UPGRADE_RECOVERY_ROOT="$recovery_root"
            INSTALL_LOCK_HELD=1
            preflight_locked_recovery_evidence
        ) >"$case_root/output" 2>&1 ||
           [ "$(ls -id "$evidence_path" | awk '{print $1}')" != \
             "$evidence_inode" ] ||
           [ "$(sha256sum "$evidence_path" | awk '{print $1}')" != \
             "$evidence_sha" ]; then
            fail "installer accepted or changed upgrader evidence: $evidence_case"
            return
        fi
    done
    pass "installer refuses every upgrader artifact without changing its inode or bytes"
}

test_installer_lock_metadata_is_verified() {
    lock_root="$TEST_ROOT/lock-metadata"
    lock_file="$lock_root/router-install.lock"
    (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        acquire_install_lock
        expected_uid="$(id -u)"
        expected_gid="$(id -g)"
        [ "$(stat -c '%a:%u:%g' "$lock_root")" = \
          "700:$expected_uid:$expected_gid" ] &&
            [ "$(stat -c '%a:%u:%g' "$lock_file")" = \
              "600:$expected_uid:$expected_gid" ]
        exec 7>&-
    ) || {
        fail "shared lock parent or inode metadata was not verified"
        return
    }

    if [ "$(id -u)" -eq 0 ]; then
        chown 1:1 "$lock_root" "$lock_file"
        (
            INSTALLER_TESTING=0
            INSTALL_LOCK="$lock_file"
            INSTALL_LOCK_HELD=0
            acquire_install_lock
            [ "$(stat -c '%a:%u:%g' "$lock_root")" = "700:0:0" ] &&
                [ "$(stat -c '%a:%u:%g' "$lock_file")" = "600:0:0" ]
            exec 7>&-
        ) || {
            fail "production lock acquisition did not repair unsafe ownership"
            return
        }
    fi
    pass "shared lock parent and inode have exact protected ownership and modes"
}

test_killed_installer_fetch_parent_releases_flock() {
    lock_root="$TEST_ROOT/installer-fetch-lock"
    lock_file="$lock_root/router-install.lock"
    helper="$TEST_BIN/uclient-fetch"
    timeout_helper="$TEST_BIN/timeout"
    helper_ready="$TEST_ROOT/installer-fetch-helper-ready"
    helper_pid_file="$TEST_ROOT/installer-fetch-helper-pid"
    cat > "$helper" <<'EOF'
#!/bin/sh
printf '%s\n' "$$" > "$INSTALLER_FETCH_HELPER_PID"
: > "$INSTALLER_FETCH_HELPER_READY"
while :; do
    sleep 1
done
EOF
    chmod 0755 "$helper"
    cat > "$timeout_helper" <<'EOF'
#!/bin/sh
[ "$1" = "-s" ] && [ "$2" = "TERM" ] &&
    [ "$3" = "-k" ] && [ "$4" = "2" ] || exit 2
shift 5
exec "$@"
EOF
    chmod 0755 "$timeout_helper"

    (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        FETCH_TIMEOUT=30
        INSTALLER_FETCH_HELPER_READY="$helper_ready"
        INSTALLER_FETCH_HELPER_PID="$helper_pid_file"
        export INSTALLER_FETCH_HELPER_READY INSTALLER_FETCH_HELPER_PID
        acquire_install_lock
        fetch_file https://example.invalid/test "$TEST_ROOT/fetch-output"
    ) >"$TEST_ROOT/installer-fetch-output" 2>&1 &
    fetch_parent=$!

    attempts=100
    while [ "$attempts" -gt 0 ] && [ ! -s "$helper_pid_file" ]; do
        sleep 0.05
        attempts=$((attempts - 1))
    done
    if [ ! -s "$helper_pid_file" ]; then
        kill "$fetch_parent" 2>/dev/null || true
        wait "$fetch_parent" 2>/dev/null || true
        sed -n '1,40p' "$TEST_ROOT/installer-fetch-output" >&2 || true
        rm -f "$helper" "$timeout_helper"
        fail "installer hanging fetch fixture did not start"
        return
    fi
    helper_pid="$(cat "$helper_pid_file")"
    lock_inode="$(ls -id "$lock_file" | awk '{print $1}')"
    kill -KILL "$fetch_parent"
    wait "$fetch_parent" 2>/dev/null || true

    if (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        acquire_install_lock
        exec 7>&-
    ) &&
       [ "$(ls -id "$lock_file" | awk '{print $1}')" = "$lock_inode" ]; then
        released=1
    else
        released=0
    fi
    kill "$helper_pid" 2>/dev/null || true
    rm -f "$helper" "$timeout_helper"
    if [ "$released" -eq 1 ]; then
        pass "killed installer fetch parent cannot orphan the shared flock"
    else
        fail "installer fetch child inherited the shared flock"
    fi
}

test_installer_fetch_is_kernel_and_time_bounded() {
    helper="$TEST_BIN/uclient-fetch"
    timeout_helper="$TEST_BIN/timeout"
    cat > "$helper" <<'EOF'
#!/bin/sh
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            output="$2"
            shift 2
            ;;
        -q)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
case "$url" in
    *oversized*)
        while :; do
            printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
        done > "$output"
        ;;
    *hanging*)
        while :; do sleep 1; done
        ;;
    *)
        printf 'ok\n' > "$output"
        ;;
esac
EOF
    chmod 0755 "$helper"
    cat > "$timeout_helper" <<'EOF'
#!/bin/sh
[ "$1" = "-s" ] && [ "$2" = "TERM" ] &&
    [ "$3" = "-k" ] && [ "$4" = "2" ] || exit 2
shift 5
for argument in "$@"; do
    case "$argument" in
        *hanging*)
            : > "$INSTALLER_TIMEOUT_INTERCEPTED"
            exit 124
            ;;
    esac
done
exec "$@"
EOF
    chmod 0755 "$timeout_helper"
    oversized_output="$TEST_ROOT/installer-fetch-oversized"
    hanging_output="$TEST_ROOT/installer-fetch-hanging"
    timeout_marker="$TEST_ROOT/installer-fetch-timeout-intercepted"
    INSTALLER_TIMEOUT_INTERCEPTED="$timeout_marker"
    export INSTALLER_TIMEOUT_INTERCEPTED
    FETCH_TIMEOUT=1
    if fetch_file https://example.invalid/oversized "$oversized_output"; then
        oversized_failed=0
    else
        oversized_failed=1
    fi
    if fetch_file https://example.invalid/hanging "$hanging_output"; then
        hanging_failed=0
    else
        hanging_failed=1
    fi
    oversized_size="$(wc -c < "$oversized_output" 2>/dev/null |
        tr -d ' ' || true)"
    rm -f "$helper" "$timeout_helper"
    if [ "$oversized_failed" -eq 1 ] &&
       [ -n "$oversized_size" ] &&
       [ "$oversized_size" -le "$FETCH_SCRIPT_MAX_BYTES" ] &&
       [ "$hanging_failed" -eq 1 ] &&
       [ -f "$timeout_marker" ]; then
        pass "installer fetch streams are kernel-size-capped and kill-after bounded"
    else
        printf 'fetch-bound diagnostics: oversized_failed=%s size=%s hanging_failed=%s timeout_marker=%s\n' \
            "$oversized_failed" "${oversized_size:-missing}" \
            "$hanging_failed" "$([ -f "$timeout_marker" ] && printf yes || printf no)" \
            >&2
        fail "installer fetch streams are kernel-size-capped and kill-after bounded"
    fi
}

test_repair_missing_and_tampered_zero_mutation() {
    if test_repair_verifies_before_mutation missing &&
       test_repair_verifies_before_mutation tampered; then
        pass "repair refuses missing or tampered installs before service/link mutation"
    else
        fail "repair refuses missing or tampered installs before service/link mutation"
    fi
}

test_repair_requires_installed_boot_gates() {
    if (
        gate_dir="$TEST_ROOT/repair-installed-gates"
        mkdir -p "$gate_dir"
        INIT_DIR="$gate_dir"
        for service in \
            tailscale jammonitor-history jammonitor-tailscale-watchdog
        do
            {
                printf '%s\n' '#!/bin/sh'
                printf '%s\n' '# JAMMONITOR_BOOT_FENCE_V1'
                printf '%s\n' '# JAMMONITOR_INSTALL_FENCE_TOKEN'
            } > "$gate_dir/$service"
            chmod 0755 "$gate_dir/$service"
        done
        verify_installed_boot_gate_contract
        printf '%s\n' '#!/bin/sh' > "$gate_dir/jammonitor-history"
        chmod 0755 "$gate_dir/jammonitor-history"
        if (verify_installed_boot_gate_contract) \
            >"$TEST_ROOT/repair-installed-gates-output" 2>&1; then
            exit 1
        fi
        grep -Fq "cannot enforce a repair fence" \
            "$TEST_ROOT/repair-installed-gates-output"
    ); then
        pass "repair refuses authenticated legacy init files that cannot enforce its fence"
    else
        fail "repair refuses authenticated legacy init files that cannot enforce its fence"
    fi
}

test_library_mode_is_test_only() {
    if JAMMONITOR_INSTALL_TESTING=0 JAMMONITOR_INSTALL_LIB_ONLY=1 \
        sh "$INSTALLER" --help >"$TEST_ROOT/library-output" 2>&1; then
        fail "installer library mode is test-harness only"
    elif grep -Fq "library mode is available only to the test harness" \
        "$TEST_ROOT/library-output"; then
        pass "installer library mode is test-harness only"
    else
        fail "installer library mode is test-harness only"
    fi
}

test_runtime_commands_are_required_target_dependencies() {
    if [ "$(grep -Fc 'require_command flock' "$INSTALLER")" -ge 2 ]; then
        pass "install and repair preflight require target flock support"
    else
        fail "install and repair preflight require target flock support"
    fi
    if [ "$(grep -Fc 'require_command sqlite3' "$INSTALLER")" -ge 2 ] &&
       [ "$(grep -Fc 'require_command conntrack' "$INSTALLER")" -ge 2 ]; then
        pass "install and repair preflight require collector runtime commands"
    else
        fail "install and repair preflight require collector runtime commands"
    fi
    if [ "$(grep -Fc 'require_command sync' "$INSTALLER")" -ge 2 ] &&
       grep -Fq 'check_timeout_capability' "$INSTALLER"; then
        pass "install and repair preflight require recovery sync and timeout capabilities"
    else
        fail "install and repair preflight require recovery sync and timeout capabilities"
    fi
}

test_semantic_readiness_requires_secure_fresh_status() {
    if (
        readiness_root="$TEST_ROOT/readiness-status"
        WORK_DIR="$readiness_root/work"
        mkdir -p "$WORK_DIR"
        history_status="$readiness_root/collector-status.json"
        cat >"$history_status" <<'EOF'
{"schema":1,"observed_at":101,"started_at":100,"healthy":true,"mounted":true,"writable":true,"mount_source":"/dev/sda1","mount_uuid":"1234-abcd","mount_kernel_id":"8:1","mount_generation":"42","database_quick_check":"ok","last_sample_at":101,"last_success_at":101,"sample_age_secs":0,"consecutive_write_failures":0}
EOF
        chmod 0600 "$history_status"
        capture_secure_status_snapshot "$history_status" history &&
            history_snapshot_is_ready 100

        watchdog_status="$readiness_root/tailscale-watchdog.json"
        cat >"$watchdog_status" <<'EOF'
{"schema":3,"observed_at":102,"status":"running","healthy":true,"connected":true,"local_api_responsive":true,"installed":true,"service_enabled":true,"service_running":true,"backend_state":"Running","control_online":true,"tun_available":true,"process_generation":"4242:10000","peer_configured":false,"peer_state":"not_configured","peer_reachable":null}
EOF
        chmod 0600 "$watchdog_status"
        capture_secure_status_snapshot "$watchdog_status" watchdog &&
            watchdog_snapshot_is_ready 100

        cat >"$watchdog_status" <<'EOF'
{"schema":3,"observed_at":102,"status":"running","healthy":"true","connected":true,"local_api_responsive":true,"installed":true,"service_enabled":true,"service_running":true,"backend_state":"Running","control_online":true,"tun_available":true,"process_generation":"4242:10000","peer_configured":false,"peer_state":"not_configured","peer_reachable":null}
EOF
        chmod 0600 "$watchdog_status"
        capture_secure_status_snapshot "$watchdog_status" watchdog
        if watchdog_snapshot_is_ready 100; then
            exit 1
        fi

        hardlink_status="$readiness_root/hardlinked.json"
        printf '%s\n' '{"schema":1}' > "$hardlink_status"
        chmod 0600 "$hardlink_status"
        ln "$hardlink_status" "$readiness_root/hardlinked-alias.json"
        if capture_secure_status_snapshot "$hardlink_status" history; then
            exit 1
        fi

        symlink_status="$readiness_root/symlink.json"
        ln -s "$history_status" "$symlink_status"
        if capture_secure_status_snapshot "$symlink_status" history; then
            exit 1
        fi
    ); then
        pass "semantic readiness requires typed fresh status from a private stable inode"
    else
        fail "semantic readiness requires typed fresh status from a private stable inode"
    fi
}

test_watchdog_readiness_requires_two_stable_generation_publications() {
    if (
        capture_count=0
        capture_secure_status_snapshot() {
            capture_count=$((capture_count + 1))
            case "$capture_count" in
                1|2)
                    READINESS_IDENTITY=1:1
                    watchdog_observed=100
                    ;;
                *)
                    READINESS_IDENTITY=1:2
                    watchdog_observed=101
                    ;;
            esac
            watchdog_generation=4242:10000
            return 0
        }
        watchdog_snapshot_is_ready() {
            return 0
        }
        read_service_state() {
            SERVICE_STATE=running
            return 0
        }
        date() {
            printf '100\n'
        }
        sleep() {
            :
        }
        WATCHDOG_READY_TIMEOUT=5
        wait_watchdog_readiness 100
        [ "$capture_count" -eq 3 ]
    ); then
        pass "watchdog readiness requires two publications from one stable daemon generation"
    else
        fail "watchdog readiness requires two publications from one stable daemon generation"
    fi
}

test_refresh_waits_for_semantic_readiness() {
    if (
        refresh_log="$TEST_ROOT/readiness-refresh.log"
        HISTORY_WAS_RUNNING=1
        LEGACY_WAS_RUNNING=0
        WATCHDOG_WAS_RUNNING=1
        date() {
            printf '100\n'
        }
        run_service_action() {
            printf 'restart:%s:%s\n' "$1" "$2" >> "$refresh_log"
        }
        wait_history_readiness() {
            printf 'ready:history:%s\n' "$1" >> "$refresh_log"
        }
        wait_watchdog_readiness() {
            printf 'ready:watchdog:%s\n' "$1" >> "$refresh_log"
        }
        refresh_previously_running_services
        expected="$TEST_ROOT/readiness-refresh.expected"
        {
            printf 'restart:jammonitor-history:restart\n'
            printf 'ready:history:100\n'
            printf 'restart:jammonitor-tailscale-watchdog:restart\n'
            printf 'ready:watchdog:100\n'
        } > "$expected"
        cmp -s "$expected" "$refresh_log"
    ) && (
        HISTORY_WAS_RUNNING=1
        LEGACY_WAS_RUNNING=0
        WATCHDOG_WAS_RUNNING=0
        date() {
            printf '100\n'
        }
        run_service_action() {
            return 0
        }
        wait_history_readiness() {
            return 1
        }
        if (refresh_previously_running_services) \
            >"$TEST_ROOT/readiness-refresh-failure" 2>&1; then
            exit 1
        fi
        grep -Fq "fresh healthy storage-backed status" \
            "$TEST_ROOT/readiness-refresh-failure"
    ); then
        pass "service refresh cannot commit after procd dispatch without semantic readiness"
    else
        fail "service refresh cannot commit after procd dispatch without semantic readiness"
    fi
}

test_persistent_flock_serializes_all_mutations() {
    lock_root="$TEST_ROOT/shared-lock"
    lock_file="$lock_root/router-install.lock"
    ready="$TEST_ROOT/shared-lock-ready"
    release="$TEST_ROOT/shared-lock-release"
    first_result="$TEST_ROOT/shared-lock-first"
    second_result="$TEST_ROOT/shared-lock-second"
    successor_result="$TEST_ROOT/shared-lock-successor"

    (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        acquire_install_lock
        printf '%s\n' acquired >"$first_result"
        : >"$ready"
        while [ ! -e "$release" ]; do sleep 0.01; done
        exec 7>&-
    ) &
    first_pid=$!

    attempts=0
    while [ ! -e "$ready" ] && [ "$attempts" -lt 200 ]; do
        sleep 0.01
        attempts=$((attempts + 1))
    done
    [ -e "$ready" ] || {
        kill "$first_pid" 2>/dev/null || true
        wait "$first_pid" 2>/dev/null || true
        fail "persistent installer flock owner did not start"
        return
    }
    first_inode="$(ls -di "$lock_file" | awk '{print $1}')"

    if (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        acquire_install_lock
        printf '%s\n' acquired >"$second_result"
        exec 7>&-
    ) >"$TEST_ROOT/shared-lock-contender-output" 2>&1; then
        contender_blocked=0
    else
        contender_blocked=1
    fi

    : >"$release"
    wait "$first_pid"

    (
        INSTALL_LOCK="$lock_file"
        INSTALL_LOCK_HELD=0
        acquire_install_lock
        printf '%s\n' acquired >"$successor_result"
        exec 7>&-
    )
    successor_inode="$(ls -di "$lock_file" | awk '{print $1}')"

    if [ "$contender_blocked" -eq 1 ] &&
       [ -s "$first_result" ] &&
       [ ! -e "$second_result" ] &&
       [ -s "$successor_result" ] &&
       [ "$first_inode" = "$successor_inode" ] &&
       [ -f "$lock_file" ] && [ ! -L "$lock_file" ]; then
        pass "persistent kernel flock serializes install, repair, and upgrade"
    else
        fail "persistent kernel flock serializes install, repair, and upgrade"
    fi
}

test_atomic_regular_restore
test_atomic_symlink_and_absent_restore
test_failed_copy_preserves_current_target
test_tampered_backup_is_refused
test_rollback_aggregates_file_failures
test_rollback_aggregates_service_failures
test_transient_migration_daemon_is_fail_safe
test_maintenance_window_is_calculated
test_maintenance_cleanup_is_owner_checked
test_interrupted_transaction_persists_and_blocks_retry
test_write_ahead_sync_precedes_mutation
test_recovery_cleanup_is_exact
test_recovery_symlink_is_refused
test_installer_boot_fence_is_durable_and_owner_checked
test_all_boot_services_enforce_the_same_install_fence
test_timeout_capability_preflight
test_lua_parser_is_mandatory
test_repair_missing_and_tampered_zero_mutation
test_repair_requires_installed_boot_gates
test_library_mode_is_test_only
test_runtime_commands_are_required_target_dependencies
test_semantic_readiness_requires_secure_fresh_status
test_watchdog_readiness_requires_two_stable_generation_publications
test_refresh_waits_for_semantic_readiness
test_persistent_flock_serializes_all_mutations
test_upgrader_evidence_blocks_installer_without_changes
test_installer_lock_metadata_is_verified
test_installer_fetch_is_kernel_and_time_bounded
test_killed_installer_fetch_parent_releases_flock

printf '1..%s\n' "$TEST_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
