# JamMonitor

A comprehensive WAN bonding dashboard for OpenMPTCProuter, designed for the Banana Pi BPI-R4 router platform. JamMonitor provides an intuitive web interface for monitoring, managing, and prioritizing multiple WAN connections with real-time statistics and drag-and-drop configuration.

## Features

- **Real-time Monitoring** - Live system health, throughput graphs, and latency tracking
- **Drag-and-Drop WAN Management** - Easily reorder and prioritize WAN connections
- **Multi-WAN Bonding** - Aggregate bandwidth across multiple internet connections
- **Failover Configuration** - Set up automatic failover with standby connections
- **Client Monitoring** - View all connected devices with traffic statistics
- **DHCP Reservations** — Create static IP assignments for connected devices
- **Tailscale Health & Peers** — Semantic health on Overview plus peers alongside LAN clients
- **WiFi AP Management** - Monitor local radios and remote access points
- **Diagnostic Tools** - Export comprehensive diagnostic bundles for troubleshooting
- **USB Storage & History** — Persistent metrics and ping history on USB storage with SQLite
- **Bandwidth Analytics** - Track usage by hour, day, and month with visual charts
- **Speed Testing** — Run download/upload speed tests per WAN interface
- **VPS Bypass Mode** — One-click toggle to route traffic directly without VPN
- **Verified Updates:** GitHub version detection with pinned, checksum-verified deployment
- **Multi-Language Support** — 22 languages with automatic browser detection

---

## Screenshots

### Overview Dashboard

<img width="2042" height="1472" alt="image" src="https://github.com/user-attachments/assets/d63924ed-9e85-4c44-94f3-6ae6852a4917" />


The Overview tab provides a bird's-eye view of your entire network at a glance:

- **Tailscale Health** — Backend condition, delivered connectivity, key expiry, watchdog state, and critical-peer reachability
- **VPN/Tunnel Status** - Current tunnel IP, connection status, endpoint, and uptime
- **System Health** - CPU temperature, load average, RAM usage, and connection tracking
- **WAN IPv4** - Public IP address and gateway information
- **Ping Monitors** - Real-time latency graphs for Internet (1.1.1.1), VPS, and Tunnel endpoints with packet loss tracking
- **System Uptime** - Boot time and local time display
- **MPTCP Status** - Active subflows and connected interfaces
- **Throughput** - Live download/upload speeds with mini graphs

---

### WAN Policy Manager

<img width="2044" height="1436" alt="image" src="https://github.com/user-attachments/assets/c18c68b9-61dc-4c3d-831d-e0ad156346e3" />


The WAN Policy tab is the heart of JamMonitor's connection management:

- **Drag-and-Drop Interface** - Simply drag WAN interfaces between priority categories
- **Priority Categories:**
  - **Primary** - Main connection (only one allowed) - all MPTCP traffic originates here
  - **Bonded** - Aggregated with Primary for combined bandwidth
  - **Standby** - Failover connections that activate when Primary/Bonded fail
  - **Disabled** - Completely turned off interfaces
- **Live Status Indicators** - See connection status (Connected/Disconnected/Disabled) in real-time
- **Click-to-Edit** - Click any WAN name to edit its settings (IP, DNS, MTU, protocol)
- **IP Details Popup** - Click IP addresses to view full network details (subnet, gateway, DNS)

---

### Interfaces & Routing

<img width="2040" height="1240" alt="image" src="https://github.com/user-attachments/assets/954698f2-1a4f-4618-b05e-ac58c1986401" />
<img width="2042" height="718" alt="image" src="https://github.com/user-attachments/assets/80ae620c-9cfd-4d60-88de-9ca68ebb12e9" />


Complete visibility into your network interfaces:

- **Categorized Display** - Interfaces grouped by type (WAN, LAN, VPN, WiFi, Physical)
- **Status Indicators** - Quick visual status for each interface (UP/DOWN)
- **Traffic Statistics** - RX/TX byte counters for each interface
- **IP Address Display** - Current IP assignments
- **Routing Table** - Full system routing table with destinations, gateways, and interfaces

---

### Client List

<img width="2012" height="1092" alt="image" src="https://github.com/user-attachments/assets/5575b418-2ed4-4b88-943e-f5b6f3e8c0d5" />


Comprehensive device tracking and management for all connected clients:

