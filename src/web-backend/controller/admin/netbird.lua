-- NetBird profile/runtime controller for TP-Link Archer AX53 V1.
--
-- Hardware validation on Build 3 proved that TP-Link's compiled
-- /admin/vpn?form=server dispatcher does not call replacement Lua handlers
-- (adapter trace stayed dispatcher patched=0 and no add/get/modify handler was
-- reached). NetBird therefore keeps the stock VPN Client UI, but its profile
-- CRUD/control is owned explicitly by this dedicated endpoint. Stock VPN types
-- continue to use TP-Link's untouched /admin/vpn controller.
module("luci.controller.admin.netbird", package.seeall)

local nixio = require "nixio"
local http   = require "luci.http"
local lfs    = require "luci.fs"
local model  = require "luci.model.netbird"
local controller = require "luci.model.controller"

local SETTINGS = "/tp_data/netbird/settings"
local TRAFFIC_STATE = "/tmp/netbird-traffic.state"
local PROFILE_CONFIG = "/tp_data/netbird/default.json"
local PROFILE_STATE = "/tp_data/netbird/state"

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

local function request_settings(body)
    local src = body or http.formvaluetable() or {}
    local cand = {}
    for key, kind in pairs(PROFILE_KEYS) do
        local value = src[key]
        if value == nil then value = http.formvalue(key) end
        if value ~= nil then
            cand[key] = kind == "bool" and bool01(value, nil) or scalar(value)
        end
    end
    if cand.enable == nil then
        local enabled = src.enabled
        if enabled == nil then enabled = http.formvalue("enabled") end
        if enabled ~= nil then cand.enable = bool01(enabled, nil) end
    end
    return cand
end

local function classify(settings, status)
    if not model.payload_ok() then return "payload_missing" end
    local ds = status and status.daemonStatus or ""
    if ds == "NeedsLogin" then return "enrollment_required"
    elseif ds == "Connected" then return "connected"
    elseif ds == "Connecting" or ds == "Restarting" then return "connecting"
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
    if not status then return settings end
    local ds, patch = status.daemonStatus or "", nil
    if ds == "NeedsLogin" then
        if settings.enrolled ~= "0" then patch = { enrolled = "0" } end
    elseif ds == "Connected" or ds == "Connecting" or ds == "Restarting" then
        patch = {}
        if settings.enrolled ~= "1" then patch.enrolled = "1" end
        if settings.enable ~= "1" then patch.enable = "1" end
    elseif ds == "Idle" or ds == "Disconnected" or ds == "Down" then
        if identity_present() and settings.enrolled ~= "1" then patch = { enrolled = "1" } end
    end
    if patch and next(patch) then
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
        profileExists = lfs.access(SETTINGS) and true or false,
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
    return reply({ settings = model.get_settings(), profileExists = lfs.access(SETTINGS) and true or false })
end

local function op_settings_set(body)
    local cand = request_settings(body)
    local prev = model.get_settings()
    local preview, err = model.preview_settings(cand)
    if not preview then return error_reply("bad_request", err or "invalid settings") end

    local old_stopped = false
    if prev.enable == "1" then
        local stop_out, stop_rc = model.control("stop")
        if stop_rc ~= 0 then
            return error_reply("apply_failed", "failed to stop before applying settings: " .. (stop_out or "stop failed"):gsub("%s+$", ""))
        end
        old_stopped = true
    end

    local cur, write_err = model.set_settings(cand)
    if not cur then
        if old_stopped then model.control("start") end
        return error_reply("bad_request", write_err or "failed to save settings")
    end

    local out, rc
    if cur.enable == "1" and cur.enrolled == "1" then
        out, rc = model.control("start")
        if rc == 0 then cur = model.set_internal_settings({ enrolled = "1", enable = "1" }) or cur end
    end
    if rc ~= nil and rc ~= 0 then
        return error_reply("apply_failed", "settings saved but apply failed: " .. (out or "start failed"):gsub("%s+$", ""))
    end
    return reply({ settings = cur, profileExists = true })
end

local function op_profile_delete()
    local stop_out, stop_rc = model.control("stop")
    if stop_rc ~= 0 then
        return error_reply("delete_failed", "failed to stop NetBird before delete: " .. (stop_out or "stop failed"):gsub("%s+$", ""))
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
        return error_reply("delete_failed", "NetBird profile files remain after cleanup")
    end
    return reply({ result = "ok", profileExists = false })
end

local function op_enroll(body)
    local key = request_value(body, "setup_key")
    if not key or key == "" then return error_reply("bad_request", "setup key required") end
    if not lfs.access(SETTINGS) then
        return error_reply("profile_required", "save the NetBird VPN profile before enrollment")
    end
    local tmp = "/tmp/nb-setup-key-" .. tostring(os.time()) .. "-" .. tostring(math.random(0x7fffffff))
    if not lfs.writefile(tmp, key) then return error_reply("internal", "failed to stage setup key") end
    nixio.fs.chmod(tmp, "0600")
    local out, rc = model.control("enroll", tmp)
    nixio.fs.unlink(tmp)
    if rc ~= 0 then return error_reply("enroll_failed", (out or "enrollment failed"):gsub("%s+$", "")) end

    -- Factory VPN Client semantics are single-active. Enrollment registers the
    -- profile but does not leave NetBird active; activation happens through the
    -- list toggle, where mutual exclusion with stock VPN profiles is enforced.
    model.control("stop")
    local cur, state_err = model.set_internal_settings({ enrolled = "1", enable = "0" })
    if not cur then return error_reply("internal", state_err or "failed to persist enrollment state") end
    return reply({ result = "ok", settings = cur })
end

local function op_control(op)
    local out, rc = model.control(op)
    if rc ~= 0 then return error_reply("control_failed", (out or op):gsub("%s+$", "")) end
    if op == "start" or op == "restart" then
        model.set_internal_settings({ enrolled = "1", enable = "1" })
    elseif op == "stop" then
        model.set_internal_settings({ enable = "0" })
    end
    return reply({ result = "ok", output = out and out:gsub("%s+$", "") or "" })
end

local function op_clean()
    model.control("stop")
    model.control("clean")
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
        elseif op == "settings_set" then return op_settings_set(body)
        elseif op == "profile_delete" then return op_profile_delete()
        elseif op == "enroll" then return op_enroll(body)
        elseif op == "start" or op == "stop" or op == "restart" then return op_control(op)
        elseif op == "clean" then return op_clean()
        elseif op == "log" then return op_log(body)
        elseif op == "payload_status" then return op_payload_status()
        else return error_reply("bad_request", "unknown operation") end
    end)
    if not ok_dispatch then return error_reply("internal", tostring(result)) end
    return result
end
