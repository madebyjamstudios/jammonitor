#!/bin/sh

set -eu
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
UPGRADER="$REPO_ROOT/router/upgrade-tailscale-arm64.sh"
TARGET_VERSION="1.98.9"
TARGET_ARCHIVE="tailscale_${TARGET_VERSION}_arm64.tgz"
TARGET_DIRECTORY="tailscale_${TARGET_VERSION}_arm64"

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
backend="\$(cat "\$TS_TEST_CONTROL_DIR/backend")"
runtime_version="\$(cat "\$TS_TEST_CONTROL_DIR/runtime-version")"
stable_id="\$(cat "\$TS_TEST_CONTROL_DIR/stable-id")"
tun="\$(cat "\$TS_TEST_CONTROL_DIR/tun")"
engine="\$(cat "\$TS_TEST_CONTROL_DIR/in-engine")"
tailnet_ip="\$(cat "\$TS_TEST_CONTROL_DIR/tailnet-ip")"
printf '{"BackendState":"%s","Version":"%s","TUN":%s,"Self":{"ID":"%s","InEngine":%s,"TailscaleIPs":["%s"]},"AuthURL":"SUPER_SECRET_AUTH_URL"}\\n' \
    "\$backend" "\$runtime_version" "\$tun" "\$stable_id" "\$engine" "\$tailnet_ip"
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
# TEST-HARNESS-BEGIN
case "${1:-}" in
    running)
        test -f "$TS_TEST_CONTROL_DIR/running"
        ;;
    stop)
        printf '%s\n' stop >> "$TS_TEST_CONTROL_DIR/actions"
        cp "$TS_UPGRADE_ROOT/var/run/jammonitor/tailscale-maintenance" \
            "$TS_TEST_CONTROL_DIR/observed-marker"
        if [ -f "$TS_TEST_CONTROL_DIR/stop-timeout" ]; then
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
                for bundle in "$TS_UPGRADE_TMPDIR"/tailscale-upgrade.*/backup; do
                    [ -d "$bundle" ] || continue
                    rm -f "$bundle/tailscale" "$bundle/tailscaled.state"
                done
            fi
        fi
        ;;
    start)
        printf '%s\n' start >> "$TS_TEST_CONTROL_DIR/actions"
        version="$("$TS_UPGRADE_ROOT/usr/sbin/tailscaled" --version)"
        printf '%s\n' "$version" > "$TS_TEST_CONTROL_DIR/runtime-version"
        backend="$(cat "$TS_TEST_CONTROL_DIR/original-backend")"
        if [ -f "$TS_TEST_CONTROL_DIR/fail-new" ] &&
           [ "$version" = "1.98.9" ]; then
            backend="Starting"
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
shift
exec "$@"
EOF
    chmod 0755 "$path"
}

make_jsonfilter_mock() {
    path="$1"
    cat > "$path" <<'EOF'
#!/bin/sh
file=""
expression=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -i)
            file="$2"
            shift 2
            ;;
        -e)
            expression="$2"
            shift 2
            ;;
        *)
            exit 2
            ;;
    esac
done
case "$expression" in
    '@.BackendState')
        sed -n 's/.*"BackendState":"\([^"]*\)".*/\1/p' "$file"
        ;;
    '@.Version')
        sed -n 's/.*"Version":"\([^"]*\)".*/\1/p' "$file"
        ;;
    '@.Self.ID')
        sed -n 's/.*"ID":"\([^"]*\)".*/\1/p' "$file"
        ;;
    '@.TUN')
        sed -n 's/.*"TUN":\([^,}]*\).*/\1/p' "$file"
        ;;
    '@.Self.InEngine')
        sed -n 's/.*"InEngine":\([^,}]*\).*/\1/p' "$file"
        ;;
    '@.Self.TailscaleIPs[0]')
        sed -n 's/.*"TailscaleIPs":\["\([^"]*\)"\].*/\1/p' "$file"
        ;;
    *)
        exit 2
        ;;