- **All Connected Devices** — Hostname, IP, and MAC for every client
- **Per-Client Traffic** — Download/upload metrics via conntrack
- **Device Type Detection** — Automatic identification (phone, tablet, laptop, desktop, TV, IoT, camera, wearable, etc.)
- **Custom Device Names** — Inline editing for friendly names
- **Manual Type Override** — Change detected device type
- **DHCP Reservations** — Create static IP assignments for connected devices
- **Tailscale Integration** — Tailscale peers shown alongside LAN clients
- **Subnet Grouping** — Clients grouped by subnet with collapsible sections
- **Sortable Columns** — Sort by IP, name, download, upload, MAC
- **Persistent Metadata** — Client data saved to `/etc/jammonitor_clients.json`

---

### Wi-Fi APs

<img width="2016" height="1282" alt="image" src="https://github.com/user-attachments/assets/3714eb5a-8af1-4d5a-b5bd-8a9ae4f75bc8" />


Monitor wireless networks and access points:

- **Local Radio Status** — Channel, TX power, and client count
- **Remote AP Monitoring** — Latency tracking for remote access points
- **Configurable AP List** — Multi-AP deployments with editable configuration
- **Online/Offline Status Badges** — Real-time AP availability

---

### Diagnostics & Data Export

<img width="2016" height="1312" alt="image" src="https://github.com/user-attachments/assets/6cb6021b-936b-4217-ad8a-62b64f9b0904" />


Diagnostic tools and persistent data storage on the Diagnostics tab:

- **Diagnostic Bundle Export** — Generate comprehensive bundles including system logs, network state, VPN status, MPTCP info, firewall rules, and more
- **Automatic Secret Redaction** — Tokens, passwords, and keys stripped from output
- **USB Device Detection** — Shows capacity info
- **One-Click ext4 Formatting**
- **Mount/Unmount Management** — Mounts to `/mnt/data`
- **SQLite Database** — Stores bandwidth, ping, and client traffic history
- **Background Collector Process** — Writes every 60s with start/stop controls
- **Storage Dashboard** — DB size, entry count, date range, and free space
- **Automatic Data Retention** — 30-day default cleanup

---

### Bandwidth Analytics

<img width="2030" height="1498" alt="image" src="https://github.com/user-attachments/assets/a9d23577-9517-4b35-a771-71369677ff44" />


Comprehensive bandwidth tracking across multiple timeframes:

- **Realtime** - Live throughput graph updated every 3 seconds
- **Hourly** - Last 24 hours of usage broken down by hour
- **Daily** - Last 30 days of bandwidth consumption
- **Monthly** - Long-term usage trends by month
- **Per-Interface Filtering** - View bandwidth for specific WANs or all combined
- **Stacked Bar Charts** - Visual breakdown of download vs upload traffic
- **Data Tables** - Detailed numeric values alongside graphs

---

### Speed Testing

<img width="2000" height="848" alt="image" src="https://github.com/user-attachments/assets/36652612-12f0-48f2-8e76-7907bf0b281a" />

Test WAN speeds directly from the dashboard with multiple server options.

- **Multi-Server Selection** — Cloudflare, CacheFly CDN
- **Per-WAN Interface Testing** — Test individual connections
- **Download and Upload Tests** — Upload via Cloudflare
- **Configurable Test Sizes** — 10/25/100 MB options
- **Real-Time Progress Tracking** — Speed results displayed in Mbps
- **Regional Server Auto-Detection**

---

### VPS Bypass Mode

<img width="2000" height="1476" alt="image" src="https://github.com/user-attachments/assets/8b33b970-90cc-409a-8e82-94a30e463b76" />

Temporarily bypass the VPN tunnel for direct internet routing.

- **One-Click Toggle** — Activate from the Overview tab
- **Confirmation Dialog** — Service impact warning before activation
- **Active WAN Indicator** — Shows which connection is in use
- **Persistent Status Banner** — Visible while bypass is active
- **Automatic Service Management** — Stops/starts OpenVPN and Shadowsocks services
- **WAN Policy Lock** — Policy controls locked during bypass for safety

---

### Update Detection and Verified Deployment

<img width="664" height="524" alt="image" src="https://github.com/user-attachments/assets/32905692-cd45-49cc-af6a-5faf9bc80991" />

JamMonitor can detect when the GitHub repository has a newer commit. The web
interface intentionally has no install button, and the backend update action
refuses to install files. Production changes must use the pinned router
installer.

