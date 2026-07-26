#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

TEST_NUMBER=0

ok() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    printf 'ok %s - %s\n' "$TEST_NUMBER" "$1"
}

fail() {
    TEST_NUMBER=$((TEST_NUMBER + 1))
    printf 'not ok %s - %s\n' "$TEST_NUMBER" "$1"
    exit 1
}

require_fixed() {
    _description="$1"
    _text="$2"
    _file="$3"
    grep -F -- "$_text" "$_file" >/dev/null 2>&1 ||
        fail "$_description"
    ok "$_description"
}

reject_fixed() {
    _description="$1"
    _text="$2"
    _file="$3"
    if grep -F -- "$_text" "$_file" >/dev/null 2>&1; then
        fail "$_description"
    fi
    ok "$_description"
}

extract_shell_fence_after() {
    _source="$1"
    _needle="$2"
    _destination="$3"
    awk -v needle="$_needle" '
        !seen && index($0, needle) {
            seen = 1
            next
        }
        seen && !in_fence && $0 == "```bash" {
            in_fence = 1
            next
        }
        in_fence && $0 == "```" {
            complete = 1
            exit
        }
        in_fence {
            print
        }
        END {
            if (!seen || !in_fence || !complete) {
                exit 1
            }
        }
    ' "$_source" >"$_destination"
}

node --check jammonitor.js >/dev/null 2>&1 ||
    fail "frontend JavaScript parses"
ok "frontend JavaScript parses"
node --check jammonitor-i18n.js >/dev/null 2>&1 ||
    fail "frontend localization JavaScript parses"
ok "frontend localization JavaScript parses"

for script in \
    router/jammonitor-collect \
    router/jammonitor-history.init \
    router/jammonitor-tailscale-watchdog \
    router/jammonitor-tailscale-watchdog.init \
    router/tailscale.init \
    router/upgrade-tailscale-arm64.sh \
    router/install-jammonitor-router.sh \
    router/generate-router-manifest.sh
do
    sh -n "$script" || fail "$script parses under POSIX sh"
done
ok "all router shell payloads parse under POSIX sh"

require_fixed \
    "clients API uses the semantic watchdog projection" \
    "result.tailscale_status = ts_projection" \
    jammonitor.lua
require_fixed \
    "peer data crosses LuCI only through an allowlisted projection" \
    "local peers = project_tailscale_peers(ts_live)" \
    jammonitor.lua
require_fixed \
    "LuCI fallback reads the configured critical-peer contract" \
    "local peer_configured, peer_state = critical_peer_contract_state()" \
    jammonitor.lua
require_fixed \
    "LuCI fallback cannot claim delivery for an unobserved critical peer" \
    'reason = "critical_peer_unobserved"' \
    jammonitor.lua
reject_fixed \
    "legacy raw Tailscale JSON is not returned to the browser" \
    "result.tailscale = ts_status" \
    jammonitor.lua
require_fixed \
    "Tailscale LocalAPI queries have an external deadline" \
    '"timeout -s TERM -k 2 3 /bin/sh -c "' \
    jammonitor.lua
require_fixed \
    "LuCI LocalAPI capture has a 64 KiB child file limit" \
    "'ulimit -f 128 || exit 125; shift; exec" \
    jammonitor.lua
require_fixed \
    "LuCI supervisor queries have a bounded tri-state path" \
    'enabled = checked_init_state("/etc/init.d/tailscale", "enabled", 3)' \
    jammonitor.lua
require_fixed \
    "LuCI malformed Health fallback is explicitly degraded" \
    'state, reason = "running_degraded", "health_state_unknown"' \
    jammonitor.lua
require_fixed \
    "LuCI rejects symlinked critical-peer contracts with lstat" \
    'local stat = fs.lstat(TAILSCALE_CRITICAL_PEER)' \
    jammonitor.lua
require_fixed \
    "LuCI pins cached status to one bounded regular inode" \
    'TAILSCALE_WATCHDOG_STATUS, 16384' \
    jammonitor.lua
