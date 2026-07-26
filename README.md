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
- `timeout`, `jsonfilter`, `sqlite3`, `conntrack`, `flock`, `sha256sum`, and
  `sync` installed on the router
- `lua` or `luac` available for the installer's mandatory Lua syntax check
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

The checksum manifests are deterministic, but neither can be considered final
until all router and VPS payload edits are complete. Run the complete
regression and syntax gate from a clean release checkout with POSIX `sh`,
`dash`, Node.js, Lua 5.1, Python, and `cfn-lint` available:

```bash
set -eu
for shell in sh dash
do
  command -v "$shell" >/dev/null
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
    "$shell" "$test"
  done
done
python3 -m unittest discover -s monitoring/aws/tests -p 'test_*.py'
cfn-lint --template monitoring/aws/template.yaml --regions us-east-1
node --check jammonitor.js
node --check jammonitor-i18n.js
LUA51="${LUA51:-lua5.1}"
command -v "$LUA51" >/dev/null
"$LUA51" -v 2>&1 | grep -Eq '^Lua 5[.]1([.]| )'
JM_LUA_FILE="$PWD/jammonitor.lua" \
  "$LUA51" -e 'assert(loadfile(os.getenv("JM_LUA_FILE")))'
for script in \
  router/*.sh router/*.init router/jammonitor-collect \
  router/jammonitor-tailscale-watchdog router/tailscale.init \
  vps/*.sh vps/jammonitor-tailscale-watchdog
do
  sh -n "$script"
  dash -n "$script"
done
git diff --check
```

Only after that gate passes, regenerate and verify both manifests:

```bash
set -eu
./router/generate-router-manifest.sh
./vps/generate-vps-manifest.sh
shasum -a 256 -c router/router-files.sha256
(cd vps && shasum -a 256 -c vps-files.sha256)
git diff --check
git diff -- router/router-files.sha256 vps/vps-files.sha256
```

On Linux or OpenWrt, the installer can also validate a checkout without
installing it. Pass the manifest digest when it came from a separate trusted
release record:

```bash
sh router/install-jammonitor-router.sh \
  --validate-source "$PWD" \
  --manifest-sha256 '<64_HEX_MANIFEST_SHA256>'
```

Run both generators again immediately before creating the release commit.
Commit both generated manifests with their payloads. After the commit, record
the router release values below and the VPS manifest and installer digests
described in [`vps/README.md`](vps/README.md):

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
(
  ulimit -f 2048
  exec timeout -s TERM -k 2 120 wget -q -T 120 -O "$INSTALLER_TMP" \
    "https://raw.githubusercontent.com/madebyjamstudios/jammonitor/$RELEASE_REF/router/install-jammonitor-router.sh"
)
INSTALLER_SIZE="$(wc -c <"$INSTALLER_TMP" | tr -d ' \r\n')"
case "$INSTALLER_SIZE" in
  ''|*[!0-9]*) exit 1 ;;
esac
[ "$INSTALLER_SIZE" -gt 0 ]
[ "$INSTALLER_SIZE" -le 1048576 ]
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

Install, `--repair-services`, and the pinned Tailscale upgrader serialize every
router mutation through the same persistent
`/var/run/jammonitor/router-install.lock` inode. Each process opens that exact
regular file and takes a nonblocking kernel `flock`; none of them unlinks it
during cleanup. Closing the held descriptor, including kernel cleanup after
`SIGKILL`, is the only ownership transition. This prevents PID reuse, stale
text, and two contenders locking different replacement inodes from allowing
overlapping file or service changes.

#### Router installer recovery

Before its first live mutation, the installer writes and synchronizes a
root-only rollback transaction under:

```text
/etc/jammonitor/recovery/active
/etc/jammonitor/recovery/UNRESOLVED
```

The bundle contains the prior files, exact hashes or symlink targets, metadata,
service state, source ref, and manifest digest. Because it is under `/etc`, it
survives reboot. A successful install or fully verified rollback removes it.
Any remaining `active` bundle or `UNRESOLVED` marker blocks install and
`--repair-services`.

If either path remains, stop. Keep LAN access, do not retry, and do not delete
the evidence to make the guard pass. Inspect it read-only first:

```bash
set -eu
RECOVERY=/etc/jammonitor/recovery
test -d "$RECOVERY/active"
test ! -L "$RECOVERY/active"
ls -la "$RECOVERY" "$RECOVERY/active"
sed -n '1,120p' "$RECOVERY/active/STATUS"
sed -n '1,240p' "$RECOVERY/active/transaction"
sed -n '1,240p' "$RECOVERY/active/backup.index"
```

Copy the complete directory to a trusted machine over the independent LAN
path, then compare every current target and service state with
`backup.index` and `transaction`. Restore only the recorded prior bytes,
symlink targets, modes, owners, and service states. After the restored set or
the new set passes its complete manifest verification, confirm that
Tailscale, the history collector, the watchdog, and uhttpd match the recorded
runtime state. Only then remove the exact reviewed `UNRESOLVED` file and
`active` directory. Never clear the whole `/etc/jammonitor` directory.

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

The first collector start performs one bounded migration of app-owned syslog
archives created by older JamMonitor builds. It validates at most 4,096
top-level leaves through the already pinned USB mount, refuses symlinks,
hardlinks, foreign ownership, unsafe modes, unexpected names, an incomplete
scan, or changed mount authority, and makes no changes unless the complete
tree passes that migration contract. If `syslog.txt.old` already exists, it is
preserved; otherwise the newest numeric `syslog.txt.<epoch>` archive becomes
`syslog.txt.old`. All remaining numeric legacy rotations are removed before
the 64-leaf runtime authority gate. Copy any legacy syslog archives needed for
forensics to the existing pre-release backup before starting the new
collector. History databases and interface snapshots are validated but never
removed by this migration.

### Service Start

Enabling and starting are separate operations. First require the exact
five-option removable ext4 mount, then invoke the installed collector's
read-only storage-authority proof. That proof joins the single enabled UCI
fstab target and exact option string to its UUID, the live `block info`
record, the unique removable partition, mount generation, root ownership, and
absence of storage-recovery evidence:

```bash
set -eu
STORAGE_SOURCE="$(
awk '
  $2 == "/mnt/data" {
    matches++
    source = $1
    fstype = $3
    option_count = split($4, options, ",")
    for (i = 1; i <= option_count; i++) {
      option_seen[options[i]]++
    }
  }
  END {
    if (matches == 1 &&
        source ~ /^\/dev\/sd[a-z][1-9][0-9]*$/ &&
        fstype == "ext4" &&
        option_count == 5 &&
        option_seen["rw"] == 1 &&
        option_seen["noatime"] == 1 &&
        option_seen["nosuid"] == 1 &&
        option_seen["nodev"] == 1 &&
        option_seen["noexec"] == 1) {
      print source
      exit 0
    }
    exit 1
  }
' /proc/mounts
)"
(
  JAMMONITOR_LIB_ONLY=1
  export JAMMONITOR_LIB_ONLY
  . /usr/bin/jammonitor-collect
  prove_storage_authority
  [ "$PROVED_STORAGE_SOURCE" = "$STORAGE_SOURCE" ]
)
/etc/init.d/tailscale start
/etc/init.d/jammonitor-tailscale-watchdog start
/etc/init.d/jammonitor-history start
```

The standalone router daemon is intentionally started with
`--tun=tailscale0` and a fixed UDP listener on port `41641`. Its authenticated
preferences must remain
`--netfilter-mode=off --accept-dns=false --accept-routes=false`, and automatic
update application must be disabled with `--auto-update=false`. The manually
installed, manifest-pinned OpenWrt binaries are owned by the transactional
upgrader in this repository; Tailscale's package-managed auto-updater must not
replace them outside that recovery boundary. Update checks may remain enabled.

With netfilter mode off, Tailscale does not own the OpenWrt firewall policy.
The required OpenWrt contract is a `tailscale0` network attached to a dedicated
zone with input `REJECT`, output `ACCEPT`, forwarding `REJECT`, no zone
forwardings, and narrow input rules for the intended management ports only.
For the current JamMonitor deployment those ports are TCP 22, 80, and 443.
Verify the persisted UCI contract rather than assuming that the tunnel device
alone grants access:

