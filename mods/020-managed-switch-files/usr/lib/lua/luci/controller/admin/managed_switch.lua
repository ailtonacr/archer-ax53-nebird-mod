module("luci.controller.admin.managed_switch", package.seeall)

local http = require "luci.http"
local sys = require "luci.sys"
local json = require "luci.json"

local CLI = "/usr/sbin/ax53-switch"
local UI = "/webpages/managed-switch.html"

function index()
    local page = entry({"admin", "managed_switch"}, call("action_index"), "Switch / VLAN", 98)
    page.leaf = true
end

local function respond(code, payload)
    http.status(code, code == 200 and "OK" or "Error")
    http.prepare_content("application/json")
    http.write(json.encode(payload))
end

local function shell_quote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_cli(args)
    local cmd = CLI
    local i

    for i = 1, #args do
        cmd = cmd .. " " .. shell_quote(args[i])
    end

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

    local raw = {}
    local in_driver = false

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
    if rc ~= 0 then
        return nil, output ~= "" and output or "unable to read switch status"
    end
    return parse_status_output(output)
end

local function uint_form(name, min_value, max_value)
    local value = tostring(http.formvalue(name) or "")
    if not value:match("^%d+$") then
        return nil, name .. " must be numeric"
    end

    local number = tonumber(value)
    if not number or number < min_value or number > max_value then
        return nil, name .. " out of range"
    end

    return tostring(number)
end

local function bool_form(name)
    local value = tostring(http.formvalue(name) or "")
    if value ~= "0" and value ~= "1" then
        return nil, name .. " must be 0 or 1"
    end
    return value
end

local function access_ports_form()
    local value = tostring(http.formvalue("access_ports") or "")
    local ports = {}
    local seen = {}

    for token in value:gmatch("%S+") do
        if not token:match("^[1-4]$") then
            return nil, "access_ports may contain only LAN ports 1..4"
        end
        if seen[token] then
            return nil, "access_ports contains a duplicate port"
        end
        seen[token] = true
        ports[#ports + 1] = token
    end

    if #ports == 0 then
        return nil, "at least one access port is required"
    end

    table.sort(ports)
    return table.concat(ports, " ")
end

local function require_post()
    if tostring(http.getenv("REQUEST_METHOD") or "GET"):upper() ~= "POST" then
        respond(405, { success = false, error = "POST required" })
        return false
    end
    return true
end

local function require_same_origin()
    local origin = tostring(http.getenv("HTTP_ORIGIN") or "")
    local host = tostring(http.getenv("HTTP_HOST") or "")

    -- Browsers normally send Origin on fetch POSTs. Keep CLI/diagnostic callers
    -- without Origin working, but reject an explicit cross-origin browser POST.
    if origin ~= "" and host ~= "" then
        local origin_host = origin:match("^https?://([^/]+)$")
        if not origin_host or origin_host ~= host then
            respond(403, { success = false, error = "cross-origin request rejected" })
            return false
        end
    end

    return true
end

local function handle_status()
    local status, err = current_status()
    if not status then
        respond(500, { success = false, error = err })
        return
    end
    respond(200, { success = true, data = status })
end

local function handle_save()
    local wan_vid, err = uint_form("wan_vid", 1, 4094)
    if not wan_vid then return respond(400, { success = false, error = err }) end

    local lan_vid
    lan_vid, err = uint_form("lan_vid", 1, 4094)
    if not lan_vid then return respond(400, { success = false, error = err }) end
    if lan_vid == wan_vid then
        return respond(400, { success = false, error = "WAN and LAN VLAN IDs must differ" })
    end

    local trunk_port
    trunk_port, err = uint_form("trunk_port", 1, 4)
    if not trunk_port then return respond(400, { success = false, error = err }) end

    local access_ports
    access_ports, err = access_ports_form()
    if not access_ports then return respond(400, { success = false, error = err }) end

    for token in access_ports:gmatch("%S+") do
        if token == trunk_port then
            return respond(400, { success = false, error = "trunk port cannot also be an access port" })
        end
    end

    local cpu_lan
    cpu_lan, err = bool_form("cpu_lan")
    if not cpu_lan then return respond(400, { success = false, error = err }) end

    local cpu_wan
    cpu_wan, err = bool_form("cpu_wan")
    if not cpu_wan then return respond(400, { success = false, error = err }) end

    if cpu_lan == "1" and lan_vid ~= "2" then
        return respond(400, {
            success = false,
            error = "LAN VLAN must remain 2 while CPU/LAN management is enabled"
        })
    end

    if cpu_wan == "1" and wan_vid ~= "4094" then
        return respond(400, {
            success = false,
            error = "WAN VLAN must remain 4094 while CPU/WAN membership is enabled"
        })
    end

    local rc, output = run_cli({
        "configure",
        wan_vid,
        lan_vid,
        trunk_port,
        access_ports,
        cpu_lan,
        cpu_wan
    })

    if rc ~= 0 then
        return respond(400, {
            success = false,
            error = output ~= "" and output or "configuration rejected"
        })
    end

    local status, status_err = current_status()
    respond(200, {
        success = true,
        message = output,
        data = status,
        warning = status_err
    })
end

local function handle_simple(command)
    local rc, output = run_cli({command})
    if rc ~= 0 then
        return respond(500, {
            success = false,
            error = output ~= "" and output or (command .. " failed")
        })
    end

    local status, status_err = current_status()
    respond(200, {
        success = true,
        message = output,
        data = status,
        warning = status_err
    })
end

function action_index()
    local operation = tostring(http.formvalue("operation") or "")

    if operation == "" then
        return http.redirect(UI)
    end

    if operation == "status" then
        return handle_status()
    end

    if not require_post() or not require_same_origin() then
        return
    end

    if operation == "save" then
        return handle_save()
    elseif operation == "enable" then
        return handle_simple("enable")
    elseif operation == "disable" then
        return handle_simple("disable")
    elseif operation == "apply" then
        return handle_simple("apply")
    elseif operation == "rollback" then
        return handle_simple("rollback")
    end

    respond(404, { success = false, error = "unknown operation" })
end
