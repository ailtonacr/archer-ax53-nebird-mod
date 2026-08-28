-- NetBird adapter for TP-Link's native VPN Client controller.
--
-- This file is installed as luci.controller.admin.vpn while the original
-- compiled TP-Link controller is preserved OUTSIDE luci/controller/. LuCI's
-- controller indexer scans every *.lua file below that tree and requires the
-- declared module name to match the file path. Keeping a backup there as
-- controller/admin/vpn_stock.lua therefore breaks the entire LuCI dispatch
-- tree because the stock bytecode still declares luci.controller.admin.vpn.
--
-- We execute the stock chunk first, retain every stock handler, and override
-- only the server handlers needed for the NetBird profile. The adapter also
-- patches dispatcher upvalues by function identity when the stock bytecode
-- captured handlers in locals/tables. This keeps the stock HTTP envelope while
-- making interception independent of whether the vendor dispatcher resolves
-- handlers globally or through closures.
module("luci.controller.admin.vpn", package.seeall)

local http    = require "luci.http"
local fs      = require "luci.fs"
local json    = require "luci.json"
local nbmodel = require "luci.model.netbird"

local STOCK = "/usr/lib/lua/luci/netbird/vpn_stock.lua"
local ok, err = pcall(dofile, STOCK)
if not ok then
    error("failed to load stock VPN controller: " .. tostring(err))
end

-- Capture stock handlers only after the bytecode populated this module.
local stock = {
    vpn_dispatch          = vpn_dispatch,
    get_server_info       = get_server_info,
    get_server_list       = get_server_list,
    client_add_server     = client_add_server,
    client_modify_server  = client_modify_server,
    client_delete_server  = client_delete_server,
    enable_server         = enable_server,
    _find_item            = _find_item,
}

local SETTINGS = "/tp_data/netbird/settings"
local TRACE_FILE = "/tmp/netbird-vpn-adapter.log"
local NB_KEY = "netbird"
local NB_TYPE = "netbird"
local MAX_SCAN_DEPTH = 6

