-- Native TP-Link VPN Client registration for NetBird.
--
-- The vendor controller remains byte-for-byte stock. Its protocol registries are
-- module globals (VPN_CFG_TBL, VPN_TYPE_TBL, VPN_TYPE_NAME_TBL and VPN_TBL),
-- and the stock dispatcher reads them dynamically. Registering NetBird here
-- therefore extends the real /admin/vpn?form=server path without replacing or
-- monkey-patching any captured dispatcher closure.
module("luci.model.netbird_vpn_native", package.seeall)

local nb_model = require "luci.model.netbird"

TYPE = "netbirdvpn"
TYPE_ID = "5"
TYPE_NAME = "NetBird"
PROTO = "netbird"

local installed = false

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
    "kill_switch",
}

local function bool01(v, fallback)
    if v == nil then return fallback end
    if v == true or v == 1 or v == "1" or v == "on" or v == "true" or v == "enabled" then return "1" end
    if v == false or v == 0 or v == "0" or v == "off" or v == "false" or v == "disabled" then return "0" end
    return fallback
end

local function settings_from_config(cfg)
    return {
        management_url = cfg.management_url or "",
        hostname = cfg.hostname or "",
        disable_dns = bool01(cfg.disable_dns, "1"),
        disable_firewall = bool01(cfg.disable_firewall, "1"),
        disable_client_routes = bool01(cfg.disable_client_routes, "1"),
        disable_server_routes = bool01(cfg.disable_server_routes, "1"),
        disable_ipv6 = bool01(cfg.disable_ipv6, "1"),
        network_monitor = bool01(cfg.network_monitor, "0"),
        advertise_lan = bool01(cfg.advertise_lan, "0"),
        advertise_cidr = cfg.advertise_cidr or "",
        wireguard_port = tostring(cfg.wireguard_port or "51820"),
        enable = (cfg.connect == "0" or cfg.connect == 0 or cfg.connect == false) and "0" or "1",
    }
end

local function netbird_config(cfg, vpn_type)
    cfg = cfg or {}

    -- Keep the already validated runtime settings file synchronized while the
    -- stock controller remains authoritative for profile CRUD. Enrollment is
    -- intentionally not touched here; it represents NetBird identity state.
    local settings = settings_from_config(cfg)
    local updated, err = nb_model.set_settings(settings)
    if not updated then
        io.stderr:write("netbird: native VPN config rejected: " .. tostring(err or "invalid settings") .. "\n")
        return {}
    end

    local vpn = {
        proto = PROTO,
        auto = "1",
        connectable = cfg.connect or "1",
        management_url = updated.management_url,
        hostname = updated.hostname,
        wireguard_port = updated.wireguard_port,
        server = cfg.server or updated.management_url,
        parent = cfg.parent or "wan",
    }

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

    -- The validator iterates numeric entries with ipairs while protocol
    -- handlers read the named .proto member, matching the vendor table shape.
    local schema = {
        { field = FIELDS, canbe_empty = true },
    }
    schema.proto = PROTO

    vpn.VPN_TBL[TYPE] = schema
    vpn.VPN_CFG_TBL[TYPE] = netbird_config
    vpn.VPN_TYPE_TBL[TYPE] = TYPE_ID
    vpn.VPN_TYPE_NAME_TBL[TYPE] = TYPE_NAME

    installed = true
    return true
end
