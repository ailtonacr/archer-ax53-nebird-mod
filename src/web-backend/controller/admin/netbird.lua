-- NetBird RPC controller for TP-Link Archer AX53 V1.
module("luci.controller.admin.netbird", package.seeall)

local nixio = require "nixio"
local http   = require "luci.http"
local model  = require "luci.model.netbird"
local controller = require "luci.model.controller"

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
local function request_value(body, key)
    if body and body[key] ~= nil then return scalar(body[key]) end
    return http.formvalue(key)
end
local function request_settings(body)
    local cand, src = {}, body or http.formvaluetable() or {}
    for k, v in pairs(src) do
        if k ~= "operation" and k ~= "setup_key" then cand[k] = scalar(v) end
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
        if settings.enrolled ~= "1" then patch = { enrolled = "1" } end
    end
    if patch and next(patch) then
        local updated = model.set_internal_settings(patch)
        if updated then return updated end
    end
    return settings
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
        code = classify(settings, st), settings = settings, netbird = nb,
        payload = { version = model.payload_version(), state = model.payload_state(), provisioned = model.payload_ok() },
    })
end

local function op_settings_get() return reply({ settings = model.get_settings() }) end

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
    -- A stale pre-fix settings file can have enable=1 while enrolled=0. Saving
    -- the form must not launch the interactive SSO path before setup-key
    -- enrollment. Once enrolled, normal saves still restart to apply flags.
    if cur.enable == "1" and cur.enrolled == "1" then
        out, rc = model.control("start")
        if rc == 0 then cur = model.set_internal_settings({ enrolled = "1", enable = "1" }) or cur end
    end

    if rc ~= nil and rc ~= 0 then
        return error_reply("apply_failed", "settings saved but apply failed: " .. (out or "start failed"):gsub("%s+$", ""))
    end
    return reply({ settings = cur })
end

local function op_enroll(body)
    local key = request_value(body, "setup_key")
    if not key or key == "" then return error_reply("bad_request", "setup key required") end
    local mgmt = request_value(body, "management_url")
    if mgmt and mgmt ~= "" then
        local cur, err = model.set_settings({ management_url = mgmt })
        if not cur then return error_reply("bad_request", err or "invalid management url") end
    end

    local tmp = "/tmp/nb-setup-key-" .. tostring(os.time()) .. "-" .. tostring(math.random(0x7fffffff))
    local lfs = require "luci.fs"
    if not lfs.writefile(tmp, key) then return error_reply("internal", "failed to stage setup key") end
    -- This TP-Link nixio binding expects a textual chmod mode.
    nixio.fs.chmod(tmp, "0600")
    local out, rc = model.control("enroll", tmp)
    nixio.fs.unlink(tmp)
    if rc ~= 0 then return error_reply("enroll_failed", (out or "enrollment failed"):gsub("%s+$", "")) end
    local cur, state_err = model.set_internal_settings({ enrolled = "1", enable = "1" })
    if not cur then return error_reply("internal", state_err or "failed to persist enrollment state") end
    return reply({ result = "ok", settings = cur })
end

local function op_control(op)
    local out, rc = model.control(op)
    if rc ~= 0 then return error_reply("control_failed", (out or op):gsub("%s+$", "")) end
    if op == "start" or op == "restart" then model.set_internal_settings({ enrolled = "1", enable = "1" })
    elseif op == "stop" then model.set_internal_settings({ enable = "0" }) end
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
    local ok, result = pcall(function()
        if op == "status" then return op_status()
        elseif op == "settings_get" then return op_settings_get()
        elseif op == "settings_set" then return op_settings_set(body)
        elseif op == "enroll" then return op_enroll(body)
        elseif op == "start" or op == "stop" or op == "restart" then return op_control(op)
        elseif op == "clean" then return op_clean()
        elseif op == "log" then return op_log(body)
        elseif op == "payload_status" then return op_payload_status()
        else return error_reply("bad_request", "unknown operation") end
    end)
    if not ok then return error_reply("internal", tostring(result)) end
    return result
end
