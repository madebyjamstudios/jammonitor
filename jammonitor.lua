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
    entry({"admin", "status", "jammonitor", "tailscale_status"}, call("action_tailscale_status"), nil)
    entry({"admin", "status", "jammonitor", "public_ip"}, call("action_public_ip"), nil)
    entry({"admin", "status", "jammonitor", "vnstat"}, call("action_vnstat"), nil)
    -- Existing endpoints
    entry({"admin", "status", "jammonitor", "diag"}, call("action_diag"), nil)
    entry({"admin", "status", "jammonitor", "wifi_status"}, call("action_wifi_status"), nil)
    entry({"admin", "status", "jammonitor", "wan_policy"}, call("action_wan_policy"), nil)
    entry({"admin", "status", "jammonitor", "wan_policy_set"}, post("action_wan_policy_set"), nil)
    entry({"admin", "status", "jammonitor", "wan_edit"}, post("action_wan_edit"), nil)
    entry({"admin", "status", "jammonitor", "wan_advanced"}, call("action_wan_advanced"), nil)
    entry({"admin", "status", "jammonitor", "wan_advanced_set"}, post("action_wan_advanced_set"), nil)
    entry({"admin", "status", "jammonitor", "wan_ifaces"}, call("action_wan_ifaces"), nil)
    entry({"admin", "status", "jammonitor", "wan_ifaces_set"}, post("action_wan_ifaces_set"), nil)
    entry({"admin", "status", "jammonitor", "history"}, call("action_history"), nil)
    entry({"admin", "status", "jammonitor", "history_clients"}, call("action_history_clients"), nil)
    entry({"admin", "status", "jammonitor", "traffic_summary"}, call("action_traffic_summary"), nil)
    entry({"admin", "status", "jammonitor", "bypass"}, call("action_bypass"), nil)
    entry({"admin", "status", "jammonitor", "bypass_set"}, post("action_bypass_set"), nil)
    entry({"admin", "status", "jammonitor", "storage_status"}, call("action_storage_status"), nil)
    -- USB Storage setup endpoints
    entry({"admin", "status", "jammonitor", "storage_devices"}, call("action_storage_devices"), nil)
    entry({"admin", "status", "jammonitor", "storage_format"}, post("action_storage_format"), nil)
    entry({"admin", "status", "jammonitor", "storage_mount"}, post("action_storage_mount"), nil)
    entry({"admin", "status", "jammonitor", "storage_init"}, post("action_storage_init"), nil)
    -- Client metadata and DHCP reservations
    entry({"admin", "status", "jammonitor", "get_client_meta"}, call("action_get_client_meta"), nil)
    entry({"admin", "status", "jammonitor", "set_client_meta"}, post("action_set_client_meta"), nil)
    entry({"admin", "status", "jammonitor", "get_reservations"}, call("action_get_reservations"), nil)
    entry({"admin", "status", "jammonitor", "set_reservation"}, post("action_set_reservation"), nil)
    entry({"admin", "status", "jammonitor", "delete_reservation"}, post("action_delete_reservation"), nil)
    -- Speed test endpoints
    entry({"admin", "status", "jammonitor", "speedtest_start"}, post("action_speedtest_start"), nil)
    entry({"admin", "status", "jammonitor", "speedtest_status"}, call("action_speedtest_status"), nil)
    -- Version check endpoint
    entry({"admin", "status", "jammonitor", "version_check"}, call("action_version_check"), nil)
    -- Version visibility plus the deliberately non-mutating update endpoint
    entry({"admin", "status", "jammonitor", "update_start"}, call("action_update_start"), nil)
    entry({"admin", "status", "jammonitor", "update_status"}, call("action_update_status"), nil)
end

-- Helper: Validate interface name (alphanumeric, dash, underscore only)
local function validate_iface(name)
    if not name or name == "" then return nil end
    if not name:match("^[a-zA-Z0-9_.%-]+$") then return nil end
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

local MAX_JSON_BODY = 65536
local MAX_WAN_INTERFACES = 32
local VALID_MULTIPATH_MODES = {
    master = true,
    on = true,
    backup = true,
    off = true
}
local VALID_DEVICE_TYPES = {
    phone = true, tablet = true, laptop = true, desktop = true,
    watch = true, wearable = true, ebook = true, ipod = true,
    tv = true, audio = true, gaming = true, camera = true,
    voip = true, printer = true, scanner = true, projector = true,
    pos = true, network = true, server = true, iot = true,
    unknown = true
}

local function parse_json_request(http, json)
    local raw = http.content()
    if type(raw) ~= "string" or raw == "" then
        return nil, "No data received"
    end
    if #raw > MAX_JSON_BODY then
        return nil, "Request body too large"
    end
    local data = json.parse(raw)
    if type(data) ~= "table" then
        return nil, "Invalid JSON"
    end
    return data
end

local function has_only_keys(value, allowed)
    if type(value) ~= "table" then return false end
    for key, _ in pairs(value) do
        if type(key) ~= "string" or not allowed[key] then
            return false
        end
    end
    return true
end

local function dense_array_length(value)
    if type(value) ~= "table" then return nil end
    local length = #value
    local count = 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" or key < 1 or
           key ~= math.floor(key) or key > length then
            return nil
        end
        count = count + 1
    end
    if count ~= length then return nil end
    return length
end

local function is_system_interface(name)
    return name == "loopback" or name == "lan" or name == "guest" or
        name == "omrvpn" or name == "omr6in4" or name:match("^omr") or
        name:match("^br%-") or name:match("^lan") or name:match("^guest") or
        name:match("^tailscale") or name:match("^tun") or name:match("^vpn")
end

local function configured_wan_hints()
    local fs = require "nixio.fs"
    local content = fs.readfile("/etc/jammonitor_wans") or ""
    local hints = {}
    if #content > 4096 then return hints end
    for line in content:gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s*$")
        if validate_iface(name) then hints[name] = true end
    end
    return hints
end

-- The client never defines WAN authority. A mutable interface must exist as a
-- UCI network interface, pass the lockout exclusions, and either be selected
-- already, match a WAN naming family, or already carry a valid multipath mode.
local function eligible_wans(uci)
    local hints = configured_wan_hints()
    local result = {}
    local seen = {}
    uci:foreach("network", "interface", function(section)
        local name = section[".name"]
        local looks_like_wan = name and (
            name:match("^wan%d*$") or name:match("^wwan") or
            name:match("^4g") or name:match("^lte") or
            name:match("^mobile")
        )
        if validate_iface(name) and not is_system_interface(name) and
           (hints[name] or looks_like_wan or section.multipath == "master" or
            section.multipath == "on" or section.multipath == "backup") and
           not seen[name] then
            seen[name] = true
            table.insert(result, name)
        end
    end)
    table.sort(result)
    return result, seen
end

local function selected_wans(uci)
    local fs = require "nixio.fs"
    local eligible_list, eligible_set = eligible_wans(uci)
    local content = fs.readfile("/etc/jammonitor_wans") or ""
    if #content > 4096 then
        return nil, nil, "WAN selection is oversized"
    end

    local selected = {}
    local selected_set = {}
    local has_config = false
    for line in content:gmatch("[^\r\n]+") do
        has_config = true
        local name = line:match("^%s*(.-)%s*$")
        if not validate_iface(name) or not eligible_set[name] or
           selected_set[name] or #selected >= MAX_WAN_INTERFACES then
            return nil, nil, "WAN selection is invalid"
        end
        selected_set[name] = true
        table.insert(selected, name)
    end

    if not has_config then
        for _, name in ipairs(eligible_list) do
            if #selected >= MAX_WAN_INTERFACES then
                return nil, nil, "WAN selection is oversized"
            end
            selected_set[name] = true
            table.insert(selected, name)
        end
    end
    return selected, selected_set
end

local function validate_hostname(name)
    if type(name) ~= "string" then return nil end
    if name == "" then return "" end
    if #name > 63 or name:find("%c") or name:find("..", 1, true) then
        return nil
    end
    for label in name:gmatch("[^.]+") do
        if #label > 63 or
           not (label:match("^%w$") or label:match("^%w[%w%-]*%w$")) then
            return nil
        end
    end
    if name:sub(1, 1) == "." or name:sub(-1) == "." then return nil end
    return name
end

local atomic_write_sequence = 0
local PRIVATE_FILE_MODE = tonumber("600", 8)
local PUBLIC_FILE_MODE = tonumber("644", 8)
local EXECUTABLE_FILE_MODE = tonumber("700", 8)
local WAN_MUTATION_LOCK = "/tmp/jammonitor-wan.lock"
local DHCP_MUTATION_LOCK = "/tmp/jammonitor-dhcp.lock"
local BYPASS_FLAG = "/etc/jammonitor_bypass_enabled"
local BYPASS_BUNDLE = "/etc/jammonitor_bypass_recovery.json"
local BYPASS_RECOVERY_FAILED = "/etc/jammonitor_bypass_recovery_failed"

-- Helper: Atomic file write with a per-process unique temporary path.
local function atomic_write(path, content, mode)
    local fs = require "nixio.fs"
    local nixio = require "nixio"
    atomic_write_sequence = atomic_write_sequence + 1
    local tmp = string.format(
        "%s.tmp.%d.%d.%d",
        path, nixio.getpid(), os.time(), atomic_write_sequence
    )
    local ok = fs.writefile(tmp, content)
    if ok and mode and not fs.chmod(tmp, mode) then
        ok = false
    end
    if ok then
        local renamed = os.rename(tmp, path)
        if renamed then return true end
    end
    fs.remove(tmp)
    return false
end

-- mkdir is the portable atomic primitive available on the target BusyBox/LuCI
-- stack. A bounded stale lease prevents a crashed request from wedging a
-- mutation forever.
local function acquire_lock_dir(path, stale_seconds)
    local fs = require "nixio.fs"
    local stat = fs.stat(path)
    if stat and tonumber(stat.mtime) and
       os.time() - tonumber(stat.mtime) > stale_seconds then
        if stat.type == "dir" then
            fs.remove(path .. "/owner")
            fs.rmdir(path)
        else
            -- Migrate a stale lock file from pre-directory releases.
            fs.remove(path)
        end
    end
    if not fs.mkdir(path) then return false end
    if not fs.writefile(path .. "/owner", tostring(os.time())) then
        fs.rmdir(path)
        return false
    end
    return true
end

local function release_lock_dir(path)
    local fs = require "nixio.fs"
    fs.remove(path .. "/owner")
    fs.rmdir(path)
    return fs.stat(path) == nil
end

local function checked_call(command)
    local sys = require "luci.sys"
    return sys.call(command .. " >/dev/null 2>&1") == 0
end

local function checked_init_action(path, action, timeout_seconds)
    if type(path) ~= "string" or
       not path:match("^/etc/init%.d/[A-Za-z0-9_.%-]+$") or
       (action ~= "start" and action ~= "stop" and action ~= "restart" and
        action ~= "reload" and action ~= "running" and action ~= "enabled" and
        action ~= "enable" and action ~= "disable") then
        return false
    end
    local timeout = tonumber(timeout_seconds) or 30
    if timeout < 1 or timeout > 120 or timeout ~= math.floor(timeout) then
        return false
    end
    return checked_call(
        "timeout " .. tostring(timeout) .. " " .. path .. " " .. action
    )
end

local command_capture_sequence = 0

-- Capture bounded command output without losing the exit status. Callers may
-- pass only fixed command text plus values that have already crossed a strict
-- allowlist validator.
local function checked_capture(command)
    local fs = require "nixio.fs"
    local nixio = require "nixio"
    local sys = require "luci.sys"
    command_capture_sequence = command_capture_sequence + 1
    local output_path = string.format(
        "/tmp/jammonitor-command.%d.%d.%d",
        nixio.getpid(), os.time(), command_capture_sequence
    )
    local rc = sys.call(command .. " >" .. output_path .. " 2>&1")
    local output = fs.readfile(output_path) or ""
    fs.remove(output_path)
    return rc == 0, output
end

local function snapshot_file(path)
    local fs = require "nixio.fs"
    local stat = fs.stat(path)
    if not stat then
        return {path = path, exists = false, content = ""}
    end
    local content = fs.readfile(path)
    if content == nil then return nil end
    return {path = path, exists = true, content = content}
end

local function restore_file_snapshot(snapshot, mode)
    local fs = require "nixio.fs"
    if not snapshot then return false end
    if snapshot.exists then
        return atomic_write(snapshot.path, snapshot.content, mode)
    end
    if fs.stat(snapshot.path) and not fs.remove(snapshot.path) then
        return false
    end
    return fs.stat(snapshot.path) == nil
end

local function run_locked(lock_path, stale_seconds, busy_error, operation)
    if not acquire_lock_dir(lock_path, stale_seconds) then
        return false, busy_error
    end
    local called, first, second = pcall(operation)
    local released = release_lock_dir(lock_path)
    if not called then
        return false, "Operation failed"
    end
    if not released then
        return false, "Operation completed but lock cleanup failed"
    end
    return first, second
end

local function revert_uci_package(package_name)
    local cursor = require "luci.model.uci".cursor()
    cursor:revert(package_name)
end

local function restore_uci_snapshot(package_name, snapshot)
    revert_uci_package(package_name)
    return restore_file_snapshot(snapshot, PRIVATE_FILE_MODE)
end

local TAILSCALE_CLI = "/usr/sbin/tailscale"
local TAILSCALE_SOCKET = "/var/run/tailscale/tailscaled.sock"
local TAILSCALE_WATCHDOG_STATUS = "/var/run/jammonitor/tailscale-watchdog.json"

-- Return the first tailscaled PID without accepting any caller-controlled text.
local function tailscaled_pid()
    local sys = require "luci.sys"
    local output = sys.exec("pidof tailscaled 2>/dev/null | awk '{print $1}'") or ""
    return output:match("^(%d+)")
end

-- Process lifetime is distinct from Tailscale connectivity. Bind the reported
-- uptime to PID plus /proc start ticks so a recycled PID cannot inherit the
-- lifetime of a replacement daemon.
local function tailscaled_process_identity(pid)
    if not pid or not pid:match("^%d+$") then return nil, nil end

    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local stat = fs.readfile("/proc/" .. pid .. "/stat")
    local uptime_text = fs.readfile("/proc/uptime")
    if not stat or not uptime_text then return nil end

    -- Strip pid and parenthesized comm. starttime is field 22, which is the
    -- 20th whitespace-delimited field in the remainder beginning with state.
    local remainder = stat:match("^%d+ %b() (.+)$")
    if not remainder then return nil end
    local start_ticks
    local index = 0
    for value in remainder:gmatch("%S+") do
        index = index + 1
        if index == 20 then
            start_ticks = tonumber(value)
            break
        end
    end

    local host_uptime = tonumber(uptime_text:match("^([%d%.]+)"))
    local clock_ticks = tonumber((sys.exec("getconf CLK_TCK 2>/dev/null") or ""):match("%d+")) or 100
    if not start_ticks or not host_uptime or clock_ticks <= 0 then return nil end

    local process_uptime = math.floor(host_uptime - (start_ticks / clock_ticks))
    if process_uptime < 0 then return nil, nil end
    return pid .. ":" .. tostring(start_ticks), process_uptime
end

-- Run status behind an external deadline. Tailscale v1.92.x LocalAPI calls can
-- otherwise wait indefinitely when the daemon accepts a socket but is wedged.
local function query_tailscale_status(include_peers)
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local command = "timeout 3 " .. TAILSCALE_CLI ..
        " --socket=" .. TAILSCALE_SOCKET .. " status --json"
    if not include_peers then
        command = command .. " --peers=false"
    end
    command = command .. " 2>/dev/null"
    local raw = sys.exec(command) or ""
    if raw == "" then return nil end
    return json.parse(raw)
end