- **Version Comparison:** Compares the installed SHA with the latest GitHub commit
- **Update Badge:** Orange indicator on the settings gear when an update is available
- **Production Upgrade Path:** The router installer verifies a pinned commit and checksum manifest
- **Transactional Install:** Existing owned files are restored if validation or installation fails
- **Service Coverage:** The installer includes the UI, controller, history collector, Tailscale watchdog, and init scripts

The retired four-file updater did not cover the collector and watchdog
services. It also fetched from a moving source without a release manifest.

---

### Multi-Language Support (i18n)

<img width="664" height="536" alt="image" src="https://github.com/user-attachments/assets/7f362c51-82c3-4210-9d38-3539aaf6e4db" />
<img width="604" height="1034" alt="image" src="https://github.com/user-attachments/assets/30c7b3a0-e028-45b2-aa78-dabf7e5b5d00" />

Full interface translation with 22 languages.

- **Languages** — English, Chinese (Simplified/Traditional), Spanish, German, French, Portuguese, Russian, Japanese, Italian, Dutch, Polish, Korean, Turkish, Vietnamese, Arabic, Thai, Indonesian, Czech, Swedish, Greek, Ukrainian
- **Automatic Browser Detection** — Detects preferred language from browser settings
- **Manual Override** — Language selector in settings popup
- **Persistent Selection** — Saved to localStorage

---

## Installation

### Prerequisites

- OpenMPTCProuter installed on BPI-R4 (or compatible OpenWrt device)
- LuCI web interface enabled
- SSH access to the router
- Standalone `tailscale` and `tailscaled` binaries already installed in `/usr/sbin`
- `timeout`, `jsonfilter`, `sqlite3`, `conntrack`, `flock`, and `sha256sum`
  installed on the router
- Persistent ext4 storage mounted at `/mnt/data` before history collection starts

The canonical service names are:

- `tailscale`
- `jammonitor-tailscale-watchdog`
- `jammonitor-history`

`jammonitor-collect` is a legacy service name. The installer disables a known
legacy service to prevent two collectors from writing the same database. If
that legacy service is running, the installer stops it and starts the
canonical history service after validation. It does not delete the legacy init
file, and a failed transaction restores its prior enable and running state.

### Release Manifest Finalization

The checksum manifest is deterministic, but it cannot be considered final
until all payload edits are complete. Run the complete regression and syntax
gate from a clean release checkout before generating it:

```bash
set -eu
for test in \
  tests/test-collector.sh \
  tests/test-luci-mutation-security.sh \
  tests/test-luci-transactions.sh \
  tests/test-router-installer.sh \
  tests/test-static-contract.sh \
  tests/test-tailscale-upgrade.sh \
  tests/test-tailscale-watchdog.sh \
  tests/test-vps-tailscale-installer.sh \
  tests/test-vps-tailscale-watchdog.sh
do
  "$test"
done
python3 -m unittest discover -s monitoring/aws/tests -p 'test_*.py'
cfn-lint --template monitoring/aws/template.yaml --regions us-east-1
node --check jammonitor.js
for script in \
  router/*.sh router/*.init router/jammonitor-collect \
  router/jammonitor-tailscale-watchdog router/tailscale.init \
  vps/*.sh vps/jammonitor-tailscale-watchdog
do
  sh -n "$script"
done
git diff --check
```

Then generate the release manifest:

```bash
set -eu
./router/generate-router-manifest.sh
shasum -a 256 -c router/router-files.sha256
git diff -- router/router-files.sha256
```

On Linux or OpenWrt, the installer can also validate a checkout without
installing it. Pass the manifest digest when it came from a separate trusted
release record:

```bash
sh router/install-jammonitor-router.sh \
  --validate-source "$PWD" \
  --manifest-sha256 '<64_HEX_MANIFEST_SHA256>'
```

Run the generator again immediately before creating the release commit. Commit
the generated `router/router-files.sha256` with the payloads. After the commit,
record these three trusted values:

```bash
set -eu
RELEASE_REF="$(git rev-parse HEAD)"
MANIFEST_SHA256="$(shasum -a 256 router/router-files.sha256 | awk '{print $1}')"
INSTALLER_SHA256="$(shasum -a 256 router/install-jammonitor-router.sh | awk '{print $1}')"
printf 'ref=%s\nmanifest=%s\ninstaller=%s\n' \
    "$RELEASE_REF" "$MANIFEST_SHA256" "$INSTALLER_SHA256"
```

Do not publish a manifest generated before the last payload change.

### Verified Remote Install

The remote installer accepts only a full 40-character Git commit. Branch
names, tags, abbreviated commits, and `main` are rejected. Set the values from
the reviewed release record, not from an untrusted response on the router:

