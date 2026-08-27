-- NetBird RPC controller for TP-Link Archer AX53 V1.
-- Registered under the admin tree, so it inherits the standard stok/session
-- authentication. All mutable ops validate input, shell-quote argv and never
-- persist or return the setup key.
--
-- Endpoint: POST /cgi-bin/luci/;stok=<token>/admin/netbird  (form-encoded)
--   operation = status | settings_get | settings_set | enroll | start | stop
--             | restart | clean | log | payload_status

module("luci.controller.admin.netbird", package.seeall)

local nixio = require "nixio"
local http   = require "luci.http"
local model  = require "luci.model.netbird"
local controller = require "luci.model.controller"

function index()
    entry({"admin", "netbird"}, call("_index")).leaf = true
end

function _index()
    return controller._index(dispatch)
end

local function reply(t)
    return { success = true, data = t }
end

local function error_reply(code, msg)
    return {
        success = false,
        errorcode = code,
        data = { error = msg or code, code = code },
    }
end

-- ---------------------------------------------------------------------------
-- status mapping
-- ---------------------------------------------------------------------------

local function classify(settings, status)
    if not model.payload_ok() then
        return "payload_missing"
    end
    if settings.enable ~= "1" then
        return "disabled"
    end
    if not status then
        return "stopped"
    end
    local ds = status.daemonStatus or ""
    if ds == "NeedsLogin" then
        return "enrollment_required"
    elseif ds == "Connected" then
        return "connected"
    elseif ds == "Connecting" or ds == "Restarting" then
        return "connecting"
    elseif ds == "Idle" or ds == "Disconnected" or ds == "Down" then
        return "disconnected"
    else
        return "stopped"
    end
end

-- ---------------------------------------------------------------------------
-- operations
-- ---------------------------------------------------------------------------

local function op_status()
    local settings = model.get_settings()
    local st = model.status()
    local nb = {}
    if st then
        nb = {
            daemonStatus = st.daemonStatus or "",
            cliVersion   = st.cliVersion or "",
            daemonVersion= st.daemonVersion or "",
            netbirdIp    = st.netbirdIp or "",
            publicKey    = st.publicKey or "",
            fqdn         = st.fqdn or "",
            wireguardPort= st.wireguardPort or 0,
            managementConnected = st.management and st.management.connected or false,
            managementUrl = st.management and st.management.url or "",
            signalConnected = st.signal and st.signal.connected or false,
            peersTotal     = st.peers and st.peers.total or 0,
            peersConnected = st.peers and st.peers.connected or 0,
        }
    end
    return reply({
        code     = classify(settings, st),
        settings = settings,
        netbird  = nb,
        payload  = {
            version     = model.payload_version(),
            state       = model.payload_state(),
            provisioned = model.payload_ok(),
        },
    })
end

local function op_settings_get()
    return reply({ settings = model.get_settings() })
end

local function op_settings_set()
    local cand = {}
    local body = http.formvaluetable()
    for k, v in pairs(body) do cand[k] = v[#v] end
    local prev = model.get_settings()
    local cur, err = model.set_settings(cand)
    if not cur then return error_reply("bad_request", err or "invalid settings") end
    -- react to enable/disable transitions
    if prev.enable ~= cur.enable then
        if cur.enable == "1" then
            model.control("start")
        else
            model.control("stop")
        end
    elseif cur.enable == "1" then
        -- flag changes while enabled require a reconnect to take effect
        model.control("restart")
    end
    return reply({ settings = cur })
end

-- setup key is written to a 0600 file, consumed by the CLI, then removed.
local function op_enroll()
    local key = http.formvalue("setup_key")
    if not key or key == "" then
        return error_reply("bad_request", "setup key required")
    end
    -- update management_url first so enrollment targets the right server
    local body = http.formvaluetable()
    local mgmt = (body.management_url and body.management_url[#body.management_url])
    if mgmt and mgmt ~= "" then
        local ok = model.set_settings({ management_url = mgmt })
        if not ok then return error_reply("bad_request", "invalid management url") end
    end

    local tmp = "/tmp/nb-setup-key-" .. tostring(os.time()) .. "-" .. tostring(math.random(0x7fffffff))
    local lfs = require "luci.fs"
    if not lfs.writefile(tmp, key) then
        return error_reply("internal", "failed to stage setup key")
    end
    nixio.fs.chmod(tmp, 384) -- 0600

    local out, rc = model.control("enroll", tmp)
    nixio.fs.unlink(tmp) -- always remove the secret immediately

    if rc ~= 0 then
        return error_reply("enroll_failed", (out or "enrollment failed"):gsub("%s+$", ""))
    end

    -- mark enrolled on success
    model.set_settings({ enrolled = "1", enable = "1" })
    return reply({ result = "ok" })
end

local function op_control(op)
    local settings = model.get_settings()
    if op == "start" and settings.enrolled ~= "1" then
        return error_reply("not_enrolled", "not enrolled")
    end
    local out, rc = model.control(op)
    if rc ~= 0 then
        return error_reply("control_failed", (out or op):gsub("%s+$", ""))
    end
    return reply({ result = "ok", output = out and out:gsub("%s+$", "") or "" })
end

local function op_clean()
    model.control("stop")
    model.control("clean")
    model.set_settings({ enrolled = "0", enable = "0" })
    return reply({ result = "ok" })
end

local function op_log()
    local n = http.formvalue("lines") or "100"
    return reply({ lines = model.log(tonumber(n) or 100) })
end

local function op_payload_status()
    return reply({
        version     = model.payload_version(),
        provisioned = model.payload_ok(),
        state       = model.payload_state(),
    })
end

-- ---------------------------------------------------------------------------

function dispatch(body)
    local op = body and body.operation or http.formvalue("operation") or "status"
    local ok, result = pcall(function()
        if op == "status" then return op_status()
        elseif op == "settings_get" then return op_settings_get()
        elseif op == "settings_set" then return op_settings_set()
        elseif op == "enroll" then return op_enroll()
        elseif op == "start" or op == "stop" or op == "restart" then return op_control(op)
        elseif op == "clean" then return op_clean()
        elseif op == "log" then return op_log()
        elseif op == "payload_status" then return op_payload_status()
        else return error_reply("bad_request", "unknown operation")
        end
    end)
    if not ok then
        return error_reply("internal", tostring(result))
    end
    return result
end
