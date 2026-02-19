# JamMonitor

A comprehensive WAN bonding dashboard for OpenMPTCProuter, designed for the Banana Pi BPI-R4 router platform. JamMonitor provides an intuitive web interface for monitoring, managing, and prioritizing multiple WAN connections with real-time statistics and drag-and-drop configuration.

## Features

- **Real-time Monitoring** - Live system health, throughput graphs, and latency tracking
- **Drag-and-Drop WAN Management** - Easily reorder and prioritize WAN connections
- **Multi-WAN Bonding** - Aggregate bandwidth across multiple internet connections
- **Failover Configuration** - Set up automatic failover with standby connections
- **Client Monitoring** - View all connected devices with traffic statistics
- **DHCP Reservations** — Create static IP assignments for connected devices
- **Tailscale Integration** — Tailscale peers shown alongside LAN clients
- **WiFi AP Management** - Monitor local radios and remote access points
- **Diagnostic Tools** - Export comprehensive diagnostic bundles for troubleshooting
- **USB Storage & History** — Persistent metrics and ping history on USB storage with SQLite
- **Bandwidth Analytics** - Track usage by hour, day, and month with visual charts
- **Speed Testing** — Run download/upload speed tests per WAN interface
- **VPS Bypass Mode** — One-click toggle to route traffic directly without VPN
- **Auto-Update System** — One-click updates with GitHub version checking
- **Multi-Language Support** — 22 languages with automatic browser detection

---

## Screenshots

### Overview Dashboard

<img width="2042" height="1472" alt="image" src="https://github.com/user-attachments/assets/d63924ed-9e85-4c44-94f3-6ae6852a4917" />


The Overview tab provides a bird's-eye view of your entire network at a glance:

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

### Auto-Update System

<img width="664" height="524" alt="image" src="https://github.com/user-attachments/assets/32905692-cd45-49cc-af6a-5faf9bc80991" />

Keep JamMonitor current with built-in update detection and one-click install.

- **Version Comparison** — Compares local SHA against latest GitHub commit
- **Update Badge** — Orange indicator on settings gear when update available
- **One-Click Install** — Downloads and atomically installs all 4 components
- **Progress Indicator** — Visual feedback during download/install
- **Automatic Reload** — Page refreshes after successful update

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

### Quick Install

SSH into your router and run:

```bash
# Create directories if needed
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/view
mkdir -p /www/luci-static/resources

# Download files
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/jammonitor.lua -O /usr/lib/lua/luci/controller/jammonitor.lua
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/jammonitor.htm -O /usr/lib/lua/luci/view/jammonitor.htm
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/jammonitor.js -O /www/luci-static/resources/jammonitor.js
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/jammonitor-i18n.js -O /www/luci-static/resources/jammonitor-i18n.js

# Save version info for update checking
JM_SHA=$(curl -s https://api.github.com/repos/madebyjamstudios/jammonitor/commits/main 2>/dev/null | grep '"sha"' | head -1 | cut -d'"' -f4)
echo "${JM_SHA:0:7}" > /www/luci-static/resources/jammonitor.version

# Clear LuCI cache and restart
rm -rf /tmp/luci-*
/etc/init.d/uhttpd restart
```

### Optional: Enable History Persistence

Install the collector scripts for USB storage persistence:

```bash
# Install history collector for USB storage persistence
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/router/jammonitor-collect -O /usr/bin/jammonitor-collect
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/router/jammonitor-history.init -O /etc/init.d/jammonitor-collect
chmod +x /usr/bin/jammonitor-collect /etc/init.d/jammonitor-collect
```

### Manual Install (via SCP)

From your local machine:

```bash
# Create version file from local git
echo $(git rev-parse --short HEAD) > jammonitor.version

# Copy files to router
scp -O jammonitor.lua root@<ROUTER_IP>:/usr/lib/lua/luci/controller/jammonitor.lua
scp -O jammonitor.htm root@<ROUTER_IP>:/usr/lib/lua/luci/view/jammonitor.htm
scp -O jammonitor.js root@<ROUTER_IP>:/www/luci-static/resources/jammonitor.js
scp -O jammonitor-i18n.js root@<ROUTER_IP>:/www/luci-static/resources/jammonitor-i18n.js
scp -O jammonitor.version root@<ROUTER_IP>:/www/luci-static/resources/jammonitor.version

# (Optional) History collector for USB storage persistence
scp -O router/jammonitor-collect root@<ROUTER_IP>:/usr/bin/jammonitor-collect
scp -O router/jammonitor-history.init root@<ROUTER_IP>:/etc/init.d/jammonitor-collect
```

Then clear the cache:

```bash
ssh root@<ROUTER_IP> "rm -rf /tmp/luci-* && /etc/init.d/uhttpd restart"
```

---

## File Structure

```
jammonitor/
├── jammonitor.lua           # LuCI controller — backend API endpoints & menu registration
├── jammonitor.htm           # LuCI view template — HTML structure & CSS styling
├── jammonitor.js            # Frontend JavaScript — UI logic, charts, drag-and-drop
├── jammonitor-i18n.js       # Internationalization — translation strings for 22 languages
├── router/
│   ├── jammonitor-collect   # Metrics collector daemon — writes to SQLite every 60s
│   └── jammonitor-history.init  # OpenWrt init script — manages collector as a procd service
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