```bash
set -eu
[ "$(uci -q get network.tailscale.proto)" = 'none' ]
[ "$(uci -q get network.tailscale.device)" = 'tailscale0' ]
[ "$(uci -q get firewall.tailscale.name)" = 'tailscale' ]
[ "$(uci -q get firewall.tailscale.input)" = 'REJECT' ]
[ "$(uci -q get firewall.tailscale.output)" = 'ACCEPT' ]
[ "$(uci -q get firewall.tailscale.forward)" = 'REJECT' ]
[ "$(uci -q get firewall.tailscale.network)" = 'tailscale' ]
[ "$(uci -q get firewall.tailscale_allow_mgmt.src)" = 'tailscale' ]
[ "$(uci -q get firewall.tailscale_allow_mgmt.proto)" = 'tcp' ]
[ "$(uci -q get firewall.tailscale_allow_mgmt.dest_port)" = '22 80 443' ]
[ "$(uci -q get firewall.tailscale_allow_mgmt.target)" = 'ACCEPT' ]
ip link show tailscale0 >/dev/null
```

The `tailscale` zone governs packets after they enter `tailscale0`; it does
not authorize the daemon's UDP `41641` listener on an underlay WAN. If direct
inbound Tailscale connectivity is required and the WAN zone rejects input,
add one explicit UDP `41641` input rule for the intended WAN zone and, where
applicable, one matching upstream NAT port-forward. DERP and outbound NAT
traversal can still provide connectivity without that inbound mapping, so
failure to open it is a direct-path performance limitation rather than a
reason to broaden all WAN input. Inventory every modem and hotspot before
changing the WAN policy, preserve an independent LAN recovery path, and test
each underlay separately.

Do not add a `tailscale`-to-`lan` or `tailscale`-to-`wan` forwarding unless
the router is deliberately being redesigned as a subnet router. Reapply all
three Tailscale preference flags together during an operator-controlled
`tailscale up`; changing netfilter mode without reviewing the UCI zone can
either expose management services or lock them out. The VPS uses its own
host-firewall policy and does not inherit this OpenWrt contract.

Starting `tailscaled` does not authenticate the node. If the backend reports
`NeedsLogin`, complete one explicit operator-controlled login and then address
key expiry in the Tailscale admin console. Device keys expire after the
tailnet's configured period unless expiry is disabled for that trusted device
or the device is assigned a tag whose policy disables expiry. A process
supervisor cannot repair an expired key. If policy requires expiry to remain
enabled, assign an owner, document and test the rotation procedure, and enable
an independent expiry alarm with enough warning to rotate before the deadline.
Acceptance requires either verified disabled/tag-managed expiry or that tested
rotation-and-alarm path for both the router and VPS.

Run forced reauthentication only through the independent underlay/LAN path.
Tailscale `1.98.9` deliberately refuses a partial `tailscale up` that would
silently reset an existing nondefault setting. `--force-reauth` alone is not a
bare `up`, so it is insufficient on this router. Immediately before login,
verify the current non-secret settings and that there are no advertised
routes, tags, exit node, Tailscale SSH, shields-up, connector, or posture
settings that must be preserved. Then state the complete reviewed
management-only `up` contract. In the first underlay/LAN router session, run
this exact private foreground capture and leave it waiting for approval:

```bash
set +x
set +a
set -eu
umask 077
SOCKET=/var/run/tailscale/tailscaled.sock
RUNTIME=/var/run/jammonitor
AUTH_STDOUT="$RUNTIME/tailscale-reauth.stdout"
AUTH_STDERR="$RUNTIME/tailscale-reauth.stderr"
AUTH_RC="$RUNTIME/tailscale-reauth.rc"

[ -d "$RUNTIME" ]
[ ! -L "$RUNTIME" ]
[ "$(stat -c '%u:%g:%a' "$RUNTIME")" = '0:0:700' ]
for path in "$AUTH_STDOUT" "$AUTH_STDERR" "$AUTH_RC"
do
  [ ! -e "$path" ]
  [ ! -L "$path" ]
done
(
  set -C
  : >"$AUTH_STDOUT"
  : >"$AUTH_STDERR"
)
chmod 0600 "$AUTH_STDOUT" "$AUTH_STDERR"
[ "$(stat -c '%u:%g:%a:%h' "$AUTH_STDOUT")" = '0:0:600:1' ]
[ "$(stat -c '%u:%g:%a:%h' "$AUTH_STDERR")" = '0:0:600:1' ]

set +e
(
  ulimit -c 0 || exit 125
  ulimit -f 8 || exit 125
  exec timeout -s TERM -k 2 620 \
    tailscale --socket="$SOCKET" up \
      --force-reauth \
      --netfilter-mode=off \
      --accept-dns=false \
      --accept-routes=false \
      --hostname=omr-bpir4 \
      --timeout=10m
) >"$AUTH_STDOUT" 2>"$AUTH_STDERR"
REAUTH_RC=$?
set -e

AUTH_RC_TMP="$(mktemp "$RUNTIME/tailscale-reauth.rc.XXXXXX")"
printf '%s\n' "$REAUTH_RC" >"$AUTH_RC_TMP"
chmod 0600 "$AUTH_RC_TMP"
mv "$AUTH_RC_TMP" "$AUTH_RC"
[ "$(stat -c '%u:%g:%a:%h' "$AUTH_RC")" = '0:0:600:1' ]
[ "$REAUTH_RC" -eq 0 ] || {
  printf '%s\n' \
    "Reauthentication failed; private captures retained for review." >&2
  exit 1
}

STATUS_TMP="$(mktemp "$RUNTIME/tailscale-reauth-status.XXXXXX")"
trap 'rm -f "$STATUS_TMP"' EXIT HUP INT TERM
(
  ulimit -c 0 || exit 125
  ulimit -f 128 || exit 125
  exec timeout -s TERM -k 2 5 \
    tailscale --socket="$SOCKET" status --json --peers=false
) >"$STATUS_TMP"
[ "$(wc -c <"$STATUS_TMP" | tr -d ' ')" -le 65536 ]
[ "$(jsonfilter -i "$STATUS_TMP" -e '@.BackendState')" = 'Running' ]
[ -n "$(jsonfilter -i "$STATUS_TMP" -e '@.Self.ID')" ]
[ -n "$(jsonfilter -i "$STATUS_TMP" -e '@.Self.TailscaleIPs[0]')" ]
rm -f "$STATUS_TMP" "$AUTH_STDOUT" "$AUTH_STDERR" "$AUTH_RC"
trap - EXIT HUP INT TERM
```

While that command is waiting, use a second trusted Mac terminal to retrieve
only the validated URL through the same underlay SSH host-key boundary and
open it without echoing it:

```bash
set +x
set +a
set -eu
unset AUTH_URL AUTH_TOKEN OPEN_RC
ROUTER_UNDERLAY='root@<UNDERLAY_ROUTER_IP>'
ROUTER_SSH_KEY='<PATH_TO_REVIEWED_ROUTER_SSH_KEY>'
AUTH_URL="$(
  ssh -i "$ROUTER_SSH_KEY" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=5 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=2 \
    -o StrictHostKeyChecking=yes \
    "$ROUTER_UNDERLAY" '
      set +x
      set +a
      set -eu
      unset MATCHES TOKEN
      AUTH_STDERR=/var/run/jammonitor/tailscale-reauth.stderr
      for attempt in 1 2 3 4 5 6 7 8 9 10 \
                     11 12 13 14 15 16 17 18 19 20 \
                     21 22 23 24 25 26 27 28 29 30
      do
        [ -f "$AUTH_STDERR" ]
        [ ! -L "$AUTH_STDERR" ]
        [ "$(stat -c "%u:%g:%a:%h" "$AUTH_STDERR")" = "0:0:600:1" ]
        AUTH_SIZE="$(wc -c <"$AUTH_STDERR" | tr -d " ")"
        case "$AUTH_SIZE" in
          ""|*[!0-9]*) exit 1 ;;
        esac
        [ "$AUTH_SIZE" -le 4096 ]
        MATCHES="$(
          sed -n \
            "s|^[[:space:]]*\\(https://login\\.tailscale\\.com/a/[A-Za-z0-9_-][A-Za-z0-9_-]*\\)[[:space:]]*$|\\1|p" \
            "$AUTH_STDERR"
        )"
        MATCH_COUNT="$(
          printf "%s\n" "$MATCHES" |
            awk "NF { count++ } END { print count + 0 }"
        )"
        if [ "$MATCH_COUNT" = 1 ]; then
          TOKEN="${MATCHES#https://login.tailscale.com/a/}"
          case "$TOKEN" in
            ""|*[!A-Za-z0-9_-]*) exit 1 ;;
          esac
          [ "$(printf "%s" "$MATCHES" | wc -c | tr -d " ")" -le 512 ]
          printf "%s\n" "$MATCHES"
          exit 0
        fi
        sleep 1
      done
      exit 1
    '
)"
case "$AUTH_URL" in
  https://login.tailscale.com/a/*) ;;
  *) exit 1 ;;
esac
AUTH_TOKEN="${AUTH_URL#https://login.tailscale.com/a/}"
case "$AUTH_TOKEN" in
  ""|*[!A-Za-z0-9_-]*) exit 1 ;;
esac
[ "$(printf '%s' "$AUTH_URL" | wc -c | tr -d ' ')" -le 512 ]
if builtin printf '%s' "$AUTH_URL" | (
  ulimit -c 0 || exit 125
  exec /usr/bin/osascript -l JavaScript -e '
ObjC.import("Foundation");
ObjC.import("AppKit");
const data = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
if (Number(data.length) === 0) throw new Error("empty authentication URL");
const text = $.NSString.alloc.initWithDataEncoding(
  data,
  $.NSUTF8StringEncoding
);
if (!text) throw new Error("invalid UTF-8");
const value = ObjC.unwrap(text);
if (
  value.length > 512 ||
  !/^https:\/\/login\.tailscale\.com\/a\/[A-Za-z0-9_-]+$/.test(value)
) {
  throw new Error("invalid authentication URL");
}
const url = $.NSURL.URLWithString(text);
if (!url) throw new Error("invalid URL");
if (!$.NSWorkspace.sharedWorkspace.openURL(url)) {
  throw new Error("LaunchServices rejected URL");
}
' >/dev/null 2>&1
)
then
  OPEN_RC=0
else
  OPEN_RC=$?
fi
unset AUTH_TOKEN AUTH_URL
[ "$OPEN_RC" -eq 0 ]
unset OPEN_RC
```

Do not add `--reset`: an unexpected unmentioned nondefault setting must make
this command fail before authentication rather than be silently erased. Keep
shell tracing disabled. Never print or copy either private capture. A
settings-completeness error is a safe pre-authentication stop; inspect it
privately and expand the reviewed command instead of using `--reset`. If the
first session exits unsuccessfully, leave every capture, final return-code
file, or return-code temporary file that exists in place until its exact
metadata and bounded contents are reviewed. A missing final return-code file
means the attempt was interrupted before status publication; do not blindly
remove its evidence and retry.

After the explicit login succeeds, pin the complete management-only preference
contract and prove the stored values without writing or printing raw preference
JSON. Tailscale `debug prefs` can include persistent private node and
network-lock keys. The raw bytes below flow only through a pipe into
`jsonfilter`; the only file contains the five allowlisted scalar fields. The
synthetic sentinel first proves this router's `jsonfilter` projection behavior:

```bash
set -eu
SOCKET=/var/run/tailscale/tailscaled.sock
RUNTIME=/var/run/jammonitor
[ -d "$RUNTIME" ]
[ ! -L "$RUNTIME" ]
[ "$(stat -c '%u:%g:%a' "$RUNTIME")" = '0:0:700' ]
SAFE_PREFS="$(mktemp "$RUNTIME/tailscale-prefs-safe.XXXXXX")"
PREFS_RC="$(mktemp "$RUNTIME/tailscale-prefs-rc.XXXXXX")"
trap 'rm -f "$SAFE_PREFS" "$PREFS_RC"' EXIT HUP INT TERM

PROBE="$(
  printf '%s\n' \
    '{"WantRunning":true,"CorpDNS":false,"RouteAll":false,"NetfilterMode":0,"AutoUpdate":{"Apply":false},"Config":{"PrivateNodeKey":"SECRET_SENTINEL"}}' |
    jsonfilter \
      -e 'WANT=@.WantRunning' \
      -e 'DNS=@.CorpDNS' \
      -e 'ROUTES=@.RouteAll' \
      -e 'NF=@.NetfilterMode' \
      -e 'AUTO=@.AutoUpdate.Apply'
)"
[ "$PROBE" = \
  'export WANT=1; export DNS=0; export ROUTES=0; export NF=0; export AUTO=0; ' ]
case "$PROBE" in *SECRET_SENTINEL*) exit 1 ;; esac

timeout -s TERM -k 2 10 \
  tailscale --socket="$SOCKET" set \
  --netfilter-mode=off \
  --accept-dns=false \
  --accept-routes=false \
  --auto-update=false

if (
  set +e
  ulimit -c 0 || {
    printf '%s\n' 125 >"$PREFS_RC"
    exit 125
  }
  timeout -s TERM -k 2 5 \
    tailscale --socket="$SOCKET" debug prefs 2>/dev/null
  producer_rc=$?
  printf '%s\n' "$producer_rc" >"$PREFS_RC"
  exit "$producer_rc"
) | (
  ulimit -c 0 || exit 125
  ulimit -f 1 || exit 125
  exec jsonfilter \
    -e 'WANT=@.WantRunning' \
    -e 'DNS=@.CorpDNS' \
    -e 'ROUTES=@.RouteAll' \
    -e 'NF=@.NetfilterMode' \
    -e 'AUTO=@.AutoUpdate.Apply'
) >"$SAFE_PREFS"
then
  filter_rc=0
else
  filter_rc=$?
fi
[ "$filter_rc" -eq 0 ]
[ "$(cat "$PREFS_RC")" = '0' ]
[ "$(wc -c <"$SAFE_PREFS" | tr -d ' ')" -le 128 ]
SAFE_PREFS_VALUE="$(cat "$SAFE_PREFS")"
[ "$SAFE_PREFS_VALUE" = \
  'export WANT=1; export DNS=0; export ROUTES=0; export NF=0; export AUTO=0; ' ]
rm -f "$SAFE_PREFS" "$PREFS_RC"
trap - EXIT HUP INT TERM
```

### Watchdog Semantics

The watchdog publishes its allowlisted state to:

```text
/var/run/jammonitor/tailscale-watchdog.json
```

The current producer writes schema 3. Router consumers also understand schema 2
for an in-place upgrade, but a legacy schema-2 snapshot may claim delivered
connectivity only when it contains the then-required boolean
`in_engine: true`. Schema 3 does not publish or depend on `Self.InEngine`.
Schema 1 and unknown future schemas fail closed.

Every router LocalAPI query runs in a bounded child with a 64 KiB output-file
limit. An attempt to exceed the limit is a command failure, not evidence of a
daemon deadline, and cannot authorize recovery. A schema-valid response must
contain `Health` as an array of at most 100 elements, every element must be a
string, and every string must have length at most 512. Missing, scalar,
non-string, oversized, or over-count `Health` data becomes
`health_state_unknown`; it is degraded and unhealthy and never defaults to an
empty healthy array.

Each observation also holds a nonblocking kernel `flock` on the persistent
same-boot `/var/run/jammonitor/tailscale-watchdog.lock` inode. The watchdog
never unlinks that inode, and exit closes the lock descriptor atomically even
after `SIGKILL`; stale PID text cannot suppress a successor or let concurrent
invocations lock different inodes.

