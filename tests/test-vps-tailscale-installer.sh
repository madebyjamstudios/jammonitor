#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

REPO_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SOURCE_VPS="${REPO_DIR}/vps"
INSTALLER="${SOURCE_VPS}/install-tailscale-watchdog.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jammonitor-vps-installer-test.XXXXXX")"
TEST_UID="$(id -u)"
TEST_GID="$(id -g)"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM

PASS_COUNT=0
CASE_ROOT=""
CASE_SOURCE=""
CASE_STATE=""
CASE_OUTPUT=""
CASE_ERROR=""
BAD_STAT_BASENAME=""
FAIL_RESTORE_LABEL=""
FAIL_POST_VERIFY=""

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

copy_source() {
    _destination="$1"
    mkdir -p "$_destination"
    cp \
        "${SOURCE_VPS}/install-tailscale-watchdog.sh" \
        "${SOURCE_VPS}/jammonitor-tailscale-watchdog" \
        "${SOURCE_VPS}/jammonitor-tailscale-watchdog.service" \
        "${SOURCE_VPS}/jammonitor-tailscale-watchdog.timer" \
        "${SOURCE_VPS}/README.md" \
        "${SOURCE_VPS}/vps-files.sha256" \
        "$_destination/"
    chmod 0755 "$_destination"
    chmod 0755 \
        "${_destination}/install-tailscale-watchdog.sh" \
        "${_destination}/jammonitor-tailscale-watchdog"
    chmod 0644 \
        "${_destination}/jammonitor-tailscale-watchdog.service" \
        "${_destination}/jammonitor-tailscale-watchdog.timer" \
        "${_destination}/README.md" \
        "${_destination}/vps-files.sha256"
}

TOOLS_DIR="${TEST_ROOT}/tools"
mkdir -p "$TOOLS_DIR"

cat >"${TOOLS_DIR}/mock-stat" <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 3 ] && [ "$1" = "-c" ] || exit 2
_path="$3"
if /usr/bin/stat -c '%u|%g|%a' "$_path" >/dev/null 2>&1; then
    _result="$(/usr/bin/stat -c '%u|%g|%a' "$_path")"
else
    _result="$(/usr/bin/stat -f '%u|%g|%Lp' "$_path")"
fi
if [ -n "${MOCK_STAT_BAD_BASENAME:-}" ] &&
   [ "${_path##*/}" = "$MOCK_STAT_BAD_BASENAME" ]; then
    _remainder="${_result#*|}"
    printf '99999|%s\n' "$_remainder"
else
    printf '%s\n' "$_result"
fi
EOF
chmod 0755 "${TOOLS_DIR}/mock-stat"

cat >"${TOOLS_DIR}/mock-sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "${TOOLS_DIR}/mock-sleep"

cat >"${TOOLS_DIR}/mock-systemd-analyze" <<'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$*" >>"${MOCK_SYSTEMCTL_STATE:?}/analyze.log"
exit 0
EOF
chmod 0755 "${TOOLS_DIR}/mock-systemd-analyze"

cat >"${TOOLS_DIR}/mock-systemctl" <<'EOF'
#!/bin/sh
set -eu

_state="${MOCK_SYSTEMCTL_STATE:?}"
_command="${1:-}"
[ "$#" -gt 0 ] && shift
printf '%s %s\n' "$_command" "$*" >>"${_state}/actions.log"

last_argument() {
    _last=""
    for _argument in "$@"; do
        _last="$_argument"
    done
    printf '%s' "$_last"
}

read_flag() {
    if [ -f "${_state}/$1" ]; then
        sed -n '1p' "${_state}/$1"
    else
        printf '0'
    fi
}

write_flag() {
    printf '%s\n' "$2" >"${_state}/$1"
}

fail_once() {
    _marker="${_state}/$1"
    if [ -f "$_marker" ]; then
        rm -f "$_marker"
        return 0
    fi
    return 1
}