```bash
RELEASE_REF='<40_HEX_COMMIT>'
MANIFEST_SHA256='<64_HEX_MANIFEST_SHA256>'
INSTALLER_SHA256='<64_HEX_INSTALLER_SHA256>'

set -eu
umask 077
INSTALLER_TMP="$(mktemp /tmp/install-jammonitor-router.XXXXXX)"
trap 'rm -f "$INSTALLER_TMP"' EXIT HUP INT TERM
wget -qO "$INSTALLER_TMP" \
  "https://raw.githubusercontent.com/madebyjamstudios/jammonitor/$RELEASE_REF/router/install-jammonitor-router.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" "$INSTALLER_TMP" | sha256sum -c -
chmod 0700 "$INSTALLER_TMP"
"$INSTALLER_TMP" \
  --ref "$RELEASE_REF" \
  --manifest-sha256 "$MANIFEST_SHA256"
rm -f "$INSTALLER_TMP"
trap - EXIT HUP INT TERM
```

The installer downloads into a private temporary directory, verifies the
trusted manifest and every payload hash, runs available shell, Lua, and
JavaScript syntax checks, backs up existing owned targets, installs each file
atomically with an explicit mode, merges exact paths into
`/etc/sysupgrade.conf`, and enables the canonical services. It also saves the
manifest, its digest, and the source ref under `/usr/share/jammonitor`.
Installed verification rejects symlinks and requires every payload and release
metadata file to have its exact mode and `root:root` ownership.
Already-running history and watchdog services are restarted only after their
new files pass installed-file verification. Services that were stopped remain
stopped, except when a running legacy collector is migrated.

The installer never removes `/etc/tailscale/tailscaled.state`, never runs
`tailscale down`, `tailscale logout`, or `tailscale up`, and never opens an
authentication URL. It does not restart `tailscaled`.

### Local Staged Install

Local mode is useful before a release exists. Generate the manifest after the
last local change, copy the exact payload set to a private router directory,
and install from that directory. The local manifest detects an incomplete or
inconsistent transfer. It does not establish source provenance by itself, so
the operator must trust the checkout and SSH host key. Passing the manifest
digest separately pins the staged payload set:

```bash
set -eu
./router/generate-router-manifest.sh
shasum -a 256 -c router/router-files.sha256
LOCAL_MANIFEST_SHA256="$(shasum -a 256 router/router-files.sha256 | awk '{print $1}')"

ROUTER='root@<ROUTER_IP>'
ROUTER_STAGE="$(ssh "$ROUTER" 'umask 077; mktemp -d /tmp/jammonitor-stage.XXXXXX')"
ssh "$ROUTER" "mkdir -p '$ROUTER_STAGE/router'"
scp -O jammonitor.lua jammonitor.htm jammonitor.js jammonitor-i18n.js \
  "$ROUTER:$ROUTER_STAGE/"
scp -O router/jammonitor-collect router/jammonitor-history.init \
  router/jammonitor-tailscale-watchdog \
  router/jammonitor-tailscale-watchdog.init router/tailscale.init \
  router/upgrade-tailscale-arm64.sh \
  router/install-jammonitor-router.sh router/router-files.sha256 \
  "$ROUTER:$ROUTER_STAGE/router/"
ssh "$ROUTER" \
  "sh '$ROUTER_STAGE/router/install-jammonitor-router.sh' \
    --source-dir '$ROUTER_STAGE' \
    --manifest-sha256 '$LOCAL_MANIFEST_SHA256'"
```

Local staged installs write `local-staged` as the source version when the
staged directory is not a Git checkout. Remove the exact staging directory
after inspection.

### Service Start

Enabling and starting are separate operations. After verifying that
`/mnt/data` is the intended persistent filesystem:

```bash
awk '$2 == "/mnt/data" && $3 == "ext4" &&
     ("," $4 ",") ~ /,rw,/ { found = 1 }
     END { exit(found ? 0 : 1) }' /proc/mounts
/etc/init.d/tailscale start
/etc/init.d/jammonitor-tailscale-watchdog start
/etc/init.d/jammonitor-history start
```

Starting `tailscaled` does not authenticate the node. If the backend reports
`NeedsLogin`, complete one explicit operator-controlled login and then address
key expiry in the Tailscale admin console. Device keys expire after the
tailnet's configured period unless expiry is disabled for that trusted device
or the device is assigned a tag whose policy disables expiry. A process
supervisor cannot repair an expired key.