require_fixed \
    "the router critical-peer probe selects TSMP explicitly" \
    '--tsmp --c=1 --timeout=3s --until-direct=false -- "$CRITICAL_PEER"' \
    router/jammonitor-tailscale-watchdog
require_fixed \
    "router acceptance reads the warning count" \
    "WATCHDOG_WARNINGS=" \
    README.md
require_fixed \
    "router acceptance requires a real warning for warning state" \
    '[ "$WATCHDOG_WARNINGS" -gt 0 ]' \
    README.md
require_fixed \
    "router acceptance includes a fresh tailnet SSH transport probe" \
    'exec 3<>"/dev/tcp/$1/22"' \
    README.md
require_fixed \
    "router acceptance includes the JamMonitor LuCI application path" \
    '/cgi-bin/luci/admin/status/jammonitor' \
    README.md
require_fixed \
    "VPS acceptance verifies the exact configured router peer" \
    'sudo cat /etc/jammonitor/tailscale-critical-peer' \
    vps/README.md
require_fixed \
    "VPS acceptance semantically disables Tailscale DNS" \
    '.CorpDNS == false and' \
    vps/README.md
require_fixed \
    "VPS acceptance keeps update checks enabled" \
    '.AutoUpdateCheck == true and' \
    vps/README.md
require_fixed \
    "VPS acceptance disables unattended Tailscale updates" \
    '.AutoUpdateApply == false' \
    vps/README.md
require_fixed \
    "VPS preference transaction sets the reviewed update policy" \
    '--update-check=true' \
    vps/README.md
require_fixed \
    "VPS preference rollback restores prior auto-update application" \
    '--auto-update="$BEFORE_AUTO_UPDATE"' \
    vps/README.md
require_fixed \
    "router preferences use a streaming allowlisted projection" \
    "SECRET_SENTINEL" \
    README.md
require_fixed \
    "router raw preference producer feeds jsonfilter directly" \
    'exec jsonfilter \' \
    README.md
require_fixed \
    "router forced reauthentication repeats the reviewed nondefault settings" \
    '--force-reauth \' \
    README.md
require_fixed \
    "router forced reauthentication is bounded by the CLI" \
    '--timeout=10m' \
    README.md
require_fixed \
    "router reauthentication captures stdout privately" \
    'AUTH_STDOUT="$RUNTIME/tailscale-reauth.stdout"' \
    README.md
require_fixed \
    "router reauthentication captures stderr privately" \
    'AUTH_STDERR="$RUNTIME/tailscale-reauth.stderr"' \
    README.md
require_fixed \
    "router reauthentication capture has a kernel file-size ceiling" \
    'ulimit -f 8 || exit 125' \
    README.md
require_fixed \
    "router reauthentication records the exact command status" \
    'AUTH_RC_TMP="$(mktemp "$RUNTIME/tailscale-reauth.rc.XXXXXX")"' \
    README.md
require_fixed \
    "router authentication URL is passed to LaunchServices only on stdin" \
    "NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile" \
    README.md
reject_fixed \
    "router authentication URL is never exposed in open command arguments" \
    '/usr/bin/open "$AUTH_URL"' \
    README.md
AUTH_TRACE_OFF_COUNT="$(grep -c '^ *set +x$' README.md)"
[ "$AUTH_TRACE_OFF_COUNT" -eq 4 ] ||
    fail "every router authentication shell disables tracing explicitly"
ok "every router authentication shell disables tracing explicitly"
AUTH_ALLEXPORT_OFF_COUNT="$(grep -c '^ *set +a$' README.md)"
[ "$AUTH_ALLEXPORT_OFF_COUNT" -eq 4 ] ||
    fail "every router authentication shell disables inherited allexport"
ok "every router authentication shell disables inherited allexport"
AUTH_URL_CAPTURE_LINE="$(
    grep -n '^AUTH_URL=' README.md | head -n 1 | cut -d: -f1
)"
AUTH_LOCAL_TRACE_OFF_LINE="$(
    grep -n '^set +x$' README.md |
        awk -F: -v auth_line="$AUTH_URL_CAPTURE_LINE" \
            '$1 < auth_line { line = $1 } END { print line }'
)"
case "$AUTH_LOCAL_TRACE_OFF_LINE:$AUTH_URL_CAPTURE_LINE" in
    *[!0-9:]*|:*|*:) fail "local tracing is disabled before URL capture" ;;
