-- NetBird provider-specific controller for TP-Link Archer AX53 V1.
--
-- Generic profile list/CRUD/toggle/connected-status is owned exclusively by the
-- stock /admin/vpn?form=server endpoint for type=netbirdvpn. This endpoint owns
-- only behavior TP-Link cannot implement generically: profile-scoped NetBird
-- enrollment, runtime diagnostics/logs/payload state and an explicit restart
-- delegated back to the native vpnc/netifd lifecycle.
module("luci.controller.admin.netbird", package.seeall)

local nixio = require "nixio"
local http   = require "luci.http"
local lfs    = require "luci.fs"
local sys    = require "luci.sys"
local model  = require "luci.model.netbird"
local controller = require "luci.model.controller"
local uci    = require("luci.model.uci").cursor()

local TRAFFIC_STATE = "/tmp/netbird-traffic.state"
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
}

local function requested_profile_key(body, required)
    local key = request_value(body, "profile_key")
    if not key or key == "" then
        if required then return nil, "profile key required" end
        return nil
    end
    if not model.valid_profile_key(key) then return nil, "invalid profile key" end
    return key
end

-- Resolve exactly one persisted stock row. Never fall back to "the first"
-- NetBird section: multiple profiles of the same provider are valid.
local function native_profile(profile_key)
    if not profile_key or not model.valid_profile_key(profile_key) then return nil end
    local found
    uci:foreach("vpn", "server", function(section)
        local name = section[".name"]
        if name == profile_key and section.type == NATIVE_TYPE then
            found = section
            return false
        end
    end)
    return found
end

local function active_profile_key()
    local key = uci:get("network", "vpn", "profile_key")
    if key and model.valid_profile_key(key) then return key end
    return nil
end

local function native_profile_active(profile_key)
    return profile_key ~= nil and
           uci:get("vpn", "client", "enabled") == "on" and
           uci:get("vpn", "client", "vpntype") == NATIVE_TYPE and
           active_profile_key() == profile_key
end

local function ensure_profile_key_option(profile_key, profile)
    if not profile then return nil, "native NetBird VPN profile not found" end
    if profile.profile_key == profile_key then return profile end
    if not uci:set("vpn", profile_key, "profile_key", profile_key) then
        return nil, "failed to persist native profile key"
    end
    if not uci:commit("vpn") then return nil, "failed to commit native profile key" end
    profile.profile_key = profile_key
    return profile
end

-- vpn.server is authoritative. The profile-scoped settings file is only a
-- materialized runtime view consumed by the NetBird protocol implementation.
local function sync_settings_from_native_profile(profile_key)
    local profile = native_profile(profile_key)
    if not profile then return nil, "native NetBird VPN profile not found" end
    local ensured, ensure_err = ensure_profile_key_option(profile_key, profile)
    if not ensured then return nil, ensure_err end

    local cand = {}
    for key, kind in pairs(PROFILE_KEYS) do
        local value = ensured[key]
        if value ~= nil then cand[key] = kind == "bool" and bool01(value, nil) or scalar(value) end
    end
    cand.enable = native_profile_active(profile_key) and "1" or "0"
    local settings, err = model.set_settings(cand, profile_key)
    if not settings then return nil, err end

    local identity = model.identity_present(profile_key)
    local updated = model.set_internal_settings({
        enrolled = identity and "1" or "0",
        enable = cand.enable,
    }, profile_key)
    return updated or settings
end

local function classify(settings, status, active)
    if not active then return "disabled" end
    if not model.payload_ok() then return "payload_missing" end
    local ds = status and status.daemonStatus or ""
    if ds == "NeedsLogin" then return "enrollment_required"
    elseif ds == "Connected" then return "connected"
    elseif ds == "Connecting" or ds == "Restarting" then return "connecting"
    elseif ds == "Idle" or ds == "Disconnected" or ds == "Down" then return "disconnected" end
    return settings.enable == "1" and "stopped" or "disabled"
end

local function reconcile_runtime(profile_key, settings, status, active)
    local patch = { enable = active and "1" or "0" }
    local identity = model.identity_present(profile_key)
    patch.enrolled = identity and "1" or "0"

    if status then
        local ds = status.daemonStatus or ""
        if ds == "NeedsLogin" then patch.enrolled = "0"
        elseif ds == "Connected" or ds == "Connecting" or ds == "Restarting" then patch.enrolled = "1" end
    end

    local changed = settings.enable ~= patch.enable or settings.enrolled ~= patch.enrolled
    if changed then
        local updated = model.set_internal_settings(patch, profile_key)
        if updated then return updated end
    end
    return settings
end

local function read_number(path)
    local raw = lfs.readfile(path)
    return tonumber(raw and raw:match("(%d+)") or "") or 0
end

local function traffic_sample(active)
    if not active then return { uploadSpeed = 0, downloadSpeed = 0, txBytes = 0, rxBytes = 0 } end
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
    return { uploadSpeed = math.floor(upload + 0.5), downloadSpeed = math.floor(download + 0.5), txBytes = tx, rxBytes = rx }
