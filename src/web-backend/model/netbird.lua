-- NetBird model for TP-Link Archer AX53 V1.
module("luci.model.netbird", package.seeall)

local nixio = require "nixio"
local fs     = require "luci.fs"
local sys    = require "luci.sys"
local json   = require "luci.json"

local function shellquote(value)
    local s = tostring(value or "")
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

SETTINGS = "/tp_data/netbird/settings"
CTL      = "/sbin/netbird-ctl"

KEYS = {
    enable                = { kind = "bool", default = "0" },
    enrolled              = { kind = "bool", default = "0", readonly = true },
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
    wireguard_port        = { kind = "int",  default = "51820" },
}

local function read_settings()
    local t = {}
    local raw = fs.readfile(SETTINGS) or ""
    for line in raw:gmatch("[^\r\n]+") do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = (v or ""):gsub("%s+$", "") end
    end
    return t
end

function get_settings()
    local cur, out = read_settings(), {}
    for k, spec in pairs(KEYS) do out[k] = cur[k] or spec.default end
    return out
end

local function valid_bool(v) return v == "0" or v == "1" end
local function valid_url(v)
    if v == nil or v == "" then return true end
    return v:match("^https?://[%w%.%-]+(%.%w+)(:%d+)?(/[%w%-%.%_~/#%%&%?%=%+%,]*)?$") ~= nil
end
local function valid_name(v) return v ~= nil and #v <= 64 and v:match("^[%w%.%-_]*$") ~= nil end
local function valid_cidr(v)
    if v == nil or v == "" then return true end
    local ip, plen = v:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$")
    if not ip then return false end
    for o in ip:gmatch("%d+") do local n = tonumber(o); if not n or n > 255 then return false end end
    local p = tonumber(plen)
    return p ~= nil and p >= 0 and p <= 32
end
local function valid_int(v, lo, hi) local n = tonumber(v); return n ~= nil and n >= lo and n <= hi end

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
            elseif spec.kind == "cidr" then v = tostring(v or ""); ok = valid_cidr(v)
            elseif spec.kind == "int" then ok = valid_int(v, 1, 65535); if ok then v = tostring(v) end end
            if not ok then return nil, "invalid value for " .. k end
            out[k] = v
        end
    end
    return out
end

local function merged_settings(cand)
    local upd, err = sanitize(cand or {}, false)
    if not upd then return nil, err end
    local cur = read_settings()
    for k, v in pairs(upd) do cur[k] = v end
    for k, spec in pairs(KEYS) do if cur[k] == nil then cur[k] = spec.default end end
    if cur.advertise_lan == "1" and cur.advertise_cidr == "" then
        return nil, "advertise_cidr required when LAN routing is enabled"
    end
    return cur
end

function preview_settings(cand)
    return merged_settings(cand)
end

local function write_settings(cur)
    local lines = {}
    for k, spec in pairs(KEYS) do lines[#lines + 1] = k .. "=" .. (cur[k] or spec.default) end
    fs.mkdir("/tp_data/netbird")
    nixio.fs.chmod("/tp_data/netbird", 448)
    if not fs.writefile(SETTINGS, table.concat(lines, "\n") .. "\n") then return nil, "failed to write settings" end
    nixio.fs.chmod(SETTINGS, 384)
    return get_settings()
end

function set_settings(cand)
    local cur, err = merged_settings(cand)
    if not cur then return nil, err end
    return write_settings(cur)
end

function set_internal_settings(cand)
    local allowed = {}
    if cand and cand.enrolled ~= nil then allowed.enrolled = cand.enrolled end
    if cand and cand.enable ~= nil then allowed.enable = cand.enable end
    local upd, err = sanitize(allowed, true)
    if not upd then return nil, err end
    local cur = read_settings()
    for k, v in pairs(upd) do cur[k] = v end
    return write_settings(cur)
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

function status()
    local out = run("status")
    if out and out ~= "" then local ok, obj = pcall(json.decode, out); if ok and type(obj) == "table" then return obj end end
    return nil
end
function control(op, keyfile)
    if op == "enroll" then return run_ex("up", "--setup-key-file", keyfile)
    elseif op == "start" or op == "up" then return run_ex("up")
    elseif op == "stop" then return run_ex("stop")
    elseif op == "down" then return run_ex("down")
    elseif op == "restart" then return run_ex("restart")
    elseif op == "clean" then return run_ex("clean") end
    return nil, nil
end
function log(n) local lines=tonumber(n) or 100; if lines<1 then lines=100 end; if lines>500 then lines=500 end; return run("log",tostring(lines)) or "" end
function payload_version() return (run("payload-version") or ""):gsub("%s+$","") end
function payload_ok() local _,rc=run_ex("payload-status"); return rc==0 end
function payload_state() local out=run("payload-status"); return (out or ""):match("^%s*(%S+)") or "UNKNOWN" end