esac
[ "$AUTH_LOCAL_TRACE_OFF_LINE" -lt "$AUTH_URL_CAPTURE_LINE" ] ||
    fail "local tracing is disabled before URL capture"
ok "local tracing is disabled before URL capture"
AUTH_TRACE_SENTINEL="https://login.tailscale.com/a/TRACELEAKSENTINEL"
AUTH_TRACE_OUTPUT="$(
    (
        set -x
        set +x
        AUTH_URL="$AUTH_TRACE_SENTINEL"
        : "$AUTH_URL"
    ) 2>&1
)"
case "$AUTH_TRACE_OUTPUT" in
    *TRACELEAKSENTINEL*)
        fail "forced trace disablement keeps authentication URLs out of xtrace"
        ;;
esac
ok "forced trace disablement keeps authentication URLs out of xtrace"
require_fixed \
    "local URL capture removes inherited export attributes" \
    'unset AUTH_URL AUTH_TOKEN OPEN_RC' \
    README.md
require_fixed \
    "remote URL capture removes inherited export attributes" \
    'unset MATCHES TOKEN' \
    README.md
AUTH_EXPORT_SENTINEL="https://login.tailscale.com/a/EXPORTLEAKSENTINEL"
AUTH_EXPORT_OUTPUT="$(
    (
        AUTH_URL=preexisting
        export AUTH_URL
        set -a
        set +a
        unset AUTH_URL
        AUTH_URL="$AUTH_EXPORT_SENTINEL"
        env
    ) 2>&1
)"
case "$AUTH_EXPORT_OUTPUT" in
    *EXPORTLEAKSENTINEL*)
        fail "forced allexport disablement keeps authentication URLs out of child environments"
        ;;
esac
ok "forced allexport disablement keeps authentication URLs out of child environments"
require_fixed \
    "exceptional recovery bounds the private status command" \
    'exec timeout -s TERM -k 2 5 \' \
    README.md
require_fixed \
    "exceptional recovery bounds the private status capture" \
    '[ "$STATUS_SIZE" -le 65536 ]' \
    README.md
require_fixed \
    "exceptional recovery verifies a private root-only status inode" \
    '[ "$(stat -c '\''%u:%g:%a:%h'\'' "$STATUS_TMP")" = '\''0:0:600:1'\'' ]' \
    README.md
require_fixed \
    "router authentication URL retrieval offers only the reviewed SSH key" \
    '-o IdentitiesOnly=yes \' \
    README.md
require_fixed \
    "router authentication URL retrieval has a connection deadline" \
    '-o ConnectTimeout=5 \' \
    README.md
require_fixed \
    "interrupted router authentication cannot imply a published return code" \
    'A missing final return-code file' \
    README.md
require_fixed \
    "router post-auth preference mutation has an external deadline" \
    'timeout -s TERM -k 2 10 \' \
    README.md
reject_fixed \
    "router reauthentication does not silently reset unreviewed settings" \
    '--reset \' \
    README.md
require_fixed \
    "VPS preferences use a streaming allowlisted projection" \
    'AutoUpdateApply: .AutoUpdate.Apply' \
    vps/README.md
require_fixed \
    "VPS raw preference producer feeds jq directly" \
    'exec /usr/bin/jq -sce' \
    vps/README.md
require_fixed \
    "preference projections have a kernel output ceiling" \
    'ulimit -f 1' \
    vps/README.md
require_fixed \
    "preference projection processes disable core dumps" \
    'ulimit -c 0 ||' \
    vps/README.md
require_fixed \
    "VPS rollback failure is operator-visible" \
    'ERROR: Tailscale preference rollback could not be proven' \
    vps/README.md
require_fixed \
    "VPS preference capture does not depend on conditional errexit" \
    '[ "$filter_rc" -eq 0 ] || return 1' \
    vps/README.md