### Watchdog Semantics

The watchdog publishes its allowlisted state to:

```text
/var/run/jammonitor/tailscale-watchdog.json
```

Only a supervisor-confirmed missing daemon, a missing or non-Unix LocalAPI
socket for a proven daemon generation, or a timed-out LocalAPI query is
eligible for automatic recovery. Three consecutive eligible failures request
one supervised restart. That recovery episode remains latched until five
valid LocalAPI responses have been observed. `NeedsLogin`,
`NeedsMachineAuth`, `Stopped`, control-plane loss, health warnings, unknown
schema, command errors, and a failed critical-peer ping are visible operator
conditions and never trigger a restart loop.

`connected` has one exact meaning across the router and VPS watchdogs: the
backend is `Running`, a valid tailnet address exists, TUN is available, the
node is in the network engine, and the configured critical peer, if any, was
reached. A temporary control-plane outage does not erase an already delivered
peer path, but it makes the observation degraded and unhealthy.
`healthy` additionally requires an online control plane, no Tailscale health
warnings, and a proven daemon process generation. Process uptime is published
only with the exact PID plus `/proc` start-tick generation that produced it.
If no critical peer is configured, `connected` proves only local data-plane
readiness and the UI reports that limitation.

To monitor one critical tailnet peer, write one Tailscale IP or MagicDNS name:

```bash
mkdir -p /etc/jammonitor
# Replace this example with the intended peer's Tailscale IP or MagicDNS name.
printf '%s\n' '100.64.0.10' > /etc/jammonitor/tailscale-critical-peer
chmod 0600 /etc/jammonitor/tailscale-critical-peer
/etc/init.d/jammonitor-tailscale-watchdog restart
```

The critical-peer check uses `tailscale ping`. Success proves Tailscale-layer
reachability to that peer, but it does not prove that LuCI, SSH, or any other
application port is accepting traffic. A peer failure ends the watchdog's
delivered-connectivity interval, but it is not proof that the local daemon
should be restarted.

Use the maintenance marker before an intentional Tailscale service change:

```bash
mkdir -p /var/run/jammonitor
NOW_EPOCH="$(date +%s)"
case "$NOW_EPOCH" in ""|*[!0-9]*) exit 1 ;; esac
printf '%s\n' "$((NOW_EPOCH + 600))" \
  > /var/run/jammonitor/tailscale-maintenance
chmod 0600 /var/run/jammonitor/tailscale-maintenance
# Perform the bounded maintenance operation.
rm -f /var/run/jammonitor/tailscale-maintenance
```

The marker contains one absolute Unix expiry epoch. The watchdog accepts only
an expiry later than the current time and no more than one hour ahead, so a
crashed maintenance process cannot suppress recovery forever. The marker is
volatile and intentionally does not survive reboot.

### Pinned Tailscale ARM64 Upgrade

The installed `/usr/bin/jammonitor-tailscale-upgrade` command upgrades the
standalone BPI-R4 binaries to the reviewed ARM64 release, currently Tailscale
`1.98.9`. It pins the official archive SHA256 to:

```text
fa554ee808d7d07ee8e3ebbc0215ea087157e2a0abbf408e6e18ea7532554db6
```

Run it from LAN access because a successful upgrade includes one bounded
Tailscale service restart:

```bash
/usr/bin/jammonitor-tailscale-upgrade
```

The upgrader requires `uname -m` to report `aarch64`. It downloads the
versioned official tarball and its `.sha256` file into a private directory,
requires both the published checksum and archive hash to match the repository
pin, validates the extracted binary versions, and refuses a downgrade.

Before changing a binary, it verifies that the init script uses cleanup and
does not contain an active `down` action. It backs up the current binaries,
sets the watchdog maintenance marker, stops the service with a timeout, proves
that the supervisor, process, and LocalAPI socket are quiescent, and only then
captures and hashes the daemon's final flushed
`/etc/tailscale/tailscaled.state`. It atomically installs both binaries and
starts the service with a timeout. A pre-upgrade `Running` state must return to
`Running`. A pre-upgrade `NeedsLogin` state must remain `NeedsLogin`;
upgrading cannot and must not authenticate an expired node.

If the post-check fails, the old binaries and the pre-upgrade state file are
restored as one transaction before the old service is restarted. This prevents
an older daemon from consuming state migrated by the failed newer daemon. The
command never runs `tailscale up`,
`tailscale down`, `tailscale login`, `tailscale logout`, or removes the state
file. It does not print status JSON, an AuthURL, node keys, or state contents.

