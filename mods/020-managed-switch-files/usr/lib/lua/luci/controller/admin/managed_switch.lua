module("luci.controller.admin.managed_switch", package.seeall)

local http = require "luci.http"
local sys = require "luci.sys"
local controller = require "luci.model.controller"

local CLI = "/usr/sbin/ax53-switch"

function index()
    entry({"admin", "managed_switch"}, call("_index"), "Switch / VLAN", 98).leaf = true
end

function _index()
    return controller._index(dispatch)
end

local function reply(data)
    return { success = true, data = data }
end

local function error_reply(code, message)
    return {
        success = false,
        errorcode = code,
        data = { error = message or code, code = code }
    }
end

local function scalar(value)
    if type(value) == "table" then return value[#value] end
    if value == nil then return nil end
    return tostring(value)
end

local function request_value(body, key)
    if body and body[key] ~= nil then return scalar(body[key]) end
    return http.formvalue(key)
end

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_cli(args)
    local cmd = CLI
    for i = 1, #args do cmd = cmd .. " " .. shell_quote(args[i]) end
    local output = sys.exec(cmd .. " 2>&1; printf '\\n__AX53_RC:%s\\n' $?") or ""
    local rc = tonumber(output:match("__AX53_RC:(%d+)%s*$")) or 1
    output = output:gsub("\n?__AX53_RC:%d+%s*$", "")
    return rc, output
end

local function parse_status_output(output)
    local data = {
        enabled = 0,
        profile = "router-on-a-stick",
        wan_vid = 4094,
        lan_vid = 2,
        trunk_port = 1,
        access_ports = "2 3 4",
        cpu_lan = 1,
        cpu_wan = 0,
        config = "/tp_data/managed-switch/config",
        driver_vlan = ""
    }

    local raw, in_driver = {}, false
    for line in tostring(output):gmatch("[^\r\n]+") do
        if line == "--- rtl8367s/vlan ---" then
            in_driver = true
        elseif in_driver then
            raw[#raw + 1] = line
        else
            local key, value = line:match("^([%w_]+)=(.*)$")
            if key and value then
                if key == "enabled" or key == "wan_vid" or key == "lan_vid"
                    or key == "cpu_lan" or key == "cpu_wan" then
                    data[key] = tonumber(value) or data[key]
                elseif key == "trunk_port" then
                    data.trunk_port = tonumber(value:match("LAN(%d+)")) or data.trunk_port
                elseif key == "access_ports" or key == "profile" or key == "config" then
                    data[key] = value
                end
            end
        end
    end
    data.driver_vlan = table.concat(raw, "\n")
    return data
end

local function current_status()
    local rc, output = run_cli({"status"})
    if rc ~= 0 then return nil, output ~= "" and output or "unable to read switch status" end
    return parse_status_output(output)
end

local function uint_value(body, name, min_value, max_value)
    local value = tostring(request_value(body, name) or "")
    if not value:match("^%d+$") then return nil, name .. " must be numeric" end
    local number = tonumber(value)
    if not number or number < min_value or number > max_value then return nil, name .. " out of range" end
    return tostring(number)
end

local function bool_value(body, name)
    local value = tostring(request_value(body, name) or "")
    if value ~= "0" and value ~= "1" then return nil, name .. " must be 0 or 1" end
    return value
end

local function access_ports_value(body)
    local value = tostring(request_value(body, "access_ports") or "")
    local ports, seen = {}, {}
    for token in value:gmatch("%S+") do
        if not token:match("^[1-4]$") then return nil, "access_ports may contain only LAN ports 1..4" end
        if seen[token] then return nil, "access_ports contains a duplicate port" end
        seen[token] = true
        ports[#ports + 1] = token
    end
    if #ports == 0 then return nil, "at least one access port is required" end
    table.sort(ports)
    return table.concat(ports, " ")
end

local function op_status()
    local status, err = current_status()
    if not status then return error_reply("status_failed", err) end
    return reply(status)
end

local function op_save(body)
    local wan_vid, err = uint_value(body, "wan_vid", 1, 4094)
    if not wan_vid then return error_reply("bad_request", err) end
    local lan_vid
    lan_vid, err = uint_value(body, "lan_vid", 1, 4094)
    if not lan_vid then return error_reply("bad_request", err) end
    if lan_vid == wan_vid then return error_reply("bad_request", "WAN and LAN VLAN IDs must differ") end

    local trunk_port
    trunk_port, err = uint_value(body, "trunk_port", 1, 4)
    if not trunk_port then return error_reply("bad_request", err) end
    local access_ports
    access_ports, err = access_ports_value(body)
    if not access_ports then return error_reply("bad_request", err) end
    for token in access_ports:gmatch("%S+") do
        if token == trunk_port then return error_reply("bad_request", "trunk port cannot also be an access port") end
    end

    local cpu_lan
    cpu_lan, err = bool_value(body, "cpu_lan")
    if not cpu_lan then return error_reply("bad_request", err) end
    local cpu_wan
    cpu_wan, err = bool_value(body, "cpu_wan")
    if not cpu_wan then return error_reply("bad_request", err) end

    if cpu_lan == "1" and lan_vid ~= "2" then
        return error_reply("bad_request", "LAN VLAN must remain 2 while CPU/LAN management is enabled")
    end
    if cpu_wan == "1" and wan_vid ~= "4094" then
        return error_reply("bad_request", "WAN VLAN must remain 4094 while CPU/WAN membership is enabled")
    end

    local rc, output = run_cli({"configure", wan_vid, lan_vid, trunk_port, access_ports, cpu_lan, cpu_wan})
    if rc ~= 0 then return error_reply("save_failed", output ~= "" and output or "configuration rejected") end

    local status, status_err = current_status()
    if not status then return error_reply("status_failed", status_err) end
    status.message = output
    return reply(status)
end

local function op_simple(command)
    local rc, output = run_cli({command})
    if rc ~= 0 then return error_reply(command .. "_failed", output ~= "" and output or (command .. " failed")) end
    local status, status_err = current_status()
    if not status then return error_reply("status_failed", status_err) end
    status.message = output
    return reply(status)
end

local function op_apply()
    local before, status_err = current_status()
    if not before then return error_reply("status_failed", status_err) end

    if tonumber(before.enabled) ~= 1 then
        local enable_rc, enable_out = run_cli({"enable"})
        if enable_rc ~= 0 then
            return error_reply("enable_failed", enable_out ~= "" and enable_out or "failed to enable profile")
        end
    end

    local rc, output = run_cli({"apply"})
    if rc ~= 0 then
        local rollback_rc, rollback_out = run_cli({"rollback"})
        local message = output ~= "" and output or "apply failed"
        if rollback_rc ~= 0 then
            message = message .. "; automatic rollback also failed: " .. (rollback_out ~= "" and rollback_out or "unknown rollback error")
        else
            message = message .. "; profile was automatically rolled back to stock"
        end
        return error_reply("apply_failed", message)
    end

    local status, after_err = current_status()
    if not status then return error_reply("status_failed", after_err) end
    status.message = output
    return reply(status)
end

function dispatch(body)
    local operation = request_value(body, "operation") or "status"
    local ok, result = pcall(function()
        if operation == "status" then return op_status()
        elseif operation == "save" then return op_save(body)
        elseif operation == "enable" then return op_simple("enable")
        elseif operation == "disable" then return op_simple("disable")
        elseif operation == "apply" then return op_apply()
        elseif operation == "rollback" then return op_simple("rollback")
        else return error_reply("bad_request", "unknown operation") end
    end)
    if not ok then return error_reply("internal", tostring(result)) end
    return result
end