Only a supervisor-confirmed missing daemon, a missing or non-Unix LocalAPI
socket for a proven daemon generation, or a bounded LocalAPI query whose
BusyBox `timeout` exits 124, 137, or 143 **and** whose measured monotonic
elapsed time reaches the configured deadline is eligible for automatic
recovery. On this OpenWrt build, a normal deadline commonly exits 143 after
`SIGTERM` and a forced kill exits 137. The same codes returned before the
deadline are ambiguous with an external kill or OOM event and are never
eligible. The router accepts a signal-derived status only with independent
elapsed-deadline evidence inside the otherwise narrow LocalAPI branch, then
uses a durable, bounded recovery episode to prevent a restart storm. Three
consecutive eligible failures request the first supervised restart. If the
same proven failure remains, a second attempt is allowed only after a
60-second monotonic cooldown and a third only after a further 300-second
cooldown. Three attempts exhaust automatic recovery for that episode. Five
valid LocalAPI responses reset the attempt count and rearm a later episode.
`NeedsLogin`,
`NeedsMachineAuth`, `Stopped`, control-plane loss, health warnings, unknown
schema, command errors, and a failed critical-peer ping are visible operator
conditions and never trigger a restart loop.

Immediately before each supervised restart, the router atomically commits the
attempt count, next monotonic retry deadline, and incremented recovery count to
the private memory file in `/var/run/jammonitor`. A watchdog crash or
`SIGKILL` after that commit spends that attempt; a successor must honor the
remaining cooldown and three-attempt cap. Invalid or legacy spent retry state
fails closed to exhausted recovery. A persistence failure suppresses the
restart. This is intentionally same-boot durability, not power-loss
durability: `/var/run` is volatile, reboot clears the episode, and the
120-second boot grace prevents an immediate post-boot restart. Do not describe
the watchdog memory as surviving reboot. The router installer's separate
`/etc/jammonitor/recovery` transaction is the persistent power-loss/reboot
recovery mechanism for file deployment.

`connected` has one exact meaning across the router and VPS watchdogs: the
backend is `Running`, a valid tailnet address exists, TUN is available, and
the configured critical peer, if any, was reached. Tailnet addresses are
accepted only as canonical dotted-decimal `100.64.0.0/10` IPv4 or structurally
valid full/compressed `fd7a:115c:a1e0::/48` IPv6. IPv6 zones, dotted suffixes,
bad group counts, and zero-width `::` compression are rejected.
`Self.InEngine` is not a current self-health signal and is intentionally not
part of schema-3 decisions. A temporary control-plane outage does not erase an
already delivered peer path, but it makes the observation degraded and
unhealthy.
`healthy` additionally requires an online control plane, no Tailscale health
warnings, and a proven daemon process generation. Process uptime is published
only with the exact PID plus `/proc` start-tick generation that produced it.
The watchdog requires exactly one matching `tailscaled` process record with
valid start ticks; zero or multiple matches fail closed. A generation whose
start ticks resolve later than the current monotonic clock is also unprovable,
so point-in-time connectivity may remain observable but the result is
degraded, unhealthy, and cannot carry process or connectivity continuity
forward.
If no critical peer is configured, `connected` proves only local data-plane
readiness and the UI reports that limitation.

Delivered-connectivity uptime is an evidence interval, not wall-clock daemon
age. It resets when connectivity is not true; the exact critical-peer contract
changes; the daemon generation is new, missing, or unprovable; monotonic time
regresses; no prior observation exists; or the gap from the last persisted
observation reaches 30 seconds. A failed memory replacement cannot advance
that persisted observation marker, so the next scheduled successful sample
reaches the gap reset instead of bridging the unpersisted sample. The router
does not bridge a successful observation across any of those gaps.

When the watchdog snapshot is missing or unusable, the LuCI controller's live
fallback keeps the same fail-closed boundaries: a 64 KiB raw LocalAPI cap,
bounded supervisor queries, the exact `Health` array contract above, a
non-symlink critical-peer file, and exactly one verified live
`/usr/sbin/tailscaled` process generation. The fallback can report current
state, but it cannot manufacture watchdog recovery history or continuity.

To monitor one critical tailnet peer, write its exact Tailscale IP literal.
Hostnames are deliberately refused because an alias for the local node could
make a self-ping look like proof of remote delivery:

```bash
mkdir -p /etc/jammonitor
# Replace this example with the intended peer's exact Tailscale IP.
printf '%s\n' '100.64.0.10' > /etc/jammonitor/tailscale-critical-peer
chmod 0600 /etc/jammonitor/tailscale-critical-peer
/etc/init.d/jammonitor-tailscale-watchdog restart
```

The critical-peer check uses `tailscale ping --tsmp`. Success proves a TSMP
round trip through WireGuard to the peer's Tailscale engine, without entering
either host operating-system network stack. It does not prove that LuCI, SSH,
or any other application port is accepting traffic. A peer failure ends the
watchdog's delivered-connectivity interval, but it is not proof that the local
daemon should be restarted.

An existing critical-peer file that is empty, malformed, oversized, unreadable,
non-regular, multiline, hard-linked, not root-owned mode `0600`, or a symlink
is an explicit invalid configuration, not the same as an absent optional file.
The watchdog rejoins the exact device, inode, size, and content contract before
and after the peer probe; an atomic replacement invalidates that observation.
A literal critical-peer IP that resolves to any local `Self.TailscaleIPs`
address is also invalid. These cases publish
`peer_state=invalid_configuration`, force `connected=false`, and never invoke
the peer ping as a recovery signal.

Use the maintenance marker before an intentional Tailscale service change:

```bash
set -eu
mkdir -p /var/run/jammonitor
NOW_EPOCH="$(date +%s)"
case "$NOW_EPOCH" in ""|*[!0-9]*) exit 1 ;; esac
MAINTENANCE=/var/run/jammonitor/tailscale-maintenance
[ ! -e "$MAINTENANCE" ]
[ ! -L "$MAINTENANCE" ]
(umask 077; set -C; printf '%s\n' "$((NOW_EPOCH + 600))" \
  > "$MAINTENANCE")
chmod 0600 "$MAINTENANCE"
# Perform the bounded maintenance operation.
rm -f "$MAINTENANCE"
```

The marker contains one absolute Unix expiry epoch. The watchdog accepts only
an expiry later than the current time and no more than one hour ahead, so a
crashed maintenance process cannot suppress recovery forever. The marker is
volatile and intentionally does not survive reboot.
A symlink, non-regular file, unreadable file, malformed bytes, or out-of-bounds
epoch is an invalid maintenance marker. It is surfaced as degraded state and
never suppresses recovery.

### Pinned Tailscale ARM64 Upgrade

The installed `/usr/bin/jammonitor-tailscale-upgrade` command upgrades the
standalone BPI-R4 binaries to the reviewed ARM64 release, currently Tailscale
`1.98.9`. It pins the official archive SHA256 to:

```text
fa554ee808d7d07ee8e3ebbc0215ea087157e2a0abbf408e6e18ea7532554db6
```

Run it from LAN access because a successful upgrade includes one bounded
Tailscale service restart. The upgrader writes its recovery transaction to
USB, so first require the exact five-option removable ext4 mount and rerun the
installed collector's UUID/fstab/live-device storage-authority proof:

```bash
set -eu
STORAGE_SOURCE="$(
awk '
  $2 == "/mnt/data" {
    matches++
    source = $1
    fstype = $3
    option_count = split($4, options, ",")
    for (i = 1; i <= option_count; i++) {
      option_seen[options[i]]++
    }
  }
  END {
    if (matches == 1 &&
        source ~ /^\/dev\/sd[a-z][1-9][0-9]*$/ &&
        fstype == "ext4" &&
        option_count == 5 &&
        option_seen["rw"] == 1 &&
        option_seen["noatime"] == 1 &&
        option_seen["nosuid"] == 1 &&
        option_seen["nodev"] == 1 &&
        option_seen["noexec"] == 1) {
      print source
      exit 0
    }
    exit 1
  }
' /proc/mounts
)"
(
  JAMMONITOR_LIB_ONLY=1
  export JAMMONITOR_LIB_ONLY
  . /usr/bin/jammonitor-collect
  prove_storage_authority
  [ "$PROVED_STORAGE_SOURCE" = "$STORAGE_SOURCE" ]
)
/usr/bin/jammonitor-tailscale-upgrade
```

