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
        shift 2
        /usr/bin/stat -f '%Lp:%u:%g' "$1"
    }
fi

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
    mkdir -p "$WORK_DIR/backup"
    BACKUP_ROOT="$WORK_DIR/backup"
    BACKUP_INDEX="$WORK_DIR/backup.index"
    : > "$BACKUP_INDEX"
    TRANSACTION_ACTIVE=0
    TRANSACTION_COMMITTED=0
    BACKUP_READY=0
    MUTATION_STARTED=0
    ROLLBACK_INCOMPLETE=0
    PRESERVE_WORK_DIR=0
    MAINTENANCE_CREATED=0
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
    RECOVERY_EVIDENCE="$TEST_ROOT/$case_name/rollback-failed"
    MAINTENANCE_FILE="$TEST_ROOT/$case_name/maintenance"
    mkdir -p "$TEST_ROOT/$case_name/live"
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
            [ -f "$WORK_DIR/ROLLBACK_INCOMPLETE" ] &&
            [ "$ROLLBACK_INCOMPLETE" -eq 1 ] &&
            [ "$PRESERVE_WORK_DIR" -eq 1 ] &&
            grep -Fqx "recovery_bundle=$WORK_DIR" "$RECOVERY_EVIDENCE" &&
            grep -Fq "CRITICAL: JamMonitor rollback is incomplete" \
                "$TEST_ROOT/aggregate-files/output"
        : > "$MAINTENANCE_FILE"
        MAINTENANCE_CREATED=1
        TRANSACTION_ACTIVE=0
        (cleanup)
        [ -d "$WORK_DIR" ] && [ -f "$MAINTENANCE_FILE" ]
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
            [ -f "$WORK_DIR/ROLLBACK_INCOMPLETE" ]
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
            [ "$actual_window" -le $((MAINTENANCE_REQUIRED_REMAINING + 2)) ]
    ) && pass "maintenance lease covers calculated forward and rollback budgets" ||
        fail "maintenance lease covers calculated forward and rollback budgets"
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
            printf 'MUTATION lock\n' >> "$call_log"
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
            printf 'prepare\n'
            printf 'verify-%s\n' "$failure_kind"
        } > "$expected"
        cmp -s "$expected" "$call_log" &&
            ! grep -Fq MUTATION "$call_log"
    )
}

test_repair_missing_and_tampered_zero_mutation() {
    if test_repair_verifies_before_mutation missing &&
       test_repair_verifies_before_mutation tampered; then
        pass "repair refuses missing or tampered installs before service/link mutation"
    else
        fail "repair refuses missing or tampered installs before service/link mutation"
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
}

test_atomic_regular_restore
test_atomic_symlink_and_absent_restore
test_failed_copy_preserves_current_target
test_tampered_backup_is_refused
test_rollback_aggregates_file_failures
test_rollback_aggregates_service_failures
test_transient_migration_daemon_is_fail_safe
test_maintenance_window_is_calculated
test_repair_missing_and_tampered_zero_mutation
test_library_mode_is_test_only
test_runtime_commands_are_required_target_dependencies

printf '1..%s\n' "$TEST_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
