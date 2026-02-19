module("luci.controller.jammonitor", package.seeall)

function index()
    entry({"admin", "status", "jammonitor"}, template("jammonitor"), _("Jam Monitor"), 99)
    -- Secure API endpoints (replacing generic /exec)
    entry({"admin", "status", "jammonitor", "system_stats"}, call("action_system_stats"), nil)
    entry({"admin", "status", "jammonitor", "network_info"}, call("action_network_info"), nil)
    entry({"admin", "status", "jammonitor", "mptcp_status"}, call("action_mptcp_status"), nil)
    entry({"admin", "status", "jammonitor", "vpn_status"}, call("action_vpn_status"), nil)
    entry({"admin", "status", "jammonitor", "ping"}, call("action_ping"), nil)
    entry({"admin", "status", "jammonitor", "ping_history"}, call("action_ping_history"), nil)
    entry({"admin", "status", "jammonitor", "clients"}, call("action_clients"), nil)
    entry({"admin", "status", "jammonitor", "public_ip"}, call("action_public_ip"), nil)
    entry({"admin", "status", "jammonitor", "vnstat"}, call("action_vnstat"), nil)
    -- Existing endpoints
    entry({"admin", "status", "jammonitor", "diag"}, call("action_diag"), nil)
    entry({"admin", "status", "jammonitor", "wifi_status"}, call("action_wifi_status"), nil)
    entry({"admin", "status", "jammonitor", "wan_policy"}, call("action_wan_policy"), nil)
    entry({"admin", "status", "jammonitor", "wan_edit"}, call("action_wan_edit"), nil)
    entry({"admin", "status", "jammonitor", "wan_advanced"}, call("action_wan_advanced"), nil)
    entry({"admin", "status", "jammonitor", "wan_ifaces"}, call("action_wan_ifaces"), nil)
    entry({"admin", "status", "jammonitor", "history"}, call("action_history"), nil)
    entry({"admin", "status", "jammonitor", "history_clients"}, call("action_history_clients"), nil)
    entry({"admin", "status", "jammonitor", "traffic_summary"}, call("action_traffic_summary"), nil)
    entry({"admin", "status", "jammonitor", "bypass"}, call("action_bypass"), nil)
    entry({"admin", "status", "jammonitor", "storage_status"}, call("action_storage_status"), nil)
    -- USB Storage setup endpoints
    entry({"admin", "status", "jammonitor", "storage_devices"}, call("action_storage_devices"), nil)
    entry({"admin", "status", "jammonitor", "storage_format"}, call("action_storage_format"), nil)
    entry({"admin", "status", "jammonitor", "storage_mount"}, call("action_storage_mount"), nil)
    entry({"admin", "status", "jammonitor", "storage_init"}, call("action_storage_init"), nil)
    -- Client metadata and DHCP reservations
    entry({"admin", "status", "jammonitor", "get_client_meta"}, call("action_get_client_meta"), nil)
    entry({"admin", "status", "jammonitor", "set_client_meta"}, call("action_set_client_meta"), nil)
    entry({"admin", "status", "jammonitor", "get_reservations"}, call("action_get_reservations"), nil)
    entry({"admin", "status", "jammonitor", "set_reservation"}, call("action_set_reservation"), nil)
    entry({"admin", "status", "jammonitor", "delete_reservation"}, call("action_delete_reservation"), nil)
    -- Speed test endpoints
    entry({"admin", "status", "jammonitor", "speedtest_start"}, call("action_speedtest_start"), nil)
    entry({"admin", "status", "jammonitor", "speedtest_status"}, call("action_speedtest_status"), nil)
    -- Version check endpoint
    entry({"admin", "status", "jammonitor", "version_check"}, call("action_version_check"), nil)
    -- Auto-update endpoints
    entry({"admin", "status", "jammonitor", "update_start"}, call("action_update_start"), nil)
    entry({"admin", "status", "jammonitor", "update_status"}, call("action_update_status"), nil)
end

-- Helper: Validate interface name (alphanumeric, dash, underscore only)
local function validate_iface(name)
    if not name or name == "" then return nil end
    if not name:match("^[a-zA-Z0-9_%-]+$") then return nil end
    if #name > 32 then return nil end
    return name
end

-- Helper: Validate IP address
local function validate_ip(ip)
    if not ip or ip == "" then return nil end
    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then return nil end
    for octet in ip:gmatch("%d+") do
        local n = tonumber(octet)
        if not n or n < 0 or n > 255 then return nil end
    end
    return ip
end

-- Helper: Validate filesystem label (ext4 max 16 chars, safe chars only)
local function validate_label(label)
    if not label or label == "" then return nil end
    if not label:match("^[a-zA-Z0-9_%-]+$") then return nil end
    if #label > 16 then return nil end
    return label
end

-- Helper: Atomic file write (write to temp, then rename)
local function atomic_write(path, content)
    local fs = require "nixio.fs"
    local tmp = path .. ".tmp"
    local ok = fs.writefile(tmp, content)
    if ok then
        os.rename(tmp, path)
        return true
    end
    return false
end

-- System stats: load, cpu, temp, ram, uptime, conntrack
function action_system_stats()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {}

    -- Load average
    local loadavg = fs.readfile("/proc/loadavg") or ""
    local l1, l2, l3 = loadavg:match("^([%d%.]+)%s+([%d%.]+)%s+([%d%.]+)")
    result.load = { l1 or "0", l2 or "0", l3 or "0" }

    -- CPU usage (snapshot - for proper calc, JS should compare two readings)
    local stat = fs.readfile("/proc/stat") or ""
    local cpu_line = stat:match("^cpu%s+(.-)[\r\n]")
    if cpu_line then
        local values = {}
        for v in cpu_line:gmatch("%d+") do
            table.insert(values, tonumber(v))
        end
        if #values >= 4 then
            result.cpu_busy = values[1] + values[2] + values[3]
            result.cpu_idle = values[4]
        end
    end

    -- Temperature
    local temp = fs.readfile("/sys/class/thermal/thermal_zone0/temp")
    if temp then
        local t = tonumber(temp:match("%d+"))
        if t then
            if t > 1000 then t = t / 1000 end
            result.temp = t
        end
    end

    -- Memory
    local meminfo = fs.readfile("/proc/meminfo") or ""
    local mem_total = tonumber(meminfo:match("MemTotal:%s*(%d+)")) or 1
    local mem_free = tonumber(meminfo:match("MemFree:%s*(%d+)")) or 0
    local mem_buffers = tonumber(meminfo:match("Buffers:%s*(%d+)")) or 0
    local mem_cached = tonumber(meminfo:match("Cached:%s*(%d+)")) or 0
    local mem_used = mem_total - mem_free - mem_buffers - mem_cached
    result.ram_pct = string.format("%.1f", (mem_used / mem_total) * 100)
    result.ram_total = mem_total
    result.ram_used = mem_used

    -- Uptime
    local uptime = fs.readfile("/proc/uptime") or ""
    local up_secs = tonumber(uptime:match("^([%d%.]+)"))
    result.uptime_secs = up_secs or 0

    -- Date
    result.date = os.date("%Y-%m-%d %H:%M:%S")

    -- Conntrack
    local ct_count = fs.readfile("/proc/sys/net/netfilter/nf_conntrack_count")
    local ct_max = fs.readfile("/proc/sys/net/netfilter/nf_conntrack_max")
    result.conntrack_count = tonumber((ct_count or ""):match("%d+")) or 0
    result.conntrack_max = tonumber((ct_max or ""):match("%d+")) or 0

    http.write(json.stringify(result))
end

-- Network info: interfaces, routes, proc/net/dev
function action_network_info()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {}

    -- ip -br link
    result.link = sys.exec("ip -br link 2>/dev/null") or ""

    -- ip -br addr
    result.addr = sys.exec("ip -br addr 2>/dev/null") or ""

    -- ip route
    result.route = sys.exec("ip route 2>/dev/null") or ""

    -- /proc/net/dev
    result.netdev = fs.readfile("/proc/net/dev") or ""

    -- Wireless info
    local phy_list = sys.exec("ls /sys/class/ieee80211/ 2>/dev/null") or ""
    result.phy_devices = phy_list:gsub("%s+$", "")

    -- Wireless config (UCI)
    result.wireless_config = sys.exec("uci show wireless 2>/dev/null | grep -E '=wifi-device|\\.disabled='") or ""

    -- Interface list (for dropdown population)
    local iface_list = sys.exec("ip -br link 2>/dev/null | awk '{print $1}' | grep -vE '^lo$|^docker|^veth'") or ""
    local ifaces = {}
    for line in iface_list:gmatch("[^\n]+") do
        local name = line:match("^([^@]+)")
        if name and name ~= "" then
            table.insert(ifaces, name)
        end
    end
    result.interfaces = ifaces

    http.write(json.stringify(result))