VPS_BOUNDED_SET_COUNT="$(
    grep -F -c \
        'sudo /usr/bin/timeout --signal=TERM --kill-after=2 10 \' \
        vps/README.md
)"
[ "$VPS_BOUNDED_SET_COUNT" -eq 2 ] ||
    fail "both VPS preference mutation and rollback have external deadlines"
ok "both VPS preference mutation and rollback have external deadlines"
reject_fixed \
    "router runbook never writes raw Tailscale preferences" \
    'debug prefs >' \
    README.md
reject_fixed \
    "VPS runbook never writes raw Tailscale preferences" \
    'debug prefs >' \
    vps/README.md
reject_fixed \
    "router raw preference temporary file is retired" \
    'PREFS_TMP' \
    README.md
reject_fixed \
    "VPS raw preference temporary file is retired" \
    'PREFS_AFTER' \
    vps/README.md
ROUTER_PREFS_PROBE_LINE="$(
    grep -n 'SECRET_SENTINEL' README.md | head -n 1 | cut -d: -f1
)"
ROUTER_PREFS_SET_LINE="$(
    grep -n 'tailscale --socket="$SOCKET" set' README.md |
        head -n 1 | cut -d: -f1
)"
case "$ROUTER_PREFS_PROBE_LINE:$ROUTER_PREFS_SET_LINE" in
    *[!0-9:]*|:*|*:) fail "router preference projection is proven before mutation" ;;
esac
[ "$ROUTER_PREFS_PROBE_LINE" -lt "$ROUTER_PREFS_SET_LINE" ] ||
    fail "router preference projection is proven before mutation"
ok "router preference projection is proven before mutation"
require_fixed \
    "VPS acceptance preserves reviewed Debian netfilter mode" \
    '.NetfilterMode == 2' \
    vps/README.md
require_fixed \
    "VPS acceptance rejects any Tailscale ULA resolver" \
    'fd7a:115c:a1e0:' \
    vps/README.md
require_fixed \
    "empty-ID recovery is documented as an explicit digest-pinned mode" \
    '--recover-empty-needs-login-state-sha256' \
    README.md

require_fixed \
    "router watchdog emits schema 3" \
    '"schema":3' \
    router/jammonitor-tailscale-watchdog
reject_fixed \
    "schema-3 watchdog does not republish peer-only InEngine metadata" \
    'in_engine' \
    router/jammonitor-tailscale-watchdog
require_fixed \
    "collector accepts only schema 2 and schema 3 snapshots" \
    'case "$_snapshot_schema" in 2|3) ;; *) return 1 ;; esac' \
    router/jammonitor-collect
require_fixed \
    "collector reads legacy schema-2 InEngine evidence" \
    "_in_engine=\"\$(watchdog_json_value '@.in_engine')\"" \
    router/jammonitor-collect
require_fixed \
    "collector verifies legacy InEngine JSON type" \
    "_in_engine_type=\"\$(watchdog_json_type '@.in_engine')\"" \
    router/jammonitor-collect
require_fixed \
    "collector gates legacy delivered connectivity on InEngine true" \
    '[ "$_in_engine" = "true" ] || return 1' \
    router/jammonitor-collect
require_fixed \
    "collector enforces JSON types for every delivery boolean" \
    '_healthy_type="$(watchdog_json_type '\''@.healthy'\'')"' \
    router/jammonitor-collect
require_fixed \
    "collector pins one bounded watchdog snapshot before parsing" \
    'if ! pin_watchdog_snapshot "$WATCHDOG_STATUS"; then' \
    router/jammonitor-collect
reject_fixed \
    "collector never parses directly from the atomically replaced producer path" \
    'jsonfilter -i "$WATCHDOG_STATUS"' \
    router/jammonitor-collect
require_fixed \
    "collector pins the verified storage mount by descriptor" \
    'exec 8<"$MOUNT_POINT"' \
    router/jammonitor-collect
require_fixed \
    "LuCI live projection emits schema 3" \
    '        schema = 3,' \
    jammonitor.lua
