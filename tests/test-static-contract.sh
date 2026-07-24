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
    grep -F "$_text" "$_file" >/dev/null 2>&1 ||
        fail "$_description"
    ok "$_description"
}

reject_fixed() {
    _description="$1"
    _text="$2"
    _file="$3"
    if grep -F "$_text" "$_file" >/dev/null 2>&1; then
        fail "$_description"
    fi
    ok "$_description"
}

node --check jammonitor.js >/dev/null 2>&1 ||
    fail "frontend JavaScript parses"
ok "frontend JavaScript parses"

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
    "result.tailscale_peers = project_tailscale_peers(ts_live)" \
    jammonitor.lua
reject_fixed \
    "legacy raw Tailscale JSON is not returned to the browser" \
    "result.tailscale = ts_status" \
    jammonitor.lua
require_fixed \
    "Tailscale LocalAPI queries have an external deadline" \
    "local command = \"timeout 3 \" .. TAILSCALE_CLI" \
    jammonitor.lua
require_fixed \
    "clients polling has a browser deadline" \
    "api('clients', null, { timeoutMs: 7000 })" \
    jammonitor.js
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
reject_fixed \
    "router runbook does not require the unavailable mountpoint utility" \
    "mountpoint -q" \
    README.md

printf '1..%s\n' "$TEST_NUMBER"