case "$_command" in
    show)
        _unit="${1:-}"
        _property=""
        for _argument in "$@"; do
            case "$_argument" in
                --property=*) _property="${_argument#--property=}" ;;
            esac
        done
        if [ "$_unit" = "tailscaled.service" ] &&
           [ "$_property" = "LoadState" ]; then
            if [ -f "${_state}/tailscaled-load-state" ]; then
                sed -n '1p' "${_state}/tailscaled-load-state"
            else
                printf '%s\n' loaded
            fi
            exit 0
        fi
        case "${_unit}:${_property}" in
            jammonitor-tailscale-watchdog.timer:ActiveState)
                if [ "$(read_flag timer-active)" = "1" ]; then
                    printf '%s\n' active
                else
                    printf '%s\n' inactive
                fi
                ;;
            jammonitor-tailscale-watchdog.service:ActiveState)
                if [ "$(read_flag service-active)" = "1" ]; then
                    printf '%s\n' active
                else
                    printf '%s\n' inactive
                fi
                ;;
            jammonitor-tailscale-watchdog.service:MainPID)
                read_flag service-main-pid
                printf '\n'
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    is-enabled)
        _unit="$(last_argument "$@")"
        [ "$_unit" = "jammonitor-tailscale-watchdog.timer" ] || exit 1
        [ "$(read_flag timer-enabled)" = "1" ]
        ;;
    is-active)
        _unit="$(last_argument "$@")"
        case "$_unit" in
            jammonitor-tailscale-watchdog.timer)
                [ "$(read_flag timer-active)" = "1" ]
                ;;
            jammonitor-tailscale-watchdog.service)
                [ "$(read_flag service-active)" = "1" ]
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    stop)
        _unit="$(last_argument "$@")"
        _ignore="$(read_flag stop-ignore-remaining)"
        case "$_ignore" in ""|*[!0-9]*) _ignore=0 ;; esac
        if [ "$_ignore" -gt 0 ]; then
            write_flag stop-ignore-remaining "$((_ignore - 1))"
            exit 0
        fi
        case "$_unit" in
            jammonitor-tailscale-watchdog.timer)
                write_flag timer-active 0
                ;;
            jammonitor-tailscale-watchdog.service)
                write_flag service-active 0
                write_flag service-main-pid 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    start)
        _unit="$(last_argument "$@")"
        if fail_once fail-start-once; then
            exit 1
        fi
        case "$_unit" in
            jammonitor-tailscale-watchdog.timer)
                write_flag timer-active 1
                ;;
            jammonitor-tailscale-watchdog.service)
                write_flag service-active 1
                write_flag service-main-pid 4242
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    enable)
        _unit="$(last_argument "$@")"
        if fail_once fail-enable-once; then
            exit 1
        fi
        [ "$_unit" = "jammonitor-tailscale-watchdog.timer" ] || exit 1
        write_flag timer-enabled 1
        ;;
    disable)
        _unit="$(last_argument "$@")"
        if fail_once fail-disable-once; then
            exit 1
        fi
        [ "$_unit" = "jammonitor-tailscale-watchdog.timer" ] || exit 1
        write_flag timer-enabled 0
        ;;
    daemon-reload)
        if fail_once fail-daemon-reload-once; then
            exit 1
        fi
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 0755 "${TOOLS_DIR}/mock-systemctl"

RUNTIME_STUB="${TOOLS_DIR}/runtime-stub"
cat >"$RUNTIME_STUB" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 "$RUNTIME_STUB"