local function copy_string_list(values, limit)
    local result = {}
    if type(values) ~= "table" then return result end
    for _, value in ipairs(values) do
        if type(value) == "string" and #value <= 128 then
            result[#result + 1] = value
            if #result >= limit then break end
        end
    end
    return result
end

local function is_tailscale_ip(value)
    if type(value) ~= "string" or #value > 128 then return false end

    local first, second, third, fourth =
        value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if first then
        first, second, third, fourth =
            tonumber(first), tonumber(second), tonumber(third), tonumber(fourth)
        return first == 100 and second >= 64 and second <= 127 and
            third <= 255 and fourth <= 255
    end

    return value:lower():match("^fd7a:115c:a1e0:") ~= nil
end

local function copy_tailscale_ip_list(values, limit)
    local result = {}
    if type(values) ~= "table" then return result end
    for _, value in ipairs(values) do
        if is_tailscale_ip(value) then
            result[#result + 1] = value
            if #result >= limit then break end
        end
    end
    return result
end

-- Project the unstable Tailscale status schema onto the small, non-sensitive
-- contract JamMonitor actually needs. AuthURL, users, keys, endpoints, DNS
-- suffixes, and the raw status payload never cross the LuCI boundary.
local function project_tailscale_peers(status)
    local peers = {}
    if type(status) ~= "table" or type(status.Peer) ~= "table" then return peers end

    for _, peer in pairs(status.Peer) do
        if type(peer) == "table" and #peers < 256 then
            peers[#peers + 1] = {
                hostname = type(peer.HostName) == "string" and peer.HostName:sub(1, 128) or "Unknown",
                ips = copy_tailscale_ip_list(peer.TailscaleIPs, 4),
                os = type(peer.OS) == "string" and peer.OS:sub(1, 64) or "",
                online = peer.Online == true,
                active = peer.Active == true,
                last_seen = type(peer.LastSeen) == "string" and peer.LastSeen or nil,
                last_handshake = type(peer.LastHandshake) == "string" and peer.LastHandshake or nil,
                key_expiry = type(peer.KeyExpiry) == "string" and peer.KeyExpiry or nil,
                rx_bytes = tonumber(peer.RxBytes) or 0,
                tx_bytes = tonumber(peer.TxBytes) or 0
            }
        end
    end

    table.sort(peers, function(a, b)
        return (a.hostname or ""):lower() < (b.hostname or ""):lower()
    end)
    return peers
end

local function count_table_values(values, limit)
    if type(values) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(values) do
        count = count + 1
        if count >= limit then break end
    end
    return count
end

local function live_tailscale_projection(status)
    local fs = require "nixio.fs"
    local sys = require "luci.sys"
    local pid = tailscaled_pid()
    local installed = fs.stat(TAILSCALE_CLI) ~= nil
    local enabled = false
    local running = false
    if fs.stat("/etc/init.d/tailscale") then
        enabled = sys.call("/etc/init.d/tailscale enabled >/dev/null 2>&1") == 0
        running = sys.call("/etc/init.d/tailscale running >/dev/null 2>&1") == 0
    end

    local backend = type(status) == "table" and status.BackendState or nil
    local self_status = type(status) == "table" and status.Self or nil
    local ips = type(self_status) == "table" and
        copy_tailscale_ip_list(self_status.TailscaleIPs, 4) or {}
    local health_warnings = type(status) == "table" and count_table_values(status.Health, 100) or 0
    local control_online = type(self_status) == "table" and self_status.Online or nil
    if type(control_online) ~= "boolean" then control_online = nil end
    local key_expiry = type(self_status) == "table" and self_status.KeyExpiry or nil
    if type(key_expiry) ~= "string" or #key_expiry > 64 then key_expiry = nil end
    local tun_available = type(status) == "table" and status.TUN or nil
    if type(tun_available) ~= "boolean" then tun_available = nil end
    local in_engine = type(self_status) == "table" and self_status.InEngine or nil
    if type(in_engine) ~= "boolean" then in_engine = nil end
    local state
    local reason
    local connected = false
    local degraded = false
    local process_generation, process_uptime_seconds =
        tailscaled_process_identity(pid)
    local has_delivery = backend == "Running" and #ips > 0 and
        tun_available == true and in_engine == true

    if not installed then
        state, reason = "not_installed", "cli_missing"
    elseif not enabled then
        state, reason = "disabled", "service_disabled"
    elseif not running then
        state, reason = "daemon_missing", "supervisor_inactive"
    elseif backend == "Running" then
        if #ips == 0 then
            state, reason = "running_degraded", "tailnet_ip_missing"
            degraded = true
        elseif tun_available == false then
            state, reason = "running_degraded", "tun_unavailable"
            degraded = true
        elseif tun_available ~= true then
            state, reason = "running_degraded", "tun_state_unknown"
            degraded = true
        elseif in_engine == false then
            state, reason = "running_degraded", "engine_inactive"
            degraded = true
        elseif in_engine ~= true then
            state, reason = "running_degraded", "engine_state_unknown"
            degraded = true
        elseif control_online == false then
            state, reason = "running_degraded", "control_offline"
            connected, degraded = true, true
        elseif control_online ~= true then
            state, reason = "running_degraded", "control_state_unknown"
            connected, degraded = true, true
        elseif health_warnings > 0 then
            state, reason = "running_degraded", "health_warning"
            connected, degraded = true, true
        elseif not process_generation or
               type(process_uptime_seconds) ~= "number" then
            state, reason = "running_degraded", "process_generation_unknown"
            connected, degraded = true, true
        else
            state, reason = "running", "ok"
            connected = true
        end
    elseif backend == "NeedsLogin" then
        state, reason = "needs_login", "authentication_required"
        connected = false
    elseif backend == "NeedsMachineAuth" then
        state, reason = "needs_machine_auth", "approval_required"
        connected = false
    elseif backend == "Stopped" then
        state, reason = "stopped", "administratively_stopped"
        connected = false
    elseif backend == "Starting" or backend == "NoState" or backend == "InUseOtherUser" then
        state, reason = "starting", "backend_not_ready"
        connected = false
    elseif status == nil then
        state, reason = "daemon_unresponsive", "localapi_error"
    else
        state, reason = "unsupported_backend", "backend_state_unknown"
        connected = false
    end

    return {
        schema = 2,
        observed_at = os.time(),
        status = state,
        reason = reason,
        healthy = state == "running",
        connected = connected,
        degraded = degraded,
        local_api_responsive = status ~= nil,
        control_online = control_online,
        installed = installed,
        service_enabled = enabled,
        service_running = running,
        process_generation = process_generation,
        process_uptime_seconds = process_uptime_seconds,
        backend_state = backend,
        tailscale_ips = ips,
        key_expiry = key_expiry,
        tun_available = tun_available,
        in_engine = in_engine,
        health_warnings = health_warnings,
        condition_since_at = os.time(),
        condition_uptime_seconds = 0,
        connected_since_at = connected == true and os.time() or 0,
        connectivity_uptime_seconds = connected == true and 0 or nil,
        last_connected_at = connected == true and os.time() or 0,
        recoverable = false,
        consecutive_failures = 0,
        recovery_attempted = 0,
        recovery_state = "none",
        recovery_count = 0,
        valid_response_streak = status ~= nil and 1 or 0,
        peer_configured = false,
        peer_state = "unknown",
        peer_reachable = nil,
        peer_last_success_at = 0,
        watchdog_active = false,
        source = "live"
    }
end

local WATCHDOG_FIELDS = {
    "schema", "observed_at", "monotonic_seconds", "status", "reason",
    "healthy", "connected", "degraded", "local_api_responsive",
    "installed", "service_enabled", "service_running", "control_online",
    "process_generation",
    "process_uptime_seconds", "backend_state",
    "key_expiry", "tun_available", "in_engine", "health_warnings",
    "condition_since_at", "condition_uptime_seconds", "connected_since_at",
    "connectivity_uptime_seconds", "last_connected_at", "recoverable",
    "consecutive_failures", "recovery_attempted", "recovery_state",
    "recovery_count", "valid_response_streak", "peer_configured",
    "peer_state", "peer_reachable", "peer_last_success_at",
    "maintenance_state", "maintenance_expires_at"
}

local WATCHDOG_STATES = {
    running = true,
    running_degraded = true,
    needs_login = true,
    needs_machine_auth = true,
    stopped = true,
    starting = true,
    unsupported_backend = true,
    not_installed = true,
    watchdog_error = true,
    disabled = true,
    maintenance = true,
    daemon_missing = true,
    socket_missing = true,
    daemon_unresponsive = true
}

local WATCHDOG_MAINTENANCE_STATES = {
    none = true,
    active = true,
    expired = true,
    malformed = true,
    out_of_bounds = true
}

local function watchdog_snapshot_is_valid(parsed)
    if type(parsed) ~= "table" or tonumber(parsed.schema) ~= 2 or
       type(parsed.status) ~= "string" or
       not WATCHDOG_STATES[parsed.status] then
        return false
    end
    if not WATCHDOG_MAINTENANCE_STATES[parsed.maintenance_state] then
        return false
    end
    local observed_at = tonumber(parsed.observed_at)
    local maintenance_expiry = tonumber(parsed.maintenance_expires_at)
    if parsed.maintenance_state == "active" then
        if parsed.status ~= "maintenance" or not observed_at or
           not maintenance_expiry or maintenance_expiry <= observed_at or
           maintenance_expiry > observed_at + 3600 then
            return false
        end
    elseif parsed.status == "maintenance" then
        return false
    end
    if type(parsed.healthy) ~= "boolean" or
       type(parsed.degraded) ~= "boolean" or
       (parsed.connected ~= nil and type(parsed.connected) ~= "boolean") or
       (parsed.control_online ~= nil and
        type(parsed.control_online) ~= "boolean") or
       (parsed.local_api_responsive ~= nil and
        type(parsed.local_api_responsive) ~= "boolean") then
        return false
    end
    if parsed.process_generation ~= nil then
        if type(parsed.process_generation) ~= "string" or
           #parsed.process_generation > 64 or
           not parsed.process_generation:match("^%d+:%d+$") or
           type(parsed.process_uptime_seconds) ~= "number" or
           parsed.process_uptime_seconds < 0 or
           parsed.process_uptime_seconds ~= math.floor(parsed.process_uptime_seconds) then
            return false
        end
    elseif parsed.process_uptime_seconds ~= nil then
        -- Uptime without a PID/start-tick generation can be accidentally
        -- rebound to a replacement process and is therefore not authoritative.
        return false
    end

    local has_delivery = parsed.backend_state == "Running" and
        parsed.tun_available == true and
        parsed.in_engine == true and
        is_tailscale_ip(parsed.tailscale_ip)
    if parsed.connected == true and not has_delivery then
        return false
    end
    if parsed.healthy == true and
       (parsed.status ~= "running" or parsed.connected ~= true or
        parsed.control_online ~= true or
        parsed.local_api_responsive ~= true or
        parsed.service_running ~= true or
        parsed.service_enabled ~= true or
        type(parsed.process_generation) ~= "string" or
        type(parsed.process_uptime_seconds) ~= "number" or
        not has_delivery) then
        return false
    end
    if parsed.status == "running" and parsed.healthy ~= true then
        return false
    end
    if parsed.peer_configured == true and parsed.peer_reachable == false and
       parsed.healthy == true then
        return false
    end
    return true
end

local function project_watchdog_snapshot(parsed)
    local projected = {}
    for _, field in ipairs(WATCHDOG_FIELDS) do
        projected[field] = parsed[field]
    end
    projected.tailscale_ips = {}
    if is_tailscale_ip(parsed.tailscale_ip) then
        projected.tailscale_ips[1] = parsed.tailscale_ip
    end
    projected.watchdog_active = true
    projected.source = "watchdog"
    return projected
end

local function get_tailscale_projection(include_live_peers)
    local fs = require "nixio.fs"
    local json = require "luci.jsonc"
    local cached = fs.readfile(TAILSCALE_WATCHDOG_STATUS)

    if cached and cached ~= "" then
        local parsed = json.parse(cached)
        local observed = type(parsed) == "table" and tonumber(parsed.observed_at) or nil
        if observed and observed <= os.time() + 5 and os.time() - observed <= 45 and
           watchdog_snapshot_is_valid(parsed) then
            return project_watchdog_snapshot(parsed), nil
        end
    end

    local live = query_tailscale_status(include_live_peers == true)
    return live_tailscale_projection(live), live
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
            local safe_wg = validate_iface(wg_iface)
            if safe_wg then
                local wg_addr = sys.exec("ip addr show dev " .. safe_wg .. " 2>/dev/null | grep -oE 'inet [0-9.]+' | cut -d' ' -f2") or ""
                result.wireguard.ip = wg_addr:gsub("%s+$", "")
            end
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
        local output = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
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
    result.conntrack = sys.exec("timeout 1 conntrack -L 2>/dev/null | head -500") or ""

    -- Tailscale service state and peers. Prefer the independent watchdog
    -- snapshot; query peers only while the local backend is actually running.
    local ts_projection, ts_live = get_tailscale_projection(true)
    result.tailscale_status = ts_projection
    if ts_projection.backend_state == "Running" then
        -- The status-only watchdog snapshot intentionally has no peer map.
        -- Fetch peers separately, still behind the same three-second bound,
        -- and project only the fields the client table needs.
        if not ts_live then
            ts_live = query_tailscale_status(true)
        end
        if type(ts_live) == "table" and ts_live.BackendState == "Running" then
            result.tailscale_peers = project_tailscale_peers(ts_live)
        end
    end

    http.write(json.stringify(result))
end

function action_tailscale_status()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local result = get_tailscale_projection()

    http.prepare_content("application/json")
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

    if alias == nil then alias = "" end
    if dtype == nil then dtype = "" end
    if type(alias) ~= "string" or #alias > 64 or alias:find("%c") then
        http.write(json.stringify({error = "Alias must be 64 printable characters or fewer"}))
        return
    end
    if dtype ~= "" and not VALID_DEVICE_TYPES[dtype] then
        http.write(json.stringify({error = "Invalid device type"}))
        return
    end

    local lock_path = "/tmp/jammonitor-client-meta.lock"
    if not acquire_lock_dir(lock_path, 30) then
        http.write(json.stringify({error = "Client metadata update is busy"}))
        return
    end

    local ok, response = pcall(function()
        -- The lock covers the full read-modify-write transaction.
        local content = fs.readfile(CLIENT_META_FILE) or "{}"
        if #content > MAX_JSON_BODY then
            return {error = "Client metadata is invalid"}
        end
        local meta = json.parse(content)
        if type(meta) ~= "table" then
            return {error = "Client metadata is invalid"}
        end

        if type(meta[mac]) ~= "table" then meta[mac] = {} end
        if alias ~= "" then
            meta[mac].alias = alias
        else
            meta[mac].alias = nil
        end
        if dtype ~= "" then
            meta[mac].type = dtype
        else
            meta[mac].type = nil
        end

        if not atomic_write(CLIENT_META_FILE, json.stringify(meta)) then
            return {error = "Failed to write metadata"}
        end
        return {success = true}
    end)
    release_lock_dir(lock_path)
    if not ok then
        response = {error = "Client metadata update failed"}
    end
    http.write(json.stringify(response))
end

-- DHCP Reservations
local function dnsmasq_running()
    return checked_init_action("/etc/init.d/dnsmasq", "running", 5)
end

local function restore_dhcp_transaction(snapshot, was_running)
    local restored = restore_uci_snapshot("dhcp", snapshot)
    if was_running then
        restored = checked_init_action(
            "/etc/init.d/dnsmasq", "restart", 30
        ) and restored
        restored = dnsmasq_running() and restored
    else
        if dnsmasq_running() then
            restored = checked_init_action(
                "/etc/init.d/dnsmasq", "stop", 30
            ) and restored
        end
        restored = not dnsmasq_running() and restored
    end
    return restored
end

local function apply_dnsmasq_after_commit(was_running)
    if not was_running then return not dnsmasq_running() end
    return checked_init_action(
        "/etc/init.d/dnsmasq", "reload", 30
    ) and dnsmasq_running()
end

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
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local mac = http.formvalue("mac")
    local ip = http.formvalue("ip")
    local name = http.formvalue("name")

    if not mac or mac == "" or not ip or ip == "" then
        http.write(json.stringify({error = "MAC and IP required"}))
        return
    end

    mac = mac:lower()

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
    local safe_name = validate_hostname(name or "")
    if safe_name == nil then
        http.write(json.stringify({error = "Invalid hostname"}))
        return
    end

    if not fs.stat("/etc/init.d/dnsmasq") then
        http.write(json.stringify({success = false, error = "dnsmasq service is unavailable"}))
        return
    end

    local response, lock_error = run_locked(
        DHCP_MUTATION_LOCK, 120, "Another DHCP update is already running",
        function()
            local snapshot = snapshot_file("/etc/config/dhcp")
            if not snapshot then
                return {success = false, error = "Cannot snapshot DHCP configuration"}
            end
            local was_running = dnsmasq_running()
            local current = require "luci.model.uci".cursor()
            local section_name = "jm_" .. mac:gsub(":", ""):lower()
            local remove_sections = {}
            local conflict = false
            current:foreach("dhcp", "host", function(section)
                local section_mac = type(section.mac) == "string" and
                    section.mac:lower() or nil
                if section.ip == ip and section_mac ~= mac then
                    conflict = true
                end
                if section_mac == mac and section[".name"] ~= section_name then
                    remove_sections[#remove_sections + 1] = section[".name"]
                end
            end)
            if conflict then
                return {
                    success = false,
                    error = "IP address is already reserved for another client"
                }
            end

            for _, section in ipairs(remove_sections) do
                current:delete("dhcp", section)
            end
            local staged =
                current:set("dhcp", section_name, "host") and
                current:set("dhcp", section_name, "mac", mac) and
                current:set("dhcp", section_name, "ip", ip)
            if safe_name ~= "" then
                staged = current:set(
                    "dhcp", section_name, "name", safe_name
                ) and staged
            else
                current:delete("dhcp", section_name, "name")
            end
            if not staged then
                current:revert("dhcp")
                return {success = false, error = "Could not stage DHCP reservation"}
            end

            local committed = current:commit("dhcp")
            local verify = require "luci.model.uci".cursor()
            local verified = committed == true and
                verify:get("dhcp", section_name) == "host" and
                verify:get("dhcp", section_name, "mac") == mac and
                verify:get("dhcp", section_name, "ip") == ip and
                verify:get("dhcp", section_name, "name") ==
                    (safe_name ~= "" and safe_name or nil)
            local same_mac = 0
            verify:foreach("dhcp", "host", function(section)
                if type(section.mac) == "string" and
                   section.mac:lower() == mac then
                    same_mac = same_mac + 1
                end
            end)
            verified = verified and same_mac == 1
            if verified then
                verified = apply_dnsmasq_after_commit(was_running)
            end
            if not verified then
                local restored = restore_dhcp_transaction(snapshot, was_running)
                return {
                    success = false,
                    error = restored and
                        "DHCP update failed and was rolled back" or
                        "DHCP update failed and rollback was incomplete"
                }
            end
            return {success = true}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

function action_delete_reservation()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local mac = http.formvalue("mac")
    if not mac or mac == "" then
        http.write(json.stringify({error = "MAC address required"}))
        return
    end

    mac = mac:lower()
    if not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        http.write(json.stringify({error = "Invalid MAC address format"}))
        return
    end
    if not fs.stat("/etc/init.d/dnsmasq") then
        http.write(json.stringify({success = false, error = "dnsmasq service is unavailable"}))
        return
    end

    local response, lock_error = run_locked(
        DHCP_MUTATION_LOCK, 120, "Another DHCP update is already running",
        function()
            local snapshot = snapshot_file("/etc/config/dhcp")
            if not snapshot then
                return {success = false, error = "Cannot snapshot DHCP configuration"}
            end
            local was_running = dnsmasq_running()
            local current = require "luci.model.uci".cursor()
            local sections = {}
            current:foreach("dhcp", "host", function(section)
                if type(section.mac) == "string" and
                   section.mac:lower() == mac then
                    sections[#sections + 1] = section[".name"]
                end
            end)
            if #sections == 0 then
                return {success = false, error = "Reservation not found"}
            end
            for _, section in ipairs(sections) do
                current:delete("dhcp", section)
            end
            local committed = current:commit("dhcp")
            local verify = require "luci.model.uci".cursor()
            local remaining = 0
            verify:foreach("dhcp", "host", function(section)
                if type(section.mac) == "string" and
                   section.mac:lower() == mac then
                    remaining = remaining + 1
                end
            end)
            local verified = committed == true and remaining == 0
            if verified then
                verified = apply_dnsmasq_after_commit(was_running)
            end
            if not verified then
                local restored = restore_dhcp_transaction(snapshot, was_running)
                return {
                    success = false,
                    error = restored and
                        "DHCP delete failed and was rolled back" or
                        "DHCP delete failed and rollback was incomplete"
                }
            end
            return {success = true}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
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

-- Production updates require the pinned transactional SSH installer. LuCI
-- has no independent trust root for a manifest digest, so it must not fetch a
-- moving branch and overwrite only part of the deployment.
function action_update_start()
    local http = require "luci.http"
    local json = require "luci.jsonc"

    http.prepare_content("application/json")
    http.write(json.stringify({
        ok = false,
        manual_update_required = true,
        error = "Use the verified pinned router installer over SSH"
    }))
end

-- Legacy read-only status endpoint. New update jobs cannot be created.
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

local function mounted_filesystem_at(path)
    local fs = require "nixio.fs"
    local mounts = fs.readfile("/proc/mounts") or ""
    for line in mounts:gmatch("[^\n]+") do
        local source, target, fstype, options =
            line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if target == path then
            return {
                source = source,
                fstype = fstype,
                options = options,
                persistent = fstype ~= "overlay" and fstype ~= "tmpfs",
                writable = options and
                    ("," .. options .. ","):find(",rw,", 1, true) ~= nil
            }
        end
    end
    return nil
end

local function collector_service_path()
    local fs = require "nixio.fs"
    if fs.stat("/etc/init.d/jammonitor-history") then
        return "/etc/init.d/jammonitor-history", "jammonitor-history"
    end
    if fs.stat("/etc/init.d/jammonitor-collect") then
        return "/etc/init.d/jammonitor-collect", "jammonitor-collect"
    end
    return nil, nil
end

local STORAGE_LOCK = "/tmp/jammonitor-storage.lock"
local FSTAB_CONFIG = "/etc/config/fstab"

local function storage_partition_identity(device)
    if type(device) ~= "string" then return nil end
    local disk, partition = device:match("^/dev/(sd[a-z])(%d+)$")
    if not disk or not partition or tonumber(partition) == 0 then return nil end

    local fs = require "nixio.fs"
    local stat = fs.stat(device)
    if not stat or (stat.type and stat.type ~= "blk") then return nil end
    local kernel_name = disk .. partition
    local kernel_id = (fs.readfile(
        "/sys/class/block/" .. kernel_name .. "/dev"
    ) or ""):match("^%s*(%d+:%d+)%s*$")
    local reported_partition = (fs.readfile(
        "/sys/class/block/" .. kernel_name .. "/partition"
    ) or ""):match("^%s*(%d+)%s*$")
    if not kernel_id or reported_partition ~= partition then return nil end
    local removable = (fs.readfile("/sys/class/block/" .. disk .. "/removable") or "")
        :match("^%s*(%d)")
    if removable ~= "1" then return nil end
    return {
        path = device,
        disk = disk,
        partition = partition,
        kernel_id = kernel_id
    }
end

local function source_uses_disk(source, disk)
    return type(source) == "string" and
        source:match("^/dev/" .. disk .. "%d*$") ~= nil
end

local function storage_partition_is_system(identity)
    if not identity then return true end
    local fs = require "nixio.fs"
    local mounts = fs.readfile("/proc/mounts") or ""
    local protected = {
        ["/"] = true, ["/rom"] = true, ["/overlay"] = true,
        ["/boot"] = true, ["/boot/efi"] = true, ["/usr"] = true
    }
    for line in mounts:gmatch("[^\n]+") do
        local source, target = line:match("^(%S+)%s+(%S+)")
        if protected[target] and source_uses_disk(source, identity.disk) then
            return true
        end
    end
    return false
end

local function exact_mount_for_source(source)
    local fs = require "nixio.fs"
    local mounts = fs.readfile("/proc/mounts") or ""
    local found
    for line in mounts:gmatch("[^\n]+") do
        local mount_source, target, fstype, options =
            line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mount_source == source then
            if found then return nil, "Device is mounted more than once" end
            found = {
                source = mount_source,
                target = target,
                fstype = fstype,
                options = options
            }
        end
    end
    return found
end

local function collector_runtime_state()
    local path, name = collector_service_path()
    if not path then return {path = nil, name = nil, running = false} end
    return {
        path = path,
        name = name,
        running = checked_init_action(path, "running", 5)
    }
end

local function stop_collector_checked(state)
    if not state or not state.path or not state.running then return true end
    return checked_init_action(state.path, "stop", 30) and
        not checked_init_action(state.path, "running", 5)
end

local function restore_collector_runtime(state)
    if not state or not state.path or not state.running then return true end
    return checked_init_action(state.path, "start", 30) and
        checked_init_action(state.path, "running", 5)
end

local function unmount_exact(target)
    local before = mounted_filesystem_at(target)
    if not before then return true end
    if not checked_call("timeout 30 umount " .. target) then return false end
    return mounted_filesystem_at(target) == nil
end

local function mount_exact(source, target)
    if not checked_call(
        "timeout 30 mount -t ext4 -o rw " .. source .. " " .. target
    ) then
        return false
    end
    local mount = mounted_filesystem_at(target)
    return mount ~= nil and mount.source == source and mount.fstype == "ext4" and
        mount.writable == true
end

local function restore_mount(mount)
    if not mount then return true end
    if mounted_filesystem_at(mount.target) then return false end
    if type(mount.target) ~= "string" or
       not mount.target:match("^/[A-Za-z0-9_./%-]+$") or
       not storage_partition_identity(mount.source) then
        return false
    end
    local options = type(mount.options) == "string" and
        mount.options:match("^[A-Za-z0-9_,=%.%-]+$") and mount.options or "rw"
    local fstype = type(mount.fstype) == "string" and
        mount.fstype:match("^[A-Za-z0-9_.%-]+$") and mount.fstype or "ext4"
    local restored = checked_call(
        "timeout 30 mount -t " .. fstype .. " -o " .. options .. " " ..
        mount.source .. " " .. mount.target
    )
    local actual = restored and mounted_filesystem_at(mount.target) or nil
    return actual ~= nil and actual.source == mount.source and
        actual.fstype == mount.fstype and
        actual.writable == (
            ("," .. (mount.options or "") .. ","):find(",rw,", 1, true) ~= nil
        )
end

local function storage_uuid(device)
    local ok, output = checked_capture(
        "timeout 5 blkid -s UUID -o value " .. device
    )
    if not ok then return nil end
    local uuid = output:match("^%s*([A-Fa-f0-9%-]+)%s*$")
    if not uuid or #uuid < 8 or #uuid > 64 then return nil end
    return uuid
end

local function persist_storage_mount(uuid)
    local uci = require "luci.model.uci".cursor()
    local conflicting_sections = {}
    uci:foreach("fstab", "mount", function(section)
        if section[".name"] ~= "jammonitor" and
           section.target == "/mnt/data" then
            conflicting_sections[#conflicting_sections + 1] =
                section[".name"]
        end
    end)
    for _, section_name in ipairs(conflicting_sections) do
        uci:delete("fstab", section_name)
    end
    uci:delete("fstab", "jammonitor", "device")
    uci:delete("fstab", "jammonitor", "label")
    if not uci:set("fstab", "jammonitor", "mount") or
       not uci:set("fstab", "jammonitor", "target", "/mnt/data") or
       not uci:set("fstab", "jammonitor", "uuid", uuid) or
       not uci:set("fstab", "jammonitor", "fstype", "ext4") or
       not uci:set("fstab", "jammonitor", "options", "rw,noatime") or
       not uci:set("fstab", "jammonitor", "enabled", "1") or
       not uci:commit("fstab") then
        uci:revert("fstab")
        return false
    end
    local verify = require "luci.model.uci".cursor()
    local verified = verify:get("fstab", "jammonitor") == "mount" and
        verify:get("fstab", "jammonitor", "target") == "/mnt/data" and
        verify:get("fstab", "jammonitor", "uuid") == uuid and
        verify:get("fstab", "jammonitor", "fstype") == "ext4" and
        verify:get("fstab", "jammonitor", "options") == "rw,noatime" and
        verify:get("fstab", "jammonitor", "enabled") == "1" and
        verify:get("fstab", "jammonitor", "device") == nil and
        verify:get("fstab", "jammonitor", "label") == nil
    verify:foreach("fstab", "mount", function(section)
        if section[".name"] ~= "jammonitor" and
           section.target == "/mnt/data" then
            verified = false
        end
    end)
    return verified
end

-- Storage status proves current sample freshness, SQLite health, and the
-- mounted filesystem rather than equating an old DB plus a PID with health.
function action_storage_status()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local db_path = "/mnt/data/jammonitor/history.db"
    local collector_status_path = "/var/run/jammonitor/collector-status.json"
    local mount = mounted_filesystem_at("/mnt/data")
    local collector_service, collector_service_name = collector_service_path()

    local result = {
        mounted = mount ~= nil and mount.persistent,
        mount_source = mount and mount.source or nil,
        mount_fstype = mount and mount.fstype or nil,
        mount_writable = mount ~= nil and mount.writable,
        collector_running = false,
        collector_service = collector_service_name,
        database_exists = false,
        database_healthy = false,
        sample_fresh = false,
        free_space = nil,
        entry_count = 0,
        oldest_ts = nil,
        newest_ts = nil,
        sample_age_secs = nil,
        recent_anomalies = 0
    }

    -- Prefer procd's own service state, with a process check for legacy installs.
    if collector_service then
        result.collector_running =
            sys.call(collector_service .. " running >/dev/null 2>&1") == 0
    else
        local pgrep = sys.exec("pgrep -f '[j]ammonitor-collect' 2>/dev/null") or ""
        result.collector_running = pgrep:match("%d+") ~= nil
    end

    local collector_raw = fs.readfile(collector_status_path)
    if collector_raw and collector_raw ~= "" then
        local collector = json.parse(collector_raw)
        local observed = type(collector) == "table" and tonumber(collector.observed_at) or nil
        if observed and observed <= os.time() + 5 and os.time() - observed <= 180 then
            result.collector_report_fresh = true
            result.collector_report_healthy = collector.healthy == true
            result.collector_write_failures = tonumber(collector.consecutive_write_failures) or 0
            result.collector_last_success_at = tonumber(collector.last_success_at)
        else
            result.collector_report_fresh = false
            result.collector_report_healthy = false
        end
    end

    -- Check if database exists
    local db_stat = fs.stat(db_path)
    result.database_exists = db_stat ~= nil
    if db_stat then
        result.database_size = db_stat.size

        -- Get entry count and date range
        local quick = sys.exec("timeout 5 sqlite3 '" .. db_path .. "' 'PRAGMA quick_check' 2>/dev/null") or ""
        result.database_quick_check = quick:match("^([^\r\n]+)")
        result.database_healthy = result.database_quick_check == "ok"

        local count = sys.exec("timeout 5 sqlite3 '" .. db_path .. "' 'SELECT COUNT(*) FROM metrics' 2>/dev/null") or ""
        result.entry_count = tonumber(count:match("%d+")) or 0

        local oldest = sys.exec("timeout 5 sqlite3 '" .. db_path .. "' 'SELECT MIN(ts) FROM metrics' 2>/dev/null") or ""
        result.oldest_ts = tonumber(oldest:match("%d+"))

        local newest = sys.exec("timeout 5 sqlite3 '" .. db_path .. "' 'SELECT MAX(ts) FROM metrics' 2>/dev/null") or ""
        result.newest_ts = tonumber(newest:match("%d+"))
        if result.newest_ts then
            result.sample_age_secs = math.max(0, os.time() - result.newest_ts)
            result.sample_fresh = result.sample_age_secs <= 180
        end

        -- Count recent anomalies (last 24h): packet loss (-1 ping) or interface down
        local cutoff = os.time() - 86400
        local anomaly_query = string.format(
            "SELECT COUNT(*) FROM metrics WHERE ts > %d AND (wan_pings LIKE '%%:-1%%' OR wan_pings LIKE '%%:null%%' OR iface_status LIKE '%%wan1\":0%%')",
            cutoff
        )
        local anomalies = sys.exec("timeout 5 sqlite3 '" .. db_path .. "' \"" .. anomaly_query .. "\" 2>/dev/null") or ""
        result.recent_anomalies = tonumber(anomalies:match("%d+")) or 0
    end

    -- Get free space
    if result.mounted then
        local df = sys.exec("timeout 5 df /mnt/data 2>/dev/null | tail -1") or ""
        local available = df:match("%s+%d+%s+%d+%s+(%d+)")
        result.free_space = tonumber(available)
    end

    result.healthy = result.mounted and result.mount_writable and
        result.collector_running and result.database_healthy and
        result.sample_fresh and result.collector_report_fresh == true and
        result.collector_report_healthy == true

    http.write(json.stringify(result))
end

-- Helper: accept only a real partition on a kernel-marked removable sd disk.
-- Whole-disk targets are intentionally excluded because formatting /dev/sda
-- while /dev/sda1 remains mounted is destructive even if `umount /dev/sda`
-- reports failure.
local function validate_device_path(path)
    local identity = storage_partition_identity(path)
    return identity and identity.path or nil
end

-- Helper: Check if device is system root
local function is_system_device(device)
    return storage_partition_is_system(storage_partition_identity(device))
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
    local current = mounted_filesystem_at("/mnt/data")
    result.current_mount = current and current.source or nil

    -- Read /proc/partitions to find block devices
    local partitions = fs.readfile("/proc/partitions") or ""
    local devices = {}

    for line in partitions:gmatch("[^\n]+") do
        -- Match sd* devices (USB drives)
        local major, minor, blocks, name = line:match(
            "%s*(%d+)%s+(%d+)%s+(%d+)%s+(sd[a-z]%d+)%s*$"
        )
        if name and blocks then
            local dev_path = "/dev/" .. name
            local is_partition = name:match("^sd[a-z]%d+$")

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
    local json = require "luci.jsonc"

    http.prepare_content("application/json")

    local params, parse_error = parse_json_request(http, json)
    if not params or not has_only_keys(params, {
        device = true, label = true, confirm = true
    }) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end
    if params.confirm ~= "FORMAT" then
        http.write(json.stringify({success = false, error = "Format confirmation required"}))
        return
    end
    local device = params.device
    local label = params.label
    if label == nil or label == "" then
        label = "JAMMONITOR"
    else
        label = validate_label(label)
        if not label then
            http.write(json.stringify({success = false, error = "Invalid filesystem label"}))
            return
        end
    end

    local identity = storage_partition_identity(device)
    if not identity then
        http.write(json.stringify({success = false, error = "Invalid device path"}))
        return
    end

    if storage_partition_is_system(identity) then
        http.write(json.stringify({success = false, error = "Cannot format system device"}))
        return
    end

    local response, lock_error = run_locked(
        STORAGE_LOCK, 600, "Another storage operation is already running",
        function()
            -- Device identity and system-disk exclusion are checked again under
            -- the shared lease so hotplug cannot substitute a target between
            -- request validation and the destructive command.
            local current_identity = storage_partition_identity(device)
            if not current_identity or
               current_identity.kernel_id ~= identity.kernel_id or
               current_identity.partition ~= identity.partition or
               storage_partition_is_system(current_identity) then
                return {success = false, error = "Storage device changed before format"}
            end

            local original_mount, mount_error = exact_mount_for_source(device)
            if mount_error then
                return {success = false, error = mount_error}
            end
            local collector = collector_runtime_state()
            local collector_stopped = false
            if original_mount and original_mount.target == "/mnt/data" and
               collector.running then
                if not stop_collector_checked(collector) then
                    return {success = false, error = "Could not stop history collector"}
                end
                collector_stopped = true
            end

            if original_mount then
                if not checked_call("timeout 30 umount " .. device) or
                   exact_mount_for_source(device) ~= nil then
                    if collector_stopped then restore_collector_runtime(collector) end
                    return {success = false, error = "Device is still mounted; format aborted"}
                end
            end

            local format_ok = checked_capture(
                "timeout 180 mkfs.ext4 -F -L " .. label .. " " .. device
            )
            if not format_ok then
                -- Once mkfs has started, prior data cannot be reconstructed.
                -- Never claim rollback or remount a partially rewritten volume.
                return {success = false, error = "Format command failed; device left unmounted"}
            end

            local type_ok, fs_type = checked_capture(
                "timeout 5 blkid -s TYPE -o value " .. device
            )
            if not type_ok or not fs_type:match("^%s*ext4%s*$") then
                return {success = false, error = "Formatted filesystem could not be verified"}
            end
            return {success = true, device = device, filesystem = "ext4"}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- Mount a USB drive partition at /mnt/data
function action_storage_mount()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local params, parse_error = parse_json_request(http, json)
    if not params or not has_only_keys(params, {device = true}) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end
    local device = params.device

    local identity = storage_partition_identity(device)
    if not identity or storage_partition_is_system(identity) then
        http.write(json.stringify({success = false, error = "Invalid device path"}))
        return
    end

    local response, lock_error = run_locked(
        STORAGE_LOCK, 600, "Another storage operation is already running",
        function()
            local current_identity = storage_partition_identity(device)
            if not current_identity or
               current_identity.kernel_id ~= identity.kernel_id or
               current_identity.partition ~= identity.partition or
               storage_partition_is_system(current_identity) then
                return {success = false, error = "Storage device changed before mount"}
            end
            if not fs.stat("/mnt/data") and
               not checked_call("mkdir -p /mnt/data") then
                return {success = false, error = "Cannot create mount point"}
            end

            local fstab_snapshot = snapshot_file(FSTAB_CONFIG)
            if not fstab_snapshot then
                return {success = false, error = "Cannot snapshot persistent mount configuration"}
            end
            local old_mount = mounted_filesystem_at("/mnt/data")
            local requested_mount, requested_mount_error =
                exact_mount_for_source(device)
            if requested_mount_error then
                return {success = false, error = requested_mount_error}
            end
            if requested_mount and requested_mount.target ~= "/mnt/data" then
                return {
                    success = false,
                    error = "Requested device is already mounted elsewhere"
                }
            end
            if old_mount and old_mount.source ~= device and
               not storage_partition_identity(old_mount.source) then
                return {
                    success = false,
                    error = "Existing data mount cannot be safely restored"
                }
            end
            local collector = collector_runtime_state()
            local collector_stopped = false

            if (not old_mount or old_mount.source ~= device) and
               collector.running then
                if not stop_collector_checked(collector) then
                    return {success = false, error = "Could not stop history collector"}
                end
                collector_stopped = true
            end

            local function rollback_mount()
                local rollback_ok = true
                local current = mounted_filesystem_at("/mnt/data")
                if current and (not old_mount or current.source ~= old_mount.source) then
                    rollback_ok = unmount_exact("/mnt/data") and rollback_ok
                end
                if old_mount and not mounted_filesystem_at("/mnt/data") then
                    rollback_ok = restore_mount(old_mount) and rollback_ok
                end
                rollback_ok = restore_uci_snapshot("fstab", fstab_snapshot) and rollback_ok
                if collector_stopped then
                    rollback_ok = restore_collector_runtime(collector) and rollback_ok
                end
                return rollback_ok
            end

            if old_mount and old_mount.source ~= device and
               not unmount_exact("/mnt/data") then
                if collector_stopped then restore_collector_runtime(collector) end
                return {success = false, error = "Existing data mount is busy"}
            end

            local mounted = mounted_filesystem_at("/mnt/data")
            if not mounted then
                if not mount_exact(device, "/mnt/data") then
                    local restored = rollback_mount()
                    return {
                        success = false,
                        error = restored and "Requested device could not be mounted" or
                            "Mount failed and prior storage could not be fully restored"
                    }
                end
            elseif mounted.source ~= device or mounted.fstype ~= "ext4" or
                   mounted.writable ~= true then
                local restored = rollback_mount()
                return {
                    success = false,
                    error = restored and "Requested device is not the active ext4 mount" or
                        "Mount conflict and rollback failed"
                }
            end

            local uuid = storage_uuid(device)
            if not uuid or not persist_storage_mount(uuid) then
                local restored = rollback_mount()
                return {
                    success = false,
                    error = restored and "Persistent mount configuration failed" or
                        "Persistent mount failed and rollback was incomplete"
                }
            end

            local verified = mounted_filesystem_at("/mnt/data")
            if not verified or verified.source ~= device or
               verified.fstype ~= "ext4" or not verified.writable then
                local restored = rollback_mount()
                return {
                    success = false,
                    error = restored and "Mounted device verification failed" or
                        "Mount verification and rollback failed"
                }
            end

            return {
                success = true,
                mount_point = "/mnt/data",
                source = device,
                uuid = uuid,
                persistent = true,
                collector_requires_init = collector_stopped
            }
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- Initialize JamMonitor database and start collector
function action_storage_init()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local params, parse_error = parse_json_request(http, json)
    if not params or not has_only_keys(params, {}) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end

    local response, lock_error = run_locked(
        STORAGE_LOCK, 600, "Another storage operation is already running",
        function()
            local mount = mounted_filesystem_at("/mnt/data")
            local identity = mount and storage_partition_identity(mount.source) or nil
            if not mount or not identity or storage_partition_is_system(identity) or
               mount.fstype ~= "ext4" or not mount.writable then
                return {
                    success = false,
                    error = "Verified removable ext4 storage is not mounted read-write"
                }
            end

            local uuid = storage_uuid(mount.source)
            local fstab_snapshot = snapshot_file(FSTAB_CONFIG)
            if not uuid or not fstab_snapshot or not persist_storage_mount(uuid) then
                if fstab_snapshot then
                    restore_uci_snapshot("fstab", fstab_snapshot)
                end
                return {success = false, error = "Persistent storage configuration is invalid"}
            end

            if not checked_call("mkdir -p /mnt/data/jammonitor") then
                restore_uci_snapshot("fstab", fstab_snapshot)
                return {success = false, error = "Cannot create JamMonitor data directory"}
            end

            local collector_service, collector_service_name = collector_service_path()
            if not collector_service then
                restore_uci_snapshot("fstab", fstab_snapshot)
                return {success = false, error = "JamMonitor history service is not installed"}
            end

            local before_ok, before_text = checked_capture(
                "timeout 5 sqlite3 /mnt/data/jammonitor/history.db " ..
                "'SELECT MAX(ts) FROM metrics'"
            )
            local before_newest = before_ok and
                (tonumber(before_text:match("%d+")) or 0) or 0
            local was_running =
                checked_init_action(collector_service, "running", 5)
            local function rollback_init()
                local restored =
                    restore_uci_snapshot("fstab", fstab_snapshot)
                local running =
                    checked_init_action(collector_service, "running", 5)
                if was_running and not running then
                    restored = checked_init_action(
                        collector_service, "start", 30
                    ) and restored
                    restored = checked_init_action(
                        collector_service, "running", 5
                    ) and restored
                elseif not was_running and running then
                    restored = checked_init_action(
                        collector_service, "stop", 30
                    ) and restored
                    restored = not checked_init_action(
                        collector_service, "running", 5
                    ) and restored
                end
                return restored
            end
            if was_running and
               (not checked_init_action(collector_service, "stop", 30) or
                checked_init_action(collector_service, "running", 5)) then
                local restored = rollback_init()
                return {
                    success = false,
                    error = restored and "Could not quiesce history collector" or
                        "Collector quiesce failed and rollback was incomplete"
                }
            end

            local service_start_at = os.time()
            if not checked_init_action(collector_service, "start", 30) then
                local restored = rollback_init()
                return {
                    success = false,
                    error = restored and "Could not start history collector" or
                        "Collector start failed and rollback was incomplete"
                }
            end

            local result = {
                success = false,
                database_exists = false,
                collector_running = false,
                collector_service = collector_service_name,
                service_start_at = service_start_at,
                mount_source = mount.source,
                mount_uuid = uuid,
                persistent = true
            }

            -- The collector takes an immediate first sample. Poll rather than
            -- assuming one fixed scheduler delay on slower flash media.
            for _ = 1, 10 do
                os.execute("sleep 1")
                result.database_exists =
                    fs.stat("/mnt/data/jammonitor/history.db") ~= nil
                result.collector_running =
                    checked_init_action(collector_service, "running", 5)

                local newest_ok, newest_text = checked_capture(
                    "timeout 5 sqlite3 /mnt/data/jammonitor/history.db " ..
                    "'SELECT MAX(ts) FROM metrics'"
                )
                result.newest_ts = newest_ok and
                    tonumber(newest_text:match("%d+")) or nil
                result.sample_after_start = result.newest_ts ~= nil and
                    result.newest_ts >= service_start_at and
                    result.newest_ts > before_newest

                local collector_raw =
                    fs.readfile("/var/run/jammonitor/collector-status.json")
                local collector =
                    collector_raw and json.parse(collector_raw) or nil
                local report_started_at = type(collector) == "table" and
                    tonumber(collector.started_at) or nil
                local report_last_success = type(collector) == "table" and
                    tonumber(collector.last_success_at) or nil
                local report_observed_at = type(collector) == "table" and
                    tonumber(collector.observed_at) or nil
                result.collector_report_ready =
                    type(collector) == "table" and collector.healthy == true and
                    report_started_at ~= nil and
                    report_started_at >= service_start_at and
                    report_last_success ~= nil and
                    report_last_success >= service_start_at and
                    report_observed_at ~= nil and
                    report_observed_at >= service_start_at and
                    report_observed_at <= os.time() + 5
                result.success = result.database_exists and
                    result.collector_running and result.sample_after_start and
                    result.collector_report_ready
                if result.success then break end
                if not result.collector_running then break end
            end

            if not result.success then
                local restored = rollback_init()
                result.error = restored and
                    "Collector did not produce a fresh verified sample" or
                    "Collector verification failed and rollback was incomplete"
            end
            return result
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
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

-- Apply WAN policy changes. The read endpoint below is deliberately separate
-- so a GET can never reach a mutation branch.
function action_wan_policy_set()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")
    local data, parse_error = parse_json_request(http, json)
    if not data or not has_only_keys(data, {order = true, modes = true}) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end

    local order = data.order
    local modes = data.modes
    local order_length = dense_array_length(order)
    local selected, selected_set, selection_error = selected_wans(uci)
    if not selected then
        http.write(json.stringify({success = false, error = selection_error}))
        return
    end
    if not order_length or order_length == 0 or
       order_length > MAX_WAN_INTERFACES or order_length ~= #selected or
       type(modes) ~= "table" then
        http.write(json.stringify({success = false, error = "Policy must cover the exact selected WAN set"}))
        return
    end

    local seen = {}
    local master_count = 0
    for _, iface in ipairs(order) do
        local mode = modes[iface]
        if type(iface) ~= "string" or not selected_set[iface] or seen[iface] or
           not VALID_MULTIPATH_MODES[mode] then
            http.write(json.stringify({success = false, error = "Invalid WAN policy"}))
            return
        end
        seen[iface] = true
        if mode == "master" then master_count = master_count + 1 end
    end
    for iface, mode in pairs(modes) do
        if type(iface) ~= "string" or not selected_set[iface] or
           not seen[iface] or not VALID_MULTIPATH_MODES[mode] then
            http.write(json.stringify({success = false, error = "Invalid WAN mode map"}))
            return
        end
    end
    if master_count ~= 1 then
        http.write(json.stringify({success = false, error = "Exactly one master WAN is required"}))
        return
    end

    local response, lock_error = run_locked(
        WAN_MUTATION_LOCK, 600, "Another WAN operation is already running",
        function()
            local fs = require "nixio.fs"
            if fs.stat(BYPASS_FLAG) or fs.stat(BYPASS_BUNDLE) then
                return {
                    success = false,
                    error = "WAN policy cannot change while bypass recovery is active"
                }
            end

            local current = require "luci.model.uci".cursor()
            local locked_selected, locked_set = selected_wans(current)
            if not locked_selected or #locked_selected ~= order_length then
                return {success = false, error = "WAN selection changed; reload and retry"}
            end
            for _, iface in ipairs(order) do
                if not locked_set[iface] then
                    return {success = false, error = "WAN selection changed; reload and retry"}
                end
            end

            local snapshot = snapshot_file("/etc/config/network")
            if not snapshot then
                return {success = false, error = "Cannot snapshot network configuration"}
            end
            local changes_made = false
            local master_iface
            local set_ok = true
            for _, iface in ipairs(order) do
                local mode = modes[iface]
                if mode == "master" then master_iface = iface end
                if current:get("network", iface, "multipath") ~= mode then
                    set_ok = current:set("network", iface, "multipath", mode) and set_ok
                    changes_made = true
                end
                local want_disabled = mode == "off"
                local disabled_value =
                    current:get("network", iface, "disabled")
                if want_disabled and disabled_value ~= "1" then
                    set_ok = current:set(
                        "network", iface, "disabled", "1"
                    ) and set_ok
                    changes_made = true
                elseif not want_disabled and disabled_value ~= nil then
                    current:delete("network", iface, "disabled")
                    changes_made = true
                end
            end
            if not set_ok then
                current:revert("network")
                return {success = false, error = "Could not stage WAN policy"}
            end
            if not changes_made then
                return {
                    success = true,
                    master = master_iface,
                    changes_made = false
                }
            end

            local committed = current:commit("network")
            local verify = require "luci.model.uci".cursor()
            local verified = committed == true
            for _, iface in ipairs(order) do
                local mode = modes[iface]
                local expected_disabled = mode == "off" and "1" or nil
                if verify:get("network", iface, "multipath") ~= mode or
                   verify:get("network", iface, "disabled") ~= expected_disabled then
                    verified = false
                end
            end
            if verified then
                verified = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                )
            end
            if not verified then
                local restored = restore_uci_snapshot("network", snapshot)
                restored = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                ) and restored
                return {
                    success = false,
                    error = restored and "WAN policy apply failed and was rolled back" or
                        "WAN policy apply and rollback both failed"
                }
            end
            return {
                success = true,
                master = master_iface,
                changes_made = true
            }
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- WAN Policy read endpoint for drag-and-drop WAN priority management.
function action_wan_policy()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")
    local result = { interfaces = {} }
    local _, selected_set, selection_error = selected_wans(uci)
    if not selected_set then
        http.write(json.stringify({success = false, error = selection_error}))
        return
    end

        -- Get all network interfaces that are WANs
        uci:foreach("network", "interface", function(s)
            local iface_name = s[".name"]

            if selected_set[iface_name] then
                local multipath = VALID_MULTIPATH_MODES[s.multipath] and
                    s.multipath or "off"
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

-- WAN Edit endpoint for editing individual WAN interface settings
function action_wan_edit()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local data, parse_error = parse_json_request(http, json)
    if not data or not has_only_keys(data, {
        iface = true, multipath = true, proto = true, ipaddr = true,
        netmask = true, gateway = true, peerdns = true, dns = true,
        mtu = true
    }) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end

    local iface = data.iface
    local selected, selected_set, selection_error = selected_wans(uci)
    if not selected or type(iface) ~= "string" or not selected_set[iface] then
        http.write(json.stringify({
            success = false,
            error = selection_error or "Interface is not in the selected WAN set"
        }))
        return
    end

    if data.multipath ~= nil and not VALID_MULTIPATH_MODES[data.multipath] then
        http.write(json.stringify({success = false, error = "Invalid multipath mode"}))
        return
    end
    if data.proto ~= nil and data.proto ~= "dhcp" and data.proto ~= "static" then
        http.write(json.stringify({success = false, error = "Invalid protocol"}))
        return
    end
    if data.proto == "static" and
       (not validate_ip(data.ipaddr) or not validate_ip(data.netmask) or
        not validate_ip(data.gateway)) then
        http.write(json.stringify({success = false, error = "Static IP settings are incomplete or invalid"}))
        return
    end
    if data.peerdns ~= nil and type(data.peerdns) ~= "boolean" then
        http.write(json.stringify({success = false, error = "peerdns must be a boolean"}))
        return
    end
    if data.dns ~= nil then
        local dns_length = dense_array_length(data.dns)
        local dns_seen = {}
        if not dns_length or dns_length > 2 then
            http.write(json.stringify({success = false, error = "At most two DNS servers are allowed"}))
            return
        end
        for _, address in ipairs(data.dns) do
            if not validate_ip(address) or dns_seen[address] then
                http.write(json.stringify({success = false, error = "Invalid or duplicate DNS server"}))
                return
            end
            dns_seen[address] = true
        end
    end
    if data.mtu ~= nil and data.mtu ~= "" then
        local mtu = tonumber(data.mtu)
        if not mtu or mtu ~= math.floor(mtu) or mtu < 576 or mtu > 9000 then
            http.write(json.stringify({success = false, error = "Invalid MTU"}))
            return
        end
    end
    if data.multipath ~= nil then
        local masters = 0
        for _, selected_iface in ipairs(selected) do
            local mode = selected_iface == iface and data.multipath or
                (uci:get("network", selected_iface, "multipath") or "off")
            if not VALID_MULTIPATH_MODES[mode] then
                http.write(json.stringify({success = false, error = "Current WAN policy is invalid"}))
                return
            end
            if mode == "master" then masters = masters + 1 end
        end
        if masters ~= 1 then
            http.write(json.stringify({success = false, error = "Exactly one master WAN is required"}))
            return
        end
    end

    if not uci:get("network", iface) then
        http.write(json.stringify({success = false, error = "Interface not found"}))
        return
    end

    local response, lock_error = run_locked(
        WAN_MUTATION_LOCK, 600, "Another WAN operation is already running",
        function()
            local fs = require "nixio.fs"
            if fs.stat(BYPASS_FLAG) or fs.stat(BYPASS_BUNDLE) then
                return {
                    success = false,
                    error = "WAN settings cannot change while bypass recovery is active"
                }
            end
            local current = require "luci.model.uci".cursor()
            local locked_selected, locked_set = selected_wans(current)
            if not locked_selected or not locked_set[iface] or
               not current:get("network", iface) then
                return {success = false, error = "WAN selection changed; reload and retry"}
            end

            if data.multipath ~= nil then
                local masters = 0
                for _, selected_iface in ipairs(locked_selected) do
                    local mode = selected_iface == iface and data.multipath or
                        (current:get(
                            "network", selected_iface, "multipath"
                        ) or "off")
                    if not VALID_MULTIPATH_MODES[mode] then
                        return {success = false, error = "Current WAN policy is invalid"}
                    end
                    if mode == "master" then masters = masters + 1 end
                end
                if masters ~= 1 then
                    return {
                        success = false,
                        error = "Exactly one master WAN is required"
                    }
                end
            end

            local snapshot = snapshot_file("/etc/config/network")
            if not snapshot then
                return {success = false, error = "Cannot snapshot network configuration"}
            end
            local changed = false
            local staged = true
            local function set_if_changed(option, value)
                if current:get("network", iface, option) ~= value then
                    staged = current:set(
                        "network", iface, option, value
                    ) and staged
                    changed = true
                end
            end
            local function delete_if_present(option)
                if current:get("network", iface, option) ~= nil then
                    current:delete("network", iface, option)
                    changed = true
                end
            end

            if data.multipath ~= nil then
                set_if_changed("multipath", data.multipath)
                if data.multipath == "off" then
                    set_if_changed("disabled", "1")
                else
                    delete_if_present("disabled")
                end
            end
            if data.proto ~= nil then
                set_if_changed("proto", data.proto)
                if data.proto == "dhcp" then
                    delete_if_present("ipaddr")
                    delete_if_present("netmask")
                    delete_if_present("gateway")
                else
                    set_if_changed("ipaddr", data.ipaddr)
                    set_if_changed("netmask", data.netmask)
                    set_if_changed("gateway", data.gateway)
                end
            end
            if data.peerdns ~= nil then
                set_if_changed("peerdns", data.peerdns and "1" or "0")
            end
            if data.dns ~= nil then
                current:delete("network", iface, "dns")
                if #data.dns > 0 then
                    staged = current:set_list(
                        "network", iface, "dns", data.dns
                    ) and staged
                end
                -- A clear-only request is a real mutation even though no list
                -- value is subsequently set.
                changed = true
            end
            if data.mtu == "" then
                delete_if_present("mtu")
            elseif data.mtu ~= nil then
                set_if_changed("mtu", tostring(tonumber(data.mtu)))
            end

            if not staged then
                current:revert("network")
                return {success = false, error = "Could not stage WAN settings"}
            end
            if not changed then
                return {success = true, iface = iface, changes_made = false}
            end
            local committed = current:commit("network")
            local verify = require "luci.model.uci".cursor()
            local verified = committed == true
            if data.multipath ~= nil then
                verified = verified and
                    verify:get("network", iface, "multipath") == data.multipath
                local expected_disabled =
                    data.multipath == "off" and "1" or nil
                verified = verified and
                    verify:get("network", iface, "disabled") == expected_disabled
            end
            if data.proto ~= nil then
                verified = verified and
                    verify:get("network", iface, "proto") == data.proto
                if data.proto == "dhcp" then
                    verified = verified and
                        verify:get("network", iface, "ipaddr") == nil and
                        verify:get("network", iface, "netmask") == nil and
                        verify:get("network", iface, "gateway") == nil
                else
                    verified = verified and
                        verify:get("network", iface, "ipaddr") == data.ipaddr and
                        verify:get("network", iface, "netmask") == data.netmask and
                        verify:get("network", iface, "gateway") == data.gateway
                end
            end
            if data.peerdns ~= nil then
                verified = verified and verify:get(
                    "network", iface, "peerdns"
                ) == (data.peerdns and "1" or "0")
            end
            if data.dns ~= nil then
                local actual_dns = verify:get_list("network", iface, "dns") or {}
                if #actual_dns ~= #data.dns then
                    verified = false
                else
                    for index, address in ipairs(data.dns) do
                        if actual_dns[index] ~= address then verified = false end
                    end
                end
            end
            if data.mtu ~= nil then
                local expected_mtu =
                    data.mtu == "" and nil or tostring(tonumber(data.mtu))
                verified = verified and
                    verify:get("network", iface, "mtu") == expected_mtu
            end
            if verified then
                verified = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                )
            end
            if not verified then
                local restored = restore_uci_snapshot("network", snapshot)
                restored = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                ) and restored
                return {
                    success = false,
                    error = restored and "WAN settings failed and were rolled back" or
                        "WAN settings failed and rollback was incomplete"
                }
            end
            return {success = true, iface = iface, changes_made = true}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- Advanced-settings mutation endpoint.
function action_wan_advanced_set()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local fs = require "nixio.fs"

    http.prepare_content("application/json")

    local data, parse_error = parse_json_request(http, json)
    if not data or not has_only_keys(data, {
        failover = true, mptcp = true, enabled = true
    }) or
       type(data.failover) ~= "table" or type(data.mptcp) ~= "table" or
       not has_only_keys(data.failover, {
           timeout = true, count = true, tries = true, interval = true,
           failure_interval = true, tries_up = true
       }) or
       not has_only_keys(data.mptcp, {
           scheduler = true, path_manager = true, congestion = true,
           subflows = true, stale_loss_cnt = true
       }) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end
    local enabled_length
    if data.enabled ~= nil then
        enabled_length = dense_array_length(data.enabled)
        if not enabled_length or enabled_length == 0 or
           enabled_length > MAX_WAN_INTERFACES then
            http.write(json.stringify({
                success = false,
                error = "Select between 1 and 32 WAN interfaces"
            }))
            return
        end
        local requested_seen = {}
        for _, iface_name in ipairs(data.enabled) do
            if type(iface_name) ~= "string" or
               not validate_iface(iface_name) or requested_seen[iface_name] then
                http.write(json.stringify({
                    success = false,
                    error = "Invalid or duplicate WAN interface"
                }))
                return
            end
            requested_seen[iface_name] = true
        end
    end

    local function strict_int(value, minimum, maximum)
        return type(value) == "number" and value == math.floor(value) and
            value >= minimum and value <= maximum and value or nil
    end

    local f = data.failover
    local validated_failover = {
        timeout = strict_int(f.timeout, 1, 10),
        count = strict_int(f.count, 1, 5),
        tries = strict_int(f.tries, 1, 10),
        interval = strict_int(f.interval, 1, 10),
        failure_interval = strict_int(f.failure_interval, 1, 30),
        tries_up = strict_int(f.tries_up, 1, 10)
    }
    local failover_keys = {
        "timeout", "count", "tries", "interval", "failure_interval", "tries_up"
    }
    for _, key in ipairs(failover_keys) do
        if validated_failover[key] == nil then
            http.write(json.stringify({success = false, error = "Invalid failover setting: " .. key}))
            return
        end
    end

    local m = data.mptcp
    local valid_schedulers = {
        default = true, blest = true, roundrobin = true, redundant = true,
        bpf_minrtt = true, bpf_rr = true, bpf_red = true,
        bpf_burst = true, bpf_first = true, bpf_bkup = true
    }
    local valid_path_managers = {fullmesh = true, ndiffports = true}
    local valid_congestion = {bbr = true, cubic = true, reno = true}
    local subflows = strict_int(m.subflows, 1, 16)
    local stale_loss = strict_int(m.stale_loss_cnt, 1, 10)
    if not valid_schedulers[m.scheduler] or
       not valid_path_managers[m.path_manager] or
       not valid_congestion[m.congestion] or not subflows or not stale_loss then
        http.write(json.stringify({success = false, error = "Invalid MPTCP settings"}))
        return
    end

    local response, lock_error = run_locked(
        WAN_MUTATION_LOCK, 600, "Another WAN operation is already running",
        function()
            if fs.stat(BYPASS_FLAG) or fs.stat(BYPASS_BUNDLE) then
                return {
                    success = false,
                    error = "WAN settings cannot change while bypass recovery is active"
                }
            end
            local tracker_snapshot = snapshot_file("/etc/config/omr-tracker")
            local network_snapshot = snapshot_file("/etc/config/network")
            local sysctl_snapshot = snapshot_file("/etc/sysctl.conf")
            local selection_snapshot = data.enabled ~= nil and
                snapshot_file("/etc/jammonitor_wans") or nil
            local old_live_ok, old_live_text = checked_capture(
                "sysctl -n net.mptcp.stale_loss_cnt"
            )
            local old_live_stale = old_live_ok and
                tonumber(old_live_text:match("%d+")) or nil
            if not tracker_snapshot or not network_snapshot or not sysctl_snapshot or
               (data.enabled ~= nil and not selection_snapshot) then
                return {success = false, error = "Cannot snapshot advanced settings"}
            end
            if #sysctl_snapshot.content > MAX_JSON_BODY then
                return {
                    success = false,
                    error = "sysctl configuration is oversized"
                }
            end
            local requested_sysctl = sysctl_snapshot.content:gsub(
                "net%.mptcp%.stale_loss_cnt%s*=%s*%d+\n?", ""
            )
            if requested_sysctl ~= "" and
               requested_sysctl:sub(-1) ~= "\n" then
                requested_sysctl = requested_sysctl .. "\n"
            end
            requested_sysctl = requested_sysctl ..
                "net.mptcp.stale_loss_cnt=" .. tostring(stale_loss) .. "\n"
            if not old_live_stale then
                return {success = false, error = "Cannot snapshot live MPTCP settings"}
            end

            if data.enabled ~= nil then
                local selection_cursor =
                    require "luci.model.uci".cursor()
                local _, locked_eligible = eligible_wans(selection_cursor)
                local masters = 0
                for _, iface_name in ipairs(data.enabled) do
                    if not locked_eligible[iface_name] then
                        return {
                            success = false,
                            error = "WAN eligibility changed; reload and retry"
                        }
                    end
                    if selection_cursor:get(
                        "network", iface_name, "multipath"
                    ) == "master" then
                        masters = masters + 1
                    end
                end
                if masters ~= 1 then
                    return {
                        success = false,
                        error = "Selected WAN set must contain exactly one master"
                    }
                end
            end

            local current = require "luci.model.uci".cursor()
            local staged = true
            for _, key in ipairs(failover_keys) do
                staged = current:set(
                    "omr-tracker", "defaults", key,
                    tostring(validated_failover[key])
                ) and staged
            end
            staged = current:set(
                "network", "globals", "mptcp_scheduler", m.scheduler
            ) and staged
            staged = current:set(
                "network", "globals", "mptcp_path_manager", m.path_manager
            ) and staged
            staged = current:set(
                "network", "globals", "congestion", m.congestion
            ) and staged
            staged = current:set(
                "network", "globals", "mptcp_subflows", tostring(subflows)
            ) and staged
            if not staged then
                current:revert("omr-tracker")
                current:revert("network")
                return {success = false, error = "Could not stage advanced settings"}
            end

            local tracker_committed = current:commit("omr-tracker")
            local network_committed = current:commit("network")
            local persisted = tracker_committed == true and
                network_committed == true and
                atomic_write(
                    "/etc/sysctl.conf", requested_sysctl, PUBLIC_FILE_MODE
                )
            local selection_content = data.enabled ~= nil and
                table.concat(data.enabled, "\n") or nil
            if persisted and selection_content ~= nil then
                persisted = atomic_write(
                    "/etc/jammonitor_wans",
                    selection_content,
                    PRIVATE_FILE_MODE
                )
            end
            local verify = require "luci.model.uci".cursor()
            local verified = persisted == true
            for _, key in ipairs(failover_keys) do
                verified = verified and verify:get(
                    "omr-tracker", "defaults", key
                ) == tostring(validated_failover[key])
            end
            verified = verified and
                verify:get(
                    "network", "globals", "mptcp_scheduler"
                ) == m.scheduler and
                verify:get(
                    "network", "globals", "mptcp_path_manager"
                ) == m.path_manager and
                verify:get(
                    "network", "globals", "congestion"
                ) == m.congestion and
                verify:get(
                    "network", "globals", "mptcp_subflows"
                ) == tostring(subflows)
            if verified and selection_content ~= nil then
                verified =
                    (fs.readfile("/etc/jammonitor_wans") or "") ==
                    selection_content
            end
            if verified then
                verified = checked_call(
                    "sysctl -w net.mptcp.stale_loss_cnt=" .. tostring(stale_loss)
                )
            end
            if verified then
                local live_ok, live_value = checked_capture(
                    "sysctl -n net.mptcp.stale_loss_cnt"
                )
                verified = live_ok and
                    tonumber(live_value:match("%d+")) == stale_loss
            end
            if verified then
                verified = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                )
            end
            if verified then
                verified = checked_init_action(
                    "/etc/init.d/omr-tracker", "restart", 60
                )
            end

            if not verified then
                local restored =
                    restore_uci_snapshot("omr-tracker", tracker_snapshot)
                restored =
                    restore_uci_snapshot("network", network_snapshot) and restored
                restored =
                    restore_file_snapshot(
                        sysctl_snapshot, PUBLIC_FILE_MODE
                    ) and restored
                if selection_snapshot then
                    restored = restore_file_snapshot(
                        selection_snapshot, PRIVATE_FILE_MODE
                    ) and restored
                end
                restored =
                    checked_call(
                        "sysctl -w net.mptcp.stale_loss_cnt=" ..
                        tostring(old_live_stale)
                    ) and restored
                restored =
                    checked_init_action(
                        "/etc/init.d/network", "reload", 60
                    ) and restored
                restored =
                    checked_init_action(
                        "/etc/init.d/omr-tracker", "restart", 60
                    ) and restored
                return {
                    success = false,
                    error = restored and
                        "Advanced settings failed and were rolled back" or
                        "Advanced settings failed and rollback was incomplete"
                }
            end
            return {success = true}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- Advanced-settings read endpoint.
function action_wan_advanced()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")
    local result = {failover = {}, mptcp = {}}
    result.failover.timeout = tonumber(uci:get("omr-tracker", "defaults", "timeout")) or 1
    result.failover.count = tonumber(uci:get("omr-tracker", "defaults", "count")) or 1
    result.failover.tries = tonumber(uci:get("omr-tracker", "defaults", "tries")) or 2
    result.failover.interval = tonumber(uci:get("omr-tracker", "defaults", "interval")) or 1
    result.failover.failure_interval = tonumber(uci:get("omr-tracker", "defaults", "failure_interval")) or 2
    result.failover.tries_up = tonumber(uci:get("omr-tracker", "defaults", "tries_up")) or 2
    result.mptcp.scheduler = uci:get("network", "globals", "mptcp_scheduler") or "default"
    result.mptcp.path_manager = uci:get("network", "globals", "mptcp_path_manager") or "fullmesh"
    result.mptcp.congestion = uci:get("network", "globals", "congestion") or "bbr"
    result.mptcp.subflows = tonumber(uci:get("network", "globals", "mptcp_subflows")) or 8
    result.mptcp.stale_loss_cnt =
        tonumber(sys.exec("sysctl -n net.mptcp.stale_loss_cnt 2>/dev/null")) or 4
    http.write(json.stringify(result))
end

-- WAN Interface selector mutation endpoint.
function action_wan_ifaces_set()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")
    local data, parse_error = parse_json_request(http, json)
    if not data or not has_only_keys(data, {enabled = true}) then
        http.write(json.stringify({success = false, error = parse_error or "Invalid request"}))
        return
    end

    local enabled_length = dense_array_length(data.enabled)
    local _, eligible_set = eligible_wans(uci)
    if not enabled_length or enabled_length == 0 or
       enabled_length > MAX_WAN_INTERFACES then
        http.write(json.stringify({success = false, error = "Select between 1 and 32 WAN interfaces"}))
        return
    end

    local seen = {}
    for _, iface_name in ipairs(data.enabled) do
        if type(iface_name) ~= "string" or not eligible_set[iface_name] or
           seen[iface_name] then
            http.write(json.stringify({success = false, error = "Invalid or duplicate WAN interface"}))
            return
        end
        seen[iface_name] = true
    end

    local response, lock_error = run_locked(
        WAN_MUTATION_LOCK, 600, "Another WAN operation is already running",
        function()
            local fs = require "nixio.fs"
            if fs.stat(BYPASS_FLAG) or fs.stat(BYPASS_BUNDLE) then
                return {
                    success = false,
                    error = "WAN selection cannot change while bypass recovery is active"
                }
            end
            local current = require "luci.model.uci".cursor()
            local _, current_eligible = eligible_wans(current)
            local masters = 0
            for _, iface_name in ipairs(data.enabled) do
                if not current_eligible[iface_name] then
                    return {
                        success = false,
                        error = "WAN eligibility changed; reload and retry"
                    }
                end
                if current:get("network", iface_name, "multipath") == "master" then
                    masters = masters + 1
                end
            end
            if masters ~= 1 then
                return {
                    success = false,
                    error = "Selected WAN set must contain exactly one master"
                }
            end

            local snapshot = snapshot_file("/etc/jammonitor_wans")
            if not snapshot then
                return {success = false, error = "Cannot snapshot WAN selection"}
            end
            local content = table.concat(data.enabled, "\n")
            if not atomic_write(
                "/etc/jammonitor_wans", content, PRIVATE_FILE_MODE
            ) or (fs.readfile("/etc/jammonitor_wans") or "") ~= content then
                local restored = restore_file_snapshot(
                    snapshot, PRIVATE_FILE_MODE
                )
                return {
                    success = false,
                    error = restored and "WAN selection write failed and was rolled back" or
                        "WAN selection write and rollback failed"
                }
            end
            return {success = true}
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

-- WAN Interface selector read endpoint.
function action_wan_ifaces()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()

    http.prepare_content("application/json")

    local selected, _, selection_error = selected_wans(uci)
    if not selected then
        http.write(json.stringify({success = false, error = selection_error}))
        return
    end
    local _, eligible_set = eligible_wans(uci)
    local result = {all = {}, enabled = selected}

        -- Get all network interfaces from UCI (exclude system/LAN interfaces permanently)
        uci:foreach("network", "interface", function(s)
            local name = s[".name"]
            if eligible_set[name] then
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
            end
        end)

    table.sort(result.all, function(a, b) return a.name < b.name end)
    http.write(json.stringify(result))
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
        tailscale_health = {},
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
        local result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
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
        result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
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

        -- Query the fixed-schema semantic Tailscale samples. json_object
        -- preserves SQL NULL as JSON null and avoids delimiter ambiguity.
        query = string.format([[
            SELECT json_object(
                'ts', ts,
                'boot_id', boot_id,
                'status', status,
                'reason', reason,
                'healthy', healthy,
                'connected', connected,
                'degraded', degraded,
                'local_api_responsive', local_api_responsive,
                'control_online', control_online,
                'process_generation', process_generation,
                'process_uptime_seconds', process_uptime_seconds,
                'backend_state', backend_state,
                'key_expiry', key_expiry,
                'condition_since_at', condition_since_at,
                'connected_since_at', connected_since_at,
                'connectivity_uptime_seconds', connectivity_uptime_seconds,
                'peer_state', peer_state,
                'peer_reachable', peer_reachable,
                'recovery_attempted', recovery_attempted,
                'recovery_count', recovery_count
            )
            FROM service_health
            WHERE service = 'tailscale' AND ts > %d AND ts <= %d
            ORDER BY ts
        ]], cutoff, end_time):gsub("\n", " ")
        result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")
        if result and result ~= "" then
            for line in result:gmatch("[^\n]+") do
                local sample = json.parse(line)
                if type(sample) == "table" then
                    table.insert(bundle.tailscale_health, sample)
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
    bundle.tailscale_health_count = #bundle.tailscale_health

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
        local result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. query .. "\" 2>/dev/null")

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

        local iface_result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. iface_query .. "\" 2>/dev/null")
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

        local client_result = sys.exec("timeout 10 sqlite3 '" .. db_path .. "' \"" .. client_query .. "\" 2>/dev/null")
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

local BYPASS_HOTPLUG = "/etc/hotplug.d/iface/40-omr-tracker"
local BYPASS_HOTPLUG_DISABLED =
    "/etc/hotplug.d/iface/40-omr-tracker.disabled"

local BYPASS_VPN_SPECS = {
    {
        id = "shadowsocks_libev", package = "shadowsocks-libev",
        section = "sss0", option = "disabled", bypass_value = "1"
    },
    {
        id = "shadowsocks_rust", package = "shadowsocks-rust",
        section = "sss0", option = "disabled", bypass_value = "1"
    },
    {
        id = "openvpn", package = "openvpn",
        section = "omr", option = "enabled", bypass_value = "0"
    },
    {
        id = "glorytun", package = "glorytun",
        section = "vpn", option = "enable", bypass_value = "0"
    }
}

local BYPASS_SERVICE_SPECS = {
    {id = "omr_tracker", path = "/etc/init.d/omr-tracker"},
    {id = "openvpn", path = "/etc/init.d/openvpn"},
    {id = "shadowsocks_libev", path = "/etc/init.d/shadowsocks-libev"},
    {id = "shadowsocks_rust", path = "/etc/init.d/shadowsocks-rust"},
    {id = "glorytun", path = "/etc/init.d/glorytun"}
}

local function bypass_hotplug_state()
    local fs = require "nixio.fs"
    local active = fs.stat(BYPASS_HOTPLUG) ~= nil
    local disabled = fs.stat(BYPASS_HOTPLUG_DISABLED) ~= nil
    if active and disabled then return "conflict" end
    if active then return "active" end
    if disabled then return "disabled" end
    return "absent"
end

local function capture_bypass_bundle(uci, selected)
    local fs = require "nixio.fs"
    local bundle = {
        schema = 1,
        phase = "prepared",
        created_at = os.time(),
        selected = {},
        selection_content = fs.readfile("/etc/jammonitor_wans") or "",
        modes = {},
        vpn = {},
        services = {},
        hotplug = bypass_hotplug_state()
    }
    if bundle.hotplug == "conflict" or
       #bundle.selection_content > 4096 then
        return nil, "Existing bypass recovery inputs are inconsistent"
    end

    local masters = 0
    for _, iface in ipairs(selected) do
        local mode = uci:get("network", iface, "multipath") or "off"
        if not VALID_MULTIPATH_MODES[mode] then
            return nil, "Current WAN policy is invalid"
        end
        bundle.selected[#bundle.selected + 1] = iface
        bundle.modes[iface] = mode
        if mode == "master" then
            masters = masters + 1
            bundle.primary = iface
        end
    end
    if masters ~= 1 then
        return nil, "Exactly one master WAN is required before enabling bypass"
    end

    for _, spec in ipairs(BYPASS_VPN_SPECS) do
        local section_type = uci:get(spec.package, spec.section)
        local value = section_type and
            uci:get(spec.package, spec.section, spec.option) or nil
        bundle.vpn[spec.id] = {
            managed = section_type ~= nil,
            present = value ~= nil,
            value = value
        }
    end

    for _, spec in ipairs(BYPASS_SERVICE_SPECS) do
        local installed = fs.stat(spec.path) ~= nil
        bundle.services[spec.id] = {
            installed = installed,
            enabled = installed and
                checked_init_action(spec.path, "enabled", 5) or false,
            running = installed and
                checked_init_action(spec.path, "running", 5) or false
        }
    end
    return bundle
end

local function bypass_bundle_is_valid(bundle)
    if type(bundle) ~= "table" or tonumber(bundle.schema) ~= 1 or
       type(bundle.phase) ~= "string" or
       (bundle.phase ~= "prepared" and bundle.phase ~= "network_off" and
        bundle.phase ~= "services_stopped" and bundle.phase ~= "active" and
        bundle.phase ~= "restoring" and bundle.phase ~= "restored") or
       type(bundle.primary) ~= "string" or
       type(bundle.selection_content) ~= "string" or
       #bundle.selection_content > 4096 or
       type(bundle.modes) ~= "table" or type(bundle.vpn) ~= "table" or
       type(bundle.services) ~= "table" then
        return false
    end
    local count = dense_array_length(bundle.selected)
    if not count or count == 0 or count > MAX_WAN_INTERFACES then return false end
    local seen = {}
    local masters = 0
    for _, iface in ipairs(bundle.selected) do
        local mode = bundle.modes[iface]
        if not validate_iface(iface) or seen[iface] or
           not VALID_MULTIPATH_MODES[mode] then
            return false
        end
        seen[iface] = true
        if mode == "master" then masters = masters + 1 end
    end
    if masters ~= 1 or not seen[bundle.primary] then return false end
    for iface, mode in pairs(bundle.modes) do
        if not seen[iface] or not VALID_MULTIPATH_MODES[mode] then return false end
    end
    for _, spec in ipairs(BYPASS_VPN_SPECS) do
        local state = bundle.vpn[spec.id]
        if type(state) ~= "table" or type(state.managed) ~= "boolean" or
           type(state.present) ~= "boolean" or
           (state.present and (type(state.value) ~= "string" or
            #state.value > 128)) then
            return false
        end
    end
    for _, spec in ipairs(BYPASS_SERVICE_SPECS) do
        local state = bundle.services[spec.id]
        if type(state) ~= "table" or type(state.installed) ~= "boolean" or
           type(state.enabled) ~= "boolean" or
           type(state.running) ~= "boolean" then
            return false
        end
    end
    return bundle.hotplug == "active" or bundle.hotplug == "disabled" or
        bundle.hotplug == "absent"
end

local function read_bypass_bundle()
    local fs = require "nixio.fs"
    local json = require "luci.jsonc"
    local raw = fs.readfile(BYPASS_BUNDLE)
    if not raw or raw == "" or #raw > MAX_JSON_BODY then return nil end
    local bundle = json.parse(raw)
    return bypass_bundle_is_valid(bundle) and bundle or nil
end

local function write_bypass_bundle(bundle)
    local json = require "luci.jsonc"
    return bypass_bundle_is_valid(bundle) and
        atomic_write(BYPASS_BUNDLE, json.stringify(bundle), PRIVATE_FILE_MODE)
end

local function apply_bypass_network(bundle, bypass_enabled)
    local uci = require "luci.model.uci".cursor()
    for _, iface in ipairs(bundle.selected) do
        local value = bypass_enabled and "off" or bundle.modes[iface]
        if not uci:get("network", iface) or
           not uci:set("network", iface, "multipath", value) then
            uci:revert("network")
            return false
        end
    end
    if not uci:commit("network") then
        uci:revert("network")
        return false
    end
    local verify = require "luci.model.uci".cursor()
    for _, iface in ipairs(bundle.selected) do
        local expected = bypass_enabled and "off" or bundle.modes[iface]
        if verify:get("network", iface, "multipath") ~= expected then
            return false
        end
    end
    return true
end

local function apply_bypass_vpn(bundle, bypass_enabled)
    local uci = require "luci.model.uci".cursor()
    local touched = {}
    for _, spec in ipairs(BYPASS_VPN_SPECS) do
        local state = bundle.vpn[spec.id]
        if state.managed then
            local ok
            if bypass_enabled then
                ok = uci:set(
                    spec.package, spec.section, spec.option, spec.bypass_value
                )
            elseif state.present then
                ok = uci:set(
                    spec.package, spec.section, spec.option, state.value
                )
            else
                uci:delete(spec.package, spec.section, spec.option)
                ok = true
            end
            if not ok then
                for package_name in pairs(touched) do
                    uci:revert(package_name)
                end
                return false
            end
            touched[spec.package] = true
        end
    end
    local committed = true
    for package_name in pairs(touched) do
        if not uci:commit(package_name) then committed = false end
    end
    if not committed then return false end

    local verify = require "luci.model.uci".cursor()
    for _, spec in ipairs(BYPASS_VPN_SPECS) do
        local state = bundle.vpn[spec.id]
        if state.managed then
            local expected = bypass_enabled and spec.bypass_value or
                (state.present and state.value or nil)
            if verify:get(spec.package, spec.section, spec.option) ~= expected then
                return false
            end
        end
    end
    return true
end

local function apply_bypass_hotplug(original_state, bypass_enabled)
    local fs = require "nixio.fs"
    if bypass_enabled then
        if original_state == "active" and
           not os.rename(BYPASS_HOTPLUG, BYPASS_HOTPLUG_DISABLED) then
            return false
        end
        local expected = original_state == "active" and "disabled" or original_state
        return bypass_hotplug_state() == expected
    end

    local current = bypass_hotplug_state()
    if original_state == "active" and current == "disabled" then
        if not os.rename(BYPASS_HOTPLUG_DISABLED, BYPASS_HOTPLUG) then
            return false
        end
    elseif original_state == "disabled" and current == "active" then
        if not os.rename(BYPASS_HOTPLUG, BYPASS_HOTPLUG_DISABLED) then
            return false
        end
    elseif original_state == "absent" and current ~= "absent" then
        -- A new file appearing during the transaction is not ours to delete.
        return false
    end
    return bypass_hotplug_state() == original_state
end

local function service_state_matches(spec, expected_running, expected_enabled)
    local fs = require "nixio.fs"
    if not fs.stat(spec.path) then return false end
    local running = checked_init_action(spec.path, "running", 5)
    local enabled = checked_init_action(spec.path, "enabled", 5)
    return running == expected_running and enabled == expected_enabled
end

local function apply_bypass_services(bundle, bypass_enabled)
    local fs = require "nixio.fs"
    local ok = true
    for _, spec in ipairs(BYPASS_SERVICE_SPECS) do
        local state = bundle.services[spec.id]
        if state.installed then
            if not fs.stat(spec.path) then
                ok = false
            else
                local want_running = not bypass_enabled and state.running
                local want_enabled = state.enabled
                local enabled =
                    checked_init_action(spec.path, "enabled", 5)
                if enabled ~= want_enabled then
                    checked_init_action(
                        spec.path, want_enabled and "enable" or "disable", 30
                    )
                end
                local running =
                    checked_init_action(spec.path, "running", 5)
                if running ~= want_running then
                    checked_init_action(
                        spec.path, want_running and "start" or "stop", 30
                    )
                end
                if not service_state_matches(
                    spec, want_running, want_enabled
                ) then
                    ok = false
                end
            end
        elseif fs.stat(spec.path) then
            -- Installation topology changed while recovery state was active.
            ok = false
        end
    end
    return ok
end

local function bypass_runtime_matches(bundle)
    local expected_hotplug =
        bundle.hotplug == "active" and "disabled" or bundle.hotplug
    if bypass_hotplug_state() ~= expected_hotplug then return false end
    for _, spec in ipairs(BYPASS_SERVICE_SPECS) do
        local state = bundle.services[spec.id]
        if state.installed and
           not service_state_matches(spec, false, state.enabled) then
            return false
        end
        local fs = require "nixio.fs"
        if not state.installed and fs.stat(spec.path) then return false end
    end
    return true
end

local function bypass_state_is_active(bundle)
    local fs = require "nixio.fs"
    local verify = require "luci.model.uci".cursor()
    if not bundle or fs.stat(BYPASS_FLAG) == nil or
       (fs.readfile(BYPASS_FLAG) or ""):match("^%s*(.-)%s*$") ~=
            bundle.primary then
        return false
    end
    for _, iface in ipairs(bundle.selected) do
        if verify:get("network", iface, "multipath") ~= "off" then
            return false
        end
    end
    for _, spec in ipairs(BYPASS_VPN_SPECS) do
        local state = bundle.vpn[spec.id]
        if state.managed and
           verify:get(spec.package, spec.section, spec.option) ~=
                spec.bypass_value then
            return false
        end
    end
    return bypass_runtime_matches(bundle)
end

local function mark_bypass_recovery_failure(message)
    return atomic_write(
        BYPASS_RECOVERY_FAILED,
        tostring(os.time()) .. "\n" .. tostring(message or "rollback_failed") .. "\n",
        PRIVATE_FILE_MODE
    )
end

local function restore_bypass_bundle(bundle)
    local fs = require "nixio.fs"
    bundle.phase = "restoring"
    if not write_bypass_bundle(bundle) then
        mark_bypass_recovery_failure("cannot_record_restoring_phase")
        return false
    end

    local ok = true
    if not atomic_write(
        "/etc/jammonitor_wans", bundle.selection_content, PRIVATE_FILE_MODE
    ) then
        ok = false
    end
    if not apply_bypass_network(bundle, false) then ok = false end
    if not apply_bypass_vpn(bundle, false) then ok = false end
    if not apply_bypass_hotplug(bundle.hotplug, false) then ok = false end
    if not checked_init_action("/etc/init.d/network", "reload", 60) then
        ok = false
    end
    if not checked_init_action("/etc/init.d/firewall", "reload", 60) then
        ok = false
    end
    if not apply_bypass_services(bundle, false) then ok = false end

    if not ok then
        mark_bypass_recovery_failure("state_restore_incomplete")
        return false
    end
    bundle.phase = "restored"
    if not write_bypass_bundle(bundle) then
        mark_bypass_recovery_failure("cannot_record_restored_phase")
        return false
    end
    if fs.stat(BYPASS_FLAG) and not fs.remove(BYPASS_FLAG) then
        mark_bypass_recovery_failure("cannot_remove_active_flag")
        return false
    end
    if fs.stat(BYPASS_FLAG) then
        mark_bypass_recovery_failure("active_flag_still_present")
        return false
    end
    if fs.stat(BYPASS_RECOVERY_FAILED) and
       not fs.remove(BYPASS_RECOVERY_FAILED) then
        return false
    end
    return true
end

local function cleanup_bypass_bundle()
    local fs = require "nixio.fs"
    fs.remove(BYPASS_BUNDLE)
    fs.remove("/etc/jammonitor_bypass_saved")
    fs.remove("/etc/jammonitor_bypass_vpn")
    return fs.stat(BYPASS_BUNDLE) == nil and
        fs.stat("/etc/jammonitor_bypass_saved") == nil and
        fs.stat("/etc/jammonitor_bypass_vpn") == nil
end

local function action_bypass_set_transactional()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"

    http.prepare_content("application/json")
    local data, parse_error = parse_json_request(http, json)
    if not data or not has_only_keys(data, {enable = true}) or
       type(data.enable) ~= "boolean" then
        http.write(json.stringify({
            success = false,
            error = parse_error or "enable must be a boolean"
        }))
        return
    end

    local response, lock_error = run_locked(
        WAN_MUTATION_LOCK, 600, "Another WAN operation is already running",
        function()
            local flag_exists = fs.stat(BYPASS_FLAG) ~= nil
            local bundle_exists = fs.stat(BYPASS_BUNDLE) ~= nil
            local bundle = bundle_exists and read_bypass_bundle() or nil
            if bundle_exists and not bundle then
                mark_bypass_recovery_failure("recovery_bundle_invalid")
                return {success = false, error = "Bypass recovery bundle is invalid"}
            end
            if flag_exists and not bundle then
                mark_bypass_recovery_failure("active_flag_without_bundle")
                return {
                    success = false,
                    error = "Bypass flag has no verified recovery bundle"
                }
            end

            if bundle and (not flag_exists or bundle.phase ~= "active") then
                if not restore_bypass_bundle(bundle) then
                    return {
                        success = false,
                        error = "Incomplete bypass transaction could not be recovered"
                    }
                end
                if not cleanup_bypass_bundle() then
                    mark_bypass_recovery_failure("cannot_remove_restored_bundle")
                    return {
                        success = false,
                        error = "Recovered bypass state but could not remove recovery bundle"
                    }
                end
                bundle = nil
                flag_exists = false
            end

            if data.enable and flag_exists then
                if bypass_state_is_active(bundle) then
                    if fs.stat(BYPASS_RECOVERY_FAILED) and
                       not fs.remove(BYPASS_RECOVERY_FAILED) then
                        return {
                            success = false,
                            bypass_enabled = true,
                            error = "Bypass is active but recovery alarm could not be cleared"
                        }
                    end
                    return {
                        success = true,
                        bypass_enabled = true,
                        active_wan = bundle.primary,
                        changes_made = false
                    }
                end
                if not restore_bypass_bundle(bundle) then
                    return {
                        success = false,
                        error = "Inconsistent bypass state requires operator recovery"
                    }
                end
                if not cleanup_bypass_bundle() then
                    mark_bypass_recovery_failure("cannot_remove_restored_bundle")
                    return {
                        success = false,
                        bypass_enabled = false,
                        error = "Bypass rolled back but recovery cleanup is incomplete"
                    }
                end
                return {
                    success = false,
                    bypass_enabled = false,
                    error = "Inconsistent bypass state was rolled back; retry enable"
                }
            end

            if not data.enable and not flag_exists then
                local uci = require "luci.model.uci".cursor()
                local selected = selected_wans(uci)
                local masters = 0
                if selected then
                    for _, iface in ipairs(selected) do
                        if uci:get("network", iface, "multipath") == "master" then
                            masters = masters + 1
                        end
                    end
                end
                if not selected or masters ~= 1 then
                    return {
                        success = false,
                        error = "Non-bypass WAN policy is inconsistent"
                    }
                end
                return {
                    success = true,
                    bypass_enabled = false,
                    changes_made = false
                }
            end

            if not data.enable then
                if not restore_bypass_bundle(bundle) then
                    return {
                        success = false,
                        error = "Bypass disable rollback is incomplete"
                    }
                end
                if not cleanup_bypass_bundle() then
                    mark_bypass_recovery_failure("cannot_remove_restored_bundle")
                    return {
                        success = false,
                        bypass_enabled = false,
                        error = "Bypass was restored but recovery cleanup is incomplete"
                    }
                end
                return {
                    success = true,
                    bypass_enabled = false,
                    restored_count = #bundle.selected,
                    changes_made = true,
                    message = "VPS bypass disabled - traffic now routed through VPS"
                }
            end

            local uci = require "luci.model.uci".cursor()
            local selected, _, selection_error = selected_wans(uci)
            if not selected or #selected == 0 then
                return {
                    success = false,
                    error = selection_error or "No selected WAN interfaces"
                }
            end
            bundle, selection_error = capture_bypass_bundle(uci, selected)
            if not bundle then
                return {success = false, error = selection_error}
            end
            if not write_bypass_bundle(bundle) then
                return {success = false, error = "Failed to persist recovery bundle"}
            end

            local applied = apply_bypass_network(bundle, true)
            if applied then
                bundle.phase = "network_off"
                applied = write_bypass_bundle(bundle)
            end
            if applied then applied = apply_bypass_vpn(bundle, true) end
            if applied then
                applied = apply_bypass_hotplug(bundle.hotplug, true)
            end
            if applied then applied = apply_bypass_services(bundle, true) end
            if applied then
                bundle.phase = "services_stopped"
                applied = write_bypass_bundle(bundle)
            end
            if applied then
                applied = checked_init_action(
                    "/etc/init.d/network", "reload", 60
                )
            end
            if applied then
                applied = checked_init_action(
                    "/etc/init.d/firewall", "reload", 60
                )
            end

            if not applied then
                local restored = restore_bypass_bundle(bundle)
                if restored and not cleanup_bypass_bundle() then
                    mark_bypass_recovery_failure("cannot_remove_restored_bundle")
                    restored = false
                end
                return {
                    success = false,
                    error = restored and "Bypass enable failed and was rolled back" or
                        "Bypass enable failed; recovery is incomplete"
                }
            end

            bundle.phase = "active"
            if not write_bypass_bundle(bundle) or
               not atomic_write(BYPASS_FLAG, bundle.primary .. "\n", PRIVATE_FILE_MODE) or
               not bypass_state_is_active(bundle) then
                local restored = restore_bypass_bundle(bundle)
                if restored and not cleanup_bypass_bundle() then
                    mark_bypass_recovery_failure("cannot_remove_restored_bundle")
                    restored = false
                end
                return {
                    success = false,
                    error = restored and
                        "Bypass activation could not be verified and was rolled back" or
                        "Bypass activation failed; recovery is incomplete"
                }
            end
            if fs.stat(BYPASS_RECOVERY_FAILED) and
               not fs.remove(BYPASS_RECOVERY_FAILED) then
                return {
                    success = false,
                    bypass_enabled = true,
                    error = "Bypass activated but recovery alarm could not be cleared"
                }
            end
            return {
                success = true,
                bypass_enabled = true,
                active_wan = bundle.primary,
                changes_made = true,
                message = "VPS bypass enabled - traffic now going direct"
            }
        end
    )
    if response == false then
        response = {success = false, error = lock_error}
    end
    http.write(json.stringify(response))
end

function action_bypass_set()
    return action_bypass_set_transactional()
end

-- VPS Bypass read endpoint.
function action_bypass()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local uci = require "luci.model.uci".cursor()
    local fs = require "nixio.fs"

    http.prepare_content("application/json")
    local flag_exists = fs.stat(BYPASS_FLAG) ~= nil
    local bundle_exists = fs.stat(BYPASS_BUNDLE) ~= nil
    local bundle = bundle_exists and read_bypass_bundle() or nil
    local recovery_failed = fs.stat(BYPASS_RECOVERY_FAILED) ~= nil
    local bypass_enabled = flag_exists and bundle ~= nil and
        bundle.phase == "active" and bypass_state_is_active(bundle)
    local active_wan = nil
    local saved_config_data = {}
    local configuration_valid = not recovery_failed and
        (not bundle_exists or bundle ~= nil) and flag_exists == bypass_enabled

    if bundle then
        for _, iface in ipairs(bundle.selected) do
            saved_config_data[iface] = bundle.modes[iface]
        end
        if bypass_enabled then active_wan = bundle.primary end
    end

    if not flag_exists and not bundle_exists and not recovery_failed then
        local selected = selected_wans(uci)
        local master_count = 0
        if selected then
            for _, iface in ipairs(selected) do
                if uci:get("network", iface, "multipath") == "master" then
                    master_count = master_count + 1
                    active_wan = iface
                end
            end
        end
        if not selected or master_count ~= 1 then
            configuration_valid = false
            active_wan = nil
        end
    elseif not bypass_enabled then
        configuration_valid = false
    end

    http.write(json.stringify({
        bypass_enabled = bypass_enabled,
        active_wan = active_wan,
        saved_config = saved_config_data,
        configuration_valid = configuration_valid,
        recovery_required = recovery_failed or bundle_exists and not bypass_enabled,
        recovery_phase = bundle and bundle.phase or nil
    }))
end

local speedtest_job_sequence = 0
local SPEEDTEST_LOCK = "/tmp/jammonitor_speedtest.lock"

local function release_speedtest_lock(job_id)
    local fs = require "nixio.fs"
    local owner = (fs.readfile(SPEEDTEST_LOCK .. "/job_id") or "")
        :match("^%s*(.-)%s*$")
    if owner ~= job_id then return false end
    fs.remove(SPEEDTEST_LOCK .. "/job_id")
    fs.remove(SPEEDTEST_LOCK .. "/owner")
    fs.rmdir(SPEEDTEST_LOCK)
    return fs.stat(SPEEDTEST_LOCK) == nil
end

local function process_generation_is_live(generation)
    if type(generation) ~= "string" then return false end
    local pid, expected_start = generation:match("^(%d+):(%d+)$")
    if not pid or not expected_start then return false end
    local fs = require "nixio.fs"
    local stat = fs.readfile("/proc/" .. pid .. "/stat")
    if not stat then return false end
    local remainder = stat:match("^%d+ %b() (.+)$")
    if not remainder then return false end
    local index = 0
    for value in remainder:gmatch("%S+") do
        index = index + 1
        if index == 20 then return value == expected_start end
    end
    return false
end

local function speedtest_status_is_valid(data, job_id)
    local function finite_number(value, minimum, maximum)
        return type(value) == "number" and value == value and
            value > -math.huge and value < math.huge and
            value >= minimum and value <= maximum
    end
    if type(data) ~= "table" or tonumber(data.schema) ~= 1 or
       data.job_id ~= job_id or
       (data.state ~= "running" and data.state ~= "done" and
        data.state ~= "error") or
       type(data.ifname) ~= "string" or not validate_iface(data.ifname) or
       (data.direction ~= "download" and data.direction ~= "upload") or
       type(data.started_at) ~= "number" or
       data.started_at ~= math.floor(data.started_at) or
       type(data.deadline_at) ~= "number" or
       data.deadline_at ~= math.floor(data.deadline_at) or
       data.deadline_at <= data.started_at then
        return false
    end
    if data.state == "running" then
        return data.worker_generation == nil or
            (type(data.worker_generation) == "string" and
             data.worker_generation:match("^%d+:%d+$") ~= nil)
    end
    if type(data.timestamp) ~= "number" or
       data.timestamp ~= math.floor(data.timestamp) then
        return false
    end
    if data.state == "done" then
        return finite_number(data.mbps, 0, 10000000) and
            finite_number(data.bytes, 0, 1024 * 1024 * 1024) and
            finite_number(data.seconds, 0, 3600)
    end
    return type(data.error) == "string" and #data.error <= 128 and
        (data.curl_exit == nil or
         (type(data.curl_exit) == "number" and data.curl_exit >= 0 and
          data.curl_exit <= 255 and data.curl_exit == math.floor(data.curl_exit)))
end

-- Speed Test Start endpoint - initiates a speed test for a specific WAN interface
function action_speedtest_start()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"
    local uci = require "luci.model.uci".cursor()

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
    local size_raw = http.formvalue("size_mb")
    local timeout_raw = http.formvalue("timeout_s")
    local server = http.formvalue("server") or "cloudflare"
    local size_mb = size_raw and size_raw:match("^%d+$") and tonumber(size_raw) or
        (size_raw == nil and 10 or nil)
    local timeout_s = timeout_raw and timeout_raw:match("^%d+$") and tonumber(timeout_raw) or
        (timeout_raw == nil and 30 or nil)

    -- Speed test server configurations
    local servers = {
        cloudflare = {
            name = "Cloudflare (Global)",
            download = "https://speed.cloudflare.com/__down?bytes=%d",
            upload = "https://speed.cloudflare.com/__up",
            referer = "https://speed.cloudflare.com/"
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

    -- Reject unknown choices rather than silently redirecting an invalid
    -- request to a different endpoint.
    if not servers[server] then
        http.write(json.stringify({ok = false, error = "Invalid speed test server"}))
        return
    end
    local srv = servers[server]

    -- Validate interface name
    local safe_iface = validate_iface(ifname)
    local _, selected_set, selection_error = selected_wans(uci)
    if not selected_set or not safe_iface or not selected_set[safe_iface] then
        http.write(json.stringify({
            ok = false,
            error = selection_error or "Interface is not in the selected WAN set"
        }))
        return
    end

    -- Validate direction
    if direction ~= "download" and direction ~= "upload" then
        http.write(json.stringify({ok = false, error = "Invalid direction (must be download or upload)"}))
        return
    end
    if direction == "upload" and not srv.upload then
        http.write(json.stringify({
            ok = false,
            error = "Upload test not supported for " .. srv.name .. ". Use Cloudflare server."
        }))
        return
    end

    if not size_mb or size_mb < 5 or size_mb > 200 or
       not timeout_s or timeout_s < 5 or timeout_s > 60 then
        http.write(json.stringify({ok = false, error = "Invalid size or timeout"}))
        return
    end

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

    -- Treat ubus/UCI output as untrusted persistent input before embedding it
    -- in a shell command.
    local bind_arg = validate_ip(source_ip) or validate_iface(l3_device)
    if not bind_arg then
        http.write(json.stringify({ok = false, error = "Interface binding is invalid"}))
        return
    end

    -- A single global lease prevents concurrent curls from saturating every
    -- WAN. Crashed jobs are reclaimable after twice the maximum test timeout.
    if not acquire_lock_dir(SPEEDTEST_LOCK, 120) then
        http.write(json.stringify({ok = false, error = "Another speed test is already running"}))
        return
    end

    local nixio = require "nixio"
    speedtest_job_sequence = speedtest_job_sequence + 1
    local job_iface = safe_iface:gsub("[^%w%-]", "_")
    local job_id = string.format(
        "%s_%s_%d_%d_%d",
        job_iface, direction, os.time(), nixio.getpid(), speedtest_job_sequence
    )
    local job_file = "/tmp/jammonitor_speedtest_" .. job_id .. ".json"
    local worker_file = "/tmp/jammonitor_speedtest_" .. job_id .. ".worker"
    local started_at = os.time()
    local deadline_at = started_at + timeout_s + 15
    local bytes = size_mb * 1024 * 1024
    if not atomic_write(
        SPEEDTEST_LOCK .. "/job_id", job_id .. "\n", PRIVATE_FILE_MODE
    ) or not atomic_write(job_file, json.stringify({
        schema = 1,
        job_id = job_id,
        state = "running",
        ifname = safe_iface,
        direction = direction,
        started_at = started_at,
        deadline_at = deadline_at
    }), PRIVATE_FILE_MODE) then
        release_speedtest_lock(job_id)
        release_lock_dir(SPEEDTEST_LOCK)
        http.write(json.stringify({ok = false, error = "Failed to create speed test job"}))
        return
    end

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
        local referer_flag = srv.referer and string.format([[-e "%s" ]], srv.referer) or ""
        curl_cmd = string.format(
            [[curl -4 -L --max-time %d --interface '%s' %s-o /dev/null -sS -w '{"speed":%%{speed_download},"time":%%{time_total},"size":%%{size_download}}' '%s']],
            timeout_s, bind_arg, referer_flag, url
        )
    else
        curl_cmd = string.format(
            [[dd if=/dev/zero bs=1M count=%d 2>/dev/null | curl -4 -L --max-time %d --interface '%s' -X POST -o /dev/null -sS -w '{"speed":%%{speed_upload},"time":%%{time_total},"size":%%{size_upload}}' --data-binary @- '%s']],
            size_mb, timeout_s, bind_arg, srv.upload
        )
    end

    -- A dedicated executable gives the worker a real PID generation. Every
    -- status transition is temp-write + rename, and the lock is released only
    -- when its job token still matches this worker.
    local wrapper = string.format([=[#!/bin/sh
umask 077
JOB_FILE='%s'
JOB_ID='%s'
LOCK_DIR='%s'
IFACE='%s'
DIRECTION='%s'
STARTED_AT=%d
DEADLINE_AT=%d

write_status() {
    _status_tmp="${JOB_FILE}.tmp.$$"
    printf '%%s\n' "$1" >"$_status_tmp" &&
        chmod 600 "$_status_tmp" &&
        mv -f "$_status_tmp" "$JOB_FILE"
}

cleanup_worker() {
    _owner="$(cat "${LOCK_DIR}/job_id" 2>/dev/null)"
    if [ "$_owner" = "$JOB_ID" ]; then
        rm -f "${LOCK_DIR}/job_id" "${LOCK_DIR}/owner"
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    rm -f "$0"
}

START_TICKS="$(awk '{print $22}' "/proc/$$/stat" 2>/dev/null)"
case "$START_TICKS" in
    ""|*[!0-9]*)
        write_status "{\"schema\":1,\"job_id\":\"$JOB_ID\",\"state\":\"error\",\"ifname\":\"$IFACE\",\"direction\":\"$DIRECTION\",\"started_at\":$STARTED_AT,\"deadline_at\":$DEADLINE_AT,\"error\":\"worker_identity_unavailable\",\"timestamp\":$(date +%%s)}"
        cleanup_worker
        exit 1
        ;;
esac
WORKER_GENERATION="$$:$START_TICKS"
if ! write_status "{\"schema\":1,\"job_id\":\"$JOB_ID\",\"state\":\"running\",\"ifname\":\"$IFACE\",\"direction\":\"$DIRECTION\",\"started_at\":$STARTED_AT,\"deadline_at\":$DEADLINE_AT,\"worker_generation\":\"$WORKER_GENERATION\"}"; then
    cleanup_worker
    exit 1
fi

on_signal() {
    write_status "{\"schema\":1,\"job_id\":\"$JOB_ID\",\"state\":\"error\",\"ifname\":\"$IFACE\",\"direction\":\"$DIRECTION\",\"started_at\":$STARTED_AT,\"deadline_at\":$DEADLINE_AT,\"worker_generation\":\"$WORKER_GENERATION\",\"error\":\"worker_terminated\",\"timestamp\":$(date +%%s)}" || true
    cleanup_worker
    exit 1
}
trap on_signal HUP INT TERM

RESULT=$(%s 2>&1)
CURL_RC=$?
SPEED="$(printf '%%s' "$RESULT" | sed -n 's/.*"speed":\([0-9.]*\).*/\1/p')"
ELAPSED="$(printf '%%s' "$RESULT" | sed -n 's/.*"time":\([0-9.]*\).*/\1/p')"
SIZE="$(printf '%%s' "$RESULT" | sed -n 's/.*"size":\([0-9.]*\).*/\1/p')"

if [ "$CURL_RC" -eq 0 ] && awk -v speed="$SPEED" -v elapsed="$ELAPSED" -v size="$SIZE" '
    BEGIN {
        number = "^[0-9]+([.][0-9]+)?$"
        exit ! (speed ~ number && elapsed ~ number && size ~ number)
    }
'; then
    MBPS="$(awk -v speed="$SPEED" 'BEGIN {printf "%%.2f", speed * 8 / 1000000}')"
    write_status "{\"schema\":1,\"job_id\":\"$JOB_ID\",\"state\":\"done\",\"ifname\":\"$IFACE\",\"direction\":\"$DIRECTION\",\"started_at\":$STARTED_AT,\"deadline_at\":$DEADLINE_AT,\"worker_generation\":\"$WORKER_GENERATION\",\"mbps\":$MBPS,\"bytes\":$SIZE,\"seconds\":$ELAPSED,\"timestamp\":$(date +%%s)}" || true
else
    write_status "{\"schema\":1,\"job_id\":\"$JOB_ID\",\"state\":\"error\",\"ifname\":\"$IFACE\",\"direction\":\"$DIRECTION\",\"started_at\":$STARTED_AT,\"deadline_at\":$DEADLINE_AT,\"worker_generation\":\"$WORKER_GENERATION\",\"error\":\"speedtest_transport_failed\",\"curl_exit\":$CURL_RC,\"timestamp\":$(date +%%s)}" || true
fi
trap - HUP INT TERM
cleanup_worker
]=],
        job_file, job_id, SPEEDTEST_LOCK, safe_iface, direction,
        started_at, deadline_at, curl_cmd
    )
    if not atomic_write(worker_file, wrapper, EXECUTABLE_FILE_MODE) or
       not checked_call("/bin/sh -n " .. worker_file) or
       sys.call(worker_file .. " >/dev/null 2>&1 &") ~= 0 then
        release_speedtest_lock(job_id)
        fs.remove(worker_file)
        fs.remove(job_file)
        http.write(json.stringify({ok = false, error = "Failed to launch speed test"}))
        return
    end

    http.write(json.stringify({
        ok = true,
        job_id = job_id,
        started_at = started_at,
        deadline_at = deadline_at
    }))
end

-- Speed Test Status endpoint - returns the status of a speed test job
function action_speedtest_status()
    local http = require "luci.http"
    local json = require "luci.jsonc"
    local fs = require "nixio.fs"
    local sys = require "luci.sys"

    http.prepare_content("application/json")

    local job_id = http.formvalue("job_id")
    if not job_id or #job_id > 128 or
       not job_id:match("^[a-zA-Z0-9_%-]+$") then
        http.write(json.stringify({ok = false, error = "Invalid job_id"}))
        return
    end

    local job_file = "/tmp/jammonitor_speedtest_" .. job_id .. ".json"
    local content = fs.readfile(job_file)

    if not content or content == "" then
        http.write(json.stringify({ok = false, error = "Job not found"}))
        return
    end
    if #content > 16384 then
        http.write(json.stringify({ok = false, error = "Invalid job data"}))
        return
    end

    local data = json.parse(content)
    if not speedtest_status_is_valid(data, job_id) then
        http.write(json.stringify({ok = false, error = "Invalid job data"}))
        return
    end

    if data.state == "running" then
        local now = os.time()
        local generation_live = process_generation_is_live(data.worker_generation)
        local startup_grace = now <= data.started_at + 5
        local terminal_error
        if now > data.deadline_at then
            terminal_error = "speedtest_deadline_exceeded"
        elseif data.worker_generation and not generation_live then
            terminal_error = "speedtest_worker_lost"
        elseif not data.worker_generation and not startup_grace then
            terminal_error = "speedtest_worker_identity_missing"
        end

        if terminal_error then
            -- Signal only the exact PID/start-tick generation we validated.
            -- SIGKILL is intentional for an overdue worker: it prevents its
            -- signal trap from racing a newer terminal status over this one.
            if generation_live then
                local pid = data.worker_generation:match("^(%d+):")
                if process_generation_is_live(data.worker_generation) then
                    sys.call("kill -KILL " .. pid .. " >/dev/null 2>&1")
                end
            end
            data.state = "error"
            data.error = terminal_error
            data.timestamp = now
            if not atomic_write(
                job_file, json.stringify(data), PRIVATE_FILE_MODE
            ) then
                http.write(json.stringify({
                    ok = false,
                    error = "Failed to finalize speed test status"
                }))
                return
            end
            fs.remove("/tmp/jammonitor_speedtest_" .. job_id .. ".worker")
            release_speedtest_lock(job_id)
        end
    else
        -- Recover a lock left behind after a worker completed but crashed
        -- during cleanup. Ownership is checked before anything is removed.
        release_speedtest_lock(job_id)
    end

    data.ok = true
    http.write(json.stringify(data))
end
