module("luci.controller.jammonitor", package.seeall)

function index()
    entry({"admin", "status", "jammonitor"}, template("jammonitor"), _("Jam Monitor"), 99)
    entry({"admin", "status", "jammonitor", "exec"}, call("action_exec"), nil)
    entry({"admin", "status", "jammonitor", "diag"}, call("action_diag"), nil)
    entry({"admin", "status", "jammonitor", "wifi_status"}, call("action_wifi_status"), nil)
    entry({"admin", "status", "jammonitor", "wan_policy"}, call("action_wan_policy"), nil)
    entry({"admin", "status", "jammonitor", "wan_edit"}, call("action_wan_edit"), nil)
    entry({"admin", "status", "jammonitor", "wan_advanced"}, call("action_wan_advanced"), nil)
    entry({"admin", "status", "jammonitor", "wan_ifaces"}, call("action_wan_ifaces"), nil)
end

function action_exec()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local cmd = http.formvalue("cmd")

    http.prepare_content("text/plain")
    if cmd then
        local result = sys.exec(cmd .. " 2>/dev/null")
        http.write(result or "")
    else
        http.write("")
    end
end

-- WiFi status endpoint for Wi-Fi APs tab
function action_wifi_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    local result = {
        local_radios = {},
        remote_aps = {},
        totals = {
            aps_online = 0,
            aps_total = 0,
            total_clients = 0
        }
    }

    -- Build MAC -> hostname map from DHCP leases
    local mac_to_hostname = {}
    local leases = sys.exec("cat /tmp/dhcp.leases 2>/dev/null")
    if leases and leases ~= "" then
        -- Format: timestamp mac ip hostname clientid
        for line in leases:gmatch("[^\n]+") do
            local mac, hostname = line:match("^%S+%s+(%S+)%s+%S+%s+(%S+)")
            if mac and hostname and hostname ~= "*" then
                mac_to_hostname[mac:upper()] = hostname
            end
        end
    end

    -- Get local radio info via ubus
    local ubus_wifi = sys.exec("ubus call network.wireless status 2>/dev/null")
    if ubus_wifi and ubus_wifi ~= "" then
        local wifi_data = json.parse(ubus_wifi)
        if wifi_data then
            for radio_name, radio_info in pairs(wifi_data) do
                local radio = {
                    name = radio_name,
                    up = radio_info.up or false,
                    channel = "N/A",
                    txpower = "N/A",
                    clients = 0,
                    ssids = {}
                }

                -- Get channel/txpower from iwinfo using first interface (not radio name)
                local first_iface = radio_info.interfaces and radio_info.interfaces[1] and radio_info.interfaces[1].ifname
                if first_iface then
                    local iwinfo_out = sys.exec("iwinfo " .. first_iface .. " info 2>/dev/null")
                    if iwinfo_out and iwinfo_out ~= "" then
                        local ch = iwinfo_out:match("Channel:%s*(%d+)")
                        local txp = iwinfo_out:match("Tx%-Power:%s*(%d+)")
                        local freq = iwinfo_out:match("Channel:%s*%d+%s*%(([%d%.]+)%s*GHz%)")
                        if ch then radio.channel = ch end
                        if txp then radio.txpower = txp .. " dBm" end
                        if freq then radio.band = freq .. " GHz" end
                    end

                    -- Get channel utilization from survey data (raw values for delta calc in JS)
                    local survey_out = sys.exec("iw " .. first_iface .. " survey dump 2>/dev/null")
                    if survey_out and survey_out ~= "" then
                        -- Find the "in use" frequency block and extract busy/active times
                        local in_use_block = survey_out:match("%[in use%][^\n]*(.-)Survey")
                        if not in_use_block then
                            in_use_block = survey_out:match("%[in use%][^\n]*(.*)")
                        end
                        if in_use_block then
                            local active = in_use_block:match("channel active time:%s*(%d+)")
                            local busy = in_use_block:match("channel busy time:%s*(%d+)")
                            if active and busy then
                                -- Send raw values for JS to calculate delta
                                radio.survey_active = tonumber(active) or 0
                                radio.survey_busy = tonumber(busy) or 0
                            end
                        end
                    end
                end

                -- Initialize client list for this radio
                radio.client_list = {}

                -- Get SSIDs from interfaces
                if radio_info.interfaces then
                    for _, iface in ipairs(radio_info.interfaces) do
                        local ssid_info = {
                            ifname = iface.ifname or "N/A",
                            ssid = (iface.config and iface.config.ssid) or "N/A",
                            mode = (iface.config and iface.config.mode) or "N/A"
                        }
                        -- Get client details for this interface using iw station dump
                        -- Provides per-client bytes and WiFi generation info
                        if iface.ifname then
                            local station_dump = sys.exec("iw dev " .. iface.ifname .. " station dump 2>/dev/null")
                            local client_count = 0
                            if station_dump and station_dump ~= "" then
                                -- Parse each station block
                                -- Split by "Station" to get individual client blocks
                                for block in station_dump:gmatch("Station%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*%b()(.-)Station") do
                                end
                                -- Better approach: parse line by line per station
                                local current_mac = nil
                                local current_data = {}
                                for line in station_dump:gmatch("[^\n]+") do
                                    local mac = line:match("^Station%s+(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
                                    if mac then
                                        -- Save previous client if exists
                                        if current_mac and current_data.rx_bytes then
                                            client_count = client_count + 1
                                            local hostname = mac_to_hostname[current_mac:upper()] or ""
                                            -- Detect WiFi generation from tx bitrate line
                                            local wifi_gen = "WiFi 4"
                                            if current_data.tx_bitrate then
                                                if current_data.tx_bitrate:match("EHT%-MCS") then
                                                    wifi_gen = "WiFi 7"
                                                elseif current_data.tx_bitrate:match("HE%-MCS") then
                                                    wifi_gen = "WiFi 6"
                                                elseif current_data.tx_bitrate:match("VHT%-MCS") then
                                                    wifi_gen = "WiFi 5"
                                                end
                                            end
                                            table.insert(radio.client_list, {
                                                mac = current_mac,
                                                hostname = hostname,
                                                signal = current_data.signal or 0,
                                                rx_bytes = current_data.rx_bytes or 0,
                                                tx_bytes = current_data.tx_bytes or 0,
                                                wifi_gen = wifi_gen,
                                                band = radio.band or "N/A"
                                            })
                                        end
                                        -- Start new client
                                        current_mac = mac
                                        current_data = {}
                                    elseif current_mac then
                                        -- Parse data lines
                                        local rx_bytes = line:match("rx bytes:%s*(%d+)")
                                        local tx_bytes = line:match("tx bytes:%s*(%d+)")
                                        local signal = line:match("signal:%s*([%-]?%d+)")
                                        local tx_bitrate = line:match("tx bitrate:%s*(.+)")
                                        if rx_bytes then current_data.rx_bytes = tonumber(rx_bytes) end
                                        if tx_bytes then current_data.tx_bytes = tonumber(tx_bytes) end
                                        if signal then current_data.signal = tonumber(signal) end
                                        if tx_bitrate then current_data.tx_bitrate = tx_bitrate end
                                    end
                                end
                                -- Don't forget the last client
                                if current_mac and current_data.rx_bytes then
                                    client_count = client_count + 1
                                    local hostname = mac_to_hostname[current_mac:upper()] or ""
                                    local wifi_gen = "WiFi 4"
                                    if current_data.tx_bitrate then
                                        if current_data.tx_bitrate:match("EHT%-MCS") then
                                            wifi_gen = "WiFi 7"
                                        elseif current_data.tx_bitrate:match("HE%-MCS") then
                                            wifi_gen = "WiFi 6"
                                        elseif current_data.tx_bitrate:match("VHT%-MCS") then
                                            wifi_gen = "WiFi 5"
                                        end
                                    end
                                    table.insert(radio.client_list, {
                                        mac = current_mac,
                                        hostname = hostname,
                                        signal = current_data.signal or 0,
                                        rx_bytes = current_data.rx_bytes or 0,
                                        tx_bytes = current_data.tx_bytes or 0,
                                        wifi_gen = wifi_gen,
                                        band = radio.band or "N/A"
                                    })
                                end
                            end
                            ssid_info.clients = client_count
                            radio.clients = radio.clients + client_count
                        end
                        table.insert(radio.ssids, ssid_info)
                    end
                end

                table.insert(result.local_radios, radio)
                if radio.up then
                    result.totals.aps_online = result.totals.aps_online + 1
                end
                result.totals.aps_total = result.totals.aps_total + 1
                result.totals.total_clients = result.totals.total_clients + radio.clients
            end
        end
    end

    -- Sort radios by name (radio0, radio1, radio2)
    table.sort(result.local_radios, function(a, b)
        return a.name < b.name
    end)

    -- Get remote AP pings (IPs passed as query param, validated)
    local remote_ips_param = http.formvalue("remote_ips")
    if remote_ips_param and remote_ips_param ~= "" then
        local ips = {}
        -- Parse comma-separated IPs with strict validation
        for ip in remote_ips_param:gmatch("[^,]+") do
            ip = ip:match("^%s*(.-)%s*$") -- trim
            -- Validate IP format strictly
            if ip:match("^%d+%.%d+%.%d+%.%d+$") then
                local valid = true
                for octet in ip:gmatch("%d+") do
                    local n = tonumber(octet)
                    if not n or n < 0 or n > 255 then
                        valid = false
                        break
                    end
                end
                if valid and #ips < 20 then -- Max 20 APs
                    table.insert(ips, ip)
                end
            end
        end

        -- Ping each remote AP
        for _, ip in ipairs(ips) do
            local ping_result = sys.exec("ping -c1 -W1 " .. ip .. " 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2")
            local latency = tonumber(ping_result:match("[%d.]+"))
            local ap = {
                ip = ip,
                online = latency ~= nil,
                latency = latency or 0,
                last_seen = os.time()
            }
            table.insert(result.remote_aps, ap)
            if ap.online then
                result.totals.aps_online = result.totals.aps_online + 1
            end
            result.totals.aps_total = result.totals.aps_total + 1
        end
    end

    http.write(json.stringify(result))
end

function action_diag()
    local http = require "luci.http"
    local sys = require "luci.sys"

    -- Generate diagnostic bundle (use [=[ ]=] to allow nested brackets in shell script)
    local script = [=[
#!/bin/sh
# Jam Monitor Diagnostics Bundle Generator
# Compatible with BusyBox ash
# Version: 2.1 - Improved DNS, package detection, route diagnostics

DIAGDIR="/tmp/jamdiag"
rm -rf "$DIAGDIR"
mkdir -p "$DIAGDIR"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

# Check if command exists
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Robust redaction function - handles multiple formats:
# - UCI: option token '...', list password '...'
# - Shell/env: TOKEN=..., password: ...
# - JSON: "token":"...", "password": "..."
# Case-insensitive matching for sensitive keys
redact_sensitive() {
    sed -E \
        -e "s/(option[[:space:]]+(token|password|passwd|private_key|preshared_key|psk|secret|api_key|jwt|key)[[:space:]]+)['\"]?[^'\"]+['\"]?/\1'<REDACTED>'/gi" \
        -e "s/(list[[:space:]]+(token|password|passwd|private_key|preshared_key|psk|secret|api_key|jwt|key)[[:space:]]+)['\"]?[^'\"]+['\"]?/\1'<REDACTED>'/gi" \
        -e "s/((token|password|passwd|private_key|preshared_key|psk|secret|api_key|jwt|key)[[:space:]]*=[[:space:]]*)['\"]?[^'\"[:space:]]+['\"]?/\1<REDACTED>/gi" \
        -e "s/((token|password|passwd|private_key|preshared_key|psk|secret|api_key|jwt|key)[[:space:]]*:[[:space:]]*)['\"]?[^'\"[:space:],}]+['\"]?/\1<REDACTED>/gi" \
        -e "s/(\"(token|password|passwd|private_key|preshared_key|psk|secret|api_key|jwt|key)\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")/\1<REDACTED>\3/gi" \
        -e "s/(eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*)/<JWT_REDACTED>/g"
}

# Write with truncation markers (prevents mid-block truncation confusion)
write_truncated() {
    local max_lines="$1"
    local total_lines
    local content
    content=$(cat)
    total_lines=$(echo "$content" | wc -l)

    if [ "$total_lines" -le "$max_lines" ]; then
        echo "$content"
    else
        local head_lines=$((max_lines * 2 / 3))
        local tail_lines=$((max_lines / 3))
        echo "$content" | head -n "$head_lines"
        echo ""
        echo "=== TRUNCATED: Showing $head_lines of $total_lines lines (first part) ==="
        echo "=== ... $((total_lines - head_lines - tail_lines)) lines omitted ... ==="
        echo "=== Showing last $tail_lines lines: ==="
        echo ""
        echo "$content" | tail -n "$tail_lines"
    fi
}

# ============================================================
# 00 - Timestamp
# ============================================================
{
    echo "=== DIAGNOSTIC TIMESTAMP ==="
    date '+%Y-%m-%d %H:%M:%S %Z'
    echo ""
    echo "=== UPTIME ==="
    uptime
    cat /proc/uptime 2>/dev/null
} > "$DIAGDIR/00_timestamp.txt"

# ============================================================
# 01 - System
# ============================================================
{
    echo "=== UNAME ==="
    uname -a
    echo ""
    echo "=== CPU INFO ==="
    cat /proc/cpuinfo 2>/dev/null
    echo ""
    echo "=== MEMORY INFO ==="
    cat /proc/meminfo 2>/dev/null
    echo ""
    echo "=== FREE ==="
    free 2>/dev/null || cat /proc/meminfo 2>/dev/null | grep -E "^(MemTotal|MemFree|MemAvailable|Buffers|Cached):"
    echo ""
    echo "=== LOAD AVERAGE ==="
    cat /proc/loadavg
    echo ""
    echo "=== TOP (snapshot) ==="
    top -bn1 2>/dev/null | head -30 || echo "(top not available)"
} > "$DIAGDIR/01_system.txt"

# ============================================================
# 02 - Thermal (FIXED: add units and context)
# ============================================================
{
    echo "=== THERMAL ZONES ==="
    if [ -d /sys/class/thermal ]; then
        for tz in /sys/class/thermal/thermal_zone*; do
            if [ -d "$tz" ]; then
                zone=$(basename "$tz")
                type=$(cat "$tz/type" 2>/dev/null || echo "unknown")
                temp=$(cat "$tz/temp" 2>/dev/null || echo "N/A")
                if [ "$temp" != "N/A" ] && [ "$temp" -gt 1000 ] 2>/dev/null; then
                    temp_c=$((temp / 1000))
                    temp_dec=$((temp % 1000 / 100))
                    echo "$zone ($type): ${temp_c}.${temp_dec} C (raw: $temp)"
                else
                    echo "$zone ($type): $temp"
                fi
            fi
        done
    else
        echo "(no thermal zones found)"
    fi
    echo ""
    echo "=== CPU FREQUENCY ==="
    if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
            if [ -d "$cpu/cpufreq" ]; then
                cpuname=$(basename "$cpu")
                cur=$(cat "$cpu/cpufreq/scaling_cur_freq" 2>/dev/null)
                min=$(cat "$cpu/cpufreq/scaling_min_freq" 2>/dev/null)
                max=$(cat "$cpu/cpufreq/scaling_max_freq" 2>/dev/null)
                gov=$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null)
                if [ -n "$cur" ]; then
                    echo "$cpuname: ${cur}kHz (min:${min} max:${max} gov:$gov)"
                fi
            fi
        done
    else
        echo "(cpufreq not available)"
    fi
    echo ""
    echo "=== THROTTLING INDICATORS ==="
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/throttle_count ]; then
        cat /sys/devices/system/cpu/cpu*/cpufreq/throttle_count 2>/dev/null
    else
        dmesg 2>/dev/null | grep -i throttl | tail -10 || echo "(no throttling info found)"
    fi
} > "$DIAGDIR/02_thermal.txt"