Changing the pinned Tailscale version requires a reviewed code change, the new
official checksum, passing upgrade regression tests, and a regenerated router
manifest. Do not change the URL to a moving `latest` target.

### Sysupgrade Preservation and Recovery

The installer merges exact entries into `/etc/sysupgrade.conf` without
replacing comments or unrelated paths. The preserved set includes:

- `/etc/tailscale/`, including the node state
- Manually installed `/usr/sbin/tailscale` and `/usr/sbin/tailscaled`
- Tailscale, history, and watchdog init scripts and canonical rc.d links
- JamMonitor controller, view, JavaScript, version, collector, and watchdog files
- Client metadata, the WAN list, the critical-peer file, pinned Tailscale upgrader, installer, checksum manifest, and source ref

Manual Tailscale binaries can make a sysupgrade backup large. Before upgrading,
verify the list and write a separate backup to persistent storage:

```bash
set -e
umask 077
sysupgrade -l | grep -E 'tailscale|jammonitor'
sysupgrade -b /mnt/data/jammonitor-pre-sysupgrade.tar.gz
chmod 0600 /mnt/data/jammonitor-pre-sysupgrade.tar.gz
ls -lh /mnt/data/jammonitor-pre-sysupgrade.tar.gz
```

After sysupgrade, use LAN access rather than relying only on Tailscale:

```bash
test -s /etc/tailscale/tailscaled.state
/usr/bin/jammonitor-router-install --verify-installed
/usr/bin/jammonitor-router-install --repair-services
/etc/init.d/tailscale start
/etc/init.d/jammonitor-tailscale-watchdog start
awk '$2 == "/mnt/data" && $3 == "ext4" &&
     ("," $4 ",") ~ /,rw,/ { found = 1 }
     END { exit(found ? 0 : 1) }' /proc/mounts &&
  /etc/init.d/jammonitor-history start
```

`--repair-services` restores preservation entries and canonical enable links.
It never restarts or authenticates Tailscale. If it finds a running known
legacy collector, it stops that service and starts `jammonitor-history`. If
`--verify-installed` reports a missing or mismatched payload, reinstall the
same reviewed commit with its trusted manifest SHA256. If the upgraded
firmware cannot execute the preserved Tailscale binaries, install a verified
ARM64 Tailscale release, keep `/etc/tailscale/tailscaled.state`, and then run
the repair command again.

### Acceptance Checks

Run these after installation and after every sysupgrade:

