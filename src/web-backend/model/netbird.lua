-- NetBird provider model for TP-Link Archer AX53 V1.
--
-- The stock vpn.server row is the profile authority. Runtime identity/settings
-- are materialized per stock profile key so multiple NetBird profiles can be
-- stored without sharing credentials or state. Generic VPN CRUD/status belongs
-- to TP-Link; this model only serves provider-specific runtime operations.
module("luci.model.netbird", package.seeall)

local nixio = require "nixio"
local fs     = require "luci.fs"
local sys    = require "luci.sys"
local json   = require "luci.json"

local function shellquote(value)
    local s = tostring(value or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

ROOT     = "/tp_data/netbird"
PROFILES = ROOT .. "/profiles"
CTL      = "/sbin/netbird-ctl"
SETUP_STAGE_PREFIX = "/tmp/netbird-setup-stage-"

KEYS = {
    enable                = { kind = "bool", default = "0" },
    enrolled              = { kind = "bool", default = "0", readonly = true },
    description           = { kind = "text", default = "NetBird" },
    management_url        = { kind = "url",  default = "https://netbird.ailton.dev.br" },
    hostname              = { kind = "name", default = "" },
    disable_dns           = { kind = "bool", default = "1" },
    disable_firewall      = { kind = "bool", default = "1" },
    disable_client_routes = { kind = "bool", default = "1" },
    disable_server_routes = { kind = "bool", default = "1" },
    disable_ipv6          = { kind = "bool", default = "1" },
    network_monitor       = { kind = "bool", default = "0" },
    advertise_lan         = { kind = "bool", default = "0" },
    advertise_cidr        = { kind = "cidr", default = "" },
    wireguard_port        = { kind = "int", default = "51820" },
}

function valid_profile_key(profile_key)
    local key = tostring(profile_key or "")
    return key ~= "" and #key <= 96 and key:match("^[%w_.%-]+$") ~= nil
end

function profile_dir(profile_key)
    if not valid_profile_key(profile_key) then return nil, "invalid profile key" end
    return PROFILES .. "/" .. tostring(profile_key)
end

local function settings_path(profile_key)
    local dir, err = profile_dir(profile_key)
    if not dir then return nil, err end
    return dir .. "/settings"
end

function profile_config_path(profile_key)
    local dir, err = profile_dir(profile_key)
    if not dir then return nil, err end
    return dir .. "/default.json"
end

function profile_state_path(profile_key)
    local dir, err = profile_dir(profile_key)
    if not dir then return nil, err end
    return dir .. "/state"
end

local function ensure_profile_dir(profile_key)
    local dir, err = profile_dir(profile_key)
    if not dir then return nil, err end
    fs.mkdir(ROOT)
    nixio.fs.chmod(ROOT, "0700")
    fs.mkdir(PROFILES)
    nixio.fs.chmod(PROFILES, "0700")
    fs.mkdir(dir)
    nixio.fs.chmod(dir, "0700")
    return dir
end

local function read_settings(profile_key)
    if not valid_profile_key(profile_key) then return {} end
    local path = settings_path(profile_key)
    local t = {}
    local raw = path and fs.readfile(path) or ""
    for line in raw:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = (v or ""):gsub("%s+$", "") end
    end
    return t
end

function get_settings(profile_key)
    if not valid_profile_key(profile_key) then return nil, "invalid profile key" end
    local cur, out = read_settings(profile_key), {}
    for k, spec in pairs(KEYS) do out[k] = cur[k] or spec.default end
    return out
end

local function valid_bool(v) return v == "0" or v == "1" end
local function valid_url(v)
    if v == nil or v == "" then return true end
    if #v > 2048 or v:find("%s") then return false end
    local scheme, authority = v:match("^(https?)://([^/]+)")
    if not scheme or not authority or authority == "" then return false end
    local host, port = authority:match("^([^:]+):(%d+)$")
    if not host then
        host = authority
        if authority:find(":", 1, true) then return false end
    end
    if not host:match("^[%w%.%-]+$") then return false end
    if host:sub(1, 1) == "." or host:sub(-1) == "." or host:find("..", 1, true) then return false end
    if not host:find(".", 1, true) then return false end
    if port then
        local n = tonumber(port)
        if not n or n < 1 or n > 65535 then return false end
    end
    local prefix = scheme .. "://" .. authority
    local rest = v:sub(#prefix + 1)
    return rest == "" or rest:sub(1, 1) == "/"
end
local function valid_name(v) return v ~= nil and #v <= 64 and v:match("^[%w%.%-_]*$") ~= nil end
local function valid_text(v) return v ~= nil and #v <= 64 and not v:find("[%c]") end
local function valid_cidr(v)
    if v == nil or v == "" then return true end
    local ip, plen = v:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
    if not ip then return false end
    for o in ip:gmatch("%d+") do local n = tonumber(o); if not n or n > 255 then return false end end
    local p = tonumber(plen)
    return p ~= nil and p >= 0 and p <= 32
end
local function valid_int(v, lo, hi)
    local raw = tostring(v or "")
    if not raw:match("^%d+$") then return false end
    local n = tonumber(raw)
    return n ~= nil and n >= lo and n <= hi
end

local function sanitize(cand, allow_readonly)
    local out = {}
    for k, spec in pairs(KEYS) do
        if cand[k] ~= nil and (allow_readonly or not spec.readonly) then
            local v, ok = cand[k], false
            if spec.kind == "bool" then
                if v == true then v = "1" elseif v == false then v = "0" else v = tostring(v) end
                ok = valid_bool(v)
            elseif spec.kind == "url" then v = tostring(v or ""); ok = valid_url(v)
            elseif spec.kind == "name" then v = tostring(v or ""); ok = valid_name(v)
            elseif spec.kind == "text" then v = tostring(v or ""); ok = valid_text(v)
            elseif spec.kind == "cidr" then v = tostring(v or ""); ok = valid_cidr(v)
            elseif spec.kind == "int" then ok = valid_int(v, 1, 65535); if ok then v = tostring(v) end end
            if not ok then return nil, "invalid value for " .. k end
            out[k] = v
        end
    end
    return out
end

local function merged_settings(cand, profile_key)
    local upd, err = sanitize(cand or {}, false)
    if not upd then return nil, err end
    local cur = read_settings(profile_key)
    for k, v in pairs(upd) do cur[k] = v end
    for k, spec in pairs(KEYS) do if cur[k] == nil then cur[k] = spec.default end end
    if cur.advertise_lan == "1" and cur.advertise_cidr == "" then
        return nil, "advertise_cidr required when LAN routing is enabled"
    end
    if cur.advertise_lan == "1" and cur.disable_client_routes ~= "0" then
        return nil, "client routes must be enabled when LAN gateway mode is enabled"
    end
    if cur.advertise_lan == "1" and cur.disable_server_routes ~= "0" then
        return nil, "server routes must be enabled when LAN routing is enabled"
    end
    if cur.advertise_lan == "1" and cur.disable_firewall ~= "0" then
        return nil, "NetBird firewall must be enabled when LAN routing is enabled"
    end
    return cur
end

function preview_settings(cand)
    return merged_settings(cand, nil)
end

local function write_settings(cur, profile_key)
    local dir, err = ensure_profile_dir(profile_key)
    if not dir then return nil, err end
    local path, path_err = settings_path(profile_key)
    if not path then return nil, path_err end
    local lines = {}
    for k, spec in pairs(KEYS) do lines[#lines + 1] = k .. "=" .. (cur[k] or spec.default) end
    if not fs.writefile(path, table.concat(lines, "\n") .. "\n") then return nil, "failed to write settings" end
    nixio.fs.chmod(path, "0600")
    return get_settings(profile_key)
end

function set_settings(cand, profile_key)
    if not valid_profile_key(profile_key) then return nil, "invalid profile key" end
    local cur, err = merged_settings(cand, profile_key)
    if not cur then return nil, err end
    return write_settings(cur, profile_key)
end

function set_internal_settings(cand, profile_key)
    if not valid_profile_key(profile_key) then return nil, "invalid profile key" end
    local allowed = {}
    if cand and cand.enrolled ~= nil then allowed.enrolled = cand.enrolled end
    if cand and cand.enable ~= nil then allowed.enable = cand.enable end
    local upd, err = sanitize(allowed, true)
    if not upd then return nil, err end
    local cur = read_settings(profile_key)
    for k, v in pairs(upd) do cur[k] = v end
    for k, spec in pairs(KEYS) do if cur[k] == nil then cur[k] = spec.default end end
    return write_settings(cur, profile_key)
end

function identity_present(profile_key)
    if not valid_profile_key(profile_key) then return false end
    local settings = read_settings(profile_key)
    return settings.enrolled == "1"
end

local function valid_stage_token(token)
    return type(token) == "string" and token:match("^[0-9a-f][0-9a-f]+$") ~= nil and #token == 32
end

local function new_stage_token()
    local raw = fs.readfile("/proc/sys/kernel/random/uuid") or ""
    local token = raw:gsub("[^0-9A-Fa-f]", ""):lower()
    if #token >= 32 then return token:sub(1, 32) end
    return nil
end

function stage_setup_key(setup_key)
    setup_key = tostring(setup_key or "")
    if setup_key == "" or #setup_key > 4096 or setup_key:find("%z") then
        return nil, "invalid setup key"
    end
    local token = new_stage_token()
    if not token then return nil, "failed to allocate setup-key token" end
    local path = SETUP_STAGE_PREFIX .. token
    if not fs.writefile(path, setup_key) then return nil, "failed to stage setup key" end
    nixio.fs.chmod(path, "0600")
    return token
end

function staged_setup_key_path(token)
    token = tostring(token or ""):lower()
    if not valid_stage_token(token) then return nil, "invalid enrollment token" end
    local path = SETUP_STAGE_PREFIX .. token
    local raw = fs.readfile(path)
    if not raw or raw == "" then return nil, "staged setup key not found" end
    return path
end

function discard_staged_setup_key(token)
    token = tostring(token or ""):lower()
    if not valid_stage_token(token) then return false end
    nixio.fs.unlink(SETUP_STAGE_PREFIX .. token)
    return true
end

local function run(...)
    local parts = { shellquote(CTL) }
    for i = 1, select("#", ...) do parts[#parts + 1] = shellquote(tostring(select(i, ...))) end
    return sys.exec(table.concat(parts, " "))
end
local function run_ex(...)
    local parts = { shellquote(CTL) }
    for i = 1, select("#", ...) do parts[#parts + 1] = shellquote(tostring(select(i, ...))) end
    local out = sys.exec(table.concat(parts, " ") .. " 2>&1; echo RC=$?")
    local rc = tonumber(out:match("RC=(%d+)%s*$") or "")
    return out:gsub("%s*RC=%d+%s*$", ""), rc
end

local function profile_args(profile_key, ...)
    if not valid_profile_key(profile_key) then return nil end
    local args = { "--profile-key", profile_key }
    for i = 1, select("#", ...) do args[#args + 1] = select(i, ...) end
    return args
end

local function run_profile(profile_key, ...)
    local args = profile_args(profile_key, ...)
    if not args then return "" end
    return run(unpack(args))
end

local function run_profile_ex(profile_key, ...)
    local args = profile_args(profile_key, ...)
    if not args then return "invalid profile key", 2 end
    return run_ex(unpack(args))
end

function status(profile_key)
    local out = run_profile(profile_key, "status")
    if out and out ~= "" then
        local ok, obj = pcall(json.decode, out)
        if ok and type(obj) == "table" then return obj end
    end
    return nil
end

function control(op, profile_key, keyfile)
    if op == "enroll" then return run_profile_ex(profile_key, "up", "--setup-key-file", keyfile)
    elseif op == "start" or op == "up" then return run_profile_ex(profile_key, "up")
    elseif op == "stop" then return run_profile_ex(profile_key, "stop")
    elseif op == "down" then return run_profile_ex(profile_key, "down")
    elseif op == "restart" then return run_profile_ex(profile_key, "restart")
    elseif op == "clean" then return run_profile_ex(profile_key, "clean") end
    return nil, nil
end

function log(profile_key, n)
    local lines = tonumber(n) or 100
    if lines < 1 then lines = 100 end
    if lines > 500 then lines = 500 end
    return run_profile(profile_key, "log", tostring(lines)) or ""
end
function payload_version() return (run("payload-version") or ""):gsub("%s+$", "") end
function payload_ok() local _, rc = run_ex("payload-status"); return rc == 0 end
function payload_state() local out = run("payload-status"); return (out or ""):match("^%s*(%S+)") or "UNKNOWN" end