require_fixed \
    "LuCI process fallback requires the exact supervised executable" \
    'executable == TAILSCALED_BINARY' \
    jammonitor.lua
require_fixed \
    "LuCI process fallback refuses multiple matching daemon generations" \
    'if matches > 1 then return nil end' \
    jammonitor.lua
require_fixed \
    "LuCI accepts only persisted schema 2 and schema 3" \
    '       (schema ~= 2 and schema ~= 3) or' \
    jammonitor.lua
require_fixed \
    "LuCI requires a numeric persisted schema" \
    'if type(schema) ~= "number" or' \
    jammonitor.lua
require_fixed \
    "LuCI gates legacy delivered connectivity on InEngine true" \
    '       parsed.in_engine ~= true then' \
    jammonitor.lua
require_fixed \
    "LuCI requires exact schema-2 InEngine boolean type" \
    'if type(parsed.in_engine) ~= "boolean" then return false end' \
    jammonitor.lua
require_fixed \
    "LuCI storage readiness accepts only ext4" \
    'persistent = fstype == "ext4"' \
    jammonitor.lua
require_fixed \
    "LuCI healthy snapshots require zero warnings" \
    'parsed.health_warnings ~= 0' \
    jammonitor.lua
WATCHDOG_FIELDS_BLOCK="$(
    sed -n '/^local WATCHDOG_FIELDS = {/,/^}/p' jammonitor.lua
)"
case "$WATCHDOG_FIELDS_BLOCK" in
    *in_engine*) fail "LuCI allowlist republishes legacy InEngine metadata" ;;
esac
ok "schema-2 InEngine is compatibility-only and cannot cross the LuCI allowlist"
for file in jammonitor.js; do
    for obsolete in Self.InEngine in_engine engine_inactive engine_state_unknown
    do
        if grep -F "$obsolete" "$file" >/dev/null 2>&1; then
            fail "$file treats peer-only InEngine metadata as current self health"
        fi
    done
done
ok "current browser semantics ignore peer-only InEngine metadata"
require_fixed \
    "browser explains an invalid critical-peer configuration" \
    "critical_peer_invalid: {" \
    jammonitor.js
require_fixed \
    "browser distinguishes invalid peer configuration from reachability loss" \
    "status.peer_state === 'invalid_configuration'" \
    jammonitor.js

require_fixed \
    "clients polling has a browser deadline" \
    "api('clients', null, { timeoutMs: 7000 })" \
    jammonitor.js
require_fixed \
    "the updated JamMonitor client uses a fresh browser cache key" \
    'jammonitor.js?v=125' \
    jammonitor.htm
reject_fixed \
    "the prior JamMonitor client cache key is retired" \
    'jammonitor.js?v=124' \
    jammonitor.htm
require_fixed \
    "the explicit Tailscale health panel is present" \
    "id=\"tailscale-health\"" \
    jammonitor.htm
require_fixed \
    "the Overview tab has an independent Tailscale health panel" \
    "id=\"tailscale-health-overview\"" \
    jammonitor.htm
require_fixed \
    "HTML escaping protects double-quoted attributes" \
    ".replace(/\"/g, '&quot;')" \
    jammonitor.js
require_fixed \
    "HTML escaping protects single-quoted attributes" \
    ".replace(/'/g, '&#39;')" \
    jammonitor.js
reject_fixed \
    "dynamic speed-test controls do not interpolate WAN names into inline handlers" \
    "onclick=\"JamMonitor.runSpeedTest" \
    jammonitor.js
require_fixed \
    "dynamic speed-test controls use inert direction data" \
    "data-direction=\"download\"" \
    jammonitor.js
require_fixed \
    "the AWS monitor grants the documented exact log-group stream ARN" \
    "Resource: !GetAtt MonitorLogGroup.Arn" \
    monitoring/aws/template.yaml
reject_fixed \
    "the AWS monitor does not append a second wildcard to the log-group ARN" \
    "MonitorLogGroup.Arn}:*" \
    monitoring/aws/template.yaml

