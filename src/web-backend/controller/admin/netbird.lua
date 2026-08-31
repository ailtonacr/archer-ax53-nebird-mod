-- NetBird runtime/identity controller for TP-Link Archer AX53 V1.
--
-- Generic profile CRUD/list/toggle/connected-status is owned by the stock
-- /admin/vpn?form=server endpoint for type=netbirdvpn. This endpoint remains
-- only for NetBird-specific concerns that the generic VPN contract cannot own:
-- enrollment, runtime diagnostics/logs/payload state, identity cleanup and a
-- manual restart action that delegates back to the native vpnc/netifd lifecycle.
-- It deliberately does not expose a writable profile-settings operation:
-- vpn/server is the sole normal configuration authority.
module("luci.controller.admin.netbird", package.seeall)

local nixio = require "nixio"
local http   = require "luci.http"
local lfs    = require "luci.fs"
local sys    = require "luci.sys"
local model  = require "luci.model.netbird"
local controller = require "luci.model.controller"
local uci    = require("luci.model.uci").cursor()

local SETTINGS = "/tp_data/netbird/settings"
local TRAFFIC_STATE = "/tmp/netbird-traffic.state"
local PROFILE_CONFIG = "/tp_data/netbird/default.json"
local PROFILE_STATE = "/tp_data/netbird/state"
local NATIVE_TYPE = "netbirdvpn"

function index() entry({"admin", "netbird"}, call("_index")).leaf = true end
function _index() return controller._index(dispatch) end

local function reply(t) return { success = true, data = t } end
local function error_reply(code, msg)
    return { success = false, errorcode = code, data = { error = msg or code, code = code } }
end

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

local function request_value(body, key)
    if body and body[key] ~= nil then return scalar(body[key]) end
    return http.formvalue(key)
end

local PROFILE_KEYS = {
    description = "scalar",
    management_url = "scalar",
    hostname = "scalar",
    disable_dns = "bool",
    disable_firewall = "bool",
    disable_client_routes = "bool",
    disable_server_routes = "bool",
    disable_ipv6 = "bool",
    network_monitor = "bool",
    advertise_lan = "bool",
    advertise_cidr = "scalar",
    wireguard_port = "scalar",
    enable = "bool",
}

-- vpn/server is the authoritative native profile store. The runtime settings
-- file is only a materialized view used by the existing NetBird shell/runtime.
local function native_profile()
    local found
    uci:foreach("vpn", "server", function(section)
        if section.type == NATIVE_TYPE then
            found = section
            return false
        end
    end)
    return found
end

local function native_profile_exists()
    return native_profile() ~= nil
end

local function native_profile_active()
    return uci:get("vpn", "client", "enabled") == "on" and
           uci:get("vpn", "client", "vpntype") == NATIVE_TYPE
end

local function sync_settings_from_native_profile()
    local profile = native_profile()
    if not profile then return nil, "native NetBird VPN profile not found" end

    local cand = {}
    for key, kind in pairs(PROFILE_KEYS) do
        local value = profile[key]
        if value ~= nil then
            cand[key] = kind == "bool" and bool01(value, nil) or scalar(value)
        end
    end
    cand.enable = "0"
    return model.set_settings(cand)
end

local function classify(settings, status)
    if not model.payload_ok() then return "payload_missing" end
    local ds = status and status.daemonStatus or ""
    if ds == "NeedsLogin" then return "enrollment_required"
    elseif ds == "Connected" then return settings.enable == "1" and "connected" or "disabled"
    elseif ds == "Connecting" or ds == "Restarting" then return settings.enable == "1" and "connecting" or "disabled"
    elseif ds == "Idle" or ds == "Disconnected" or ds == "Down" then
        return settings.enable == "1" and "disconnected" or "disabled"
    end
    return settings.enable == "1" and "stopped" or "disabled"
end

local function identity_present()
    local raw = lfs.readfile(PROFILE_CONFIG) or ""
    return raw:match("%S") ~= nil