end

-- MPTCP status
function action_mptcp_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    local result = {}

    -- MPTCP endpoints
    result.endpoints = sys.exec("ip mptcp endpoint show 2>/dev/null") or ""

    -- MPTCP limits
    result.limits = sys.exec("ip mptcp limits 2>/dev/null") or ""

    -- MPTCP connections (count)
    local ss_out = sys.exec("ss -M 2>/dev/null | grep -c ESTAB") or "0"
    result.connections = tonumber(ss_out:match("%d+")) or 0

    -- Interfaces in use
    local ifaces_out = sys.exec("ip mptcp endpoint show 2>/dev/null | grep -oE 'dev [a-z0-9]+' | cut -d' ' -f2 | sort -u | tr '\\n' ' '") or ""
    result.interfaces = ifaces_out:gsub("%s+$", "")

    -- Endpoint count
    local ep_count = sys.exec("ip mptcp endpoint show 2>/dev/null | wc -l") or "0"
    result.endpoint_count = tonumber(ep_count:match("%d+")) or 0

    http.write(json.stringify(result))
end

-- VPN/Tunnel status
function action_vpn_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local result = {
        tunnel = {},
        wireguard = {},
        vps = {}
    }

    -- Check tun0
    local tun0_addr = sys.exec("ip addr show dev tun0 2>/dev/null") or ""
    result.tunnel.exists = tun0_addr ~= ""
    if result.tunnel.exists then
        local ip_match = tun0_addr:match("inet%s+([%d%.]+)")
        result.tunnel.ip = ip_match
        local peer_match = tun0_addr:match("peer%s+([%d%.]+)")
        result.tunnel.peer = peer_match
    end

    -- tun0 route (for tunnel gateway)
    local tun0_route = sys.exec("ip route show dev tun0 2>/dev/null | grep -oE 'via [0-9.]+' | head -1 | cut -d' ' -f2") or ""
    result.tunnel.gateway = tun0_route:gsub("%s+$", "")

    -- omrvpn status
    local omrvpn_status = sys.exec("ifstatus omrvpn 2>/dev/null")
    if omrvpn_status and omrvpn_status ~= "" then
        local status = json.parse(omrvpn_status)
        if status then
            result.tunnel.omrvpn_up = status.up
            result.tunnel.omrvpn_uptime = status.uptime
        end
    end

    -- WireGuard
    local wg_show = sys.exec("wg show 2>/dev/null") or ""
    result.wireguard.active = wg_show ~= ""
    if result.wireguard.active then
        local wg_iface = wg_show:match("interface:%s*(%S+)")
        result.wireguard.interface = wg_iface
        local endpoints = sys.exec("wg show all endpoints 2>/dev/null") or ""
        local ep_match = endpoints:match("(%d+%.%d+%.%d+%.%d+):")
        result.wireguard.endpoint = ep_match

        if wg_iface then
            local wg_addr = sys.exec("ip addr show dev " .. validate_iface(wg_iface) .. " 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2") or ""
            result.wireguard.ip = wg_addr:gsub("%s+$", "")
        end
    end

    -- VPS IP from UCI
    local vps_ip = uci:get("openmptcprouter", "vps", "ip")
    if not vps_ip then
        vps_ip = uci:get("glorytun", "vpn", "host")
    end
    result.vps.ip = vps_ip

    http.write(json.stringify(result))
end

-- Ping endpoint (validated host)
function action_ping()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    local host = http.formvalue("host")
    local validated_host = validate_ip(host)

    if not validated_host then
        http.write(json.stringify({ error = "Invalid IP address" }))
        return
    end

    -- Run ping with strict timeout
    local result = sys.exec("ping -c1 -W1 " .. validated_host .. " 2>/dev/null | grep -oE 'time=[0-9.]+' | cut -d= -f2")
    local latency = tonumber(result:match("[%d%.]+"))

    http.write(json.stringify({
        host = validated_host,
        latency = latency,
        success = latency ~= nil
    }))
end