Keep that exact USB mounted and powered for the entire upgrade, post-check,
rollback, and recovery-bundle cleanup. Never remove it while the command or
collector is active.

The upgrader acquires the shared persistent router installer `flock` before
checking or changing the durable recovery root and holds it through commit or
rollback. It cannot overlap an install or service repair, and the shared lock
inode is never removed.

The upgrader requires `uname -m` to report `aarch64`. It downloads the
versioned official tarball and its `.sha256` file into a private directory,
requires both the published checksum and archive hash to match the repository
pin, validates the extracted binary versions, and refuses a downgrade.

Before changing a binary, it verifies that the init script uses cleanup and
does not contain an active `down` action. It refuses any unsafe, non-ext4,
read-only, or unresolved recovery path under:

```text
/mnt/data/.jammonitor-tailscale-upgrade
```

It sets the watchdog maintenance marker, copies the current binaries and
pre-stop state into a root-only staging bundle, hashes them, synchronizes the
filesystem, atomically publishes that bundle as `pending`, and synchronizes it
again before stopping the service. After it proves that the supervisor,
process, and LocalAPI socket are quiescent, it adds and hashes the final
quiescent state, advances the recovery manifest to
`ready_for_binary_mutation`, and completes another sync barrier. Only then
does it atomically install either new binary. This write-ahead ordering leaves
a complete old binary pair and matching state on persistent ext4 storage even
if the upgrader is killed between the two binary renames.
The `pending` directory is the durable write-ahead log: both its contents and
the parent-directory rename are synchronized before daemon or binary mutation.
On commit or verified rollback, the resulting live files are synchronized
before the exact evidence directory is removed, and the recovery parent is
synchronized again after removal. A failed barrier preserves evidence and
blocks retry rather than claiming a durable result.

After installation it starts the service with a timeout. A pre-upgrade
`Running` state must return to `Running`. A pre-upgrade `NeedsLogin` state must
remain `NeedsLogin`; upgrading cannot and must not authenticate an expired
node. A successful commit or fully verified rollback synchronizes and removes
only the exact owned pending bundle.

If the post-check fails, the old binaries and the pre-upgrade state file are
restored as one transaction before the old service is restarted. This prevents
an older daemon from consuming state migrated by the failed newer daemon. The
command never runs `tailscale up`,
`tailscale down`, `tailscale login`, `tailscale logout`, or removes the state
file. It does not print status JSON, an AuthURL, node keys, or state contents.

The zero-argument command deliberately refuses a `NeedsLogin` observation
whose `Self.ID` is already empty. This can occur when an expired node key is
regenerated after a daemon restart. Do not authenticate the old binary merely
to bypass that guard. After securely archiving and reviewing any prior
rollback bundle, an operator may authorize only the exact already-reviewed
state-file bytes:

```bash
set +x
set +a
set -eu
umask 077
STATE=/etc/tailscale/tailscaled.state
REVIEWED_STATE_SHA256='<64_HEX_SHA256_FROM_REVIEWED_RECOVERY_EVIDENCE>'
[ -f "$STATE" ]
[ ! -L "$STATE" ]
[ "$(stat -c '%u:%g %a' "$STATE")" = '0:0 600' ]
[ "$(sha256sum "$STATE" | awk '{print $1}')" = \
  "$REVIEWED_STATE_SHA256" ]

STATUS_TMP="$(mktemp /tmp/tailscale-recovery-status.XXXXXX)"
trap 'rm -f "$STATUS_TMP"' EXIT HUP INT TERM
[ "$(stat -c '%u:%g:%a:%h' "$STATUS_TMP")" = '0:0:600:1' ]
(
  ulimit -c 0 || exit 125
  ulimit -f 128 || exit 125
  exec timeout -s TERM -k 2 5 \
    tailscale --socket=/var/run/tailscale/tailscaled.sock \
      status --json --peers=false
) >"$STATUS_TMP"
STATUS_SIZE="$(wc -c <"$STATUS_TMP" | tr -d ' ')"
case "$STATUS_SIZE" in
  ""|*[!0-9]*) exit 1 ;;
esac
[ "$STATUS_SIZE" -le 65536 ]
[ "$(jsonfilter -i "$STATUS_TMP" -e '@.BackendState')" = 'NeedsLogin' ]
[ -z "$(jsonfilter -i "$STATUS_TMP" -e '@.Self.ID')" ]
[ -n "$(jsonfilter -i "$STATUS_TMP" -e '@.AuthURL')" ]

/usr/bin/jammonitor-tailscale-upgrade \
  --recover-empty-needs-login-state-sha256 \
  "$REVIEWED_STATE_SHA256"
rm -f "$STATUS_TMP"
trap - EXIT HUP INT TERM
```

That exceptional mode pins the running, quiescent, post-upgrade, and rollback
state to the supplied digest. It accepts only `NeedsLogin` with an empty
identity and a pending authentication URL; the target must remain
`NeedsLogin`, empty-ID, and byte-identical on Tailscale `1.98.9`. A state
rewrite, unexpected identity, or transition to `Running` triggers exact
rollback. The upgrader still never performs authentication or exposes the
URL. Generate the new login only after the verified target version is active.

#### Upgrader rollback recovery

An ordinary upgrade failure automatically quiesces the daemon, restores the
old binary pair and exact pre-upgrade state bytes, restarts the old service,
and verifies its version, backend state, and identity. If any part of that
rollback cannot be proven, or if the upgrader is killed after publishing its
write-ahead bundle, recovery evidence remains at:

```text
/mnt/data/.jammonitor-tailscale-upgrade/pending
/var/run/jammonitor/tailscale-upgrade-rollback-failed
```

The USB `pending` directory is the durable, authoritative bundle and survives
reboot when the same filesystem is mounted. The `/var/run` marker is a
same-boot pointer created when a rollback failure is observed; a hard kill may
leave only the durable bundle. Any entry, including an unfinished staging
directory, under `.jammonitor-tailscale-upgrade` blocks another upgrade.

If evidence appears, do not reauthenticate, rerun the upgrader, remove or
unmount the USB, remove the marker, or start the watchdog. Keep LAN access and
copy the complete durable directory and any volatile marker to a trusted
machine. Inspect `manifest`, `RECOVERY_REQUIRED`, the saved old binaries,
`tailscaled.state.before-stop`, optional quiescent `tailscaled.state`,
hashes, phase, `ROLLBACK_INCOMPLETE`, and current service state. The phase
`prepared_before_stop` proves only the pre-stop copy; the phase
`ready_for_binary_mutation` proves the quiescent state and final write-ahead
barrier.

Restore state only while `tailscaled`, its supervisor state, and the LocalAPI
socket are all proven quiescent. Restore the exact old binary pair and the
matching state named by the reviewed manifest as one set. Start the service
and verify the original version, backend state, StableID, binary hashes, and
state hash. Only after that exact rollback is proved and copied off-router may
the reviewed `/var/run` marker and exact owned durable bundle be removed. Run
`sync`, confirm the durable recovery root is empty, and only then begin a new
upgrade attempt.

The exceptional empty-identity command above is not a generic retry switch.
Use it only after the failed bundle has been archived off-router and the
currently installed old binary, exact state SHA256, `NeedsLogin`, empty ID,
and pending AuthURL have all been independently reviewed.

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

Manual Tailscale binaries can make a sysupgrade backup large. Before every
write under `/mnt/data`, prove that exactly one mount entry exists for that
path and that it is ext4 with the `rw` option. A directory on overlay flash is
not an acceptable fallback. Then capture both the complete APK inventory and
the explicit world file so missing runtime packages can be identified after
the firmware change:

