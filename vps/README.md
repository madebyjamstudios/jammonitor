# JamMonitor VPS - Historical Metrics Collector

This component runs on your VPS to collect and store long-term metrics from your router.

## Prerequisites

- Python 3.8+
- Tailscale installed and connected to your router
- Router running JamMonitor with the `/metrics` endpoint

## Quick Install

```bash
# SSH to your VPS
ssh user@your-vps

# Create directory
sudo mkdir -p /opt/jammonitor-vps
cd /opt/jammonitor-vps

# Download files (or copy from this directory)
# Option 1: wget from GitHub
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/vps/jammonitor_vps.py
wget https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main/vps/requirements.txt

# Option 2: Copy files manually
scp jammonitor_vps.py requirements.txt user@vps:/opt/jammonitor-vps/

# Install dependencies
pip3 install -r requirements.txt

# Test manually first
export ROUTER_URL="http://YOUR_ROUTER_TAILSCALE_IP/cgi-bin/luci/jammonitor/metrics"
python3 jammonitor_vps.py

# If it works, set up as service
```

## Systemd Service Setup

```bash
# Copy service file
sudo cp jammonitor-vps.service /etc/systemd/system/

# Edit to set your ROUTER_URL
sudo nano /etc/systemd/system/jammonitor-vps.service
# Change: Environment="ROUTER_URL=http://100.x.x.x/cgi-bin/luci/jammonitor/metrics"

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable jammonitor-vps
sudo systemctl start jammonitor-vps

# Check status
sudo systemctl status jammonitor-vps
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `ROUTER_URL` | (required) | Full URL to router's metrics endpoint |
| `POLL_SECONDS` | 5 | How often to poll the router |
| `RETENTION_DAYS` | 30 | How long to keep historical data |
| `PORT` | 8080 | Server port for API |
| `DB_PATH` | ./jammonitor.db | SQLite database path |

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/status` | GET | Health check + sample count |
| `/metrics?hours=24` | GET | Query metrics as JSON |
| `/bundle?hours=24` | GET | Download gzipped bundle |

## Testing

```bash
# Check status
curl http://localhost:8080/status

# Test metrics endpoint on router (from VPS)
curl http://ROUTER_TAILSCALE_IP/cgi-bin/luci/jammonitor/metrics

# Download 24-hour bundle
curl -o history.json.gz http://localhost:8080/bundle?hours=24
```

## Connecting JamMonitor UI

1. In JamMonitor, go to Diagnostics tab
2. Enter your VPS URL: `http://YOUR_VPS_TAILSCALE_IP:8080`
3. Click Save
4. Use "Download Historical Bundle" to get extended history

## Storage Estimates

| Retention | Poll Interval | Samples | Approx Size |
|-----------|--------------|---------|-------------|
| 7 days | 5 sec | 120,960 | ~85 MB |
| 30 days | 5 sec | 518,400 | ~360 MB |
| 30 days | 10 sec | 259,200 | ~180 MB |

## Troubleshooting

**403 Forbidden from router:**
- Check Tailscale is connected
- Verify your VPS Tailscale IP starts with `100.`
- Router only allows Tailscale IPs (100.64.0.0/10)

**Connection refused:**
- Check router is running JamMonitor
- Verify LuCI cache was cleared after update

**No samples being collected:**
- Check `ROUTER_URL` is set correctly
- Test with: `curl $ROUTER_URL`