# ============================================================
# 03 - Network
# ============================================================
{
    echo "=== IP ADDR ==="
    ip addr
    echo ""
    echo "=== IP LINK ==="
    ip -s link
    echo ""
    echo "=== IP ROUTE ==="
    ip route
    echo ""
    echo "=== IP ROUTE TABLE ALL ==="
    ip route show table all 2>/dev/null | head -100
    echo ""
    echo "=== IP RULE ==="
    ip rule
    echo ""
    echo "=== IPV6 ROUTE ==="
    ip -6 route 2>/dev/null | head -50
} > "$DIAGDIR/03_network.txt"

# ============================================================
# 04 - MPTCP
# ============================================================
{
    echo "=== MPTCP SNMP ==="
    cat /proc/net/mptcp_net/snmp 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== MPTCP ENDPOINTS ==="
    ip mptcp endpoint show 2>/dev/null || echo "(not available)"
    echo ""
    echo "=== MPTCP LIMITS ==="
    ip mptcp limits 2>/dev/null || echo "(not available)"
} > "$DIAGDIR/04_mptcp.txt"

# ============================================================
# 05 - VPN (basic)
# ============================================================
{
    echo "=== WIREGUARD ==="
    if has_cmd wg; then
        wg show 2>/dev/null || echo "(no wireguard interfaces)"
    else
        echo "(wg command not found)"
    fi
    echo ""
    echo "=== GLORYTUN PROCESSES ==="
    pgrep -a glorytun 2>/dev/null || echo "(not running)"
    echo ""
    echo "=== OPENVPN PROCESSES ==="
    pgrep -a openvpn 2>/dev/null || echo "(not running)"
    echo ""
    echo "=== MLVPN PROCESSES ==="
    pgrep -a mlvpn 2>/dev/null || echo "(not running)"
} > "$DIAGDIR/05_vpn.txt"