local function scalar(v)
    if type(v) == "table" then return v[#v] end
    if v == nil then return nil end
    return tostring(v)
end

local function normalized(v)
    local s = scalar(v)
    if not s then return nil end
    return s:lower()
end

local function bool01(v, fallback)
    if v == nil then return fallback end
    if v == true or v == 1 or v == "1" or v == "on" or v == "true" or v == "enabled" then return "1" end
    if v == false or v == 0 or v == "0" or v == "off" or v == "false" or v == "disabled" then return "0" end
    return fallback
end

local function each_arg(...)
    local out = {}
    for i = 1, select("#", ...) do out[#out + 1] = select(i, ...) end
    return out
end

-- Minimal diagnostics live only in /tmp. Never record request bodies, setup
-- keys, passwords, cookies or stok values. Only fixed event names and bounded
-- internal errors/operation labels are written.
local function trace(event, detail)
    local f = io.open(TRACE_FILE, "a")
    if not f then return end
    local msg = tostring(detail or ""):gsub("[%c]", " "):sub(1, 240)
    f:write(os.date("%Y-%m-%dT%H:%M:%S"), " ", tostring(event or "event"), " ", msg, "\n")
    f:close()
end

local function request_body()
    local ok_body, body = pcall(http.formvaluetable)
    return ok_body and type(body) == "table" and body or {}
end

local function table_is_netbird(t)
    if type(t) ~= "table" then return false end
    local key = normalized(t.key or t.id or t.name)
    local typ = normalized(t.type or t.proto or t.vpntype or t.client_type)
    return key == NB_KEY or typ == NB_TYPE
end

local function decode_json_table(value)
    if type(value) ~= "string" then return nil end
    local first = value:match("^%s*(.)")
    if first ~= "{" and first ~= "[" then return nil end
    local ok_json, decoded = pcall(json.decode, value)
    if ok_json and type(decoded) == "table" then return decoded end
    return nil
end

local scan_value
local PRIORITY_KEYS = {
    "new", "data", "profile", "server", "item", "record", "value",
    "form", "params", "payload", "config", "old",
}

-- Find a NetBird profile through both flat requests and the nested/serialized
-- envelopes commonly used by TP-Link update-store. `new` is intentionally
-- preferred over `old` for update requests.
local function scan_table(t, seen, depth)
    if type(t) ~= "table" or depth > MAX_SCAN_DEPTH then return nil end
    seen = seen or {}
    if seen[t] then return nil end
    seen[t] = true

    if table_is_netbird(t) then return t end

    for _, key in ipairs(PRIORITY_KEYS) do
        if t[key] ~= nil then
            local found = scan_value(t[key], seen, depth + 1)
            if found then return found end
        end
    end

    for key, value in pairs(t) do
        local prioritized = false
        for _, pkey in ipairs(PRIORITY_KEYS) do
            if key == pkey then prioritized = true break end
        end
        if not prioritized and (type(value) == "table" or type(value) == "string") then
            local found = scan_value(value, seen, depth + 1)
            if found then return found end
        end
    end
    return nil
end

scan_value = function(value, seen, depth)
    if depth > MAX_SCAN_DEPTH then return nil end
    if type(value) == "table" then return scan_table(value, seen, depth) end
    local decoded = decode_json_table(value)
    if decoded then return scan_table(decoded, seen, depth) end
    return nil
end

local function request_operation(body)
    body = type(body) == "table" and body or {}
    return normalized(body.operation or body.action or body.method)
        or normalized(http.formvalue("operation"))
        or normalized(http.formvalue("action"))
        or normalized(http.formvalue("method"))
        or "unknown"
end

local function direct_request_is_netbird()
    local key = normalized(http.formvalue("key") or http.formvalue("id") or http.formvalue("name"))
    local typ = normalized(http.formvalue("type") or http.formvalue("proto") or http.formvalue("vpntype") or http.formvalue("client_type"))
    return key == NB_KEY or typ == NB_TYPE
end

local function request_context(...)
    local body = request_body()
    local profile, source

    for i, value in ipairs(each_arg(...)) do
        profile = scan_value(value, {}, 0)
        if profile then source = "arg" .. tostring(i); break end
    end

    if not profile then
        profile = scan_value(body, {}, 0)
        if profile then source = "body" end
    end

    if not profile then
        -- formvaluetable() implementations vary across TP-Link builds. Probe
        -- common envelope fields individually as a compatibility fallback.
        for _, key in ipairs(PRIORITY_KEYS) do
            local raw = http.formvalue(key)
            profile = scan_value(raw, {}, 0)
            if profile then source = "form:" .. key; break end
        end
    end

    local is_netbird = profile ~= nil or direct_request_is_netbird()
    return {
        body = body,
        profile = profile or body,
        is_netbird = is_netbird,
        source = source or (is_netbird and "direct" or "none"),
        operation = request_operation(body),
    }
end

local function profile_exists()
    return fs.access(SETTINGS) and true or false
end

local function runtime_status()
    local st = nbmodel.status() or {}
    local ds = st.daemonStatus or ""
    local status = "disconnected"
    if ds == "Connected" then status = "connected"
    elseif ds == "Connecting" or ds == "Restarting" then status = "connecting" end
    return st, status
end

local function read_counter(path)
    local raw = fs.readfile(path) or ""
    return tonumber(raw:match("(%d+)")) or 0
end

local function profile_info()
    local s = nbmodel.get_settings()
    local st, status = runtime_status()
    return {
        key = NB_KEY,
        id = NB_KEY,
        name = "NetBird",
        des = "NetBird",
        description = "NetBird",
        type = NB_TYPE,
        proto = NB_TYPE,
        vpntype = NB_TYPE,
        vendor = "manual",
        server = s.management_url or "",
        server_name = s.management_url or "",
        management_url = s.management_url or "",
        hostname = s.hostname or "",
        enable = s.enable == "1" and "on" or "off",
        enabled = s.enable == "1",
        enrolled = s.enrolled or "0",
        status = status,
        connected_status = status,
        disable_dns = s.disable_dns or "1",
        disable_firewall = s.disable_firewall or "1",
        disable_client_routes = s.disable_client_routes or "1",
        disable_server_routes = s.disable_server_routes or "1",
        disable_ipv6 = s.disable_ipv6 or "1",
        network_monitor = s.network_monitor or "0",
        advertise_lan = s.advertise_lan or "0",
        advertise_cidr = s.advertise_cidr or "",
        wireguard_port = s.wireguard_port or "51820",
        upload_speed = 0,
        download_speed = 0,
        uploadSpeed = 0,
        downloadSpeed = 0,
        tx_bytes = read_counter("/sys/class/net/wt0/statistics/tx_bytes"),
        rx_bytes = read_counter("/sys/class/net/wt0/statistics/rx_bytes"),
        netbird_ip = st.netbirdIp or "",
    }
end

local function candidate_from(t)
    t = type(t) == "table" and t or {}
    local cand = {}
    local mgmt = scalar(t.management_url or t.server)
    if mgmt ~= nil then cand.management_url = mgmt end
    if t.hostname ~= nil then cand.hostname = scalar(t.hostname) end
    if t.disable_dns ~= nil then cand.disable_dns = bool01(t.disable_dns, "1") end
    if t.disable_firewall ~= nil then cand.disable_firewall = bool01(t.disable_firewall, "1") end
    if t.disable_client_routes ~= nil then cand.disable_client_routes = bool01(t.disable_client_routes, "1") end
    if t.disable_server_routes ~= nil then cand.disable_server_routes = bool01(t.disable_server_routes, "1") end
    if t.disable_ipv6 ~= nil then cand.disable_ipv6 = bool01(t.disable_ipv6, "1") end
    if t.network_monitor ~= nil then cand.network_monitor = bool01(t.network_monitor, "0") end
    if t.advertise_lan ~= nil then cand.advertise_lan = bool01(t.advertise_lan, "0") end
    if t.advertise_cidr ~= nil then cand.advertise_cidr = scalar(t.advertise_cidr) end
    if t.wireguard_port ~= nil then cand.wireguard_port = scalar(t.wireguard_port) end
    if t.enable ~= nil or t.enabled ~= nil then
        cand.enable = bool01(t.enable ~= nil and t.enable or t.enabled, "0")
    end
    return cand
end

local function safe_netbird(label, fn)
    local ok_call, a, b = pcall(fn)
    if ok_call then return a, b end
    local msg = tostring(a or "unknown NetBird adapter error"):gsub("[%c]", " "):sub(1, 240)
    trace("error:" .. label, msg)
    return nil, "NetBird " .. label .. " failed: " .. msg
end

local function save_profile(t)
    local cand = candidate_from(t)
    local saved, save_err = nbmodel.set_settings(cand)
    if not saved then return nil, save_err or "failed to save NetBird profile" end

    -- Native CRUD owns the requested enabled state. Only start automatically
    -- after enrollment; otherwise saving a profile must never trigger SSO.
    if saved.enable == "1" and saved.enrolled == "1" then
        local out, rc = nbmodel.control("start")
        if rc ~= 0 then return nil, (out or "failed to start NetBird"):gsub("%s+$", "") end
        saved = nbmodel.set_internal_settings({ enable = "1", enrolled = "1" }) or saved
    end
    return profile_info()
end

local function set_enabled(value)
    local enable = bool01(value, "0")
    if enable == "1" then
        local s = nbmodel.get_settings()
        if s.enrolled ~= "1" then return nil, "NetBird enrollment required" end
        local out, rc = nbmodel.control("start")
        if rc ~= 0 then return nil, (out or "failed to start NetBird"):gsub("%s+$", "") end
        nbmodel.set_internal_settings({ enable = "1", enrolled = "1" })
    else
        local out, rc = nbmodel.control("stop")
        if rc ~= 0 then return nil, (out or "failed to stop NetBird"):gsub("%s+$", "") end
        nbmodel.set_internal_settings({ enable = "0" })
    end
    return profile_info()
end

local function delete_profile()
    nbmodel.control("stop")
    nbmodel.control("clean")
    fs.unlink(SETTINGS)
    return true
end

-- The TP-Link controller exposes these handlers from the module. Keep their
-- native names/signatures and use varargs so minor firmware signature changes
-- do not affect delegation of stock VPN types.
function get_server_info(...)
    local ctx = request_context(...)
    if ctx.is_netbird then
        trace("get", ctx.operation .. ":" .. ctx.source)
        return safe_netbird("get", profile_info)
    end
    if stock.get_server_info then return stock.get_server_info(...) end
    return nil
end

function get_server_list(...)
    local list
    if stock.get_server_list then list = stock.get_server_list(...) end
    if type(list) ~= "table" then list = {} end
    if profile_exists() then
        local found = false
        for _, item in ipairs(list) do if table_is_netbird(item) then found = true break end end
        if not found then list[#list + 1] = profile_info() end
    end
    return list
end

function client_add_server(...)
    local ctx = request_context(...)
    if ctx.is_netbird then
        trace("add", ctx.operation .. ":" .. ctx.source)
        return safe_netbird("add", function() return save_profile(ctx.profile) end)
    end
    if stock.client_add_server then return stock.client_add_server(...) end
    return nil
end

function client_modify_server(...)
    local ctx = request_context(...)
    if ctx.is_netbird then
        trace("modify", ctx.operation .. ":" .. ctx.source)
        return safe_netbird("modify", function() return save_profile(ctx.profile) end)
    end
    if stock.client_modify_server then return stock.client_modify_server(...) end
    return nil
end

function client_delete_server(...)
    local ctx = request_context(...)
    if ctx.is_netbird then
        trace("delete", ctx.operation .. ":" .. ctx.source)
        return safe_netbird("delete", delete_profile)
    end
    if stock.client_delete_server then return stock.client_delete_server(...) end
    return nil
end

function enable_server(...)
    local ctx = request_context(...)
    if ctx.is_netbird then
        local t = type(ctx.profile) == "table" and ctx.profile or {}
        local value = t.enable
        if value == nil then value = t.enabled end
        if value == nil then value = http.formvalue("enable") or http.formvalue("enabled") end
        if value == nil then
            local args = each_arg(...)
            for _, v in ipairs(args) do
                if v == "on" or v == "off" or v == "1" or v == "0" or type(v) == "boolean" then value = v end
            end
        end
        trace("enable", ctx.operation .. ":" .. ctx.source)
        return safe_netbird("enable", function() return set_enabled(value) end)
    end
    if stock.enable_server then return stock.enable_server(...) end
    return nil
end

-- Some stock handlers resolve a record through _find_item before calling the
-- operation-specific function. Supplying the native NetBird record here keeps
-- that path on /admin/vpn as well, while delegating every other lookup.
function _find_item(...)
    local ctx = request_context(...)
    if ctx.is_netbird then return profile_info() end
    if stock._find_item then return stock._find_item(...) end
    return nil
end

-- Some vendor Lua bytecode versions capture handler functions into dispatcher
-- upvalues or handler tables during module initialization. Merely replacing the
-- globals is insufficient in that case. Patch only values that are EXACTLY one
-- of the captured stock handler functions, preserving every unrelated upvalue.
local function patch_handler_table(t, replacements, seen, depth)
    if type(t) ~= "table" or depth > 3 then return 0 end
    seen = seen or {}
    if seen[t] then return 0 end
    seen[t] = true
    local changed = 0
    for key, value in pairs(t) do
        local replacement = replacements[value]
        if replacement then
            t[key] = replacement
            changed = changed + 1
        elseif type(value) == "table" then
            changed = changed + patch_handler_table(value, replacements, seen, depth + 1)
        end
    end
    return changed
end

local function patch_dispatch_upvalues()
    if type(stock.vpn_dispatch) ~= "function" then return 0 end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" or type(debug.setupvalue) ~= "function" then
        trace("dispatcher", "debug-upvalues-unavailable")
        return 0
    end

    local replacements = {}
    if type(stock.get_server_info) == "function" then replacements[stock.get_server_info] = get_server_info end
    if type(stock.get_server_list) == "function" then replacements[stock.get_server_list] = get_server_list end
    if type(stock.client_add_server) == "function" then replacements[stock.client_add_server] = client_add_server end
    if type(stock.client_modify_server) == "function" then replacements[stock.client_modify_server] = client_modify_server end
    if type(stock.client_delete_server) == "function" then replacements[stock.client_delete_server] = client_delete_server end
    if type(stock.enable_server) == "function" then replacements[stock.enable_server] = enable_server end
    if type(stock._find_item) == "function" then replacements[stock._find_item] = _find_item end

    local changed, i = 0, 1
    while true do
        local name, value = debug.getupvalue(stock.vpn_dispatch, i)
        if not name then break end
        local replacement = replacements[value]
        if replacement then
            debug.setupvalue(stock.vpn_dispatch, i, replacement)
            changed = changed + 1
        elseif type(value) == "table" then
            changed = changed + patch_handler_table(value, replacements, {}, 0)
        end
        i = i + 1
    end
    trace("dispatcher", "patched=" .. tostring(changed))
    return changed
end

patch_dispatch_upvalues()

-- Keep the stock dispatcher itself so its request/response envelope remains
-- byte-for-byte vendor-owned. The adapter handlers above are visible either as
-- globals or through the patched captured references.
if stock.vpn_dispatch then vpn_dispatch = stock.vpn_dispatch end