-- Historical ping data from metrics table (for graph on page load)
function action_ping_history()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local db_path = "/mnt/data/jammonitor/history.db"
    local minutes = tonumber(http.formvalue("minutes")) or 10

    -- Limit to reasonable range
    if minutes < 1 then minutes = 1 end
    if minutes > 60 then minutes = 60 end

    local cutoff = os.time() - (minutes * 60)
    local result = { ok = true, pings = {} }

    if fs.stat(db_path) then
        local query = string.format(
            "SELECT ts, wan_pings FROM metrics WHERE ts > %d ORDER BY ts",
            cutoff
        )
        local output = sys.exec("sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
        if output and output ~= "" then
            for line in output:gmatch("[^\n]+") do
                local ts, pings_json = line:match("([^|]+)|(.+)")
                if ts and pings_json then
                    table.insert(result.pings, {
                        ts = tonumber(ts) * 1000,  -- Convert to JS milliseconds
                        data = pings_json
                    })
                end
            end
        end
    end

    http.write(json.stringify(result))
end

-- Clients: DHCP leases, ARP, conntrack
function action_clients()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {}

    -- DHCP leases
    result.dhcp_leases = fs.readfile("/tmp/dhcp.leases") or ""

    -- ARP table
    result.arp = fs.readfile("/proc/net/arp") or ""

    -- Conntrack (limited to first 500 entries for performance)
    result.conntrack = sys.exec("conntrack -L 2>/dev/null | head -500") or ""

    -- Tailscale peers (if tailscale is installed)
    local ts_status = sys.exec("tailscale status --json 2>/dev/null") or ""
    if ts_status ~= "" then
        result.tailscale = ts_status
    end

    http.write(json.stringify(result))
end

-- Client metadata: custom aliases and device types
local CLIENT_META_FILE = "/etc/jammonitor_clients.json"

function action_get_client_meta()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local content = fs.readfile(CLIENT_META_FILE)
    if content and content ~= "" then
        http.write(content)
    else
        http.write("{}")
    end
end

function action_set_client_meta()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local mac = http.formvalue("mac")
    local alias = http.formvalue("alias")
    local dtype = http.formvalue("type")

    if not mac or mac == "" then
        http.write(json.stringify({error = "MAC address required"}))
        return
    end

    -- Normalize MAC to lowercase and validate format
    mac = mac:lower()
    if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        http.write(json.stringify({error = "Invalid MAC address format"}))
        return
    end

    -- Cap alias length
    if alias and #alias > 64 then alias = alias:sub(1, 64) end

    -- Read existing metadata
    local content = fs.readfile(CLIENT_META_FILE) or "{}"
    local meta = json.parse(content) or {}

    -- Update entry
    if not meta[mac] then meta[mac] = {} end
    if alias and alias ~= "" then meta[mac].alias = alias end
    if dtype and dtype ~= "" then meta[mac].type = dtype end

    -- Write back atomically
    if atomic_write(CLIENT_META_FILE, json.stringify(meta)) then
        http.write(json.stringify({success = true}))
    else
        http.write(json.stringify({error = "Failed to write metadata"}))
    end
end

-- DHCP Reservations
function action_get_reservations()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local result = {}
    uci:foreach("dhcp", "host", function(s)
        if s.mac then
            result[s.mac:lower()] = {
                name = s.name or "",
                ip = s.ip or "",
                mac = s.mac
            }
        end
    end)

    http.write(json.stringify(result))
end

function action_set_reservation()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"

    http.prepare_content("application/json")

    local mac = http.formvalue("mac")
    local ip = http.formvalue("ip")
    local name = http.formvalue("name")

    if not mac or mac == "" or not ip or ip == "" then
        http.write(json.stringify({error = "MAC and IP required"}))
        return
    end

    -- Validate MAC format
    if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        http.write(json.stringify({error = "Invalid MAC address format"}))
        return
    end

    -- Validate IP
    if not validate_ip(ip) then
        http.write(json.stringify({error = "Invalid IP address"}))
        return
    end

    -- Create section name from MAC
    local section_name = "jm_" .. mac:gsub(":", ""):lower()

    uci:set("dhcp", section_name, "host")
    uci:set("dhcp", section_name, "mac", mac)
    uci:set("dhcp", section_name, "ip", ip)
    if name and name ~= "" then
        uci:set("dhcp", section_name, "name", name)
    end
    uci:commit("dhcp")

    -- Restart dnsmasq to apply
    sys.exec("/etc/init.d/dnsmasq restart >/dev/null 2>&1 &")

    http.write(json.stringify({success = true}))
end

function action_delete_reservation()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local sys = require "luci.sys"

    http.prepare_content("application/json")

    local mac = http.formvalue("mac")
    if not mac or mac == "" then
        http.write(json.stringify({error = "MAC address required"}))
        return
    end

    mac = mac:lower()
    local found = false

    uci:foreach("dhcp", "host", function(s)
        if s.mac and s.mac:lower() == mac then
            uci:delete("dhcp", s[".name"])
            found = true
        end
    end)

    uci:commit("dhcp")

    if found then
        sys.exec("/etc/init.d/dnsmasq restart >/dev/null 2>&1 &")
        http.write(json.stringify({success = true}))
    else
        http.write(json.stringify({error = "Reservation not found"}))
    end
end

-- Public IP check
function action_public_ip()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    -- Try multiple services with short timeout
    local ip = sys.exec("curl -s --max-time 3 ifconfig.me 2>/dev/null") or ""
    ip = ip:gsub("%s+$", "")

    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        ip = sys.exec("curl -s --max-time 3 api.ipify.org 2>/dev/null") or ""
        ip = ip:gsub("%s+$", "")
    end

    if not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        ip = sys.exec("curl -s --max-time 3 icanhazip.com 2>/dev/null") or ""
        ip = ip:gsub("%s+$", "")
    end

    local valid = ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil

    http.write(json.stringify({
        ip = valid and ip or nil,
        success = valid
    }))
end

-- Version check: Compare local version with GitHub latest
function action_version_check()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {
        local_version = nil,
        remote_version = nil,
        update_available = false,
        error = nil
    }

    -- Read local version file
    local version_file = "/www/luci-static/resources/jammonitor.version"
    local local_ver = fs.readfile(version_file)
    if local_ver then
        result.local_version = local_ver:gsub("%s+$", ""):sub(1, 7)
    end

    -- Check if we should fetch remote (passed as param to avoid unnecessary calls)
    local check_remote = http.formvalue("check_remote")
    if check_remote == "1" then
        -- Fetch latest commit SHA from GitHub API
        local github_resp = sys.exec(
            "curl -s --max-time 5 -H 'Accept: application/vnd.github.v3+json' " ..
            "'https://api.github.com/repos/madebyjamstudios/jammonitor/commits/main' 2>/dev/null"
        )

        if github_resp and github_resp ~= "" then
            local github_data = json.parse(github_resp)
            if github_data and github_data.sha then
                result.remote_version = github_data.sha:sub(1, 7)
                -- Compare local vs remote versions
                if not result.local_version then
                    -- No version file means unknown install — treat as needing update
                    result.update_available = true
                else
                    result.update_available = (result.local_version ~= result.remote_version)
                end
            else
                result.error = "github_parse_error"
            end
        else
            result.error = "github_unreachable"
        end
    end

    http.write(json.stringify(result))
end

-- Auto-update: Start update process
function action_update_start()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    -- Check if curl exists
    local curl_check = sys.exec("command -v curl 2>/dev/null")
    if not curl_check or curl_check:match("^%s*$") then
        http.write(json.stringify({
            ok = false,
            error = "curl not installed"
        }))
        return
    end

    -- Get target version from request (should be passed by JS after version_check)
    local target_version = http.formvalue("target_version")
    if not target_version or not target_version:match("^[a-f0-9]+$") then
        http.write(json.stringify({ok = false, error = "Invalid target version"}))
        return
    end

    -- Generate job ID
    local job_id = "update_" .. os.time()
    local job_file = "/tmp/jammonitor_" .. job_id .. ".json"

    -- Base URL for raw files
    local base_url = "https://raw.githubusercontent.com/madebyjamstudios/jammonitor/main"

    -- File destinations
    local files = {
        { name = "jammonitor.lua", url = base_url .. "/jammonitor.lua", dest = "/usr/lib/lua/luci/controller/jammonitor.lua", progress = 25 },
        { name = "jammonitor.htm", url = base_url .. "/jammonitor.htm", dest = "/usr/lib/lua/luci/view/jammonitor.htm", progress = 50 },
        { name = "jammonitor.js", url = base_url .. "/jammonitor.js", dest = "/www/luci-static/resources/jammonitor.js", progress = 75 },
        { name = "jammonitor-i18n.js", url = base_url .. "/jammonitor-i18n.js", dest = "/www/luci-static/resources/jammonitor-i18n.js", progress = 90 }
    }

    -- Build the update script
    local script_parts = {
        string.format([[echo '{"state":"downloading","file":"jammonitor.lua","progress":0}' > %s]], job_file)
    }

    for _, file in ipairs(files) do
        local tmp_file = "/tmp/jm_" .. file.name:gsub("%.", "_") .. ".tmp"
        table.insert(script_parts, string.format(
            [[if ! curl -f -s -L --max-time 30 -o '%s' '%s' 2>/dev/null; then echo '{"state":"error","error":"Failed to download %s"}' > %s; exit 1; fi]],
            tmp_file, file.url, file.name, job_file
        ))
        -- Update progress after each download
        local next_file = files[_ + 1]
        if next_file then
            table.insert(script_parts, string.format(
                [[echo '{"state":"downloading","file":"%s","progress":%d}' > %s]],
                next_file.name, file.progress, job_file
            ))
        end
    end

    -- Installing phase
    table.insert(script_parts, string.format(
        [[echo '{"state":"installing","progress":90}' > %s]], job_file
    ))

    -- Move files atomically
    for _, file in ipairs(files) do
        local tmp_file = "/tmp/jm_" .. file.name:gsub("%.", "_") .. ".tmp"
        table.insert(script_parts, string.format(
            [[mv '%s' '%s']], tmp_file, file.dest
        ))
    end

    -- Update version file
    table.insert(script_parts, string.format(
        [[echo '%s' > /www/luci-static/resources/jammonitor.version]],
        target_version:sub(1, 7)
    ))

    -- Clear LuCI cache
    table.insert(script_parts, [[rm -rf /tmp/luci-*]])

    -- Done
    table.insert(script_parts, string.format(
        [[echo '{"state":"done","progress":100}' > %s]], job_file
    ))

    -- Join script parts
    local wrapper = table.concat(script_parts, "\n")

    -- Run in background
    sys.exec("(" .. wrapper .. ") >/dev/null 2>&1 &")

    http.write(json.stringify({
        ok = true,
        job_id = job_id
    }))
end

-- Auto-update: Check status of update job
function action_update_status()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local job_id = http.formvalue("job_id")
    if not job_id or not job_id:match("^update_[0-9]+$") then
        http.write(json.stringify({ok = false, error = "Invalid job_id"}))
        return
    end

    local job_file = "/tmp/jammonitor_" .. job_id .. ".json"
    local content = fs.readfile(job_file)

    if not content or content == "" then
        http.write(json.stringify({ok = false, error = "Job not found", state = "pending"}))
        return
    end

    local data = json.parse(content)
    if data then
        data.ok = true
        http.write(json.stringify(data))
    else
        http.write(json.stringify({ok = false, error = "Invalid job data"}))
    end
end

-- vnstat stats
function action_vnstat()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    local iface = http.formvalue("iface")
    local validated_iface = validate_iface(iface)

    local cmd = "vnstat --json"
    if validated_iface then
        cmd = "vnstat -i " .. validated_iface .. " --json"
    end

    local result = sys.exec(cmd .. " 2>/dev/null") or ""

    -- Try to parse as JSON, return raw if fails
    local data = json.parse(result)
    if data then
        http.write(json.stringify(data))
    else
        http.write(json.stringify({ error = "vnstat not available" }))
    end
end

-- Storage status (USB mount check)
function action_storage_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local db_path = "/mnt/data/jammonitor/history.db"

    local result = {
        mounted = false,
        collector_running = false,
        database_exists = false,
        free_space = nil,
        entry_count = 0,
        oldest_ts = nil,
        newest_ts = nil,
        recent_anomalies = 0
    }

    -- Check if /mnt/data is mounted
    local mounts = fs.readfile("/proc/mounts") or ""
    result.mounted = mounts:match("/mnt/data") ~= nil

    -- Check if collector is running
    local pgrep = sys.exec("pgrep -f jammonitor-collect 2>/dev/null") or ""
    result.collector_running = pgrep:match("%d+") ~= nil

    -- Check if database exists
    local db_stat = fs.stat(db_path)
    result.database_exists = db_stat ~= nil
    if db_stat then
        result.database_size = db_stat.size

        -- Get entry count and date range
        local count = sys.exec("sqlite3 '" .. db_path .. "' 'SELECT COUNT(*) FROM metrics' 2>/dev/null") or ""
        result.entry_count = tonumber(count:match("%d+")) or 0

        local oldest = sys.exec("sqlite3 '" .. db_path .. "' 'SELECT MIN(ts) FROM metrics' 2>/dev/null") or ""
        result.oldest_ts = tonumber(oldest:match("%d+"))

        local newest = sys.exec("sqlite3 '" .. db_path .. "' 'SELECT MAX(ts) FROM metrics' 2>/dev/null") or ""
        result.newest_ts = tonumber(newest:match("%d+"))

        -- Count recent anomalies (last 24h): packet loss (-1 ping) or interface down
        local cutoff = os.time() - 86400
        local anomaly_query = string.format(
            "SELECT COUNT(*) FROM metrics WHERE ts > %d AND (wan_pings LIKE '%%:-1%%' OR wan_pings LIKE '%%:null%%' OR iface_status LIKE '%%wan1\":0%%')",
            cutoff
        )
        local anomalies = sys.exec("sqlite3 '" .. db_path .. "' \"" .. anomaly_query .. "\" 2>/dev/null") or ""
        result.recent_anomalies = tonumber(anomalies:match("%d+")) or 0
    end

    -- Get free space
    if result.mounted then
        local df = sys.exec("df /mnt/data 2>/dev/null | tail -1") or ""
        local available = df:match("%s+%d+%s+%d+%s+(%d+)")
        result.free_space = tonumber(available)
    end

    http.write(json.stringify(result))
end

-- Helper: Validate block device path (only allow /dev/sd[a-z] or /dev/sd[a-z][0-9])
local function validate_device_path(path)
    if not path or path == "" then return nil end
    -- Only allow /dev/sd[a-z] or /dev/sd[a-z][0-9] patterns
    if not path:match("^/dev/sd[a-z][0-9]?$") then return nil end
    -- Verify device exists
    local fs = require "nixio.fs"
    if not fs.stat(path) then return nil end
    return path
end

-- Helper: Check if device is system root
local function is_system_device(device)
    local fs = require "nixio.fs"
    local mounts = fs.readfile("/proc/mounts") or ""
    -- Find what device is mounted at /
    local root_dev = mounts:match("(/dev/[%w]+)%s+/%s+")
    if not root_dev then return false end
    -- Extract base device (sda from sda1)
    local device_base = device:match("^(/dev/sd[a-z])")
    local root_base = root_dev:match("^(/dev/sd[a-z])")
    return device_base == root_base
end

-- Helper: Format bytes to human readable
local function format_bytes(bytes)
    if not bytes or bytes == 0 then return "0 B" end
    local units = {"B", "KB", "MB", "GB", "TB"}
    local i = 1
    while bytes >= 1024 and i < #units do
        bytes = bytes / 1024
        i = i + 1
    end
    return string.format("%.1f %s", bytes, units[i])
end

-- List available USB storage devices
function action_storage_devices()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {
        devices = {},
        current_mount = nil
    }

    -- Find what's currently mounted at /mnt/data
    local mounts = fs.readfile("/proc/mounts") or ""
    local current = mounts:match("(/dev/sd[a-z][0-9]?)%s+/mnt/data")
    result.current_mount = current

    -- Read /proc/partitions to find block devices
    local partitions = fs.readfile("/proc/partitions") or ""
    local devices = {}

    for line in partitions:gmatch("[^\n]+") do
        -- Match sd* devices (USB drives)
        local major, minor, blocks, name = line:match("%s*(%d+)%s+(%d+)%s+(%d+)%s+(sd[a-z][0-9]?)%s*$")
        if name and blocks then
            local dev_path = "/dev/" .. name
            local is_partition = name:match("sd[a-z]%d")

            -- Only process partitions (sda1, sdb1, etc.) not whole disks
            if is_partition then
                local partition_info = {
                    partition = dev_path,
                    size_bytes = tonumber(blocks) * 1024,
                    size_human = format_bytes(tonumber(blocks) * 1024),
                    filesystem = nil,
                    label = nil,
                    uuid = nil,
                    mounted = false,
                    mount_point = nil,
                    is_system = is_system_device(dev_path)
                }

                -- Get filesystem info via blkid
                local blkid = sys.exec("blkid " .. dev_path .. " 2>/dev/null") or ""
                partition_info.filesystem = blkid:match('TYPE="([^"]+)"')
                partition_info.label = blkid:match('LABEL="([^"]+)"')
                partition_info.uuid = blkid:match('UUID="([^"]+)"')

                -- Check mount status
                local mount_point = mounts:match(dev_path:gsub("%-", "%%-") .. "%s+([^%s]+)")
                if mount_point then
                    partition_info.mounted = true
                    partition_info.mount_point = mount_point
                end

                table.insert(result.devices, partition_info)
            end
        end
    end

    http.write(json.stringify(result))
end

-- Format a USB drive partition
function action_storage_format()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    -- Parse POST body
    local content = http.content()
    local params = json.parse(content) or {}
    local device = params.device
    local label = validate_label(params.label) or "JAMMONITOR"

    -- Validate device path
    local safe_device = validate_device_path(device)
    if not safe_device then
        http.write(json.stringify({success = false, error = "Invalid device path"}))
        return
    end

    -- Check if it's a system device
    if is_system_device(safe_device) then
        http.write(json.stringify({success = false, error = "Cannot format system device"}))
        return
    end

    -- Unmount if currently mounted
    local mounts = fs.readfile("/proc/mounts") or ""
    if mounts:match(safe_device:gsub("%-", "%%-")) then
        sys.exec("umount " .. safe_device .. " 2>/dev/null")
        -- Wait briefly for unmount
        os.execute("sleep 1")
    end

    -- Format with ext4
    local format_cmd = string.format("mkfs.ext4 -F -L %s %s 2>&1", label, safe_device)
    local result = sys.exec(format_cmd) or ""

    -- Check if format succeeded by looking for successful completion
    if result:match("Writing superblocks") or result:match("done") then
        http.write(json.stringify({success = true}))
    else
        http.write(json.stringify({success = false, error = "Format failed. Check device and try again."}))
    end
end

-- Mount a USB drive partition at /mnt/data
function action_storage_mount()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    -- Parse POST body
    local content = http.content()
    local params = json.parse(content) or {}
    local device = params.device

    -- Validate device path
    local safe_device = validate_device_path(device)
    if not safe_device then
        http.write(json.stringify({success = false, error = "Invalid device path"}))
        return
    end

    -- Create mount point if needed
    if not fs.stat("/mnt/data") then
        sys.exec("mkdir -p /mnt/data")
    end

    -- Unmount anything currently at /mnt/data
    local mounts = fs.readfile("/proc/mounts") or ""
    if mounts:match("/mnt/data") then
        sys.exec("umount /mnt/data 2>/dev/null")
        os.execute("sleep 1")
    end

    -- Mount the device
    local mount_result = sys.exec("mount " .. safe_device .. " /mnt/data 2>&1") or ""

    -- Verify mount succeeded
    mounts = fs.readfile("/proc/mounts") or ""
    if mounts:match("/mnt/data") then
        http.write(json.stringify({success = true, mount_point = "/mnt/data"}))
    else
        http.write(json.stringify({success = false, error = mount_result ~= "" and mount_result or "Mount failed"}))
    end
end

-- Initialize JamMonitor database and start collector
function action_storage_init()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local result = {
        success = false,
        database_exists = false,
        collector_running = false
    }

    -- Check if /mnt/data is mounted
    local mounts = fs.readfile("/proc/mounts") or ""
    if not mounts:match("/mnt/data") then
        http.write(json.stringify({success = false, error = "USB not mounted"}))
        return
    end

    -- Create jammonitor directory
    sys.exec("mkdir -p /mnt/data/jammonitor")

    -- Stop any existing collector
    sys.exec("/etc/init.d/jammonitor-collect stop 2>/dev/null")
    os.execute("sleep 1")

    -- Start the collector (it will create the database)
    sys.exec("/etc/init.d/jammonitor-collect start 2>/dev/null")
    os.execute("sleep 2")

    -- Check if database was created
    local db_stat = fs.stat("/mnt/data/jammonitor/history.db")
    result.database_exists = db_stat ~= nil

    -- Check if collector is running
    local pgrep = sys.exec("pgrep -f jammonitor-collect 2>/dev/null") or ""
    result.collector_running = pgrep:match("%d+") ~= nil

    result.success = result.database_exists or result.collector_running

    http.write(json.stringify(result))
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
                first_iface = validate_iface(first_iface)
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
                    -- first_iface already validated above
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
                        if iface.ifname and validate_iface(iface.ifname) then
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

            -- Bring down disabled interfaces (with validation)
            for _, iface in ipairs(disabled_ifaces) do
                local safe_iface = validate_iface(iface)
                if safe_iface then
                    sys.exec("ifdown " .. safe_iface .. " >/dev/null 2>&1 &")
                end
            end

            -- Bring up enabled interfaces (with validation)
            for _, iface in ipairs(enabled_ifaces) do
                local safe_iface = validate_iface(iface)
                if safe_iface then
                    sys.exec("ifup " .. safe_iface .. " >/dev/null 2>&1 &")
                end
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

                -- Get interface status for IP and state (validated)
                local safe_iface = validate_iface(iface_name)
                local status_json = safe_iface and sys.exec("ifstatus " .. safe_iface .. " 2>/dev/null") or ""
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

                -- Get MTU from device (using validated path)
                local mtu = nil
                local safe_device = validate_iface(device)
                if safe_device then
                    local fs = require "nixio.fs"
                    local mtu_str = fs.readfile("/sys/class/net/" .. safe_device .. "/mtu")
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

    -- Validate interface name format (security check)
    if not validate_iface(iface) then
        http.write(json.stringify({ success = false, error = "Invalid interface name format" }))
        return
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
        if validate_ip(data.ipaddr) then
            local current = uci:get("network", iface, "ipaddr")
            if current ~= data.ipaddr then
                uci:set("network", iface, "ipaddr", data.ipaddr)
                changes_made = true
                need_ifup = true
            end
        end

        if validate_ip(data.netmask) then
            local current = uci:get("network", iface, "netmask")
            if current ~= data.netmask then
                uci:set("network", iface, "netmask", data.netmask)
                changes_made = true
                need_ifup = true
            end
        end

        if validate_ip(data.gateway) then
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
                if validate_ip(d) then
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

        -- Helper: validate integer in range
        local function valid_int(val, min, max)
            local n = tonumber(val)
            if n and n >= min and n <= max and n == math.floor(n) then return n end
            return nil
        end

        -- Update failover settings (omr-tracker.defaults)
        if data.failover then
            local f = data.failover
            local n
            n = valid_int(f.timeout, 1, 60)
            if n then uci:set("omr-tracker", "defaults", "timeout", tostring(n)); changes_made = true end
            n = valid_int(f.count, 1, 20)
            if n then uci:set("omr-tracker", "defaults", "count", tostring(n)); changes_made = true end
            n = valid_int(f.tries, 1, 20)
            if n then uci:set("omr-tracker", "defaults", "tries", tostring(n)); changes_made = true end
            n = valid_int(f.interval, 1, 300)
            if n then uci:set("omr-tracker", "defaults", "interval", tostring(n)); changes_made = true end
            n = valid_int(f.failure_interval, 1, 300)
            if n then uci:set("omr-tracker", "defaults", "failure_interval", tostring(n)); changes_made = true end
            n = valid_int(f.tries_up, 1, 20)
            if n then uci:set("omr-tracker", "defaults", "tries_up", tostring(n)); changes_made = true end
        end

        -- Update MPTCP settings (network.globals)
        if data.mptcp then
            local m = data.mptcp
            local valid_schedulers = { default = true, roundrobin = true, redundant = true }
            local valid_path_managers = { default = true, fullmesh = true }
            local valid_congestion = { cubic = true, olia = true, wvegas = true, balia = true }
            if m.scheduler and valid_schedulers[m.scheduler] then
                uci:set("network", "globals", "mptcp_scheduler", m.scheduler)
                changes_made = true
            end
            if m.path_manager and valid_path_managers[m.path_manager] then
                uci:set("network", "globals", "mptcp_path_manager", m.path_manager)
                changes_made = true
            end
            if m.congestion and valid_congestion[m.congestion] then
                uci:set("network", "globals", "congestion", m.congestion)
                changes_made = true
            end
            local sf = valid_int(m.subflows, 1, 8)
            if sf then
                uci:set("network", "globals", "mptcp_subflows", tostring(sf))
                changes_made = true
            end
            if m.stale_loss_cnt then
                -- Validate stale_loss_cnt is a safe integer (1-100)
                local stale_val = tonumber(m.stale_loss_cnt)
                if stale_val and stale_val >= 1 and stale_val <= 100 and stale_val == math.floor(stale_val) then
                    -- stale_loss_cnt is a sysctl, set it directly
                    sys.exec("sysctl -w net.mptcp.stale_loss_cnt=" .. tostring(stale_val) .. " >/dev/null 2>&1")
                    -- Also persist to sysctl.conf atomically
                    local sysctl_content = fs.readfile("/etc/sysctl.conf") or ""
                    sysctl_content = sysctl_content:gsub("net%.mptcp%.stale_loss_cnt%s*=%s*%d+\n?", "")
                    sysctl_content = sysctl_content .. "net.mptcp.stale_loss_cnt=" .. tostring(stale_val) .. "\n"
                    atomic_write("/etc/sysctl.conf", sysctl_content)
                end
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

        -- Validate each interface name before writing
        local valid_ifaces = {}
        for _, iface_name in ipairs(data.enabled) do
            if validate_iface(iface_name) then
                table.insert(valid_ifaces, iface_name)
            end
        end

        -- Write to config file atomically (one interface per line)
        local content = table.concat(valid_ifaces, "\n")
        atomic_write(config_file, content)

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

                -- Get interface status (validated)
                local safe_name = validate_iface(name)
                local status_json = safe_name and sys.exec("ifstatus " .. safe_name .. " 2>/dev/null") or ""
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

-- Historical metrics download - ONE bundle with EVERYTHING
function action_history()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    -- Support both hours-based and custom date range queries
    local from_ts = tonumber(http.formvalue("from"))
    local to_ts = tonumber(http.formvalue("to"))
    local hours = tonumber(http.formvalue("hours")) or 24

    local db_path = "/mnt/data/jammonitor/history.db"
    local log_path = "/mnt/data/jammonitor/syslog.txt"
    local cutoff, end_time

    if from_ts and to_ts then
        -- Custom date range mode (cap to 720 hours max)
        local max_range = 720 * 3600
        if (to_ts - from_ts) > max_range then
            from_ts = to_ts - max_range
        end
        cutoff = from_ts
        end_time = to_ts
        -- Calculate hours for display
        hours = math.ceil((to_ts - from_ts) / 3600)
    else
        -- Hours-based mode (backward compatible)
        if hours < 1 then hours = 1 end
        if hours > 720 then hours = 720 end
        cutoff = os.time() - (hours * 3600)
        end_time = os.time()
    end

    local bundle = {
        generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        hours = hours,
        from_ts = cutoff,
        to_ts = end_time,
        metrics = {},
        snapshots = {},
        syslog = "",
        current_state = {}
    }

    -- Check if database exists
    if fs.stat(db_path) then
        -- Query fast metrics (with upper bound for custom range)
        local query = string.format(
            "SELECT ts, load, ram_pct, temp, wan_pings, iface_status FROM metrics WHERE ts > %d AND ts <= %d ORDER BY ts",
            cutoff, end_time
        )
        local result = sys.exec("sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
        if result and result ~= "" then
            for line in result:gmatch("[^\n]+") do
                local ts, load, ram, temp, pings, ifaces = line:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.+)")
                if ts then
                    table.insert(bundle.metrics, {
                        ts = tonumber(ts),
                        load = load,
                        ram_pct = tonumber(ram),
                        temp = tonumber(temp),
                        wan_pings = pings,
                        iface_status = ifaces
                    })
                end
            end
        end

        -- Query slow snapshots (MPTCP, VPN, routes, conntrack, DNS)
        query = string.format(
            "SELECT ts, mptcp, vpn, routes, conntrack_count, dns FROM snapshots WHERE ts > %d AND ts <= %d ORDER BY ts",
            cutoff, end_time
        )
        result = sys.exec("sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
        if result and result ~= "" then
            for line in result:gmatch("[^\n]+") do
                local ts, mptcp, vpn, routes, ct, dns = line:match("([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)")
                if ts then
                    table.insert(bundle.snapshots, {
                        ts = tonumber(ts),
                        mptcp = mptcp or "",
                        vpn = vpn or "",
                        routes = routes or "",
                        conntrack_count = tonumber(ct) or 0,
                        dns = dns or ""
                    })
                end
            end
        end
    end

    -- Include syslog as array of lines (last 2MB max)
    if fs.stat(log_path) then
        local log_content = fs.readfile(log_path) or ""
        -- Limit to last 2MB to keep bundle manageable
        if #log_content > 2097152 then
            log_content = log_content:sub(-2097152)
        end
        -- Split into lines array (JSON encodes strings char-by-char otherwise)
        local lines = {}
        for line in log_content:gmatch("[^\r\n]+") do
            lines[#lines + 1] = line
        end
        bundle.syslog = lines
    end

    -- Include current system state (like diagnostic bundle)
    bundle.current_state = {
        timestamp = os.time(),
        uptime = sys.exec("cat /proc/uptime 2>/dev/null"):gsub("%s+$", ""),
        uname = sys.exec("uname -a 2>/dev/null"):gsub("%s+$", ""),
        ip_addr = sys.exec("ip addr 2>/dev/null"),
        ip_route = sys.exec("ip route 2>/dev/null"),
        mptcp_endpoints = sys.exec("ip mptcp endpoint show 2>/dev/null"),
        mptcp_limits = sys.exec("ip mptcp limits 2>/dev/null"),
        conntrack_count = sys.exec("cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null"):gsub("%s+$", ""),
        conntrack_max = sys.exec("cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null"):gsub("%s+$", ""),
        memory = sys.exec("free 2>/dev/null"),
        load = sys.exec("cat /proc/loadavg 2>/dev/null"):gsub("%s+$", ""),
        dmesg_tail = sys.exec("dmesg 2>/dev/null | tail -200"),
        errors = sys.exec("logread 2>/dev/null | grep -iE '(error|fail|warn|crit|down|timeout)' | tail -100")
    }

    bundle.sample_count = #bundle.metrics
    bundle.snapshot_count = #bundle.snapshots

    http.header("Content-Disposition", 'attachment; filename="jammonitor-history-' .. hours .. 'h-' .. os.date("%Y%m%d-%H%M%S") .. '.json"')
    http.prepare_content("application/json")
    http.write(json.stringify(bundle))
end

-- Per-client traffic for a specific time bucket (hourly/daily/monthly popup)
function action_history_clients()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local range = http.formvalue("range") or "hourly"
    local start_ts = tonumber(http.formvalue("start")) or 0

    -- Validate range
    if range ~= "hourly" and range ~= "daily" and range ~= "monthly" then
        range = "hourly"
    end

    -- Calculate time range based on bucket type
    local end_ts
    if range == "hourly" then
        end_ts = start_ts + 3600
    elseif range == "daily" then
        end_ts = start_ts + 86400
    else -- monthly (approximate 31 days)
        end_ts = start_ts + 31 * 86400
    end

    local db_path = "/mnt/data/jammonitor/history.db"
    local devices = {}

    -- Check if database exists
    if fs.stat(db_path) then
        -- Query both raw and hourly rollup tables, union and aggregate
        -- For raw: match ts in range
        -- For hourly: match hour_ts in range (hourly buckets that overlap)
        local query = string.format([[
            SELECT ip, mac, hostname, SUM(rx_bytes) as rx, SUM(tx_bytes) as tx
            FROM (
                SELECT ip, mac, hostname, rx_bytes, tx_bytes FROM client_traffic
                WHERE ts >= %d AND ts < %d
                UNION ALL
                SELECT ip, mac, hostname, rx_bytes, tx_bytes FROM client_traffic_hourly
                WHERE hour_ts >= %d AND hour_ts < %d
            )
            GROUP BY ip
            ORDER BY (rx + tx) DESC
            LIMIT 100
        ]], start_ts, end_ts, start_ts, end_ts)

        -- Escape for shell
        query = query:gsub("\n", " ")
        local result = sys.exec("sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")

        if result and result ~= "" then
            -- Build current DHCP hostname map for enrichment
            local dhcp_map = {}
            local dhcp_leases = sys.exec("cat /tmp/dhcp.leases 2>/dev/null")
            if dhcp_leases and dhcp_leases ~= "" then
                for line in dhcp_leases:gmatch("[^\n]+") do
                    local mac, ip, host = line:match("^%S+%s+(%S+)%s+(%S+)%s+(%S+)")
                    if ip and host and host ~= "*" then
                        dhcp_map[ip] = host
                    end
                end
            end

            for line in result:gmatch("[^\n]+") do
                local ip, mac, hostname, rx, tx = line:match("([^|]+)|([^|]*)|([^|]*)|([^|]*)|([^|]*)")
                if ip then
                    -- Use current DHCP hostname if stored one is stale
                    local display_name = hostname
                    if (not display_name or display_name == "" or display_name == "*") and dhcp_map[ip] then
                        display_name = dhcp_map[ip]
                    end
                    if not display_name or display_name == "" then
                        display_name = "*"
                    end

                    table.insert(devices, {
                        ip = ip,
                        mac = mac or "unknown",
                        hostname = display_name,
                        rx = tonumber(rx) or 0,
                        tx = tonumber(tx) or 0
                    })
                end
            end
        end
    end

    http.prepare_content("application/json")
    http.write(json.stringify({
        ok = true,
        range = range,
        start = start_ts,
        ["end"] = end_ts,
        devices = devices
    }))
end

-- Traffic summary with unattributed calculation
-- Returns interface totals, client totals, and unattributed delta
function action_traffic_summary()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    local range = http.formvalue("range") or "hourly"
    local start_ts = tonumber(http.formvalue("start")) or 0

    -- Calculate time range based on bucket type
    local end_ts
    if range == "hourly" then
        end_ts = start_ts + 3600
    elseif range == "daily" then
        end_ts = start_ts + 86400
    else
        end_ts = start_ts + 31 * 86400
    end

    local db_path = "/mnt/data/jammonitor/history.db"
    local result = {
        interfaces = {},
        client_total = { rx = 0, tx = 0 },
        unattributed = { rx = 0, tx = 0 }
    }

    if fs.stat(db_path) then
        -- Get interface totals for time range
        local iface_query = string.format([[
            SELECT iface, SUM(rx_bytes) as rx, SUM(tx_bytes) as tx
            FROM interface_traffic
            WHERE ts >= %d AND ts < %d
            GROUP BY iface
        ]], start_ts, end_ts)
        iface_query = iface_query:gsub("\n", " ")

        local iface_result = sys.exec("sqlite3 '" .. db_path .. "' \"" .. iface_query .. "\" 2>/dev/null")
        local total_iface_rx = 0
        local total_iface_tx = 0

        if iface_result and iface_result ~= "" then
            for line in iface_result:gmatch("[^\n]+") do
                local iface, rx, tx = line:match("^([^|]+)|([^|]+)|([^|]+)")
                if iface then
                    rx = tonumber(rx) or 0
                    tx = tonumber(tx) or 0
                    result.interfaces[iface] = { rx = rx, tx = tx }
                    -- Only count WAN/tunnel interfaces for unattributed calc
                    if iface:match("^wan") or iface:match("^eth") or iface:match("^tun") or iface:match("^wg") then
                        total_iface_rx = total_iface_rx + rx
                        total_iface_tx = total_iface_tx + tx
                    end
                end
            end
        end

        -- Get client traffic totals for same time range
        local client_query = string.format([[
            SELECT SUM(rx_bytes) as rx, SUM(tx_bytes) as tx
            FROM (
                SELECT rx_bytes, tx_bytes FROM client_traffic
                WHERE ts >= %d AND ts < %d
                UNION ALL
                SELECT rx_bytes, tx_bytes FROM client_traffic_hourly
                WHERE hour_ts >= %d AND hour_ts < %d
            )
        ]], start_ts, end_ts, start_ts, end_ts)
        client_query = client_query:gsub("\n", " ")

        local client_result = sys.exec("sqlite3 '" .. db_path .. "' \"" .. client_query .. "\" 2>/dev/null")
        if client_result and client_result ~= "" then
            local rx, tx = client_result:match("^([^|]*)|([^|]*)")
            result.client_total.rx = tonumber(rx) or 0
            result.client_total.tx = tonumber(tx) or 0
        end

        -- Calculate unattributed (interface total - client total)
        result.unattributed.rx = math.max(0, total_iface_rx - result.client_total.rx)
        result.unattributed.tx = math.max(0, total_iface_tx - result.client_total.tx)
    end

    http.prepare_content("application/json")
    http.write(json.stringify({
        ok = true,
        range = range,
        start = start_ts,
        ["end"] = end_ts,
        data = result
    }))
end

-- VPS Bypass endpoint - toggle between bonded and direct WAN mode
function action_bypass()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local bypass_flag = "/etc/jammonitor_bypass_enabled"
    local saved_config = "/etc/jammonitor_bypass_saved"
    local method = http.getenv("REQUEST_METHOD")

    if method == "POST" then
        -- Prevent concurrent bypass requests with a lock file
        local lockfile = "/tmp/jammonitor_bypass.lock"
        if fs.stat(lockfile) then
            http.write(json.stringify({ success = false, error = "Bypass operation already in progress" }))
            return
        end
        fs.writefile(lockfile, tostring(os.time()))

        -- Toggle bypass mode
        local raw = http.content()
        local data = json.parse(raw) or {}
        local enable = data.enable

        if enable then
            -- ENABLE BYPASS: Save current config, disable all MPTCP
            local saved_lines = {}
            local primary_wan = nil

            -- Find all WAN interfaces and save their multipath settings
            uci:foreach("network", "interface", function(s)
                local iface_name = s[".name"]
                local multipath = s.multipath

                -- Only save interfaces that have multipath configured
                if multipath and (multipath == "master" or multipath == "on" or multipath == "backup") then
                    table.insert(saved_lines, iface_name .. "=" .. multipath)

                    -- Track the primary (master) interface
                    if multipath == "master" then
                        primary_wan = iface_name
                    end

                    -- Set all to off
                    uci:set("network", iface_name, "multipath", "off")
                end
            end)

            -- Check if any MPTCP interfaces were found
            if #saved_lines == 0 then
                http.write(json.stringify({
                    success = false,
                    error = "No MPTCP interfaces configured. Cannot enable bypass mode."
                }))
                fs.remove(lockfile)
                return
            end

            -- Save to file for restore + persistence (atomic write)
            atomic_write(saved_config, table.concat(saved_lines, "\n"))

            -- Write bypass flag (stores primary WAN name for reference)
            atomic_write(bypass_flag, primary_wan or "unknown")

            -- Commit multipath changes
            uci:commit("network")

            -- OMR-bypass doesn't support 0.0.0.0/0 wildcard, so we must stop the VPN services
            -- The /usr/share/omr/schedule.d/010-services script runs every minute and
            -- restarts services UNLESS their UCI config has disabled=1

            -- Save original VPN service states before disabling
            local vpn_states = {}
            local ss_libev = sys.exec("uci get shadowsocks-libev.sss0.disabled 2>/dev/null"):gsub("%s+$", "")
            local ss_rust = sys.exec("uci get shadowsocks-rust.sss0.disabled 2>/dev/null"):gsub("%s+$", "")
            local ovpn = sys.exec("uci get openvpn.omr.enabled 2>/dev/null"):gsub("%s+$", "")
            local gt = sys.exec("uci get glorytun.vpn.enable 2>/dev/null"):gsub("%s+$", "")

            -- Store original states (default to disabled if not set)
            table.insert(vpn_states, "ss_libev=" .. (ss_libev ~= "" and ss_libev or "1"))
            table.insert(vpn_states, "ss_rust=" .. (ss_rust ~= "" and ss_rust or "1"))
            table.insert(vpn_states, "openvpn=" .. (ovpn ~= "" and ovpn or "0"))
            table.insert(vpn_states, "glorytun=" .. (gt ~= "" and gt or "0"))

            -- Save VPN states to separate file
            atomic_write("/etc/jammonitor_bypass_vpn", table.concat(vpn_states, "\n"))

            -- 1. Set UCI disabled flags (prevents omr-schedule from restarting services)
            sys.exec("uci set shadowsocks-libev.sss0.disabled=1 2>/dev/null")
            sys.exec("uci set shadowsocks-rust.sss0.disabled=1 2>/dev/null")
            sys.exec("uci set openvpn.omr.enabled=0 2>/dev/null")
            sys.exec("uci set glorytun.vpn.enable=0 2>/dev/null")
            sys.exec("uci commit shadowsocks-libev 2>/dev/null")
            sys.exec("uci commit shadowsocks-rust 2>/dev/null")
            sys.exec("uci commit openvpn 2>/dev/null")
            sys.exec("uci commit glorytun 2>/dev/null")

            -- 2. Disable hotplug script that restarts omr-tracker on interface changes
            sys.exec("mv /etc/hotplug.d/iface/40-omr-tracker /etc/hotplug.d/iface/40-omr-tracker.disabled 2>/dev/null")

            -- 3. Stop omr-tracker
            sys.exec("/etc/init.d/omr-tracker stop >/dev/null 2>&1")
            sys.exec("killall -9 omr-tracker omr-tracker-ss 2>/dev/null")

            -- 4. Stop OpenVPN
            sys.exec("/etc/init.d/openvpn stop >/dev/null 2>&1")
            sys.exec("killall -9 openvpn 2>/dev/null")

            -- 5. Stop Shadowsocks
            sys.exec("/etc/init.d/shadowsocks-libev stop >/dev/null 2>&1")
            sys.exec("/etc/init.d/shadowsocks-rust stop >/dev/null 2>&1")
            sys.exec("killall -9 sslocal ss-redir ss-local 2>/dev/null")

            -- 6. Bring down tun0 interface
            sys.exec("ip link set tun0 down 2>/dev/null")

            -- Wait for services to stop
            sys.exec("sleep 3")

            -- Verify the change took effect
            local new_uci = require "luci.model.uci".cursor()
            local verify_ok = true
            for line in table.concat(saved_lines, "\n"):gmatch("[^\n]+") do
                local iface = line:match("^([^=]+)=")
                if iface then
                    local current = new_uci:get("network", iface, "multipath")
                    if current ~= "off" then
                        verify_ok = false
                        break
                    end
                end
            end

            if verify_ok then
                http.write(json.stringify({
                    success = true,
                    bypass_enabled = true,
                    active_wan = primary_wan,
                    message = "VPS bypass enabled - traffic now going direct"
                }))
            else
                -- Verification failed - try to rollback
                for _, line in ipairs(saved_lines) do
                    local iface, mode = line:match("^([^=]+)=(.+)$")
                    if iface and mode then
                        uci:set("network", iface, "multipath", mode)
                    end
                end
                uci:commit("network")
                fs.remove(bypass_flag)
                fs.remove("/etc/jammonitor_bypass_vpn")
                fs.remove(lockfile)
                http.write(json.stringify({
                    success = false,
                    error = "Failed to set multipath to off - changes rolled back"
                }))
            end
        else
            -- DISABLE BYPASS: Restore saved config
            local saved_content = fs.readfile(saved_config) or ""
            local restored_count = 0

            if saved_content == "" then
                http.write(json.stringify({
                    success = false,
                    error = "No saved configuration found to restore"
                }))
                fs.remove(lockfile)
                return
            end

            for line in saved_content:gmatch("[^\n]+") do
                local iface, mode = line:match("^([^=]+)=(.+)$")
                if iface and mode and validate_iface(iface) then
                    uci:set("network", iface, "multipath", mode)
                    restored_count = restored_count + 1
                end
            end

            -- Remove bypass flag
            fs.remove(bypass_flag)

            -- Commit network changes
            uci:commit("network")

            -- Restore original VPN service states from saved file
            local vpn_saved = fs.readfile("/etc/jammonitor_bypass_vpn") or ""
            local vpn_restore = {
                ss_libev = "0",   -- default: enabled (disabled=0)
                ss_rust = "1",   -- default: disabled (disabled=1)
                openvpn = "1",   -- default: enabled (enabled=1)
                glorytun = "0"   -- default: disabled (enable=0)
            }

            -- Parse saved VPN states (validate each is 0 or 1)
            for line in vpn_saved:gmatch("[^\n]+") do
                local key, val = line:match("^([^=]+)=(.+)$")
                if key and val and val:match("^[01]$") then
                    vpn_restore[key] = val
                end
            end

            -- Restore to original states
            sys.exec("uci set shadowsocks-libev.sss0.disabled=" .. vpn_restore.ss_libev .. " 2>/dev/null")
            sys.exec("uci set shadowsocks-rust.sss0.disabled=" .. vpn_restore.ss_rust .. " 2>/dev/null")
            sys.exec("uci set openvpn.omr.enabled=" .. vpn_restore.openvpn .. " 2>/dev/null")
            sys.exec("uci set glorytun.vpn.enable=" .. vpn_restore.glorytun .. " 2>/dev/null")
            sys.exec("uci commit shadowsocks-libev 2>/dev/null")
            sys.exec("uci commit shadowsocks-rust 2>/dev/null")
            sys.exec("uci commit openvpn 2>/dev/null")
            sys.exec("uci commit glorytun 2>/dev/null")

            -- Clean up saved VPN state file
            fs.remove("/etc/jammonitor_bypass_vpn")

            -- Restore hotplug script
            sys.exec("mv /etc/hotplug.d/iface/40-omr-tracker.disabled /etc/hotplug.d/iface/40-omr-tracker 2>/dev/null")

            -- Start VPN services

            -- 1. Start Shadowsocks
            sys.exec("/etc/init.d/shadowsocks-libev start >/dev/null 2>&1")
            sys.exec("/etc/init.d/shadowsocks-rust start >/dev/null 2>&1")

            -- 2. Start OpenVPN
            sys.exec("/etc/init.d/openvpn start >/dev/null 2>&1")

            -- 3. Start omr-tracker
            sys.exec("/etc/init.d/omr-tracker start >/dev/null 2>&1")

            -- Verify multipath settings were restored
            local verify_uci = require "luci.model.uci".cursor()
            local verify_ok = true
            for line in saved_content:gmatch("[^\n]+") do
                local iface, expected_mode = line:match("^([^=]+)=(.+)$")
                if iface and expected_mode then
                    local actual_mode = verify_uci:get("network", iface, "multipath")
                    if actual_mode ~= expected_mode then
                        verify_ok = false
                        break
                    end
                end
            end

            if verify_ok then
                -- Send response BEFORE network reload (reload drops connection)
                http.write(json.stringify({
                    success = true,
                    bypass_enabled = false,
                    restored_count = restored_count,
                    message = "VPS bypass disabled - traffic now routed through VPS"
                }))
            else
                http.write(json.stringify({
                    success = false,
                    error = "Failed to restore multipath settings"
                }))
                fs.remove(lockfile)
                return
            end

            -- 4. Reload firewall and network in background (after response sent)
            sys.exec("(sleep 1 && /etc/init.d/firewall reload && /etc/init.d/network reload) >/dev/null 2>&1 &")
        end

        -- Release bypass lock
        fs.remove(lockfile)
    else
        -- GET: Return current bypass status
        local bypass_enabled = fs.stat(bypass_flag) ~= nil
        local active_wan = nil
        local saved_config_data = {}

        if bypass_enabled then
            active_wan = (fs.readfile(bypass_flag) or ""):gsub("%s+$", "")
        end

        -- Read saved config if exists
        local saved_content = fs.readfile(saved_config) or ""
        for line in saved_content:gmatch("[^\n]+") do
            local iface, mode = line:match("^([^=]+)=(.+)$")
            if iface and mode then
                saved_config_data[iface] = mode
            end
        end

        -- If not bypassing, find current primary
        if not bypass_enabled then
            uci:foreach("network", "interface", function(s)
                if s.multipath == "master" then
                    active_wan = s[".name"]
                end
            end)
        end

        http.write(json.stringify({
            bypass_enabled = bypass_enabled,
            active_wan = active_wan,
            saved_config = saved_config_data
        }))
    end
end

-- Speed Test Start endpoint - initiates a speed test for a specific WAN interface
function action_speedtest_start()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    -- Check if curl exists
    local curl_check = sys.exec("command -v curl 2>/dev/null")
    if not curl_check or curl_check:match("^%s*$") then
        http.write(json.stringify({
            ok = false,
            error = "curl not installed",
            install_hint = "apk add curl"
        }))
        return
    end

    -- Get parameters
    local ifname = http.formvalue("ifname")
    local direction = http.formvalue("direction")
    local size_mb = tonumber(http.formvalue("size_mb")) or 10
    local timeout_s = tonumber(http.formvalue("timeout_s")) or 30
    local server = http.formvalue("server") or "cloudflare"

    -- Speed test server configurations
    local servers = {
        cloudflare = {
            name = "Cloudflare (Global)",
            download = "https://speed.cloudflare.com/__down?bytes=%d",
            upload = "https://speed.cloudflare.com/__up"
        },
        china = {
            name = "China (CacheFly)",
            -- CacheFly CDN - has nodes in China, commonly used for speed tests
            download = "http://cachefly.cachefly.net/%dmb.test",
            upload = nil  -- Upload not supported for this server
        },
        global = {
            name = "Global Fallback",
            -- Tele2 speed test - works globally including China
            download = "http://speedtest.tele2.net/%dMB.zip",
            upload = nil  -- Upload not supported for this server
        }
    }

    -- Validate server choice
    if not servers[server] then
        server = "cloudflare"
    end
    local srv = servers[server]

    -- Validate interface name
    local safe_iface = validate_iface(ifname)
    if not safe_iface then
        http.write(json.stringify({ok = false, error = "Invalid interface name"}))
        return
    end

    -- Validate direction
    if direction ~= "download" and direction ~= "upload" then
        http.write(json.stringify({ok = false, error = "Invalid direction (must be download or upload)"}))
        return
    end

    -- Clamp size and timeout to safe values
    if size_mb < 5 then size_mb = 5 end
    if size_mb > 200 then size_mb = 200 end
    if timeout_s < 5 then timeout_s = 5 end
    if timeout_s > 60 then timeout_s = 60 end

    -- Get interface IP and device for binding
    local status_json = sys.exec("ifstatus " .. safe_iface .. " 2>/dev/null")
    local source_ip = nil
    local l3_device = nil

    if status_json and status_json ~= "" then
        local status = json.parse(status_json)
        if status then
            l3_device = status.l3_device or status.device
            if status["ipv4-address"] and status["ipv4-address"][1] then
                source_ip = status["ipv4-address"][1].address
            end
        end
    end

    if not source_ip and not l3_device then
        http.write(json.stringify({ok = false, error = "Interface has no IPv4 address or device"}))
        return
    end

    -- Prefer source IP, fallback to device
    local bind_arg = source_ip or l3_device

    -- Generate job ID and file path
    local job_id = safe_iface .. "_" .. os.time()
    local job_file = "/tmp/jammonitor_speedtest_" .. job_id .. ".json"
    local bytes = size_mb * 1024 * 1024

    -- Build curl command based on server
    local curl_cmd
    if direction == "download" then
        local url
        if server == "cloudflare" then
            url = string.format(srv.download, bytes)
        else
            -- Other servers use MB-based files
            url = string.format(srv.download, size_mb)
        end
        curl_cmd = string.format(
            [[curl -4 -L --max-time %d --interface '%s' -o /dev/null -s -w '{"speed":%%{speed_download},"time":%%{time_total},"size":%%{size_download}}' '%s']],
            timeout_s, bind_arg, url
        )
    else
        -- Upload test - only supported on Cloudflare
        if not srv.upload then
            http.write(json.stringify({ok = false, error = "Upload test not supported for " .. srv.name .. ". Use Cloudflare server."}))
            return
        end
        curl_cmd = string.format(
            [[dd if=/dev/zero bs=1M count=%d 2>/dev/null | curl -4 -L --max-time %d --interface '%s' -X POST -o /dev/null -s -w '{"speed":%%{speed_upload},"time":%%{time_total},"size":%%{size_upload}}' --data-binary @- '%s']],
            size_mb, timeout_s, bind_arg, srv.upload
        )
    end

    -- Wrapper script that writes status to job file
    local wrapper = string.format([[
        echo '{"state":"running","ifname":"%s","direction":"%s","started_at":'$(date +%%s)'}' > %s
        RESULT=$(%s 2>&1)
        if echo "$RESULT" | grep -q '"speed"'; then
            SPEED=$(echo "$RESULT" | sed 's/.*"speed":\([0-9.]*\).*/\1/')
            TIME=$(echo "$RESULT" | sed 's/.*"time":\([0-9.]*\).*/\1/')
            SIZE=$(echo "$RESULT" | sed 's/.*"size":\([0-9.]*\).*/\1/')
            MBPS=$(awk "BEGIN {printf \"%%.2f\", $SPEED * 8 / 1000000}")
            echo '{"state":"done","ifname":"%s","direction":"%s","mbps":'$MBPS',"bytes":'$SIZE',"seconds":'$TIME',"timestamp":'$(date +%%s)'}' > %s
        else
            ERRMSG=$(echo "$RESULT" | head -c 200 | tr '"' "'" | tr '\n' ' ')
            echo '{"state":"error","ifname":"%s","direction":"%s","error":"'"$ERRMSG"'","timestamp":'$(date +%%s)'}' > %s
        fi
    ]], safe_iface, direction, job_file, curl_cmd, safe_iface, direction, job_file, safe_iface, direction, job_file)

    -- Run in background
    sys.exec("(" .. wrapper .. ") >/dev/null 2>&1 &")

    http.write(json.stringify({
        ok = true,
        job_id = job_id,
        started_at = os.time()
    }))
end

-- Speed Test Status endpoint - returns the status of a speed test job
function action_speedtest_status()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local job_id = http.formvalue("job_id")
    if not job_id or not job_id:match("^[a-zA-Z0-9_%-]+$") then
        http.write(json.stringify({ok = false, error = "Invalid job_id"}))
        return
    end

    local job_file = "/tmp/jammonitor_speedtest_" .. job_id .. ".json"
    local content = fs.readfile(job_file)

    if not content or content == "" then
        http.write(json.stringify({ok = false, error = "Job not found"}))
        return
    end

    local data = json.parse(content)
    if data then
        data.ok = true
        http.write(json.stringify(data))
    else
        http.write(json.stringify({ok = false, error = "Invalid job data"}))
    end
end
