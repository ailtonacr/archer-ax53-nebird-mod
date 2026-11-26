-- Lua 5.1 only: stub the stock dispatcher and privileged CLI.
-- Never execute a shell, touch the router, or load stock bytecode.
local status = table.concat({
    "config=/tp_data/managed-switch/config", "enabled=0", "profile=router-on-a-stick",
    "wan_vid=4094", "lan_vid=2", "trunk_port=LAN1", "access_ports=2 3 4",
    "cpu_lan=1", "cpu_wan=0", "transition=idle", "--- rtl8367s/vlan ---",
    "mock table", "",
}, "\n")
local calls, form, result, fail = {}, {}, status, false
local gateway = "mode=disabled\nphase=NORMAL\nadapter=unqualified\nconsecutive=0\nprobe=unknown\naction=none\nlast_sample=0\nfirst_sample=0\nfreshness=disabled\njournal=none\n"
package.loaded["luci.http"] = { formvalue = function(k) return form[k] end }
package.loaded["luci.sys"] = {
    exec = function(cmd)
        calls[#calls + 1] = cmd
        if fail then return "failed\n__AX53_RC:1\n" end
        if cmd:find("/usr/sbin/ax53-failover", 1, true) then
            if cmd:find("'status'", 1, true) then return gateway .. "\n__AX53_RC:0\n" end
            if cmd:find("'set-observe'", 1, true) then gateway = gateway:gsub("mode=disabled", "mode=observe") end
            if cmd:find("'set-disabled'", 1, true) then gateway = gateway:gsub("mode=observe", "mode=disabled") end
            return "\n__AX53_RC:0\n"
        end
        if cmd:find("'status'", 1, true) then return result .. "\n__AX53_RC:0\n" end
        return "mock mutation\n__AX53_RC:0\n"
    end,
}
package.loaded["luci.model.controller"] = { _index = function(fn) return fn({operation="status"}) end }
assert(loadfile(arg[1]))()
local controller = assert(package.loaded["luci.controller.admin.managed_switch"])
local function invoke(body)
    calls = {}
    return controller.dispatch(body)
end
local function reject(body)
    assert(invoke(body).success == false)
    assert(#calls == 0, "invalid input reached CLI")
end
assert(invoke({operation="status"}).success)
result = status:gsub("wan_vid=4094\n", "")
assert(not invoke({operation="status"}).success, "missing status field accepted")
result = status:gsub("enabled=0\n", "enabled=0\nenabled=1\n")
assert(not invoke({operation="status"}).success, "duplicate status accepted")
result = status
reject({operation={"status","rollback"}})
reject({operation="not-supported"})
reject("not a table")
reject({operation="save", wan_vid={"4094"}})
reject({operation="save", wan_vid="0409"})
form = {wan_vid="4094"}
reject({operation="save"})
form = {}
assert(invoke({operation="apply"}).success)
assert(#calls == 2 and calls[1]:find("'activate'",1,true), "apply must be single mutation")
assert(invoke({operation="gateway_status"}).data.mode == "disabled")
assert(invoke({operation="gateway_observe"}).data.mode == "observe")
assert(invoke({operation="gateway_disabled"}).data.mode == "disabled")
reject({operation="gateway_auto"})
fail = true
assert(not invoke({operation="apply"}).success, "CLI failure became success")
print("OK: Lua 5.1 controller input, status and transaction contracts")