UPDATE_FUNCTION="$(
    awk '
        /^function action_update_start\(\)/ { capture = 1 }
        capture { print }
        capture && /^end$/ { exit }
    ' jammonitor.lua
)"
printf '%s\n' "$UPDATE_FUNCTION" | grep -F "manual_update_required = true" >/dev/null 2>&1 ||
    fail "LuCI update action is explicitly non-mutating"
if printf '%s\n' "$UPDATE_FUNCTION" | grep -E "wget|curl|mv |cp |/etc/init.d/" >/dev/null 2>&1; then
    fail "LuCI update action contains no installer or service mutation"
fi
ok "LuCI update action is explicitly non-mutating"

reject_fixed \
    "Tailscale service stop never persists an administrative down state" \
    "tailscale down" \
    router/tailscale.init
require_fixed \
    "Tailscale pins the UDP listener required by netfilter-mode off" \
    'procd_append_param command --port=41641' \
    router/tailscale.init
for gated_init in \
    router/tailscale.init \
    router/jammonitor-history.init \
    router/jammonitor-tailscale-watchdog.init
do
    require_fixed \
        "$gated_init implements the shared installer boot-fence contract" \
        "JAMMONITOR_BOOT_FENCE_V1" \
        "$gated_init"
    require_fixed \
        "$gated_init accepts only the lock-owning installer token" \
        "JAMMONITOR_INSTALL_FENCE_TOKEN" \
        "$gated_init"
done
require_fixed \
    "Tailscale init refuses unresolved installer recovery evidence" \
    'INSTALL_RECOVERY_UNRESOLVED="/etc/jammonitor/recovery/UNRESOLVED"' \
    router/tailscale.init
require_fixed \
    "Tailscale init refuses an unresolved durable upgrader fence" \
    'UPGRADE_FENCE="/etc/jammonitor/tailscale-upgrade-fence"' \
    router/tailscale.init
require_fixed \
    "the upgrader publishes a root-private durable boot fence" \
    'format=jammonitor-tailscale-upgrade-fence-v1' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the upgrader bounds one global OpenWrt block metadata capture" \
    '"$BLOCK_CMD" info ||' \
    router/upgrade-tailscale-arm64.sh
reject_fixed \
    "the upgrader does not depend on absent blkid" \
    "blkid" \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the upgrader proves a removable parent in sysfs" \
    'storage_sys_removable' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the upgrader pins the recovery device descriptor" \
    'exec 6<"$STORAGE_SOURCE_PATH"' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the upgrader pins the recovery mount-root descriptor" \
    'exec 8<"$PERSISTENT_MOUNT"' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the installer fetch path has a kernel file-size limit" \
    'jammonitor-fetch-limit "$fetch_blocks"' \
    router/install-jammonitor-router.sh
require_fixed \
    "installer restart acceptance requires fresh history status" \
    'wait_history_readiness "$history_restart_epoch"' \
    router/install-jammonitor-router.sh
require_fixed \
    "installer restart acceptance requires stable watchdog status" \
    'wait_watchdog_readiness "$watchdog_restart_epoch"' \
    router/install-jammonitor-router.sh
require_fixed \
    "repair publishes the synchronized installer fence" \
    'publish_install_fence' \
    router/install-jammonitor-router.sh
require_fixed \
    "persistent recovery uses exact non-executable mount options" \
    'rw,noatime,nosuid,nodev,noexec' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "the upgrader archive fetch has a kernel file-size limit" \
    'jammonitor-fetch-limit "$file_blocks"' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "archive extraction is preceded by an expanded-size ceiling" \
    'ARCHIVE_MAX_EXPANDED_BYTES=134217728' \
    router/upgrade-tailscale-arm64.sh
require_fixed \
    "installer init gates are synchronized before runtime payload mutation" \
    "could not durably publish all boot-gated init payloads" \
    router/install-jammonitor-router.sh
require_fixed \
    "collector health requires a fresh semantic report" \
    "result.collector_report_fresh == true" \
    jammonitor.lua
require_fixed \
    "installed files reject symlinks" \
    '[ -f "$file" ] && [ ! -L "$file" ]' \
    router/install-jammonitor-router.sh