new_case() {
    _name="$1"
    _case="${TEST_ROOT}/case-${_name}"
    CASE_ROOT="${_case}/root"
    CASE_SOURCE="${_case}/source"
    CASE_STATE="${_case}/state"
    CASE_OUTPUT="${_case}/stdout"
    CASE_ERROR="${_case}/stderr"
    mkdir -p \
        "$CASE_ROOT/usr/bin" \
        "$CASE_ROOT/run/lock" \
        "$CASE_ROOT/etc/systemd/system" \
        "$CASE_ROOT/usr/local/libexec" \
        "$CASE_ROOT/usr/share/doc" \
        "$CASE_STATE"
    copy_source "$CASE_SOURCE"
    for _runtime_name in tailscale timeout jq logger flock systemctl; do
        cp "$RUNTIME_STUB" "$CASE_ROOT/usr/bin/$_runtime_name"
        chmod 0755 "$CASE_ROOT/usr/bin/$_runtime_name"
    done
    printf '%s\n' 0 >"${CASE_STATE}/timer-enabled"
    printf '%s\n' 0 >"${CASE_STATE}/timer-active"
    printf '%s\n' 0 >"${CASE_STATE}/service-active"
    printf '%s\n' 0 >"${CASE_STATE}/service-main-pid"
    : >"${CASE_STATE}/actions.log"
    : >"${CASE_STATE}/analyze.log"
    BAD_STAT_BASENAME=""
    FAIL_RESTORE_LABEL=""
    FAIL_POST_VERIFY=""
}

run_case_install() {
    env \
        JM_VPS_INSTALLER_TESTING=1 \
        JM_VPS_INSTALLER_ROOT="$CASE_ROOT" \
        JM_VPS_INSTALLER_SYSTEMCTL="${TOOLS_DIR}/mock-systemctl" \
        JM_VPS_INSTALLER_SYSTEMD_ANALYZE="${TOOLS_DIR}/mock-systemd-analyze" \
        JM_VPS_INSTALLER_STAT="${TOOLS_DIR}/mock-stat" \
        JM_VPS_INSTALLER_SLEEP="${TOOLS_DIR}/mock-sleep" \
        JM_VPS_INSTALLER_EXPECTED_UID="$TEST_UID" \
        JM_VPS_INSTALLER_EXPECTED_GID="$TEST_GID" \
        JM_VPS_INSTALLER_FAIL_RESTORE_LABEL="$FAIL_RESTORE_LABEL" \
        JM_VPS_INSTALLER_FAIL_POST_VERIFY="$FAIL_POST_VERIFY" \
        MOCK_SYSTEMCTL_STATE="$CASE_STATE" \
        MOCK_STAT_BAD_BASENAME="$BAD_STAT_BASENAME" \
        "$INSTALLER" \
        --source-dir "$CASE_SOURCE" \
        --manifest-sha256 "$MANIFEST_SHA256" \
        "$@" >"$CASE_OUTPUT" 2>"$CASE_ERROR"
}

target_path() {
    case "$1" in
        watchdog)
            printf '%s' \
                "$CASE_ROOT/usr/local/libexec/jammonitor-tailscale-watchdog"
            ;;
        service)
            printf '%s' \
                "$CASE_ROOT/etc/systemd/system/jammonitor-tailscale-watchdog.service"
            ;;
        timer)
            printf '%s' \
                "$CASE_ROOT/etc/systemd/system/jammonitor-tailscale-watchdog.timer"
            ;;
        readme)
            printf '%s' \
                "$CASE_ROOT/usr/share/doc/jammonitor-tailscale-watchdog/README.md"
            ;;
        *) return 1 ;;
    esac
}

source_path() {
    case "$1" in
        watchdog) printf '%s' "$CASE_SOURCE/jammonitor-tailscale-watchdog" ;;
        service)
            printf '%s' \
                "$CASE_SOURCE/jammonitor-tailscale-watchdog.service"
            ;;
        timer)
            printf '%s' "$CASE_SOURCE/jammonitor-tailscale-watchdog.timer"
            ;;
        readme) printf '%s' "$CASE_SOURCE/README.md" ;;
        *) return 1 ;;
    esac
}

target_mode() {
    case "$1" in
        watchdog) printf '%s' 755 ;;
        service|timer|readme) printf '%s' 644 ;;
        *) return 1 ;;
    esac
}

