-- Native TP-Link VPN Client registration for NetBird.
--
-- The vendor controller remains byte-for-byte stock. Its protocol registries are
-- module globals (VPN_CFG_TBL, VPN_TYPE_TBL, VPN_TYPE_NAME_TBL and VPN_TBL),
-- and the stock dispatcher reads them dynamically. Registering NetBird here
-- therefore extends the real /admin/vpn?form=server path without replacing or
-- monkey-patching any captured dispatcher closure.
module("luci.model.netbird_vpn_native", package.seeall)

local nixio    = require "nixio"
local fs       = require "luci.fs"
local nb_model = require "luci.model.netbird"

TYPE = "netbirdvpn"
TYPE_ID = "5"
TYPE_NAME = "NetBird"
PROTO = "netbird"

local installed = false

-- Provider fields staged by the stock VPN path belong in VPN_TBL. The Setup Key
-- itself is deliberately absent; only an opaque short-lived enrollment_token
-- crosses vpn/server -> protocol.netbirdvpn and is deleted after consumption.
local FIELDS = {
    "management_url",
    "hostname",
    "disable_dns",
    "disable_firewall",
    "disable_client_routes",
    "disable_server_routes",
    "disable_ipv6",
    "network_monitor",
    "advertise_lan",
    "advertise_cidr",
    "wireguard_port",
    "server",
    "profile_key",
    "enrollment_token",
    "kill_switch",
}

local function bool01(v, fallback)
    if v == nil then return fallback end
    if v == true or v == 1 or v == "1" or v == "on" or v == "true" or v == "enabled" then return "1" end
    if v == false or v == 0 or v == "0" or v == "off" or v == "false" or v == "disabled" then return "0" end
    return fallback
end

local function management_host(url)
    url = tostring(url or "")
    local authority = url:match("^https?://([^/%?#]+)") or url:match("^([^/%?#]+)") or ""
    if authority:sub(1, 1) == "[" then
        return authority:match("^%[([^%]]+)%]") or authority
    end
    return authority:match("^([^:]+)") or authority
end

local function profile_key_from_config(cfg)
    local key = cfg.profile_key or cfg.key or cfg.id or cfg[".name"]
    key = tostring(key or "")
    if nb_model.valid_profile_key(key) then return key end
    return ""
end

local function value_or_current(cfg, current, key, fallback)
    if cfg[key] ~= nil then return cfg[key] end
    if current[key] ~= nil then return current[key] end
    return fallback
end

local function settings_from_config(cfg, profile_key)
    local current = profile_key ~= "" and nb_model.get_settings(profile_key) or {}
    if type(current) ~= "table" then current = {} end

    local management_url = value_or_current(cfg, current, "management_url", "")
    if management_url == "" then management_url = current.management_url or "" end

    local connect = cfg.connect
    local enable
    if connect == nil then
        enable = current.enable or "0"
    else
        enable = (connect == "0" or connect == 0 or connect == false or connect == "off") and "0" or "1"
    end

    return {
        description = tostring(value_or_current(cfg, current, "description", "NetBird") or "NetBird"),
        management_url = management_url,
        hostname = tostring(value_or_current(cfg, current, "hostname", "") or ""),
        disable_dns = bool01(cfg.disable_dns, current.disable_dns or "1"),
        disable_firewall = bool01(cfg.disable_firewall, current.disable_firewall or "1"),
        disable_client_routes = bool01(cfg.disable_client_routes, current.disable_client_routes or "1"),
        disable_server_routes = bool01(cfg.disable_server_routes, current.disable_server_routes or "1"),
        disable_ipv6 = bool01(cfg.disable_ipv6, current.disable_ipv6 or "1"),
        network_monitor = bool01(cfg.network_monitor, current.network_monitor or "0"),
        advertise_lan = bool01(cfg.advertise_lan, current.advertise_lan or "0"),
        advertise_cidr = tostring(value_or_current(cfg, current, "advertise_cidr", "") or ""),
        wireguard_port = tostring(value_or_current(cfg, current, "wireguard_port", "51820") or "51820"),
        enable = enable,
    }
end

local function netbird_config(cfg, vpn_type)
    cfg = cfg or {}
    local profile_key = profile_key_from_config(cfg)
    if profile_key == "" then
        io.stderr:write("netbird: stock VPN profile key missing\n")
        return {}
    end

    local settings = settings_from_config(cfg, profile_key)
    local updated, err = nb_model.set_settings(settings, profile_key)
    if not updated then
        io.stderr:write("netbird: native VPN config rejected: " .. tostring(err or "invalid settings") .. "\n")
        return {}
    end

    local enrollment_token = tostring(cfg.enrollment_token or "")
    local identity_present = nb_model.identity_present(profile_key)
    if enrollment_token ~= "" then
        local keyfile, token_err = nb_model.staged_setup_key_path(enrollment_token)
        if not keyfile then
            io.stderr:write("netbird: staged enrollment token invalid for profile " .. profile_key .. ": " .. tostring(token_err or "unavailable") .. "\n")
            return {}
        end
    elseif not identity_present then
        io.stderr:write("netbird: enrollment token required for unenrolled profile " .. profile_key .. "\n")
        return {}
    end

    local server = cfg.server
    if not server or server == "" then server = management_host(updated.management_url) end
    local vpn = {
        proto = PROTO,
        auto = "1",
        connectable = cfg.connect or "1",
        management_url = updated.management_url,
        hostname = updated.hostname,
        wireguard_port = updated.wireguard_port,
        server = server,
        parent = cfg.parent or "wan",
        profile_key = profile_key,
    }
    if enrollment_token ~= "" then vpn.enrollment_token = enrollment_token end
    if cfg.kill_switch ~= nil then vpn.kill_switch = cfg.kill_switch end
    return { vpn = vpn }
end

function install()
    if installed then return true end

    local vpn = require "luci.controller.admin.vpn"
    if type(vpn) ~= "table" then return nil, "stock VPN controller module unavailable" end
    if type(vpn.VPN_CFG_TBL) ~= "table" or type(vpn.VPN_TYPE_TBL) ~= "table" or
       type(vpn.VPN_TYPE_NAME_TBL) ~= "table" or type(vpn.VPN_TBL) ~= "table" then
        return nil, "stock VPN registries unavailable"
    end

    -- Match the vendor VPN_TBL contract observed on hardware exactly. Each
    -- provider-specific field is represented as a positional rule table with a
    -- single string member named "key"; generic fields (key/des/type/enable)
    -- remain owned by the stock controller.
    local schema = { proto = PROTO }
    for _, key in ipairs(FIELDS) do
        table.insert(schema, { key = key })
    end

    vpn.VPN_TBL[TYPE] = schema
    vpn.VPN_CFG_TBL[TYPE] = netbird_config
    vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID
    vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME

    installed = true
    return true
end