require_fixed \
    "installed files enforce exact mode and root ownership" \
    "stat -c '%a:%u:%g'" \
    router/install-jammonitor-router.sh
RUNBOOK_EXACT_MOUNT_COUNT="$(
    grep -F -c 'option_count == 5 &&' README.md
)"
[ "$RUNBOOK_EXACT_MOUNT_COUNT" -eq 2 ] ||
    fail "both router storage preflights require exactly five live mount options"
ok "both router storage preflights require exactly five live mount options"
RUNBOOK_STORAGE_AUTHORITY_COUNT="$(
    grep -F -c '. /usr/bin/jammonitor-collect' README.md
)"
[ "$RUNBOOK_STORAGE_AUTHORITY_COUNT" -eq 2 ] ||
    fail "both router storage preflights invoke the installed UUID and fstab authority proof"
ok "both router storage preflights invoke the installed UUID and fstab authority proof"
RUNBOOK_STORAGE_JOIN_COUNT="$(
    grep -F -c \
        '[ "$PROVED_STORAGE_SOURCE" = "$STORAGE_SOURCE" ]' README.md
)"
[ "$RUNBOOK_STORAGE_JOIN_COUNT" -eq 2 ] ||
    fail "both router storage preflights join the proved and observed source"
ok "both router storage preflights join the proved and observed source"
reject_fixed \
    "router runbook does not require the unavailable mountpoint utility" \
    "mountpoint -q" \
    README.md

RUNBOOK_TEST_DIR="$(
    mktemp -d "${TMPDIR:-/tmp}/jammonitor-runbook-contract.XXXXXX"
)"
trap 'rm -rf "$RUNBOOK_TEST_DIR"' EXIT HUP INT TERM
extract_shell_fence_after README.md \
    "Use the maintenance marker before an intentional Tailscale service change:" \
    "${RUNBOOK_TEST_DIR}/router-maintenance.sh" ||
    fail "router manual-maintenance fence can be extracted deterministically"
extract_shell_fence_after README.md \
    "With a separate LAN session still working, perform one controlled generation" \
    "${RUNBOOK_TEST_DIR}/router-generation-reset.sh" ||
    fail "router generation-reset fence can be extracted deterministically"
extract_shell_fence_after vps/README.md \
    "### Bounded maintenance marker" \
    "${RUNBOOK_TEST_DIR}/vps-maintenance.sh" ||
    fail "VPS manual-maintenance fence can be extracted deterministically"
extract_shell_fence_after vps/README.md \
    "This is a deliberate service restart, not a crash injection:" \
    "${RUNBOOK_TEST_DIR}/vps-generation-reset.sh" ||
    fail "VPS generation-reset fence can be extracted deterministically"
for runbook_script in "${RUNBOOK_TEST_DIR}"/*.sh; do
    sh -n "$runbook_script" ||
        fail "${runbook_script##*/} parses under POSIX sh"
    dash -n "$runbook_script" ||
        fail "${runbook_script##*/} parses under dash"
done
ok "all four lock-held maintenance runbooks parse under sh and dash"
[ "$(grep -F -c 'is_uint "$5" && is_uint "$6" && is_uint "$7"' README.md)" \
    -eq 2 ] &&
    [ "$(grep -F -c '[ "$7" -le 1024 ]' README.md)" -eq 2 ] ||
    fail "both router maintenance runbooks bound exact lock metadata"
ok "both router maintenance runbooks bound exact lock metadata"
[ "$(grep -F -c 'MARKER_EXPECTED_BYTES=$((' vps/README.md)" -eq 2 ] &&
    [ "$(grep -F -c '"$MARKER_EXPECTED_BYTES" ] &&' vps/README.md)" -eq 2 ] ||
    fail "both VPS maintenance runbooks prove exact marker byte length"
ok "both VPS maintenance runbooks prove exact marker byte length"
rm -rf "$RUNBOOK_TEST_DIR"
trap - EXIT HUP INT TERM

printf '1..%s\n' "$TEST_NUMBER"