```bash
set -eu
umask 077
require_jammonitor_usb() {
  awk '
    $2 == "/mnt/data" {
      matches++
      if ($3 == "ext4" && ("," $4 ",") ~ /,rw,/) valid++
    }
    END { exit(matches == 1 && valid == 1 ? 0 : 1) }
  ' /proc/mounts
}
require_jammonitor_usb

apk info > /mnt/data/jammonitor-pre-sysupgrade.packages.unsorted
sort /mnt/data/jammonitor-pre-sysupgrade.packages.unsorted \
  > /mnt/data/jammonitor-pre-sysupgrade.packages.txt
rm -f /mnt/data/jammonitor-pre-sysupgrade.packages.unsorted
cp /etc/apk/world /mnt/data/jammonitor-pre-sysupgrade.apk-world
{
  for command_name in timeout jsonfilter sqlite3 conntrack flock \
    sha256sum sync
  do
    command_path="$(command -v "$command_name")"
    printf '\ncommand=%s path=%s\n' "$command_name" "$command_path"
    apk info -W "$command_path" || true
  done
  lua_path="$(command -v luac || command -v lua)"
  printf '\ncommand=lua-parser path=%s\n' "$lua_path"
  apk info -W "$lua_path" || true
} > /mnt/data/jammonitor-pre-sysupgrade.package-owners.txt

sysupgrade -l | grep -E 'tailscale|jammonitor'
sysupgrade -b /mnt/data/jammonitor-pre-sysupgrade.tar.gz
chmod 0600 /mnt/data/jammonitor-pre-sysupgrade.tar.gz
sync
ls -lh \
  /mnt/data/jammonitor-pre-sysupgrade.tar.gz \
  /mnt/data/jammonitor-pre-sysupgrade.packages.txt \
  /mnt/data/jammonitor-pre-sysupgrade.apk-world \
  /mnt/data/jammonitor-pre-sysupgrade.package-owners.txt
```

Review `package-owners.txt` before reboot and record the exact package names
owning every required command. Do not blindly feed the complete old package
list into `apk add`; firmware feeds and package splits can change.

After sysupgrade, use LAN access rather than relying only on Tailscale:

```bash
set -eu
for command_name in timeout jsonfilter sqlite3 conntrack flock \
  sha256sum sync
do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done
command -v luac >/dev/null 2>&1 || command -v lua >/dev/null 2>&1 || {
  printf 'missing required Lua parser: luac or lua\n' >&2
  exit 1
}

test -s /etc/tailscale/tailscaled.state
/usr/bin/jammonitor-router-install --verify-installed
/usr/bin/jammonitor-router-install --repair-services
/etc/init.d/tailscale start
/etc/init.d/jammonitor-tailscale-watchdog start
awk '
  $2 == "/mnt/data" {
    matches++
    if ($3 == "ext4" && ("," $4 ",") ~ /,rw,/) valid++
  }
  END { exit(matches == 1 && valid == 1 ? 0 : 1) }
' /proc/mounts &&
  /etc/init.d/jammonitor-history start
```

If that command inventory fails, run `apk update`, reinstall only the exact
reviewed packages recorded in `package-owners.txt`, and repeat the inventory
before running either JamMonitor repair command. If the JamMonitor installer
or its saved manifest did not survive, use the immutable remote-install
procedure with the same reviewed commit, manifest digest, and installer
digest. Never use a moving branch to repair a sysupgrade.

The reinstall action is explicit and reviewed, for example:

```bash
apk update
apk add '<EXACT_RECORDED_PACKAGE_1>' '<EXACT_RECORDED_PACKAGE_2>'
```

Replace every placeholder with a package name from the reviewed pre-upgrade
owner inventory. Do not use command substitution to install the complete old
inventory.

`--repair-services` restores preservation entries and canonical enable links.
It never restarts or authenticates Tailscale. If it finds a running known
legacy collector, it stops that service and starts `jammonitor-history`. If
`--verify-installed` reports a missing or mismatched payload, reinstall the
same reviewed commit with its trusted manifest SHA256. If the upgraded
firmware cannot execute the preserved Tailscale binaries, install a verified
ARM64 Tailscale release, keep `/etc/tailscale/tailscaled.state`, and then run
the repair command again.

Never remove or unmount the USB device while `jammonitor-history` is running,
while `sysupgrade -b` is writing, or while an installer, updater, backup,
SQLite check, or archive copy is using `/mnt/data`. For an intentional
unmount, first stop the collector, prove it is stopped, run `sync`, then
unmount through the normal OpenWrt storage path:

```bash
/etc/init.d/jammonitor-history stop
if /etc/init.d/jammonitor-history running >/dev/null 2>&1; then
  exit 1
fi
sync
```

The live JamMonitor mount intentionally keeps OpenWrt's global boot-time
`check_fs` setting disabled. An unbounded repair during boot can strand remote
management before Tailscale starts. After an unclean removal, I/O error, or
suspected power-loss corruption, keep independent LAN or console access,
stop the collector as above, prove the exact `/mnt/data` source and UUID, and
unmount it before checking it.

Run only a bounded, read-only first pass on the exact reviewed block device:

```bash
DATA_DEVICE='<EXACT_REVIEWED_MNT_DATA_BLOCK_DEVICE>'
timeout -s TERM -k 10 300 e2fsck -f -n "$DATA_DEVICE"
```

Only exit status zero is a clean acceptance result. A timeout or any nonzero
result leaves the filesystem unaccepted and unmounted. Perform any write-mode
repair from a physical console or a separate trusted Linux host with stable
power and an explicit maintenance window. Do not put a timeout around a
write-mode filesystem repair and do not start `jammonitor-history` until a
subsequent read-only check is clean, the exact UUID is mounted once at
`/mnt/data` as confined read-write ext4, and SQLite `PRAGMA quick_check`
returns `ok`.

### Acceptance Checks

Run these after installation and after every sysupgrade:

```bash
set -eu
is_uint() {
  case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac
}

VPS_TAILSCALE_IP='<VPS_TAILSCALE_IP>'
CRITICAL_PEER_FILE=/etc/jammonitor/tailscale-critical-peer
[ "$(cat "$CRITICAL_PEER_FILE")" = "$VPS_TAILSCALE_IP" ]

/usr/bin/jammonitor-router-install --verify-installed
/etc/init.d/tailscale enabled
/etc/init.d/tailscale running
/etc/init.d/jammonitor-tailscale-watchdog enabled
/etc/init.d/jammonitor-tailscale-watchdog running
/etc/init.d/jammonitor-history enabled
/etc/init.d/jammonitor-history running

WATCHDOG_STATUS=/var/run/jammonitor/tailscale-watchdog.json
OLD_OBSERVED_AT="$(
  jsonfilter -i "$WATCHDOG_STATUS" -e '@.observed_at' 2>/dev/null || true
)"
is_uint "$OLD_OBSERVED_AT" || OLD_OBSERVED_AT=0
/etc/init.d/jammonitor-tailscale-watchdog restart
for attempt in 1 2 3 4 5 6 7 8 9 10
do
  NEW_OBSERVED_AT="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.observed_at' 2>/dev/null || true
  )"
  if is_uint "$NEW_OBSERVED_AT" &&
     [ "$NEW_OBSERVED_AT" -gt "$OLD_OBSERVED_AT" ]; then
    break
  fi
  sleep 2
done
is_uint "$NEW_OBSERVED_AT"
[ "$NEW_OBSERVED_AT" -gt "$OLD_OBSERVED_AT" ]
[ "$(cat "$CRITICAL_PEER_FILE")" = "$VPS_TAILSCALE_IP" ]
[ "$(sed -n 's/^peer_contract_key=//p' \
  /var/run/jammonitor/tailscale-watchdog.memory | tail -n 1)" = \
  "$VPS_TAILSCALE_IP" ]

TAILSCALE_STATUS_TMP="$(mktemp /tmp/tailscale-status.XXXXXX)"
TAILSCALE_HEALTH_TMP="$(mktemp /tmp/tailscale-health.XXXXXX)"
trap 'rm -f "$TAILSCALE_STATUS_TMP" "$TAILSCALE_HEALTH_TMP"' \
  EXIT HUP INT TERM
timeout -s TERM -k 2 5 /bin/sh -c \
  'ulimit -f "$1" || exit 125; shift; exec "$@"' \
  jammonitor-acceptance-limit 128 \
  tailscale --socket=/var/run/tailscale/tailscaled.sock \
  status --json --peers=false > "$TAILSCALE_STATUS_TMP"
[ "$(wc -c < "$TAILSCALE_STATUS_TMP" | tr -d ' ')" -le 65536 ]
[ "$(jsonfilter -i "$TAILSCALE_STATUS_TMP" \
  -t '@.BackendState')" = 'string' ]
[ "$(jsonfilter -i "$TAILSCALE_STATUS_TMP" -t '@.Health')" = 'array' ]
BACKEND_STATE="$(jsonfilter -i "$TAILSCALE_STATUS_TMP" -e '@.BackendState')"
[ "$BACKEND_STATE" = 'Running' ]
TAILSCALE_HEALTH_TYPES="$(
  jsonfilter -i "$TAILSCALE_STATUS_TMP" -t '@.Health[*]' 2>/dev/null
)"
RAW_HEALTH_COUNT=0
while [ -n "$TAILSCALE_HEALTH_TYPES" ]
do
  case "$TAILSCALE_HEALTH_TYPES" in
    string)
      RAW_HEALTH_COUNT=$((RAW_HEALTH_COUNT + 1))
      TAILSCALE_HEALTH_TYPES=''
      ;;
    string\\\ *)
      RAW_HEALTH_COUNT=$((RAW_HEALTH_COUNT + 1))
      TAILSCALE_HEALTH_TYPES="${TAILSCALE_HEALTH_TYPES#string\\ }"
      ;;
    *) exit 1 ;;
  esac
  [ "$RAW_HEALTH_COUNT" -le 100 ]
done
jsonfilter -i "$TAILSCALE_STATUS_TMP" -e '@.Health[*]' \
  > "$TAILSCALE_HEALTH_TMP" 2>/dev/null || true
awk -v expected="$RAW_HEALTH_COUNT" '
  length($0) > 512 { invalid = 1 }
  { count++ }
  END { exit(invalid || count != expected ? 1 : 0) }
' "$TAILSCALE_HEALTH_TMP"
RAW_HEALTH_SHA256="$(sha256sum "$TAILSCALE_HEALTH_TMP" | awk '{print $1}')"

NOW_EPOCH="$(date +%s)"
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.schema')" = '3' ]
WATCHDOG_OBSERVED_AT="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.observed_at')"
is_uint "$NOW_EPOCH"
is_uint "$WATCHDOG_OBSERVED_AT"
WATCHDOG_AGE=$((NOW_EPOCH - WATCHDOG_OBSERVED_AT))
[ "$WATCHDOG_AGE" -ge 0 ]
[ "$WATCHDOG_AGE" -le 45 ]
WATCHDOG_STATE="$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.status')"
WATCHDOG_REASON="$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.reason')"
WATCHDOG_HEALTHY="$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.healthy')"
WATCHDOG_DEGRADED="$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.degraded')"
WATCHDOG_WARNINGS="$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.health_warnings')"
case "${WATCHDOG_STATE}:${WATCHDOG_REASON}" in
  running:ok)
    [ "$WATCHDOG_HEALTHY" = 'true' ]
    [ "$WATCHDOG_DEGRADED" = 'false' ]
    [ "$WATCHDOG_WARNINGS" = '0' ]
    [ "$RAW_HEALTH_COUNT" = '0' ]
    ;;
  running_degraded:health_warning)
    [ "$WATCHDOG_HEALTHY" = 'false' ]
    [ "$WATCHDOG_DEGRADED" = 'true' ]
    is_uint "$WATCHDOG_WARNINGS"
    [ "$WATCHDOG_WARNINGS" -gt 0 ]
    [ "$RAW_HEALTH_COUNT" = "$WATCHDOG_WARNINGS" ]
    sed 's/^/Tailscale Health: /' "$TAILSCALE_HEALTH_TMP" >&2
    printf 'raw Health SHA256: %s\n' "$RAW_HEALTH_SHA256" >&2
    [ -n "${REVIEWED_HEALTH_SHA256:-}" ]
    [ "$REVIEWED_HEALTH_SHA256" = "$RAW_HEALTH_SHA256" ]
    ;;
  *) exit 1 ;;
esac
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.backend_state')" = 'Running' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.local_api_responsive')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.service_running')" = 'true' ]
[ "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.tun_available')" = 'true' ]
[ -n "$(jsonfilter -i "$WATCHDOG_STATUS" -e '@.tailscale_ip')" ]
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
CONNECTIVITY_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.connectivity_uptime_seconds')"
is_uint "$CONNECTIVITY_UPTIME"
FIRST_OBSERVED_AT="$WATCHDOG_OBSERVED_AT"
FIRST_PROCESS_GENERATION="$PROCESS_GENERATION"
FIRST_PROCESS_UPTIME="$PROCESS_UPTIME"
FIRST_CONNECTIVITY_UPTIME="$CONNECTIVITY_UPTIME"

for attempt in 1 2 3 4 5 6 7 8 9 10
do
  sleep 3
  SECOND_OBSERVED_AT="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.observed_at' 2>/dev/null || true
  )"
  if is_uint "$SECOND_OBSERVED_AT" &&
     [ "$SECOND_OBSERVED_AT" -gt "$FIRST_OBSERVED_AT" ]; then
    break
  fi
done
is_uint "$SECOND_OBSERVED_AT"
[ "$SECOND_OBSERVED_AT" -gt "$FIRST_OBSERVED_AT" ]
SECOND_PROCESS_GENERATION="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_generation')"
SECOND_PROCESS_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_uptime_seconds')"
SECOND_CONNECTIVITY_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.connectivity_uptime_seconds')"
is_uint "$SECOND_PROCESS_UPTIME"
is_uint "$SECOND_CONNECTIVITY_UPTIME"
[ "$SECOND_PROCESS_GENERATION" = "$FIRST_PROCESS_GENERATION" ]
[ "$SECOND_PROCESS_UPTIME" -gt "$FIRST_PROCESS_UPTIME" ]
[ "$SECOND_CONNECTIVITY_UPTIME" -gt "$FIRST_CONNECTIVITY_UPTIME" ]
[ "$(cat "$CRITICAL_PEER_FILE")" = "$VPS_TAILSCALE_IP" ]
[ "$(sed -n 's/^peer_contract_key=//p' \
  /var/run/jammonitor/tailscale-watchdog.memory | tail -n 1)" = \
  "$VPS_TAILSCALE_IP" ]

awk '
  $2 == "/mnt/data" {
    matches++
    if ($3 == "ext4" && ("," $4 ",") ~ /,rw,/) valid++
  }
  END { exit(matches == 1 && valid == 1 ? 0 : 1) }
' /proc/mounts
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
rm -f "$TAILSCALE_STATUS_TMP" "$TAILSCALE_HEALTH_TMP"
trap - EXIT HUP INT TERM
```

The acceptance gate permits `running_degraded:health_warning` because
Tailscale may report a non-fatal advisory, such as advertised routes while
route acceptance is disabled, even when the local tunnel and critical-peer
TSMP path are working. A warning is accepted only after the operator inspects
the raw `Health` lines from the adjacent LocalAPI query and reruns the gate
with their exact SHA256 in `REVIEWED_HEALTH_SHA256`. A count alone is not
approval. The raw text remains in the private temporary file and must not be
copied into JamMonitor, logs, or public tickets. The gate still requires fresh
connected, control-plane, peer, TUN, address, stable process-generation, and
two-sample uptime-advancement evidence.

TSMP does not enter the router's operating-system network stack, so it cannot
prove that the firewall attachment, SSH, uhttpd, or LuCI works over Tailscale.
Verify that the configured peer is the intended VPS, then run separate
application-path checks from that VPS or another independent tailnet node:

```bash
# On the router:
VPS_TAILSCALE_IP='<VPS_TAILSCALE_IP>'
[ "$(cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$VPS_TAILSCALE_IP" ]

# On a Debian tailnet node with bash and curl:
ROUTER_TAILSCALE_IP='<ROUTER_TAILSCALE_IP>'
timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/22"' \
  jammonitor-probe "$ROUTER_TAILSCALE_IP"
HTTP_CODE="$(curl --silent --show-error --output /dev/null \
  --max-time 5 --write-out '%{http_code}' \
  "http://${ROUTER_TAILSCALE_IP}/cgi-bin/luci/admin/status/jammonitor")"
case "$HTTP_CODE" in
  200|301|302|303|307|308|401|403) ;;
  *) exit 1 ;;
esac
```

Repeat both application-path probes after a daemon restart and after each
reboot. Treat TSMP success with either application probe failing as an
acceptance failure, not as working management connectivity.

With a separate LAN session still working, perform one controlled generation
reset. This proves that a daemon restart cannot inherit the prior
connectivity-uptime interval:

```bash
set -eu
is_uint() {
  case "${1:-}" in ""|*[!0-9]*) return 1 ;; esac
}

WATCHDOG_STATUS=/var/run/jammonitor/tailscale-watchdog.json
VPS_TAILSCALE_IP='<VPS_TAILSCALE_IP>'
BEFORE_GENERATION="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_generation')"
BEFORE_OBSERVED_AT="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.observed_at')"
case "$BEFORE_GENERATION" in *:*) ;; *) exit 1 ;; esac
is_uint "$BEFORE_OBSERVED_AT"

MAINTENANCE=/var/run/jammonitor/tailscale-maintenance
NOW_EPOCH="$(date +%s)"
printf '%s\n' "$((NOW_EPOCH + 300))" > "$MAINTENANCE"
chmod 0600 "$MAINTENANCE"
trap 'rm -f "$MAINTENANCE"' EXIT HUP INT TERM
/etc/init.d/tailscale restart
/etc/init.d/tailscale running
rm -f "$MAINTENANCE"
trap - EXIT HUP INT TERM
/etc/init.d/jammonitor-tailscale-watchdog restart

for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
do
  AFTER_OBSERVED_AT="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.observed_at' 2>/dev/null || true
  )"
  AFTER_GENERATION="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.process_generation' \
      2>/dev/null || true
  )"
  AFTER_CONNECTED="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.connected' 2>/dev/null || true
  )"
  if is_uint "$AFTER_OBSERVED_AT" &&
     [ "$AFTER_OBSERVED_AT" -gt "$BEFORE_OBSERVED_AT" ] &&
     [ "$AFTER_GENERATION" != "$BEFORE_GENERATION" ] &&
     [ "$AFTER_CONNECTED" = 'true' ]; then
    break
  fi
  sleep 3
done
[ "$AFTER_GENERATION" != "$BEFORE_GENERATION" ]
[ "$AFTER_CONNECTED" = 'true' ]
RESET_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.connectivity_uptime_seconds')"
is_uint "$RESET_UPTIME"
[ "$RESET_UPTIME" -le 20 ]
[ "$(cat /etc/jammonitor/tailscale-critical-peer)" = \
  "$VPS_TAILSCALE_IP" ]
[ "$(sed -n 's/^peer_contract_key=//p' \
  /var/run/jammonitor/tailscale-watchdog.memory | tail -n 1)" = \
  "$VPS_TAILSCALE_IP" ]
RESET_OBSERVED_AT="$AFTER_OBSERVED_AT"

for attempt in 1 2 3 4 5 6 7 8 9 10
do
  sleep 3
  NEXT_OBSERVED_AT="$(
    jsonfilter -i "$WATCHDOG_STATUS" -e '@.observed_at' 2>/dev/null || true
  )"
  if is_uint "$NEXT_OBSERVED_AT" &&
     [ "$NEXT_OBSERVED_AT" -gt "$RESET_OBSERVED_AT" ]; then
    break
  fi
done
[ "$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.process_generation')" = "$AFTER_GENERATION" ]
NEXT_UPTIME="$(jsonfilter \
  -i "$WATCHDOG_STATUS" -e '@.connectivity_uptime_seconds')"
is_uint "$NEXT_UPTIME"
[ "$NEXT_UPTIME" -gt "$RESET_UPTIME" ]
```

On a test router with working LAN fallback, a stopped-process test can confirm
procd recovery. A LocalAPI hang test can confirm the first restart, the
60-second and 300-second cooldowns, and the three-attempt exhausted state. Do
not inject either failure through a Tailscale-only management session.

### Historical Metrics Architecture

JamMonitor history is local to the router on the mounted USB SQLite database.
The former VPS collector, port 8080 API, `ROUTER_URL`, and router `/metrics`
procedure were reverted and are obsolete. Do not deploy that procedure. A
process on the OMR VPS is not part of the current history data path.
Supabase and Convex are also intentionally unused. No Supabase CLI, Convex
CLI, project, schema, credential, login, or hosted database is required for
this release. Introducing either service would be a separate architecture and
privacy review, not an uptime fix.

The collector holds a kernel `flock` for its complete lifetime. A stale PID
file, PID reuse, or simultaneous manual and procd starts therefore cannot
create two SQLite writers or suppress a valid successor. Each Tailscale
history row records local connectivity, control-plane state, and the exact
daemon generation used for uptime continuity.

### Independent Availability Alarms

The local watchdog is intentionally conservative and cannot notify an operator
when the entire router or tailnet path is unreachable. The optional
[`monitoring/aws`](monitoring/aws/) stack runs outside those failure domains.
Its presence in this repository is not deployment evidence, and this runbook
does not claim that the external monitor is deployed.
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

The stack is not guaranteed to be free. Before execution, review current AWS
pricing and account-level usage for its retained customer-managed KMS key,
Secrets Manager secret, CloudWatch custom metrics and alarms, Logs, X-Ray,
Lambda, Scheduler, SQS, and SNS. Deleting the stack intentionally retains the
KMS key, log group, and dead-letter queue as audit and recovery evidence, so
those retained resources require a separate reviewed cleanup and can continue
to incur charges.

Deploy this optional stack from a scoped, non-root AWS identity and always
create a non-executed change set first. Substitute exact reviewed values:

```bash
set -eu
aws sts get-caller-identity --region us-east-1 --no-cli-pager
sam build --template-file monitoring/aws/template.yaml
sam deploy \
  --stack-name jammonitor-tailscale-monitor \
  --region us-east-1 \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --parameter-overrides \
    OAuthSecretArn='<SECRET_ARN>' \
    RouterDeviceId='<EXACT_ROUTER_DEVICE_ID>' \
    VpsDeviceId='<EXACT_VPS_DEVICE_ID>' \
    NotificationEmail='<EMAIL>' \
  --no-execute-changeset

# Copy the exact ARN printed by SAM. Do not guess the generated name.
CHANGE_SET_ARN='<EXACT_CHANGE_SET_ARN>'
aws cloudformation describe-change-set \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1 \
  --no-cli-pager
aws cloudformation describe-events \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1 \
  --output json \
  --no-cli-pager
aws cloudformation get-template \
  --change-set-name "$CHANGE_SET_ARN" \
  --template-stage Processed \
  --region us-east-1 \
  --no-cli-pager
```

Review every add, modify, replacement, deletion, IAM capability, parameter,
and processed-template change. Wait until `describe-change-set` reports
`CREATE_COMPLETE` or `FAILED`. In the `describe-events` output, review every
`VALIDATION_ERROR`, including both blocking `FAIL` and nonblocking `WARN`
results. Do not use legacy `describe-stack-events` for this gate because it
does not return pre-deployment validation results. If the organization has a
CloudFormation Guard policy, validate this exact template against the
version-pinned reviewed rules file before creating the change set; cfn-guard
has no safe built-in ruleset to assume.

Only after the change set is complete, all `FAIL` results are resolved, every
warning and change is explicitly accepted, and a human separately authorizes
execution may that exact ARN be executed:

```bash
aws cloudformation execute-change-set \
  --change-set-name "$CHANGE_SET_ARN" \
  --region us-east-1
```

Execution is a separate authorized action. Creating or reviewing a change set
must never be treated as permission to execute it. After execution, confirm
the SNS subscription, trigger a test notification, invoke the monitor once,
and verify both device metrics, the dead-letter queue, and the composite
alarm.

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