end

local function empty_netbird_status()
    return {
        daemonStatus = "", cliVersion = "", daemonVersion = "", netbirdIp = "",
        publicKey = "", fqdn = "", wireguardPort = 0,
        managementConnected = false, managementUrl = "", signalConnected = false,
        peersTotal = 0, peersConnected = 0,
    }
end

local function op_status(body)
    local profile_key, key_err = requested_profile_key(body, true)
    if not profile_key then return error_reply("bad_request", key_err) end

    local profile = native_profile(profile_key)
    if not profile then
        return reply({
            code = "disabled",
            settings = model.get_settings(profile_key),
            netbird = empty_netbird_status(),
            profileExists = false,
            profileKey = profile_key,
            traffic = traffic_sample(false),
            payload = { version = model.payload_version(), state = model.payload_state(), provisioned = model.payload_ok() },
        })
    end

    local settings, sync_err = sync_settings_from_native_profile(profile_key)
    if not settings then return error_reply("profile_invalid", sync_err) end
    local active = native_profile_active(profile_key)
    local st = active and model.status(profile_key) or nil
    settings = reconcile_runtime(profile_key, settings, st, active)
    local nb = empty_netbird_status()
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
        code = classify(settings, st, active),
        settings = settings,
        netbird = nb,
        profileExists = true,
        profileKey = profile_key,
        traffic = traffic_sample(active),
        payload = { version = model.payload_version(), state = model.payload_state(), provisioned = model.payload_ok() },
    })
end

local function op_enroll(body)
    local profile_key, key_err = requested_profile_key(body, true)
    if not profile_key then return error_reply("bad_request", key_err) end
    local key = request_value(body, "setup_key")
    if not key or key == "" then return error_reply("bad_request", "setup key required") end
    if not native_profile(profile_key) then return error_reply("profile_required", "save the NetBird VPN profile before enrollment") end

    -- Enrollment temporarily starts the NetBird daemon. Do not disturb another
    -- active TP-Link VPN Client profile. Re-enrolling the currently active row
    -- is explicit: turn it off first, enroll, then use the stock toggle again.
    if uci:get("vpn", "client", "enabled") == "on" then
        return error_reply("active_conflict", "disable the active VPN Client profile before NetBird enrollment")
    end

    local synced, sync_err = sync_settings_from_native_profile(profile_key)
    if not synced then return error_reply("profile_required", sync_err) end

    local tmp = "/tmp/nb-setup-key-" .. tostring(os.time()) .. "-" .. tostring(math.random(0x7fffffff))
    if not lfs.writefile(tmp, key) then return error_reply("internal", "failed to stage setup key") end
    nixio.fs.chmod(tmp, "0600")
    local out, rc = model.control("enroll", profile_key, tmp)
    nixio.fs.unlink(tmp)
    if rc ~= 0 then return error_reply("enroll_failed", (out or "enrollment failed"):gsub("%s+$", "")) end

    model.control("stop", profile_key)
    local cur, state_err = model.set_internal_settings({ enrolled = "1", enable = "0" }, profile_key)
    if not cur then return error_reply("internal", state_err or "failed to persist enrollment state") end
    return reply({ result = "ok", profileKey = profile_key, settings = cur })
end

local function op_restart(body)
    local profile_key, key_err = requested_profile_key(body, true)
    if not profile_key then return error_reply("bad_request", key_err) end
    if not native_profile_active(profile_key) then
        return error_reply("not_active", "this NetBird profile is not the active TP-Link VPN Client profile")
    end
    local rc = sys.call("/etc/init.d/vpnc restart >/dev/null 2>&1")
    if rc ~= 0 then return error_reply("control_failed", "native vpnc restart failed") end
    return reply({ result = "ok", profileKey = profile_key })
end

local function op_log(body)
    local profile_key, key_err = requested_profile_key(body, true)
    if not profile_key then return error_reply("bad_request", key_err) end
    if not native_profile(profile_key) then return error_reply("profile_required", "native NetBird VPN profile not found") end
    local n = request_value(body, "lines") or "100"
    return reply({ lines = model.log(tonumber(n) or 100) })
end

local function op_payload_status()
    return reply({ version = model.payload_version(), provisioned = model.payload_ok(), state = model.payload_state() })
end

function dispatch(body)
    local op = request_value(body, "operation") or "status"
    local ok_dispatch, result = pcall(function()
        if op == "status" then return op_status(body)
        elseif op == "enroll" then return op_enroll(body)
        elseif op == "restart" then return op_restart(body)
        elseif op == "log" then return op_log(body)
        elseif op == "payload_status" then return op_payload_status()
        else return error_reply("bad_request", "unknown operation") end
    end)
    if ok_dispatch then return result end
    return error_reply("internal", tostring(result))
end