snapshot_targets() {
    _snapshot="$1"
    : >"$_snapshot"
    for _label in watchdog service timer readme; do
        _path="$(target_path "$_label")"
        if [ -e "$_path" ]; then
            _stat="$("${TOOLS_DIR}/mock-stat" -c '%u|%g|%a' "$_path")"
            printf '%s|present|%s|%s\n' \
                "$_label" "$(hash_file "$_path")" "$_stat" >>"$_snapshot"
        else
            printf '%s|missing\n' "$_label" >>"$_snapshot"
        fi
    done
}

assert_snapshot() {
    _expected="$1"
    _actual="${_expected}.actual"
    snapshot_targets "$_actual"
    cmp -s "$_expected" "$_actual" ||
        fail "owned target snapshot was not restored exactly"
}

seed_old_install() {
    _enabled="$1"
    _active="$2"
    install -d -m 0755 \
        "$CASE_ROOT/usr/share/doc/jammonitor-tailscale-watchdog"
    printf '%s\n' old-watchdog >"$(target_path watchdog)"
    printf '%s\n' old-service >"$(target_path service)"
    printf '%s\n' old-timer >"$(target_path timer)"
    printf '%s\n' old-readme >"$(target_path readme)"
    chmod 0700 "$(target_path watchdog)"
    chmod 0600 "$(target_path service)"
    chmod 0640 "$(target_path timer)"
    chmod 0444 "$(target_path readme)"
    printf '%s\n' "$_enabled" >"${CASE_STATE}/timer-enabled"
    printf '%s\n' "$_active" >"${CASE_STATE}/timer-active"
}

assert_flag() {
    _flag="$1"
    _expected="$2"
    _actual="$(sed -n '1p' "${CASE_STATE}/${_flag}")"
    [ "$_actual" = "$_expected" ] ||
        fail "${_flag} was ${_actual}, expected ${_expected}"
}

assert_installed_exact() {
    for _label in watchdog service timer readme; do
        _target="$(target_path "$_label")"
        _source="$(source_path "$_label")"
        [ -f "$_target" ] && [ ! -L "$_target" ] ||
            fail "installed ${_label} is not a regular file"
        [ "$(hash_file "$_target")" = "$(hash_file "$_source")" ] ||
            fail "installed ${_label} digest differs from source"
        _actual_stat="$("${TOOLS_DIR}/mock-stat" -c '%u|%g|%a' "$_target")"
        _expected_stat="${TEST_UID}|${TEST_GID}|$(target_mode "$_label")"
        [ "$_actual_stat" = "$_expected_stat" ] ||
            fail "installed ${_label} metadata ${_actual_stat}, expected ${_expected_stat}"
    done
}

assert_no_temporary_targets() {
    if find "$CASE_ROOT" \
        \( -name '.jammonitor-install.*' -o \
           -name '.jammonitor-restore.*' \) -print |
        grep -q .; then
        fail "installer left a temporary target behind"
    fi
}

assert_no_recovery_transaction() {
    if find "$CASE_ROOT/var/lib/jammonitor-tailscale-watchdog" \
        -maxdepth 1 -name 'transaction.*' -print 2>/dev/null |
        grep -q .; then
        fail "completed transaction left a recovery bundle"
    fi
}

assert_no_tailscaled_mutation() {
    if grep -E \
        '^(start|stop|restart|enable|disable) .*tailscaled\.service' \
        "${CASE_STATE}/actions.log" >/dev/null 2>&1; then
        fail "installer attempted to mutate tailscaled.service"
    fi
}

assert_targets_absent() {
    for _label in watchdog service timer readme; do
        [ ! -e "$(target_path "$_label")" ] ||
            fail "preflight failure mutated target ${_label}"
    done
}

sh -n "$INSTALLER"
dash -n "$INSTALLER"
sh -n "${SOURCE_VPS}/generate-vps-manifest.sh"
pass "installer and manifest generator parse in sh and dash"