esac
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
        "$ROOT/etc/init.d" \
        "$ROOT/etc/tailscale" \
        "$ROOT/var/run/jammonitor" \
        "$ROOT/var/run/tailscale" \
        "$ROOT/proc/4242" \
        "$CONTROL" \
        "$TOOLS" \
        "$TEST_ROOT/work"

    : > "$CONTROL/actions"
    : > "$CONTROL/running"
    printf '%s\n' "$backend" > "$CONTROL/backend"
    printf '%s\n' "$backend" > "$CONTROL/original-backend"
    printf '%s\n' "$old_version" > "$CONTROL/runtime-version"
    printf '%s\n' "node-stable-123" > "$CONTROL/stable-id"
    if [ "$backend" = "Running" ]; then
        printf 'true\n' > "$CONTROL/tun"
        printf 'true\n' > "$CONTROL/in-engine"
        printf '100.104.78.42\n' > "$CONTROL/tailnet-ip"
    else
        printf 'false\n' > "$CONTROL/tun"
        printf 'false\n' > "$CONTROL/in-engine"
        printf '\n' > "$CONTROL/tailnet-ip"
    fi
    printf '%s\n' "SUPER_SECRET_STATE" \
        > "$ROOT/etc/tailscale/tailscaled.state"
    chmod 0600 "$ROOT/etc/tailscale/tailscaled.state"
    printf 'tailscaled\n' > "$ROOT/proc/4242/comm"
    : > "$ROOT/var/run/tailscale/tailscaled.sock"

    make_tailscale_binary "$ROOT/usr/sbin/tailscale" "$old_version"
    make_tailscaled_binary "$ROOT/usr/sbin/tailscaled" "$old_version"
    make_safe_init "$ROOT/etc/init.d/tailscale"
    make_timeout_mock "$TOOLS/timeout"
    make_jsonfilter_mock "$TOOLS/jsonfilter"
    build_package
}

run_upgrade() {
    output="$1"
    LAST_OUTPUT="$output"
    arch="${2:-aarch64}"
    env \
        TS_UPGRADE_TESTING=1 \
        TS_UPGRADE_ROOT="$ROOT" \
        TS_UPGRADE_PACKAGE_SOURCE_DIR="$TEST_ROOT/packages" \
        TS_UPGRADE_EXPECTED_SHA256="$PACKAGE_SHA" \
        TS_UPGRADE_UNAME_OVERRIDE="$arch" \
        TS_UPGRADE_TIMEOUT_CMD="$TOOLS/timeout" \
        TS_UPGRADE_JSONFILTER_CMD="$TOOLS/jsonfilter" \
        TS_UPGRADE_STATUS_ATTEMPTS=2 \
        TS_UPGRADE_STATUS_DELAY=0 \
        TS_UPGRADE_QUIESCE_ATTEMPTS=2 \
        TS_UPGRADE_QUIESCE_DELAY=0 \
        TS_UPGRADE_TMPDIR="$TEST_ROOT/work" \
        TS_UPGRADE_PROC_ROOT="$ROOT/proc" \
        TS_TEST_CONTROL_DIR="$CONTROL" \
        sh "$UPGRADER" > "$output" 2>&1
}

assert_no_secret_output() {
    output="$1"
    ! grep -Fq "SUPER_SECRET_STATE" "$output"
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

test_running_success() {
    setup_case Running
    output="$TEST_ROOT/output"
    if run_upgrade "$output" &&
       [ "$(installed_version)" = "$TARGET_VERSION" ] &&
       [ "$(cat "$ROOT/etc/tailscale/tailscaled.state")" = "SUPER_SECRET_STATE" ] &&
       grep -Eq '^[0-9]+$' "$CONTROL/observed-marker" &&
       [ ! -e "$ROOT/var/run/jammonitor/tailscale-maintenance" ] &&
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
    setup_case Running
    output="$TEST_ROOT/output"
    if ! env \
       TS_UPGRADE_STATUS_ATTEMPTS=1 \
       sh "$UPGRADER" > "$output" 2>&1 &&
       assert_file_contains "$output" "test-only command or timing override refused" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "test overrides are refused outside the test harness"
    else
        fail "test overrides are refused outside the test harness"
    fi
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
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "maintenance marker is malformed" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "malformed maintenance marker is refused before mutation"
    else
        fail "malformed maintenance marker is refused before mutation"
    fi
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
    setup_case Running
    : > "$CONTROL/stable-id"
    output="$TEST_ROOT/output"
    if ! run_upgrade "$output" &&
       assert_file_contains "$output" "lacks StableID" &&
       ! grep -Fq "stop" "$CONTROL/actions"; then
        pass "empty canonical StableID fails before mutation"
    else
        fail "empty canonical StableID fails before mutation"
    fi
}

test_degraded_running_refused() {
    for field in tun in-engine tailnet-ip; do
        setup_case Running
        case "$field" in
            tun) printf 'false\n' > "$CONTROL/tun" ;;
            in-engine) printf 'false\n' > "$CONTROL/in-engine" ;;
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
    pass "Running requires TUN, InEngine, and a real tailnet address"
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

test_running_success
test_needs_login_success
test_checksum_failure
test_architecture_guard
test_production_override_guard
test_unsafe_init_guard
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
test_degraded_running_refused
test_installed_hash_mismatch_rolls_back
test_additional_unsafe_init_guards
test_incomplete_rollback_preserves_recovery

cleanup_case
printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