end

local function reconcile_runtime(settings, status)
    local patch = {}
    local active = native_profile_active()
    local expected_enable = active and "1" or "0"

    if settings.enable ~= expected_enable then
        patch.enable = expected_enable
    end

    if status then
        local ds = status.daemonStatus or ""
        if ds == "NeedsLogin" then
            if settings.enrolled ~= "0" then patch.enrolled = "0" end
        elseif ds == "Connected" or ds == "Connecting" or ds == "Restarting" then
            if settings.enrolled ~= "1" then patch.enrolled = "1" end
        elseif ds == "Idle" or ds == "Disconnected" or ds == "Down" then
            if identity_present() and settings.enrolled ~= "1" then patch.enrolled = "1" end
        end
    elseif identity_present() and settings.enrolled ~= "1" then
        patch.enrolled = "1"
    end

    if next(patch) then
        local updated = model.set_internal_settings(patch)
        if updated then return updated end
    end
    return settings
end

local function read_number(path)
    local raw = lfs.readfile(path)
    return tonumber(raw and raw:match("(%d+)") or "") or 0
end

local function traffic_sample()
    local uptime = lfs.readfile("/proc/uptime") or ""
    local now = tonumber(uptime:match("^([%d%.]+)")) or 0
    local rx = read_number("/sys/class/net/wt0/statistics/rx_bytes")
    local tx = read_number("/sys/class/net/wt0/statistics/tx_bytes")
    local upload, download = 0, 0
    local prev = lfs.readfile(TRAFFIC_STATE) or ""
    local pts, prx, ptx = prev:match("^([%d%.]+)%s+(%d+)%s+(%d+)")
    pts, prx, ptx = tonumber(pts), tonumber(prx), tonumber(ptx)
    if pts and prx and ptx and now > pts and rx >= prx and tx >= ptx then
        local dt = now - pts
        download = (rx - prx) / dt
        upload = (tx - ptx) / dt
    end
    lfs.writefile(TRAFFIC_STATE, string.format("%.3f %d %d\n", now, rx, tx))
    return {
        uploadSpeed = math.floor(upload + 0.5),
        downloadSpeed = math.floor(download + 0.5),
        txBytes = tx,
        rxBytes = rx,
    }
end

local function op_status()
    local settings = model.get_settings()
    local st = model.status()
    settings = reconcile_runtime(settings, st)
    local nb = {}
    if st then
        nb = {
            daemonStatus = st.daemonStatus or "", cliVersion = st.cliVersion or "",
            daemonVersion = st.daemonVersion or "", netbirdIp = st.netbirdIp or "",
            publicKey = st.publicKey or "", fqdn = st.fqdn or "",
            wireguardPort = st.wireguardPort or 0,
            managementConnected = st.management and st.management.connected or false,
            managementUrl = st.management and st.management.url or "",
            signalConnected = st.signal and st.signal.connected or false,
            peersTotal = st.peers and st.peers.total or 0,
            peersConnected = st.peers and st.peers.connected or 0,
        }
    end
    return reply({
        code = classify(settings, st),
        settings = settings,
        netbird = nb,
        profileExists = native_profile_exists(),
        traffic = traffic_sample(),
        payload = {
            version = model.payload_version(),
            state = model.payload_state(),
            provisioned = model.payload_ok(),
        },
    })
end

local function op_connected_status()
    return reply(model.connected_status())
end

local function op_settings_get()
    -- Read-only diagnostics. All writes must go through stock /admin/vpn CRUD.
    return reply({ settings = model.get_settings(), profileExists = native_profile_exists() })
end