MANIFEST_SHA256="$(hash_file "${SOURCE_VPS}/vps-files.sha256")"
"$INSTALLER" \
    --validate-source "$SOURCE_VPS" \
    --manifest-sha256 "$MANIFEST_SHA256" \
    >"${TEST_ROOT}/validate-output"
grep -Fq 'source validation passed' "${TEST_ROOT}/validate-output" ||
    fail "valid pinned source was not accepted"
pass "valid source requires and accepts the separately pinned manifest"

case "$MANIFEST_SHA256" in
    0*) WRONG_MANIFEST_SHA256="1${MANIFEST_SHA256#?}" ;;
    *) WRONG_MANIFEST_SHA256="0${MANIFEST_SHA256#?}" ;;
esac
if "$INSTALLER" \
    --validate-source "$SOURCE_VPS" \
    --manifest-sha256 "$WRONG_MANIFEST_SHA256" \
    >"${TEST_ROOT}/wrong-output" 2>"${TEST_ROOT}/wrong-error"; then
    fail "wrong trusted manifest digest was accepted"
fi
grep -Fq 'manifest digest mismatch' "${TEST_ROOT}/wrong-error" ||
    fail "wrong digest did not fail at the provenance boundary"
pass "wrong trusted manifest digest is rejected"

TAMPER_SOURCE="${TEST_ROOT}/tamper"
copy_source "$TAMPER_SOURCE"
printf '%s\n' 'tampered' >>"${TAMPER_SOURCE}/README.md"
if "$INSTALLER" \
    --validate-source "$TAMPER_SOURCE" \
    --manifest-sha256 "$MANIFEST_SHA256" \
    >"${TEST_ROOT}/tamper-output" 2>"${TEST_ROOT}/tamper-error"; then
    fail "payload tampering was accepted"
fi
pass "payload modification is rejected by the pinned manifest"

INSTALLER_TAMPER_SOURCE="${TEST_ROOT}/installer-tamper"
copy_source "$INSTALLER_TAMPER_SOURCE"
printf '%s\n' '# tampered installer' \
    >>"${INSTALLER_TAMPER_SOURCE}/install-tailscale-watchdog.sh"
if "$INSTALLER" \
    --validate-source "$INSTALLER_TAMPER_SOURCE" \
    --manifest-sha256 "$MANIFEST_SHA256" \
    >"${TEST_ROOT}/installer-tamper-output" \
    2>"${TEST_ROOT}/installer-tamper-error"; then
    fail "root installer tampering was accepted"
fi
pass "the root-executed installer is itself covered by the manifest"

SYMLINK_SOURCE="${TEST_ROOT}/symlink"
copy_source "$SYMLINK_SOURCE"
rm -f "${SYMLINK_SOURCE}/jammonitor-tailscale-watchdog"
ln -s "${SOURCE_VPS}/jammonitor-tailscale-watchdog" \
    "${SYMLINK_SOURCE}/jammonitor-tailscale-watchdog"
if "$INSTALLER" \
    --validate-source "$SYMLINK_SOURCE" \
    --manifest-sha256 "$MANIFEST_SHA256" \
    >"${TEST_ROOT}/symlink-output" 2>"${TEST_ROOT}/symlink-error"; then
    fail "symlink payload was accepted"
fi
pass "symlink payload is rejected"

EXTRA_SOURCE="${TEST_ROOT}/extra"
copy_source "$EXTRA_SOURCE"
printf '%s\n' unexpected >"${EXTRA_SOURCE}/unexpected-file"
EXTRA_HASH="$(hash_file "${EXTRA_SOURCE}/unexpected-file")"
printf '%s  %s\n' "$EXTRA_HASH" unexpected-file \
    >>"${EXTRA_SOURCE}/vps-files.sha256"