```bash
set -e
/usr/bin/jammonitor-router-install --verify-installed
/etc/init.d/tailscale enabled
/etc/init.d/tailscale running
/etc/init.d/jammonitor-tailscale-watchdog enabled
/etc/init.d/jammonitor-tailscale-watchdog running
/etc/init.d/jammonitor-history enabled
/etc/init.d/jammonitor-history running

TAILSCALE_STATUS_TMP="$(mktemp /tmp/tailscale-status.XXXXXX)"
trap 'rm -f "$TAILSCALE_STATUS_TMP"' EXIT HUP INT TERM
timeout 5 tailscale --socket=/var/run/tailscale/tailscaled.sock \
  status --json --peers=false > "$TAILSCALE_STATUS_TMP"
BACKEND_STATE="$(jsonfilter -i "$TAILSCALE_STATUS_TMP" -e '@.BackendState')"
[ "$BACKEND_STATE" = 'Running' ]

is_uint() {
  case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac
}

NOW_EPOCH="$(date +%s)"
WATCHDOG_STATUS=/var/run/jammonitor/tailscale-watchdog.json
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.schema')" = '2' ]
WATCHDOG_OBSERVED_AT="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.observed_at')"
is_uint "$NOW_EPOCH"
is_uint "$WATCHDOG_OBSERVED_AT"
WATCHDOG_AGE=$((NOW_EPOCH - WATCHDOG_OBSERVED_AT))
[ "$WATCHDOG_AGE" -ge 0 ]
[ "$WATCHDOG_AGE" -le 45 ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.status')" = 'running' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.healthy')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.connected')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.control_online')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.peer_configured')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.peer_reachable')" = 'true' ]

PROCESS_GENERATION="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_generation')"
case "$PROCESS_GENERATION" in
  *:*)
    PROCESS_PID="${PROCESS_GENERATION%%:*}"
    PROCESS_TICKS="${PROCESS_GENERATION#*:}"
    case "$PROCESS_TICKS" in *:*) exit 1 ;; esac
    is_uint "$PROCESS_PID"
    is_uint "$PROCESS_TICKS"
    [ "$PROCESS_PID" -gt 1 ]
    [ "$PROCESS_TICKS" -gt 0 ]
    ;;
  *) exit 1 ;;
esac
PROCESS_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_uptime_seconds')"
is_uint "$PROCESS_UPTIME"

awk '$2 == "/mnt/data" && $3 == "ext4" &&
     ("," $4 ",") ~ /,rw,/ { found = 1 }
     END { exit(found ? 0 : 1) }' /proc/mounts
[ "$(sqlite3 /mnt/data/jammonitor/history.db 'PRAGMA quick_check;')" = 'ok' ]

COLLECTOR_STATUS=/var/run/jammonitor/collector-status.json
[ "$(jsonfilter -i "$COLLECTOR_STATUS" -e '@.schema')" = '1' ]
COLLECTOR_OBSERVED_AT="$(jsonfilter \
  -i "$COLLECTOR_STATUS" -e '@.observed_at')"
COLLECTOR_LAST_SUCCESS_AT="$(jsonfilter \
  -i "$COLLECTOR_STATUS" -e '@.last_success_at')"
is_uint "$COLLECTOR_OBSERVED_AT"
is_uint "$COLLECTOR_LAST_SUCCESS_AT"
COLLECTOR_AGE=$((NOW_EPOCH - COLLECTOR_OBSERVED_AT))
COLLECTOR_SUCCESS_AGE=$((NOW_EPOCH - COLLECTOR_LAST_SUCCESS_AT))
[ "$COLLECTOR_AGE" -ge 0 ]
[ "$COLLECTOR_AGE" -le 75 ]
[ "$COLLECTOR_SUCCESS_AGE" -ge 0 ]
[ "$COLLECTOR_SUCCESS_AGE" -le 180 ]
[ "$(jsonfilter -i "$COLLECTOR_STATUS" -e '@.healthy')" = 'true' ]
[ "$(jsonfilter -i "$COLLECTOR_STATUS" -e '@.mounted')" = 'true' ]
[ "$(jsonfilter -i "$COLLECTOR_STATUS" -e '@.writable')" = 'true' ]
[ "$(jsonfilter \
  -i "$COLLECTOR_STATUS" -e '@.database_quick_check')" = 'ok' ]

BEFORE_MAX="$(sqlite3 /mnt/data/jammonitor/history.db \
  'SELECT COALESCE(MAX(ts), 0) FROM metrics;')"
is_uint "$BEFORE_MAX"
sleep 65
AFTER_MAX="$(sqlite3 /mnt/data/jammonitor/history.db \
  'SELECT COALESCE(MAX(ts), 0) FROM metrics;')"
is_uint "$AFTER_MAX"
[ "$AFTER_MAX" -gt "$BEFORE_MAX" ]

sysupgrade -l | grep -E 'tailscale|jammonitor'
logread -e jammonitor-tailscale-watchdog
rm -f "$TAILSCALE_STATUS_TMP"
trap - EXIT HUP INT TERM
```

On a test router with working LAN fallback, a stopped-process test can confirm
procd recovery. A LocalAPI hang test can confirm the watchdog's one-attempt
latch. Do not inject either failure through a Tailscale-only management
session.

### Historical Metrics Architecture

JamMonitor history is local to the router on the mounted USB SQLite database.
The former VPS collector, port 8080 API, `ROUTER_URL`, and router `/metrics`
procedure were reverted and are obsolete. Do not deploy that procedure. A
process on the OMR VPS is not part of the current history data path.

The collector holds a kernel `flock` for its complete lifetime. A stale PID
file, PID reuse, or simultaneous manual and procd starts therefore cannot
create two SQLite writers or suppress a valid successor. Each Tailscale
history row records local connectivity, control-plane state, and the exact
daemon generation used for uptime continuity.

### Independent Availability Alarms

The local watchdog is intentionally conservative and cannot notify an operator
when the entire router or tailnet path is unreachable. The optional
[`monitoring/aws`](monitoring/aws/) stack runs outside those failure domains.
It polls the Tailscale device API once per minute using a read-only
`devices:core:read` OAuth client and alarms on:

- either exact router/VPS device becoming stale, unapproved, or key-invalid
- either node key entering the configured expiry warning window
- missing observations, Lambda errors/throttles/slow execution, or dead letters