-- Called after every successful stock remove by the patched frontend. This is
-- deliberately idempotent so deleting a non-NetBird stock profile is harmless:
-- if a native NetBird profile still exists, cleanup is skipped; if no NetBird
-- profile and no NetBird artifacts exist, this is a no-op. Stale orphan identity
-- without a native profile is safely cleaned as recovery hygiene.
local function op_profile_delete()
    if native_profile_exists() then
        return reply({ result = "skipped", profileExists = true })
    end

    if not lfs.access(SETTINGS) and not lfs.access(PROFILE_CONFIG) and not lfs.access(PROFILE_STATE) then
        nixio.fs.unlink(TRAFFIC_STATE)
        return reply({ result = "noop", profileExists = false })
    end

    local clean_out, clean_rc = model.control("clean")
    if clean_rc ~= 0 then
        return error_reply("delete_failed", "failed to clean NetBird identity: " .. (clean_out or "clean failed"):gsub("%s+$", ""))
    end

    nixio.fs.unlink(SETTINGS)
    nixio.fs.unlink(SETTINGS .. ".tmp")
    nixio.fs.unlink(PROFILE_CONFIG)
    nixio.fs.unlink(TRAFFIC_STATE)

    if lfs.access(SETTINGS) or lfs.access(PROFILE_CONFIG) or lfs.access(PROFILE_STATE) then
        return error_reply("delete_failed", "NetBird runtime files remain after cleanup")
    end
    return reply({ result = "ok", profileExists = false })
end

local function op_enroll(body)
    local key = request_value(body, "setup_key")
    if not key or key == "" then return error_reply("bad_request", "setup key required") end

    local synced, sync_err = sync_settings_from_native_profile()
    if not synced then
        return error_reply("profile_required", sync_err or "save the NetBird VPN profile before enrollment")
    end

    local tmp = "/tmp/nb-setup-key-" .. tostring(os.time()) .. "-" .. tostring(math.random(0x7fffffff))
    if not lfs.writefile(tmp, key) then return error_reply("internal", "failed to stage setup key") end
    nixio.fs.chmod(tmp, "0600")
    local out, rc = model.control("enroll", tmp)
    nixio.fs.unlink(tmp)
    if rc ~= 0 then return error_reply("enroll_failed", (out or "enrollment failed"):gsub("%s+$", "")) end

    model.control("stop")
    local cur, state_err = model.set_internal_settings({ enrolled = "1", enable = "0" })
    if not cur then return error_reply("internal", state_err or "failed to persist enrollment state") end
    return reply({ result = "ok", settings = cur })
end

local function op_restart()
    if not native_profile_active() then
        return error_reply("not_active", "NetBird is not the active TP-Link VPN Client profile")
    end
    local rc = sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")
    if rc ~= 0 then return error_reply("control_failed", "native vpnc restart failed") end
    return reply({ result = "ok" })
end

local function op_clean()
    local _, rc = model.control("clean")
    if rc ~= 0 then return error_reply("control_failed", "NetBird clean failed") end
    local cur, err = model.set_internal_settings({ enrolled = "0", enable = "0" })
    if not cur then return error_reply("internal", err or "failed to reset NetBird state") end
    return reply({ result = "ok", settings = cur })
end

local function op_log(body)
    local n = request_value(body, "lines") or "100"
    return reply({ lines = model.log(tonumber(n) or 100) })
end

local function op_payload_status()
    return reply({ version = model.payload_version(), provisioned = model.payload_ok(), state = model.payload_state() })
end

function dispatch(body)
    local op = request_value(body, "operation") or "status"
    local ok_dispatch, result = pcall(function()
        if op == "status" then return op_status()
        elseif op == "connected_status" then return op_connected_status()
        elseif op == "settings_get" then return op_settings_get()
        elseif op == "profile_delete" then return op_profile_delete()
        elseif op == "enroll" then return op_enroll(body)
        elseif op == "restart" then return op_restart()
        elseif op == "clean" then return op_clean()
        elseif op == "log" then return op_log(body)
        elseif op == "payload_status" then return op_payload_status()
        else return error_reply("bad_request", "unknown operation") end
    end)
    if ok_dispatch then return result end
    return error_reply("internal", tostring(result))
end