EXTRA_MANIFEST_SHA256="$(hash_file "${EXTRA_SOURCE}/vps-files.sha256")"
if "$INSTALLER" \
    --validate-source "$EXTRA_SOURCE" \
    --manifest-sha256 "$EXTRA_MANIFEST_SHA256" \
    >"${TEST_ROOT}/extra-output" 2>"${TEST_ROOT}/extra-error"; then
    fail "unexpected manifest payload was accepted"
fi
grep -Fq 'fixed VPS payload allowlist' "${TEST_ROOT}/extra-error" ||
    fail "unexpected manifest entry did not fail at the allowlist"
pass "manifest cannot expand the fixed installation target set"

for _accepted_mode in 0644 0755; do
    new_case "accepted-mode-${_accepted_mode}"
    chmod "$_accepted_mode" "${CASE_SOURCE}/README.md"
    rm -f "$CASE_ROOT/usr/bin/tailscale"
    if run_case_install; then
        fail "fixture without required runtime unexpectedly installed"
    fi
    grep -Fq 'required watchdog runtime' "$CASE_ERROR" ||
        fail "source mode ${_accepted_mode} did not pass the trust boundary"
done
for _rejected_mode in 0664 0666 0777; do
    new_case "rejected-mode-${_rejected_mode}"
    chmod "$_rejected_mode" "${CASE_SOURCE}/README.md"
    if run_case_install; then
        fail "group/world-writable mode ${_rejected_mode} was accepted"
    fi
    grep -Fq 'must not be group/world writable' "$CASE_ERROR" ||
        fail "mode ${_rejected_mode} failed outside the source trust boundary"
    assert_targets_absent
done
pass "source mode matrix accepts 0644/0755 and rejects 0664/0666/0777"

new_case source-owner
BAD_STAT_BASENAME="jammonitor-tailscale-watchdog.timer"
if run_case_install; then
    fail "non-root-owned source payload was accepted"
fi
grep -Fq 'must be root-owned' "$CASE_ERROR" ||
    fail "source owner mismatch did not fail at the trust boundary"
assert_targets_absent
pass "every source payload must have the trusted root owner and group"

if env JM_VPS_INSTALLER_ROOT="${TEST_ROOT}/forbidden-test-root" \
    "$INSTALLER" \
    --source-dir "$SOURCE_VPS" \
    --manifest-sha256 "$MANIFEST_SHA256" \
    >"${TEST_ROOT}/override-output" 2>"${TEST_ROOT}/override-error"; then
    fail "test-only path override was accepted outside test mode"
fi
grep -Fq 'test overrides are refused outside test mode' \
    "${TEST_ROOT}/override-error" ||
    fail "production override refusal was not explicit"
pass "absolute-path and fault overrides are refused outside explicit test mode"

for _missing_runtime in tailscale timeout jq logger flock systemctl; do
    new_case "missing-runtime-${_missing_runtime}"
    rm -f "$CASE_ROOT/usr/bin/$_missing_runtime"
    if run_case_install; then
        fail "missing /usr/bin/${_missing_runtime} was accepted"
    fi
    grep -Fq "/usr/bin/${_missing_runtime}" "$CASE_ERROR" ||
        fail "missing runtime ${_missing_runtime} was not identified"
    assert_targets_absent
    [ ! -e "$CASE_ROOT/var/lib/jammonitor-tailscale-watchdog" ] ||
        fail "runtime preflight created recovery state"
done
pass "all six absolute watchdog runtime dependencies are executable preflight gates"

new_case tailscaled-missing
printf '%s\n' not-found >"${CASE_STATE}/tailscaled-load-state"
if run_case_install; then
    fail "missing tailscaled.service was accepted"
fi
grep -Fq 'tailscaled.service is not present' "$CASE_ERROR" ||
    fail "missing tailscaled.service was not identified"
assert_targets_absent
assert_no_tailscaled_mutation
pass "tailscaled.service presence is verified without mutating it"

new_case live-lock
mkdir -p \
    "$CASE_ROOT/run/lock/jammonitor-tailscale-watchdog-install.lock"
