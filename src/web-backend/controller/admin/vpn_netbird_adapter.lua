-- NetBird adapter for TP-Link's native VPN Client controller.
--
-- This file is installed as luci.controller.admin.vpn while the original
-- compiled TP-Link controller is preserved as vpn_stock.lua.  We execute the
-- stock chunk first, retain every stock handler, and override only the server
-- handlers needed for the NetBird profile.  Therefore the HTTP contract stays
-- on the native /admin/vpn?form=server route and every non-NetBird VPN type is
-- delegated unchanged to TP-Link's implementation.
module("luci.controller.admin.vpn", package.seeall)

local http    = require "luci.http"
local fs      = require "luci.fs"
local nbmodel = require "luci.model.netbird"

local STOCK = "/usr/lib/lua/luci/controller/admin/vpn_stock.lua"
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
local NB_KEY = "netbird"
local NB_TYPE = "netbird"

local function scalar(v)
    if type(v) == "table" then return v[#v] end
    if v == nil then return nil end
    return tostring(v)
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

local function request_body()
    local ok_body, body = pcall(http.formvaluetable)
    return ok_body and type(body) == "table" and body or {}
end

local function table_is_netbird(t)
    if type(t) ~= "table" then return false end
    local key = scalar(t.key or t.id or t.name)
    local typ = scalar(t.type or t.proto or t.vpntype or t.client_type)
    return key == NB_KEY or typ == NB_TYPE
end

local function request_is_netbird(...)
    for _, v in ipairs(each_arg(...)) do
        if type(v) == "string" and v == NB_KEY then return true end
        if table_is_netbird(v) then return true end
    end
    local body = request_body()
    return table_is_netbird(body) or scalar(http.formvalue("key")) == NB_KEY or scalar(http.formvalue("type")) == NB_TYPE
end

local function first_table(...)
    for _, v in ipairs(each_arg(...)) do
        if type(v) == "table" and (v.key ~= nil or v.type ~= nil or v.server ~= nil or v.management_url ~= nil) then
            return v
        end
    end
    local body = request_body()
    return body
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

local function save_profile(t)
    local cand = candidate_from(t)
    local saved, save_err = nbmodel.set_settings(cand)
    if not saved then return nil, save_err or "failed to save NetBird profile" end

    -- Native CRUD owns the requested enabled state.  Only start automatically
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

-- The TP-Link controller exposes these handlers from the module.  Keep their
-- native names/signatures and use varargs so minor firmware signature changes
-- do not affect delegation of stock VPN types.
function get_server_info(...)
    if request_is_netbird(...) then return profile_info() end
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
    if request_is_netbird(...) then return save_profile(first_table(...)) end
    if stock.client_add_server then return stock.client_add_server(...) end
    return nil
end

function client_modify_server(...)
    if request_is_netbird(...) then return save_profile(first_table(...)) end
    if stock.client_modify_server then return stock.client_modify_server(...) end
    return nil
end

function client_delete_server(...)
    if request_is_netbird(...) then return delete_profile() end
    if stock.client_delete_server then return stock.client_delete_server(...) end
    return nil
end

function enable_server(...)
    if request_is_netbird(...) then
        local t = first_table(...)
        local value = t.enable
        if value == nil then value = t.enabled end
        if value == nil then
            local args = each_arg(...)
            for _, v in ipairs(args) do
                if v == "on" or v == "off" or v == "1" or v == "0" or type(v) == "boolean" then value = v end
            end
        end
        return set_enabled(value)
    end
    if stock.enable_server then return stock.enable_server(...) end
    return nil
end

-- Some stock handlers resolve a record through _find_item before calling the
-- operation-specific function.  Supplying the native NetBird record here keeps
-- that path on /admin/vpn as well, while delegating every other lookup.
function _find_item(...)
    if request_is_netbird(...) then return profile_info() end
    if stock._find_item then return stock._find_item(...) end
    return nil
end

-- Keep the stock dispatcher and route registration.  The overridden module
-- handlers above are resolved by the stock controller at request time.
if stock.vpn_dispatch then vpn_dispatch = stock.vpn_dispatch end
