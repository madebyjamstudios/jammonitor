# JamMonitor

A comprehensive WAN bonding dashboard for OpenMPTCProuter, designed for the Banana Pi BPI-R4 router platform. JamMonitor provides an intuitive web interface for monitoring, managing, and prioritizing multiple WAN connections with real-time statistics and drag-and-drop configuration.

## Features

- **Real-time Monitoring** - Live system health, throughput graphs, and latency tracking
- **Drag-and-Drop WAN Management** - Easily reorder and prioritize WAN connections
- **Multi-WAN Bonding** - Aggregate bandwidth across multiple internet connections
- **Failover Configuration** - Set up automatic failover with standby connections
- **Bandwidth Analytics** - Track usage by hour, day, and month with visual charts
- **Client Monitoring** - View all connected devices with traffic statistics
- **WiFi AP Management** - Monitor local radios and remote access points
- **Diagnostic Tools** - Export comprehensive diagnostic bundles for troubleshooting

---

## Screenshots

### Overview Dashboard

![Overview Dashboard](screenshots/overview.png)

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

![WAN Policy](screenshots/wan-policy.png)

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

### Bandwidth Analytics

![Bandwidth Charts](screenshots/bandwidth.png)

Comprehensive bandwidth tracking across multiple timeframes:

- **Realtime** - Live throughput graph updated every 3 seconds
- **Hourly** - Last 24 hours of usage broken down by hour
- **Daily** - Last 30 days of bandwidth consumption
- **Monthly** - Long-term usage trends by month
- **Per-Interface Filtering** - View bandwidth for specific WANs or all combined
- **Stacked Bar Charts** - Visual breakdown of download vs upload traffic
- **Data Tables** - Detailed numeric values alongside graphs

---

### Interfaces & Routing

![Interfaces](screenshots/interfaces.png)

Complete visibility into your network interfaces:

- **Categorized Display** - Interfaces grouped by type (WAN, LAN, VPN, WiFi, Physical)
- **Status Indicators** - Quick visual status for each interface (UP/DOWN)
- **Traffic Statistics** - RX/TX byte counters for each interface
- **IP Address Display** - Current IP assignments
- **Routing Table** - Full system routing table with destinations, gateways, and interfaces

---

### WiFi & Client Management

![WiFi APs](screenshots/wifi-clients.png)

Monitor wireless networks and connected clients:

**WiFi APs Tab:**
- Local radio status (channel, TX power, client count)
- Remote AP monitoring with latency tracking
- Configurable AP list for multi-AP deployments
- Online/Offline status badges

**Client List Tab:**
- All connected devices with hostname, IP, and MAC
- Per-client download/upload traffic
- Automatic DHCP lease and ARP table parsing

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

# Clear LuCI cache and restart
rm -rf /tmp/luci-*
/etc/init.d/uhttpd restart
```

### Manual Install (via SCP)

From your local machine:

```bash
scp -O jammonitor.lua root@<ROUTER_IP>:/usr/lib/lua/luci/controller/jammonitor.lua
scp -O jammonitor.htm root@<ROUTER_IP>:/usr/lib/lua/luci/view/jammonitor.htm
scp -O jammonitor.js root@<ROUTER_IP>:/www/luci-static/resources/jammonitor.js
```

Then clear the cache:

```bash
ssh root@<ROUTER_IP> "rm -rf /tmp/luci-* && /etc/init.d/uhttpd restart"
```

---

## File Structure

```
jammonitor/
├── jammonitor.lua    # LuCI controller - backend API endpoints & menu registration
├── jammonitor.htm    # LuCI view template - HTML structure & CSS styling
├── jammonitor.js     # Frontend JavaScript - UI logic, charts, drag-and-drop
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
- Network state (interfaces, routing, ARP)
- VPN status (WireGuard, GlorryTun, OpenVPN)
- MPTCP information
- OpenMPTCProuter configuration
- Connectivity test results
- Error summaries

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