printf '%s\n' "$$" \
    >"$CASE_ROOT/run/lock/jammonitor-tailscale-watchdog-install.lock/pid"
if run_case_install; then
    fail "live installer lock was ignored"
fi
grep -Fq 'another VPS watchdog installation holds' "$CASE_ERROR" ||
    fail "live lock refusal was not explicit"
assert_targets_absent
pass "a live install lock serializes target mutations"

new_case new-default
run_case_install || {
    sed -n '1,240p' "$CASE_ERROR" >&2
    fail "new default installation failed"
}
assert_installed_exact
assert_flag timer-enabled 1
assert_flag timer-active 0
assert_no_temporary_targets
assert_no_recovery_transaction
assert_no_tailscaled_mutation
pass "new install is exact, atomic, enabled, and intentionally inactive"

new_case new-start
run_case_install --start || fail "new --start installation failed"
assert_installed_exact
assert_flag timer-enabled 1
assert_flag timer-active 1
assert_no_temporary_targets
assert_no_recovery_transaction
pass "new install starts only when --start is explicit"

new_case upgrade-disabled
seed_old_install 0 0
run_case_install || fail "disabled/inactive upgrade failed"
assert_installed_exact
assert_flag timer-enabled 0
assert_flag timer-active 0
pass "upgrade preserves a disabled and inactive timer"

new_case upgrade-active
seed_old_install 1 1
run_case_install || fail "enabled/active upgrade failed"
assert_installed_exact
assert_flag timer-enabled 1
assert_flag timer-active 1
assert_no_tailscaled_mutation
pass "upgrade resumes the exact prior enabled and active timer state"

new_case quiescence
seed_old_install 1 1
printf '%s\n' 1 >"${CASE_STATE}/service-active"
printf '%s\n' 4242 >"${CASE_STATE}/service-main-pid"
printf '%s\n' 2 >"${CASE_STATE}/stop-ignore-remaining"
QUIESCENCE_SNAPSHOT="${TEST_ROOT}/quiescence.snapshot"
snapshot_targets "$QUIESCENCE_SNAPSHOT"
if run_case_install; then
    fail "non-quiescent units were mutated"
fi
grep -Fq 'did not become quiescent before mutation' "$CASE_ERROR" ||
    fail "quiescence failure was not explicit"
assert_snapshot "$QUIESCENCE_SNAPSHOT"
assert_flag timer-enabled 1
assert_flag timer-active 1
assert_no_recovery_transaction
pass "installer proves timer and service quiescence before target mutation"

new_case daemon-reload-failure
DAEMON_SNAPSHOT="${TEST_ROOT}/daemon.snapshot"
snapshot_targets "$DAEMON_SNAPSHOT"
: >"${CASE_STATE}/fail-daemon-reload-once"
if run_case_install; then
    fail "injected daemon-reload failure was ignored"
fi
assert_snapshot "$DAEMON_SNAPSHOT"
assert_flag timer-enabled 0
assert_flag timer-active 0
assert_no_recovery_transaction
pass "daemon-reload failure rolls back every file and prior state"

new_case enable-failure
ENABLE_SNAPSHOT="${TEST_ROOT}/enable.snapshot"
snapshot_targets "$ENABLE_SNAPSHOT"
: >"${CASE_STATE}/fail-enable-once"
if run_case_install; then
    fail "injected enable failure was ignored"
fi
assert_snapshot "$ENABLE_SNAPSHOT"
assert_flag timer-enabled 0
assert_flag timer-active 0
assert_no_recovery_transaction
pass "timer enable failure rolls back every file and prior state"

new_case start-failure
START_SNAPSHOT="${TEST_ROOT}/start.snapshot"
snapshot_targets "$START_SNAPSHOT"
: >"${CASE_STATE}/fail-start-once"
if run_case_install --start; then
    fail "injected start failure was ignored"