It publishes only low-cardinality aliases (`router` and `vps`) to CloudWatch.
The OAuth secret stays in Secrets Manager. The monitor cannot log in a node,
change a key, approve a device, or alter tailnet policy. This remains
control-plane evidence; the router critical-peer ping is the complementary
data-plane observation.

---

## File Structure

```
jammonitor/
├── jammonitor.lua           # LuCI controller — backend API endpoints & menu registration
├── jammonitor.htm           # LuCI view template — HTML structure & CSS styling
├── jammonitor.js            # Frontend JavaScript — UI logic, charts, drag-and-drop
├── jammonitor-i18n.js       # Internationalization — translation strings for 22 languages
├── router/
│   ├── jammonitor-collect
│   ├── jammonitor-history.init
│   ├── jammonitor-tailscale-watchdog
│   ├── jammonitor-tailscale-watchdog.init
│   ├── tailscale.init
│   ├── upgrade-tailscale-arm64.sh
│   ├── install-jammonitor-router.sh
│   ├── generate-router-manifest.sh
│   └── router-files.sha256
├── monitoring/
│   └── aws/                    # Optional independent Lambda/CloudWatch alarms
├── tests/
│   ├── test-collector.sh
│   ├── test-luci-mutation-security.sh
│   ├── test-luci-transactions.sh
│   ├── test-router-installer.sh
│   ├── test-static-contract.sh
│   ├── test-tailscale-upgrade.sh
│   ├── test-tailscale-watchdog.sh
│   ├── test-vps-tailscale-installer.sh
│   └── test-vps-tailscale-watchdog.sh
├── vps/                       # Transactional Debian watchdog deployment
│   ├── install-tailscale-watchdog.sh
│   ├── jammonitor-tailscale-watchdog
│   ├── jammonitor-tailscale-watchdog.service
│   ├── jammonitor-tailscale-watchdog.timer
│   ├── generate-vps-manifest.sh
│   └── vps-files.sha256
└── README.md
```

---

## How WAN Bonding Works

JamMonitor interfaces with OpenMPTCProuter's multipath TCP implementation:

| Priority | Multipath Mode | Behavior |
|----------|---------------|----------|
| **Primary** | `master` | Main connection - only one allowed. All traffic originates here. |
| **Bonded** | `on` | Aggregated with Primary. Traffic split across all bonded interfaces. |
| **Standby** | `backup` | Dormant until Primary/Bonded fail. Activates on failover. |
| **Disabled** | `off` | Interface completely turned off. |

When you drag a WAN interface to a new category, JamMonitor updates the UCI configuration and triggers the appropriate `ifup`/`ifdown` commands automatically.

---

## Configuration Options

### WAN Interface Settings

Click on any WAN name to edit:

- **Priority** - Primary / Bonded / Standby / Disabled
- **Protocol** - DHCP or Static IP
- **Static IP Settings** - IP address, subnet mask, gateway
- **DNS** - Auto (from DHCP) or Custom DNS servers
- **MTU** - Manual MTU override (576-9000)

### Remote AP Monitoring

In the WiFi APs tab, click "Edit AP List" to add remote access points:

```json
[
  {"name": "AP-Living-Room", "ip": "10.0.0.2"},
  {"name": "AP-Office", "ip": "10.0.0.3"},
  {"name": "AP-Garage", "ip": "10.0.0.4"}
]
```

---

## Diagnostics

The Diagnostics tab generates a comprehensive bundle including:

- System logs (syslog, dmesg)
- Network state (interfaces, routing, ARP, IPv6)
- VPN status (WireGuard, Glorytun, OpenVPN, MLVPN)
- MPTCP information (endpoints, limits, sysctl)
- OpenMPTCProuter configuration
- DNS configuration (per-interface DNS, resolution tests)
- Thermal monitoring (CPU temperature, frequency, throttling)
- Connectivity test results
- Firewall rules (nftables/iptables export)
- Error and warning summaries
- Automatic secret redaction (tokens, passwords, keys stripped from output)

---

## Compatibility

- **Router:** Banana Pi BPI-R4 (primary target)
- **Firmware:** OpenMPTCProuter (OpenWrt-based)
- **Browser:** Modern browsers with ES5+ JavaScript support
- **Dependencies:** LuCI, uhttpd, standard OpenWrt utilities

---

## License

MIT License - Feel free to modify and distribute.

---

## Contributing

Contributions welcome! Please open an issue or pull request.