# ============================================================
# 06 - Conntrack (FIXED: real conntrack data)
# ============================================================
{
    echo "=== CONNTRACK COUNTS ==="
    echo -n "Current: "
    cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A"
    echo -n "Max: "
    cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A"
    echo ""
    echo "=== CONNTRACK STATS ==="
    if has_cmd conntrack; then
        conntrack -S 2>/dev/null || echo "(conntrack -S failed)"
        echo ""
        echo "=== CONNTRACK LIST (first 200 entries) ==="
        conntrack -L 2>/dev/null | head -200 || echo "(conntrack -L failed)"
    else
        echo "(conntrack command not found)"
        echo ""
        echo "=== /proc/net/nf_conntrack (first 200 lines) ==="
        head -200 /proc/net/nf_conntrack 2>/dev/null || echo "(not available)"
    fi
    echo ""
    echo "=== CONNTRACK SYSCTL ==="
    for f in /proc/sys/net/netfilter/nf_conntrack_*; do
        [ -f "$f" ] && echo "$(basename $f): $(cat $f 2>/dev/null)"
    done 2>/dev/null | head -30
} > "$DIAGDIR/06_conntrack.txt"

# ============================================================
# 07 - DNS (IMPROVED: per-interface DNS with jsonfilter)
# ============================================================
{
    echo "=== DNS CONFIGURATION ==="
    echo ""

    echo "--- /tmp/resolv.conf Status ---"
    if [ -f /tmp/resolv.conf ]; then
        echo "Lines: $(wc -l < /tmp/resolv.conf)"
        ls -l /tmp/resolv.conf
        if [ ! -s /tmp/resolv.conf ]; then
            echo "WARNING: /tmp/resolv.conf exists but is EMPTY"
        fi
    else
        echo "/tmp/resolv.conf: NOT FOUND"
    fi
    echo ""

    echo "--- /etc/resolv.conf Symlink ---"
    ls -l /etc/resolv.conf 2>/dev/null || echo "(not found)"
    RESOLVED_PATH=$(readlink -f /etc/resolv.conf 2>/dev/null)
    echo "Resolves to: $RESOLVED_PATH"
    echo ""

    echo "--- Effective resolv.conf Content ---"
    if [ -n "$RESOLVED_PATH" ] && [ -f "$RESOLVED_PATH" ]; then
        cat "$RESOLVED_PATH" 2>/dev/null
    else
        cat /etc/resolv.conf 2>/dev/null || echo "(not found)"
    fi
    echo ""

    echo "=== PER-INTERFACE DNS ==="
    echo ""

    IFACE_LIST="lan wan wan1 wan2 wan3 wan4 omrvpn"

    if has_cmd jsonfilter; then
        echo "--- Using jsonfilter for clean output ---"
        echo ""
        printf "%-12s %-6s %-12s %-10s %-40s %s\n" "INTERFACE" "UP" "DEVICE" "PROTO" "DNS-SERVERS" "DNS-SEARCH"
        printf "%-12s %-6s %-12s %-10s %-40s %s\n" "-----------" "------" "------------" "----------" "----------------------------------------" "----------"

        for iface in $IFACE_LIST; do
            STATUS=$(ifstatus "$iface" 2>/dev/null)
            if [ -n "$STATUS" ] && [ "$STATUS" != "" ]; then
                UP=$(echo "$STATUS" | jsonfilter -e '@.up' 2>/dev/null || echo "N/A")
                DEVICE=$(echo "$STATUS" | jsonfilter -e '@.device' 2>/dev/null)
                [ -z "$DEVICE" ] && DEVICE=$(echo "$STATUS" | jsonfilter -e '@.l3_device' 2>/dev/null)
                [ -z "$DEVICE" ] && DEVICE="N/A"
                PROTO=$(echo "$STATUS" | jsonfilter -e '@.proto' 2>/dev/null || echo "N/A")
                DNS=$(echo "$STATUS" | jsonfilter -e '@["dns-server"][*]' 2>/dev/null | tr '\n' ' ')
                [ -z "$DNS" ] && DNS="(none)"
                SEARCH=$(echo "$STATUS" | jsonfilter -e '@["dns-search"][*]' 2>/dev/null | tr '\n' ' ')
                [ -z "$SEARCH" ] && SEARCH="(none)"

                printf "%-12s %-6s %-12s %-10s %-40s %s\n" "$iface" "$UP" "$DEVICE" "$PROTO" "$DNS" "$SEARCH"
            fi
        done
    else
        echo "--- jsonfilter not available, showing full JSON ---"
        echo ""
        for iface in $IFACE_LIST; do
            STATUS=$(ifstatus "$iface" 2>/dev/null)
            if [ -n "$STATUS" ] && [ "$STATUS" != "" ]; then
                echo "=========================================="
                echo "INTERFACE: $iface"
                echo "=========================================="
                # Print complete JSON, not truncated
                echo "$STATUS"
                echo ""
            fi
        done
    fi

    echo ""
    echo "=== /tmp/resolv.conf.auto ==="
    cat /tmp/resolv.conf.auto 2>/dev/null || echo "(not found)"
    echo ""

    echo "=== /tmp/resolv.conf.d/* ==="
    if [ -d /tmp/resolv.conf.d ]; then
        for f in /tmp/resolv.conf.d/*; do
            if [ -f "$f" ]; then
                echo "--- $f ---"
                cat "$f"
                echo ""
            fi
        done
    else
        echo "(directory not found)"
    fi

    echo ""
    echo "=== DNS RESOLUTION TESTS ==="
    if has_cmd nslookup; then
        echo "--- nslookup openwrt.org 1.1.1.1 ---"
        timeout 5 nslookup openwrt.org 1.1.1.1 2>&1 || echo "(timeout or failed)"
        echo ""
        echo "--- nslookup google.com 8.8.8.8 ---"
        timeout 5 nslookup google.com 8.8.8.8 2>&1 || echo "(timeout or failed)"
    elif has_cmd dig; then
        echo "--- dig openwrt.org @1.1.1.1 ---"
        timeout 5 dig openwrt.org @1.1.1.1 +short 2>&1 || echo "(timeout or failed)"
        echo ""
        echo "--- dig google.com @8.8.8.8 ---"
        timeout 5 dig google.com @8.8.8.8 +short 2>&1 || echo "(timeout or failed)"
    else
        echo "(nslookup/dig not available)"
    fi
} > "$DIAGDIR/07_dns.txt"

# ============================================================
# 08 - DHCP Leases
# ============================================================
{
    echo "=== DHCP LEASES ==="
    cat /tmp/dhcp.leases 2>/dev/null || echo "(no leases file)"
} > "$DIAGDIR/08_dhcp_leases.txt"

# ============================================================
# 09 - OMR Config (REDACTED - all sensitive values removed)
# ============================================================
{
    echo "=== OMR CONFIG (REDACTED) ==="
    echo "NOTE: Tokens, passwords, keys, and secrets have been redacted for security."
    echo ""
    if [ -f /etc/config/openmptcprouter ]; then
        cat /etc/config/openmptcprouter | redact_sensitive
    else
        echo "(not found)"
    fi
    echo ""
    echo "=== NETWORK CONFIG (REDACTED) ==="
    if [ -f /etc/config/network ]; then
        cat /etc/config/network | redact_sensitive
    else
        echo "(not found)"
    fi
    echo ""
    echo "=== FIREWALL CONFIG ==="
    if [ -f /etc/config/firewall ]; then
        cat /etc/config/firewall | redact_sensitive | write_truncated 300
    else
        echo "(not found)"
    fi
    echo ""
    echo "=== WIREGUARD CONFIG (REDACTED) ==="
    if [ -f /etc/config/wireguard ]; then
        cat /etc/config/wireguard | redact_sensitive
    else
        echo "(not found)"
    fi
    echo ""
    echo "=== SHADOWSOCKS CONFIG (REDACTED) ==="
    if [ -f /etc/config/shadowsocks-libev ]; then
        cat /etc/config/shadowsocks-libev | redact_sensitive
    else
        echo "(not found)"
    fi
    echo ""
    echo "=== VPN CONFIG (REDACTED) ==="
    for cfg in glorytun mlvpn openvpn dsvpn; do
        if [ -f "/etc/config/$cfg" ]; then
            echo "--- $cfg ---"
            cat "/etc/config/$cfg" | redact_sensitive
            echo ""
        fi
    done
} > "$DIAGDIR/09_omr_config.txt"

# ============================================================
# 10 - Services Status
# ============================================================
{
    echo "=== SERVICE STATUS ==="
    for svc in openmptcprouter mptcpd shadowsocks-libev glorytun-udp glorytun-tcp mlvpn openvpn wireguard dnsmasq; do
        if [ -x "/etc/init.d/$svc" ]; then
            echo "--- $svc ---"
            /etc/init.d/$svc status 2>&1 || echo "(status failed)"
            /etc/init.d/$svc enabled 2>&1 && echo "enabled=yes" || echo "enabled=no"
            echo ""
        fi
    done
} > "$DIAGDIR/10_services.txt"

# ============================================================
# 11 - Syslog
# ============================================================
{
    echo "=== SYSLOG (last 1000 lines) ==="
    logread -l 1000 2>/dev/null || logread 2>/dev/null | tail -1000 || echo "(logread not available)"
} > "$DIAGDIR/11_syslog.txt"

# ============================================================
# 12 - Dmesg
# ============================================================
{
    echo "=== DMESG (last 500 lines) ==="
    dmesg 2>/dev/null | tail -500 || echo "(dmesg not available)"
} > "$DIAGDIR/12_dmesg.txt"

# ============================================================
# 13 - Errors/Warnings
# ============================================================
{
    echo "=== ERRORS/WARNINGS FROM LOGS ==="
    logread 2>/dev/null | grep -iE "(error|fail|warn|crit|emerg|down|timeout|unreachable|refused|denied)" | tail -200
} > "$DIAGDIR/13_errors.txt"

# ============================================================
# 14 - Connectivity Tests
# ============================================================
{
    echo "=== CONNECTIVITY TESTS ==="
    echo "--- Ping 1.1.1.1 ---"
    ping -c3 -W2 1.1.1.1 2>&1
    echo ""
    echo "--- Ping 8.8.8.8 ---"
    ping -c3 -W2 8.8.8.8 2>&1
    echo ""
    echo "--- Ping VPS (if configured) ---"
    VPS_IP=$(uci get openmptcprouter.vps.ip 2>/dev/null)
    if [ -n "$VPS_IP" ]; then
        ping -c3 -W2 "$VPS_IP" 2>&1
    else
        echo "(VPS IP not configured)"
    fi
} > "$DIAGDIR/14_connectivity.txt"

# ============================================================
# 15 - OMR Status (FIXED: multiple fallback methods)
# ============================================================
{
    echo "=== OMR STATUS ==="
    got_status=0

    # Method 1: omr command
    if has_cmd omr; then
        echo "--- omr status ---"
        omr status 2>&1 && got_status=1
        echo ""
    fi

    # Method 2: ubus call
    if [ $got_status -eq 0 ] && has_cmd ubus; then
        echo "--- ubus call openmptcprouter getStatus ---"
        result=$(ubus call openmptcprouter getStatus 2>&1)
        if [ -n "$result" ] && [ "$result" != "" ]; then
            echo "$result"
            got_status=1
        fi
        echo ""
    fi

    # Method 3: service status
    if [ -x /etc/init.d/openmptcprouter ]; then
        echo "--- /etc/init.d/openmptcprouter status ---"
        /etc/init.d/openmptcprouter status 2>&1
        echo ""
    fi

    # Method 4: OMR-related log entries
    echo "--- OMR Log Entries (last 50) ---"
    logread 2>/dev/null | grep -iE "(openmptcprouter|omr|mptcp)" | tail -50

    # Method 5: OMR tracking state
    echo ""
    echo "--- OMR Tracking State ---"
    cat /tmp/openmptcprouter_* 2>/dev/null || echo "(no tracking files)"

    # Method 6: VPS connection info
    echo ""
    echo "--- VPS Configuration ---"
    uci show openmptcprouter.vps 2>/dev/null | redact_sensitive || echo "(not configured)"
} > "$DIAGDIR/15_omr_status.txt"

# ============================================================
# 16 - Interface Stats
# ============================================================
{
    echo "=== /proc/net/dev ==="
    cat /proc/net/dev
    echo ""
    echo "=== INTERFACE BYTE COUNTS ==="
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        rx=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
        tx=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
        echo "$iface: RX=$rx TX=$tx"
    done
} > "$DIAGDIR/16_interface_stats.txt"

# ============================================================
# 17 - ARP
# ============================================================
{
    echo "=== IP NEIGH ==="
    ip neigh
    echo ""
    echo "=== /proc/net/arp ==="
    cat /proc/net/arp 2>/dev/null
} > "$DIAGDIR/17_arp.txt"

# ============================================================
# 18 - System Identity (IMPROVED: apk fallback)
# ============================================================
{
    echo "=== SYSTEM IDENTITY ==="
    echo ""
    echo "--- ubus call system board ---"
    if has_cmd ubus; then
        ubus call system board 2>/dev/null || echo "(failed)"
    else
        echo "(ubus not available)"
    fi
    echo ""
    echo "--- /etc/openwrt_release ---"
    cat /etc/openwrt_release 2>/dev/null || echo "(not found)"
    echo ""
    echo "--- /etc/os-release ---"
    cat /etc/os-release 2>/dev/null || echo "(not found)"
    echo ""
    echo "--- Kernel Version ---"
    uname -r
    cat /proc/version 2>/dev/null
    echo ""

    echo "--- OpenMPTCProuter Version ---"
    OMR_VERSION=""
    # Method 1: /etc/openmptcprouter_version (note: underscore variant)
    if [ -f /etc/openmptcprouter_version ]; then
        OMR_VERSION=$(cat /etc/openmptcprouter_version)
        echo "From /etc/openmptcprouter_version: $OMR_VERSION"
    fi
    # Method 2: /etc/openmptcprouter-version (dash variant)
    if [ -z "$OMR_VERSION" ] && [ -f /etc/openmptcprouter-version ]; then
        OMR_VERSION=$(cat /etc/openmptcprouter-version)
        echo "From /etc/openmptcprouter-version: $OMR_VERSION"
    fi
    # Method 3: opkg list-installed
    if [ -z "$OMR_VERSION" ] && has_cmd opkg; then
        OMR_PKG=$(opkg list-installed 2>/dev/null | grep -i "^openmptcprouter " | head -1)
        if [ -n "$OMR_PKG" ]; then
            OMR_VERSION=$(echo "$OMR_PKG" | awk '{print $3}')
            echo "From opkg: $OMR_PKG"
        fi
    fi
    # Method 4: uci show
    if [ -z "$OMR_VERSION" ]; then
        OMR_UCI=$(uci get openmptcprouter.settings.version 2>/dev/null)
        if [ -n "$OMR_UCI" ]; then
            OMR_VERSION="$OMR_UCI"
            echo "From UCI: $OMR_VERSION"
        fi
    fi
    # Method 5: Check footer of LuCI
    if [ -z "$OMR_VERSION" ]; then
        echo "(version not found via standard methods)"
    fi
    echo ""

    echo "--- Installed OMR/VPN Packages ---"
    PKG_PATTERN="openmptcp|omr|glorytun|mlvpn|dsvpn|shadowsocks|xray|wireguard|openvpn"
    if has_cmd opkg; then
        echo "Using opkg:"
        opkg list-installed 2>/dev/null | grep -iE "($PKG_PATTERN)" | sort
    elif has_cmd apk; then
        echo "Using apk:"
        apk info -vv 2>/dev/null | grep -iE "($PKG_PATTERN)" | sort || \
        apk info 2>/dev/null | grep -iE "($PKG_PATTERN)" | sort
    else
        echo "(neither opkg nor apk available)"
        echo "Attempted: opkg list-installed, apk info -vv, apk info"
    fi
} > "$DIAGDIR/18_system_identity.txt"

# ============================================================
# 19 - Firewall Ruleset (with proper truncation markers)
# ============================================================
{
    echo "=== FIREWALL RULESET ==="
    if has_cmd nft; then
        echo "--- nft list ruleset ---"
        NFT_OUTPUT=$(nft list ruleset 2>&1)
        NFT_LINES=$(echo "$NFT_OUTPUT" | wc -l)
        echo "Total lines: $NFT_LINES"
        echo ""
        if [ "$NFT_LINES" -le 600 ]; then
            echo "$NFT_OUTPUT"
        else
            echo "$NFT_OUTPUT" | head -400
            echo ""
            echo "=== TRUNCATED: Showing 400 of $NFT_LINES lines (first part) ==="
            echo "=== ... $((NFT_LINES - 500)) lines omitted ... ==="
            echo "=== Showing last 100 lines: ==="
            echo ""
            echo "$NFT_OUTPUT" | tail -100
        fi
    elif has_cmd iptables-save; then
        echo "--- iptables-save ---"
        iptables-save 2>&1 | write_truncated 400
        echo ""
        echo "--- ip6tables-save ---"
        ip6tables-save 2>&1 | write_truncated 200
    elif has_cmd iptables; then
        echo "--- iptables -L -n -v ---"
        iptables -L -n -v 2>&1 | write_truncated 300
    else
        echo "(no firewall tools found)"
    fi
} > "$DIAGDIR/19_firewall_ruleset.txt"

# ============================================================
# 20 - Interface Status (clean, complete JSON per interface)
# ============================================================
{
    echo "=== INTERFACE STATUS ==="
    echo ""

    # Get list of all network interfaces from ubus
    if has_cmd ubus; then
        IFACE_LIST=$(ubus list 2>/dev/null | grep "^network.interface\." | sed 's/network.interface.//' | sort)

        if [ -z "$IFACE_LIST" ]; then
            # Fallback to known interfaces
            IFACE_LIST="lan wan wan1 wan2 wan3 wan4 omrvpn"
        fi

        for iface in $IFACE_LIST; do
            # Skip loopback
            [ "$iface" = "loopback" ] && continue

            echo "=========================================="
            echo "INTERFACE: $iface"
            echo "=========================================="

            # Get full status - complete JSON, no truncation
            STATUS=$(ubus call network.interface.$iface status 2>/dev/null)

            if [ -n "$STATUS" ] && [ "$STATUS" != "" ]; then
                # If jsonfilter is available, show clean summary
                if has_cmd jsonfilter; then
                    echo "up:        $(echo "$STATUS" | jsonfilter -e '@.up' 2>/dev/null || echo 'N/A')"
                    echo "pending:   $(echo "$STATUS" | jsonfilter -e '@.pending' 2>/dev/null || echo 'N/A')"
                    echo "available: $(echo "$STATUS" | jsonfilter -e '@.available' 2>/dev/null || echo 'N/A')"
                    echo "autostart: $(echo "$STATUS" | jsonfilter -e '@.autostart' 2>/dev/null || echo 'N/A')"
                    echo "device:    $(echo "$STATUS" | jsonfilter -e '@.device' 2>/dev/null || echo 'N/A')"
                    echo "l3_device: $(echo "$STATUS" | jsonfilter -e '@.l3_device' 2>/dev/null || echo 'N/A')"
                    echo "proto:     $(echo "$STATUS" | jsonfilter -e '@.proto' 2>/dev/null || echo 'N/A')"
                    echo "uptime:    $(echo "$STATUS" | jsonfilter -e '@.uptime' 2>/dev/null || echo 'N/A') seconds"

                    # IPv4 addresses
                    IPV4=$(echo "$STATUS" | jsonfilter -e '@["ipv4-address"][*].address' 2>/dev/null | tr '\n' ' ')
                    [ -n "$IPV4" ] && echo "ipv4:      $IPV4"

                    # IPv6 addresses
                    IPV6=$(echo "$STATUS" | jsonfilter -e '@["ipv6-address"][*].address' 2>/dev/null | tr '\n' ' ')
                    [ -n "$IPV6" ] && echo "ipv6:      $IPV6"

                    # Gateway
                    GW=$(echo "$STATUS" | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
                    [ -n "$GW" ] && echo "gateway:   $GW"

                    # DNS
                    DNS=$(echo "$STATUS" | jsonfilter -e '@["dns-server"][*]' 2>/dev/null | tr '\n' ' ')
                    [ -n "$DNS" ] && echo "dns:       $DNS"

                    echo ""
                    echo "--- Full JSON ---"
                fi

                # Always include the full JSON (for completeness)
                echo "$STATUS"
            else
                echo "(interface not found or no status)"
            fi
            echo ""
        done
    elif has_cmd ifstatus; then
        # Fallback to ifstatus command
        for iface in lan wan wan1 wan2 wan3 wan4 omrvpn; do
            result=$(ifstatus "$iface" 2>/dev/null)
            if [ -n "$result" ]; then
                echo "=========================================="
                echo "INTERFACE: $iface"
                echo "=========================================="
                echo "$result"
                echo ""
            fi
        done
    else
        echo "(ubus and ifstatus not available)"
    fi
} > "$DIAGDIR/20_ifstatus.txt"

# ============================================================
# 21 - Link State (NEW)
# ============================================================
{
    echo "=== LINK STATE ==="
    echo ""
    echo "--- ip -s link ---"
    ip -s link
    echo ""
    echo "--- ETHTOOL / LINK DETAILS ---"
    for dev in eth0 eth1 wan wan1 lan lan1 lan2 sfp1 sfp2; do
        if [ -e "/sys/class/net/$dev" ]; then
            echo "=== $dev ==="
            if has_cmd ethtool; then
                ethtool "$dev" 2>&1 | grep -E "(Speed|Duplex|Link|Auto)" | head -10
            elif has_cmd mii-tool; then
                mii-tool "$dev" 2>&1
            else
                # Fallback: sysfs
                echo "operstate: $(cat /sys/class/net/$dev/operstate 2>/dev/null)"
                echo "carrier: $(cat /sys/class/net/$dev/carrier 2>/dev/null)"
                echo "speed: $(cat /sys/class/net/$dev/speed 2>/dev/null)"
                echo "duplex: $(cat /sys/class/net/$dev/duplex 2>/dev/null)"
            fi
            echo ""
        fi
    done
} > "$DIAGDIR/21_link_state.txt"

# ============================================================
# 22 - MPTCP Details (NEW)
# ============================================================
{
    echo "=== MPTCP DETAILS ==="
    echo ""
    echo "--- ip mptcp endpoint show ---"
    ip mptcp endpoint show 2>/dev/null || echo "(not available)"
    echo ""
    echo "--- ip mptcp limits ---"
    ip mptcp limits 2>/dev/null || echo "(not available)"
    echo ""
    echo "--- MPTCP sysctl ---"
    sysctl -a 2>/dev/null | grep mptcp | head -30
    echo ""
    echo "--- /proc/net/mptcp* ---"
    for f in /proc/net/mptcp*; do
        if [ -f "$f" ]; then
            echo "=== $f ==="
            cat "$f" 2>/dev/null | head -50
            echo ""
        fi
    done
    echo ""
    echo "--- MPTCP Connections (ss -M) ---"
    if has_cmd ss; then
        ss -M 2>/dev/null | head -50 || echo "(ss -M failed)"
    else
        echo "(ss not available)"
    fi
    echo ""
    echo "--- mptcpd status ---"
    if [ -x /etc/init.d/mptcpd ]; then
        /etc/init.d/mptcpd status 2>&1
    fi
} > "$DIAGDIR/22_mptcp_details.txt"

# ============================================================
# 23 - VPN Status (NEW)
# ============================================================
{
    echo "=== VPN STATUS ==="
    echo ""
    echo "--- WireGuard ---"
    if has_cmd wg; then
        wg show all 2>/dev/null || echo "(no wg interfaces)"
        echo ""
        echo "wg interfaces:"
        wg show interfaces 2>/dev/null
    else
        echo "(wg command not found)"
    fi
    echo ""
    echo "--- OpenVPN ---"
    if pgrep openvpn >/dev/null 2>&1; then
        echo "OpenVPN processes:"
        pgrep -a openvpn 2>/dev/null
        echo ""
        echo "OpenVPN status files:"
        for f in /var/run/openvpn*.status /tmp/openvpn*.status; do
            if [ -f "$f" ]; then
                echo "=== $f ==="
                cat "$f" | head -30
            fi
        done
    else
        echo "(openvpn not running)"
    fi
    echo ""
    echo "--- Glorytun ---"
    if pgrep glorytun >/dev/null 2>&1; then
        echo "Glorytun processes:"
        pgrep -a glorytun 2>/dev/null
        if [ -x /etc/init.d/glorytun-udp ]; then
            echo ""
            /etc/init.d/glorytun-udp status 2>&1
        fi
        if [ -x /etc/init.d/glorytun-tcp ]; then
            /etc/init.d/glorytun-tcp status 2>&1
        fi
    else
        echo "(glorytun not running)"
    fi
    echo ""
    echo "--- MLVPN ---"
    if pgrep mlvpn >/dev/null 2>&1; then
        echo "MLVPN processes:"
        pgrep -a mlvpn 2>/dev/null
        if [ -x /etc/init.d/mlvpn ]; then
            /etc/init.d/mlvpn status 2>&1
        fi
    else
        echo "(mlvpn not running)"
    fi
    echo ""
    echo "--- Tunnel Interfaces ---"
    ip link show type tun 2>/dev/null || echo "(no tun interfaces)"
    echo ""
    ip addr show dev tun0 2>/dev/null || echo "(tun0 not found)"
} > "$DIAGDIR/23_vpn_status.txt"

# ============================================================
# 24 - Route Get (NEW)
# ============================================================
{
    echo "=== ROUTE GET DIAGNOSTICS ==="
    echo ""
    echo "--- ip -4 route get 1.1.1.1 ---"
    ip -4 route get 1.1.1.1 2>&1
    echo ""
    echo "--- ip -6 route get 2606:4700:4700::1111 ---"
    ip -6 route get 2606:4700:4700::1111 2>&1
    echo ""
    echo "--- ip rule show ---"
    ip rule show 2>&1
} > "$DIAGDIR/24_route_get.txt"

# ============================================================
# 99 - REDACTION SELF-TEST (security verification)
# ============================================================
{
    echo "=== REDACTION SELF-TEST ==="
    echo "Checking for leaked secrets in diagnostic files..."
    echo ""
    WARNINGS=0

    # Check for JWT tokens (eyJ prefix)
    JWT_LEAKS=$(grep -r "eyJ[A-Za-z0-9]" "$DIAGDIR" 2>/dev/null | grep -v "99_redaction" | grep -v "<JWT_REDACTED>" || true)
    if [ -n "$JWT_LEAKS" ]; then
        echo "!!! WARNING: Possible JWT token leak detected !!!"
        echo "$JWT_LEAKS"
        echo ""
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for unredacted 'option token'
    TOKEN_LEAKS=$(grep -ri "option token " "$DIAGDIR" 2>/dev/null | grep -v "99_redaction" | grep -v "REDACTED" || true)
    if [ -n "$TOKEN_LEAKS" ]; then
        echo "!!! WARNING: Unredacted 'option token' found !!!"
        echo "$TOKEN_LEAKS"
        echo ""
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for unredacted 'option password'
    PASS_LEAKS=$(grep -ri "option password " "$DIAGDIR" 2>/dev/null | grep -v "99_redaction" | grep -v "REDACTED" || true)
    if [ -n "$PASS_LEAKS" ]; then
        echo "!!! WARNING: Unredacted 'option password' found !!!"
        echo "$PASS_LEAKS"
        echo ""
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check for private keys
    KEY_LEAKS=$(grep -ri "private_key\|preshared_key" "$DIAGDIR" 2>/dev/null | grep -v "99_redaction" | grep -v "REDACTED" | grep -v "^#" || true)
    if [ -n "$KEY_LEAKS" ]; then
        echo "!!! WARNING: Possible private key leak detected !!!"
        echo "$KEY_LEAKS"
        echo ""
        WARNINGS=$((WARNINGS + 1))
    fi

    if [ $WARNINGS -eq 0 ]; then
        echo "OK: No obvious secret leaks detected."
        echo "Redaction appears to be working correctly."
    else
        echo "=============================================="
        echo "!!! $WARNINGS POTENTIAL SECRET LEAK(S) FOUND !!!"
        echo "Review the warnings above before sharing this bundle."
        echo "=============================================="
    fi

    echo ""
    echo "Files checked:"
    ls -la "$DIAGDIR"/*.txt 2>/dev/null | wc -l
    echo "diagnostic files generated."
} > "$DIAGDIR/99_redaction_warnings.txt"

# ============================================================
# Create tarball
# ============================================================
cd /tmp
tar -czf jammonitor-diag.tar.gz jamdiag/
rm -rf "$DIAGDIR"
echo "/tmp/jammonitor-diag.tar.gz"
]=]

    sys.exec(script)

    -- Send the file
    local fs = require "nixio.fs"
    local filename = "/tmp/jammonitor-diag.tar.gz"
    local stat = fs.stat(filename)

    if stat then
        http.header("Content-Disposition", 'attachment; filename="jammonitor-diag-' .. os.date("%Y%m%d-%H%M%S") .. '.tar.gz"')
        http.header("Content-Length", stat.size)
        http.prepare_content("application/octet-stream")

        local nixio = require "nixio"
        local f = nixio.open(filename, "r")
        if f then
            while true do
                local chunk = f:read(8192)
                if not chunk or #chunk == 0 then break end
                http.write(chunk)
            end
            f:close()
        end
        fs.remove(filename)
    else
        http.status(500, "Error")
        http.prepare_content("text/plain")
        http.write("Failed to generate diagnostic bundle")
    end
end

-- WAN Policy endpoint for drag-and-drop WAN priority management
function action_wan_policy()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    local method = http.getenv("REQUEST_METHOD")

    if method == "POST" then
        -- Apply WAN policy changes
        http.prepare_content("application/json")

        local content = http.content()
        if not content or content == "" then
            http.write(json.stringify({ success = false, error = "No data received" }))
            return
        end

        local data = json.parse(content)
        if not data then
            http.write(json.stringify({ success = false, error = "Invalid JSON" }))
            return
        end

        local order = data.order or {}
        local modes = data.modes or {}

        -- Validate inputs
        if #order == 0 then
            http.write(json.stringify({ success = false, error = "No interfaces in order" }))
            return
        end

        -- Apply UCI changes - modes now directly contain master/on/backup/off
        local changes_made = false
        local master_iface = nil
        local disabled_ifaces = {}
        local enabled_ifaces = {}

        for i, iface in ipairs(order) do
            local mode = modes[iface] or "off"

            -- Track which interface is master for response
            if mode == "master" then
                master_iface = iface
            end

            -- Update the network interface multipath setting
            local current_multipath = uci:get("network", iface, "multipath")
            if current_multipath ~= mode then
                uci:set("network", iface, "multipath", mode)
                changes_made = true
            end

            -- Handle interface disabled state
            local current_disabled = uci:get("network", iface, "disabled")
            if mode == "off" then
                -- Disable the interface completely
                if current_disabled ~= "1" then
                    uci:set("network", iface, "disabled", "1")
                    changes_made = true
                    table.insert(disabled_ifaces, iface)
                end
            else
                -- Enable the interface
                if current_disabled == "1" then
                    uci:delete("network", iface, "disabled")
                    changes_made = true
                    table.insert(enabled_ifaces, iface)
                end
            end
        end

        if changes_made then
            uci:commit("network")

            -- Bring down disabled interfaces
            for _, iface in ipairs(disabled_ifaces) do
                sys.exec("ifdown " .. iface .. " >/dev/null 2>&1 &")
            end

            -- Bring up enabled interfaces
            for _, iface in ipairs(enabled_ifaces) do
                sys.exec("ifup " .. iface .. " >/dev/null 2>&1 &")
            end

            -- Reload network to apply all changes
            sys.exec("/etc/init.d/network reload >/dev/null 2>&1 &")
        end

        http.write(json.stringify({
            success = true,
            master = master_iface,
            changes_made = changes_made
        }))
    else
        -- GET: Return current WAN interface list with multipath settings
        http.prepare_content("application/json")

        local result = { interfaces = {} }
        local fs = require "nixio.fs"

        -- Load enabled WANs from config file (or fall back to pattern matching)
        local config_file = "/etc/jammonitor_wans"
        local enabled_content = fs.readfile(config_file) or ""
        local enabled_map = {}
        local has_config = false
        for line in enabled_content:gmatch("[^\r\n]+") do
            local iface = line:match("^%s*(.-)%s*$")
            if iface and iface ~= "" then
                enabled_map[iface] = true
                has_config = true
            end
        end

        -- Get all network interfaces that are WANs
        uci:foreach("network", "interface", function(s)
            local iface_name = s[".name"]

            -- Check if in enabled list (from config file)
            local is_enabled = enabled_map[iface_name]

            -- Fallback: pattern match if no config file exists
            if not has_config then
                is_enabled = iface_name:match("^wan[0-9]") or iface_name:match("^wwan") or iface_name:match("^4g") or iface_name:match("^lte") or iface_name:match("^mobile")
            end

            -- Active multipath means it's participating in bonding (always show)
            local is_active_multipath = s.multipath and (s.multipath == "master" or s.multipath == "on" or s.multipath == "backup")

            -- Check if user explicitly selected this interface (overrides exclusions)
            local user_selected = enabled_map[iface_name]

            -- ALWAYS exclude LAN/system interfaces from WAN policy (no override)
            -- This prevents accidental lockouts
            local is_lan_system = iface_name == "loopback" or iface_name == "lan" or iface_name == "guest" or
                                  iface_name:match("^br%-") or iface_name:match("^lan") or iface_name:match("^guest")
            if is_lan_system then
                return  -- Skip this interface entirely
            end

            -- Only apply soft exclusions if NOT explicitly selected by user
            local is_excluded = false
            if not user_selected then
                is_excluded = iface_name == "omrvpn"
            end

            -- When config exists, respect it fully (ignore multipath status)
            -- When no config, use pattern match + active multipath as fallback
            local should_show = false
            if has_config then
                should_show = is_enabled  -- Config has final say
            else
                should_show = is_enabled or is_active_multipath  -- Fallback
            end

            if not is_excluded and should_show then
                local multipath = s.multipath or "off"
                local proto = s.proto or "dhcp"
                local device = s.device or s.ifname or ""
                local disabled = s.disabled == "1"

                -- Get interface status for IP and state
                local status_json = sys.exec("ifstatus " .. iface_name .. " 2>/dev/null")
                local ip = nil
                local subnet = nil
                local gateway = nil
                local dns = {}
                local is_up = false

                if status_json and status_json ~= "" then
                    local status = json.parse(status_json)
                    if status then
                        is_up = status.up or false
                        if status["ipv4-address"] and status["ipv4-address"][1] then
                            ip = status["ipv4-address"][1].address
                            local mask = status["ipv4-address"][1].mask
                            if mask then
                                subnet = tostring(mask)
                            end
                        end
                        -- Get gateway from route
                        if status.route and status.route[1] then
                            gateway = status.route[1].nexthop
                        end
                        -- Get DNS servers
                        if status["dns-server"] then
                            for _, d in ipairs(status["dns-server"]) do
                                table.insert(dns, d)
                            end
                        end
                    end
                end

                -- Get MTU from device
                local mtu = nil
                if device and device ~= "" then
                    local mtu_str = sys.exec("cat /sys/class/net/" .. device .. "/mtu 2>/dev/null")
                    if mtu_str and mtu_str ~= "" then
                        mtu = mtu_str:gsub("%s+", "")
                    end
                end

                -- If interface is disabled in UCI, it's not up
                if disabled then
                    is_up = false
                end

                -- Get peerdns setting
                local peerdns = s.peerdns
                local peerdns_bool = (peerdns ~= "0") -- default is true (auto)

                table.insert(result.interfaces, {
                    name = iface_name,
                    multipath = multipath,
                    proto = proto,
                    device = device,
                    ip = ip,
                    subnet = subnet,
                    gateway = gateway,
                    dns = dns,
                    mtu = mtu,
                    up = is_up,
                    disabled = disabled,
                    peerdns = peerdns_bool
                })
            end
        end)

        -- Sort by name (lan1, lan2, lan3, etc.)
        table.sort(result.interfaces, function(a, b)
            return a.name < b.name
        end)

        http.write(json.stringify(result))
    end
end

-- WAN Edit endpoint for editing individual WAN interface settings
function action_wan_edit()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local method = http.getenv("REQUEST_METHOD")
    if method ~= "POST" then
        http.write(json.stringify({ success = false, error = "POST method required" }))
        return
    end

    local content = http.content()
    if not content or content == "" then
        http.write(json.stringify({ success = false, error = "No data received" }))
        return
    end

    local data = json.parse(content)
    if not data then
        http.write(json.stringify({ success = false, error = "Invalid JSON" }))
        return
    end

    -- Validate interface name
    local iface = data.iface
    local fs = require "nixio.fs"

    -- Check if in enabled list from config file
    local config_file = "/etc/jammonitor_wans"
    local enabled_content = fs.readfile(config_file) or ""
    local is_in_config = false
    for line in enabled_content:gmatch("[^\r\n]+") do
        local cfg_iface = line:match("^%s*(.-)%s*$")
        if cfg_iface == iface then
            is_in_config = true
            break
        end
    end

    -- Valid if in config OR matches WAN pattern
    local is_valid = iface and (is_in_config or iface:match("^wan[0-9]") or iface:match("^wwan") or iface:match("^4g") or iface:match("^lte") or iface:match("^mobile"))
    if not is_valid then
        http.write(json.stringify({ success = false, error = "Invalid interface name" }))
        return
    end

    -- Check if interface exists in UCI
    local existing = uci:get("network", iface)
    if not existing then
        http.write(json.stringify({ success = false, error = "Interface not found" }))
        return
    end

    -- Apply settings
    local changes_made = false
    local need_ifup = false
    local need_ifdown = false

    -- Priority / Multipath mode
    if data.multipath then
        local valid_modes = { master = true, on = true, backup = true, off = true }
        if valid_modes[data.multipath] then
            local current = uci:get("network", iface, "multipath")
            if current ~= data.multipath then
                uci:set("network", iface, "multipath", data.multipath)
                changes_made = true
            end

            -- Handle disabled state based on mode
            local current_disabled = uci:get("network", iface, "disabled")
            if data.multipath == "off" then
                if current_disabled ~= "1" then
                    uci:set("network", iface, "disabled", "1")
                    changes_made = true
                    need_ifdown = true
                end
            else
                if current_disabled == "1" then
                    uci:delete("network", iface, "disabled")
                    changes_made = true
                    need_ifup = true
                end
            end
        end
    end

    -- Protocol (dhcp or static)
    if data.proto then
        local valid_protos = { dhcp = true, static = true }
        if valid_protos[data.proto] then
            local current = uci:get("network", iface, "proto")
            if current ~= data.proto then
                uci:set("network", iface, "proto", data.proto)
                changes_made = true
                need_ifup = true

                -- Clear static IP settings if switching to DHCP
                if data.proto == "dhcp" then
                    uci:delete("network", iface, "ipaddr")
                    uci:delete("network", iface, "netmask")
                    uci:delete("network", iface, "gateway")
                end
            end
        end
    end

    -- Static IP settings (only if proto is static)
    if data.proto == "static" then
        if data.ipaddr and data.ipaddr:match("^%d+%.%d+%.%d+%.%d+$") then
            local current = uci:get("network", iface, "ipaddr")
            if current ~= data.ipaddr then
                uci:set("network", iface, "ipaddr", data.ipaddr)
                changes_made = true
                need_ifup = true
            end
        end

        if data.netmask and data.netmask:match("^%d+%.%d+%.%d+%.%d+$") then
            local current = uci:get("network", iface, "netmask")
            if current ~= data.netmask then
                uci:set("network", iface, "netmask", data.netmask)
                changes_made = true
                need_ifup = true
            end
        end

        if data.gateway and data.gateway:match("^%d+%.%d+%.%d+%.%d+$") then
            local current = uci:get("network", iface, "gateway")
            if current ~= data.gateway then
                uci:set("network", iface, "gateway", data.gateway)
                changes_made = true
                need_ifup = true
            end
        end
    end

    -- DNS settings
    if data.peerdns ~= nil then
        local current = uci:get("network", iface, "peerdns")
        local new_val = data.peerdns and "1" or "0"
        if current ~= new_val then
            uci:set("network", iface, "peerdns", new_val)
            changes_made = true
        end
    end

    if data.dns and type(data.dns) == "table" then
        -- Delete existing DNS entries
        uci:delete("network", iface, "dns")
        -- Add new DNS entries as list
        if #data.dns > 0 then
            local valid_dns = {}
            for _, d in ipairs(data.dns) do
                if d:match("^%d+%.%d+%.%d+%.%d+$") then
                    table.insert(valid_dns, d)
                end
            end
            if #valid_dns > 0 then
                uci:set_list("network", iface, "dns", valid_dns)
                changes_made = true
            end
        end
    end

    -- MTU
    if data.mtu then
        local mtu_num = tonumber(data.mtu)
        if mtu_num and mtu_num >= 576 and mtu_num <= 9000 then
            local current = uci:get("network", iface, "mtu")
            if current ~= tostring(mtu_num) then
                uci:set("network", iface, "mtu", tostring(mtu_num))
                changes_made = true
                need_ifup = true
            end
        end
    elseif data.mtu == nil or data.mtu == "" then
        -- Clear MTU if empty (use default)
        local current = uci:get("network", iface, "mtu")
        if current then
            uci:delete("network", iface, "mtu")
            changes_made = true
        end
    end

    if changes_made then
        uci:commit("network")

        -- Apply interface changes
        if need_ifdown then
            sys.exec("ifdown " .. iface .. " >/dev/null 2>&1 &")
        elseif need_ifup then
            sys.exec("ifdown " .. iface .. " >/dev/null 2>&1; sleep 1; ifup " .. iface .. " >/dev/null 2>&1 &")
        end

        -- Reload network config
        sys.exec("/etc/init.d/network reload >/dev/null 2>&1 &")
    end

    http.write(json.stringify({
        success = true,
        iface = iface,
        changes_made = changes_made
    }))
end

-- Advanced settings endpoint for failover and MPTCP tuning
function action_wan_advanced()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local method = http.getenv("REQUEST_METHOD")

    if method == "POST" then
        -- Parse JSON body
        local raw = http.content()
        local data = json.parse(raw)
        if not data then
            http.write(json.stringify({ success = false, error = "Invalid JSON" }))
            return
        end

        local changes_made = false

        -- Update failover settings (omr-tracker.defaults)
        if data.failover then
            local f = data.failover
            if f.timeout then
                uci:set("omr-tracker", "defaults", "timeout", tostring(f.timeout))
                changes_made = true
            end
            if f.count then
                uci:set("omr-tracker", "defaults", "count", tostring(f.count))
                changes_made = true
            end
            if f.tries then
                uci:set("omr-tracker", "defaults", "tries", tostring(f.tries))
                changes_made = true
            end
            if f.interval then
                uci:set("omr-tracker", "defaults", "interval", tostring(f.interval))
                changes_made = true
            end
            if f.failure_interval then
                uci:set("omr-tracker", "defaults", "failure_interval", tostring(f.failure_interval))
                changes_made = true
            end
            if f.tries_up then
                uci:set("omr-tracker", "defaults", "tries_up", tostring(f.tries_up))
                changes_made = true
            end
        end

        -- Update MPTCP settings (network.globals)
        if data.mptcp then
            local m = data.mptcp
            if m.scheduler then
                uci:set("network", "globals", "mptcp_scheduler", m.scheduler)
                changes_made = true
            end
            if m.path_manager then
                uci:set("network", "globals", "mptcp_path_manager", m.path_manager)
                changes_made = true
            end
            if m.congestion then
                uci:set("network", "globals", "congestion", m.congestion)
                changes_made = true
            end
            if m.subflows then
                uci:set("network", "globals", "mptcp_subflows", tostring(m.subflows))
                changes_made = true
            end
            if m.stale_loss_cnt then
                -- stale_loss_cnt is a sysctl, set it directly
                sys.exec("sysctl -w net.mptcp.stale_loss_cnt=" .. tostring(m.stale_loss_cnt) .. " >/dev/null 2>&1")
                -- Also persist to sysctl.conf if possible
                sys.exec("sed -i '/net.mptcp.stale_loss_cnt/d' /etc/sysctl.conf 2>/dev/null; echo 'net.mptcp.stale_loss_cnt=" .. tostring(m.stale_loss_cnt) .. "' >> /etc/sysctl.conf 2>/dev/null")
            end
        end

        if changes_made then
            uci:commit("omr-tracker")
            uci:commit("network")
            -- Restart omr-tracker to apply failover changes
            sys.exec("/etc/init.d/omr-tracker restart >/dev/null 2>&1 &")
        end

        http.write(json.stringify({ success = true }))
    else
        -- GET: Read current settings
        local result = {
            failover = {},
            mptcp = {}
        }

        -- Read failover settings from omr-tracker.defaults
        result.failover.timeout = tonumber(uci:get("omr-tracker", "defaults", "timeout")) or 1
        result.failover.count = tonumber(uci:get("omr-tracker", "defaults", "count")) or 1
        result.failover.tries = tonumber(uci:get("omr-tracker", "defaults", "tries")) or 2
        result.failover.interval = tonumber(uci:get("omr-tracker", "defaults", "interval")) or 1
        result.failover.failure_interval = tonumber(uci:get("omr-tracker", "defaults", "failure_interval")) or 2
        result.failover.tries_up = tonumber(uci:get("omr-tracker", "defaults", "tries_up")) or 2

        -- Read MPTCP settings from network.globals
        result.mptcp.scheduler = uci:get("network", "globals", "mptcp_scheduler") or "default"
        result.mptcp.path_manager = uci:get("network", "globals", "mptcp_path_manager") or "fullmesh"
        result.mptcp.congestion = uci:get("network", "globals", "congestion") or "bbr"
        result.mptcp.subflows = tonumber(uci:get("network", "globals", "mptcp_subflows")) or 8

        -- Read stale_loss_cnt from sysctl
        local stale = sys.exec("sysctl -n net.mptcp.stale_loss_cnt 2>/dev/null")
        result.mptcp.stale_loss_cnt = tonumber(stale) or 4

        http.write(json.stringify(result))
    end
end

-- WAN Interface selector - manage which interfaces appear in WAN Policy
function action_wan_ifaces()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local config_file = "/etc/jammonitor_wans"
    local method = http.getenv("REQUEST_METHOD")

    if method == "POST" then
        -- Save selected interfaces
        local raw = http.content()
        local data = json.parse(raw)
        if not data or not data.enabled then
            http.write(json.stringify({ success = false, error = "Invalid JSON" }))
            return
        end

        -- Write to config file (one interface per line)
        local content = table.concat(data.enabled, "\n")
        fs.writefile(config_file, content)

        http.write(json.stringify({ success = true }))
    else
        -- GET: Return all interfaces and which are enabled
        local result = { all = {}, enabled = {} }

        -- Read enabled list from config file
        local enabled_content = fs.readfile(config_file) or ""
        local enabled_map = {}
        for line in enabled_content:gmatch("[^\r\n]+") do
            local iface = line:match("^%s*(.-)%s*$")
            if iface and iface ~= "" then
                table.insert(result.enabled, iface)
                enabled_map[iface] = true
            end
        end

        -- Get all network interfaces from UCI (exclude system/LAN interfaces permanently)
        uci:foreach("network", "interface", function(s)
            local name = s[".name"]
            -- PERMANENTLY exclude LAN/system interfaces from WAN selector to prevent lockouts
            local is_system_iface = name == "loopback" or name == "lan" or name == "guest" or
                                    name:match("^br%-") or name:match("^lan") or name:match("^guest")
            if not is_system_iface then
                local device = s.device or s.ifname or ""
                local multipath = s.multipath or "off"

                -- Get interface status
                local status_json = sys.exec("ifstatus " .. name .. " 2>/dev/null")
                local is_up = false
                local ip = nil
                if status_json and status_json ~= "" then
                    local status = json.parse(status_json)
                    if status then
                        is_up = status.up or false
                        if status["ipv4-address"] and status["ipv4-address"][1] then
                            ip = status["ipv4-address"][1].address
                        end
                    end
                end

                table.insert(result.all, {
                    name = name,
                    device = device,
                    proto = s.proto or "dhcp",
                    multipath = multipath,
                    is_up = is_up,
                    ip = ip
                })
                -- Auto-enable if matches WAN pattern and not in config yet
                if #result.enabled == 0 then
                    -- First run - auto-detect WANs
                    local is_wan = name:match("^wan[0-9]") or name:match("^wwan") or name:match("^4g") or name:match("^lte") or name:match("^mobile")
                    if is_wan then
                        table.insert(result.enabled, name)
                    end
                end
            end
        end)

        -- Sort by name
        table.sort(result.all, function(a, b) return a.name < b.name end)

        http.write(json.stringify(result))
    end
end