fi
assert_snapshot "$START_SNAPSHOT"
assert_flag timer-enabled 0
assert_flag timer-active 0
assert_no_recovery_transaction
pass "timer start failure rolls back every file and prior state"

new_case post-verification-failure
seed_old_install 1 1
VERIFY_SNAPSHOT="${TEST_ROOT}/verify.snapshot"
snapshot_targets "$VERIFY_SNAPSHOT"
FAIL_POST_VERIFY=1
if run_case_install; then
    fail "injected post-install verification failure was ignored"
fi
assert_snapshot "$VERIFY_SNAPSHOT"
assert_flag timer-enabled 1
assert_flag timer-active 1
assert_no_recovery_transaction
pass "post-install verification failure restores exact old metadata and state"

for _failed_restore in watchdog service; do
    new_case "restore-failure-${_failed_restore}"
    seed_old_install 1 1
    printf '%s\n' 1 >"${CASE_STATE}/service-active"
    printf '%s\n' 4242 >"${CASE_STATE}/service-main-pid"
    FAIL_POST_VERIFY=1
    FAIL_RESTORE_LABEL="$_failed_restore"
    if run_case_install; then
        fail "injected ${_failed_restore} restore failure was ignored"
    fi
    grep -Fq 'ROLLBACK INCOMPLETE' "$CASE_ERROR" ||
        fail "incomplete ${_failed_restore} restore lacked conspicuous evidence"
    _evidence="$CASE_ROOT/var/lib/jammonitor-tailscale-watchdog/INSTALL-ROLLBACK-INCOMPLETE"
    [ -f "$_evidence" ] || fail "incomplete rollback evidence file is absent"
    _evidence_stat="$("${TOOLS_DIR}/mock-stat" -c '%u|%g|%a' "$_evidence")"
    [ "$_evidence_stat" = "${TEST_UID}|${TEST_GID}|600" ] ||
        fail "incomplete rollback evidence is not private"
    _bundle="$(sed -n 's/^recovery_bundle=//p' "$_evidence")"
    [ -d "$_bundle" ] || fail "incomplete rollback bundle was not preserved"
    _bundle_stat="$("${TOOLS_DIR}/mock-stat" -c '%u|%g|%a' "$_bundle")"
    [ "$_bundle_stat" = "${TEST_UID}|${TEST_GID}|700" ] ||
        fail "incomplete rollback bundle is not private"
    [ -f "$_bundle/prior-timer-state" ] ||
        fail "recovery bundle lacks prior timer state"
    grep -Fq 'enabled=1' "$_bundle/prior-timer-state" ||
        fail "recovery bundle lost prior enabled state"
    grep -Fq 'active=1' "$_bundle/prior-timer-state" ||
        fail "recovery bundle lost prior active state"
    assert_flag timer-enabled 0
    assert_flag timer-active 0
    assert_flag service-active 0
    if grep -E '^start (jammonitor-tailscale-watchdog.timer|jammonitor-tailscale-watchdog.service)' \
        "${CASE_STATE}/actions.log" >/dev/null 2>&1; then
        fail "incomplete rollback reactivated a mixed payload"
    fi
    INCOMPLETE_SNAPSHOT="${TEST_ROOT}/incomplete-${_failed_restore}.snapshot"
    snapshot_targets "$INCOMPLETE_SNAPSHOT"
    FAIL_POST_VERIFY=""
    FAIL_RESTORE_LABEL=""
    if run_case_install; then
        fail "installer ignored unresolved rollback evidence"
    fi
    grep -Fq 'incomplete rollback evidence blocks installation' "$CASE_ERROR" ||
        fail "future installation did not stop at rollback evidence"
    assert_snapshot "$INCOMPLETE_SNAPSHOT"
    assert_no_tailscaled_mutation
done
pass "restore failure remains fail-safe, preserves recovery evidence, and blocks reuse"

printf '1..%s\n' "$PASS_COUNT"
