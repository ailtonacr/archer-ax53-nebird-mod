-- Load-time registration of NetBird in TP-Link's stock VPN Client controller.
-- No HTTP route is registered here. The require must happen inside index():
-- this LuCI dispatcher serializes/caches controller index() functions and does
-- not preserve local upvalues when recreating the route tree.
module("luci.controller.admin.netbird_native", package.seeall)

function index()
    local native = require "luci.model.netbird_vpn_native"

    local ok, err = native.install()
    if not ok then
        io.stderr:write(
            "netbird: failed to register native VPN type: "
            .. tostring(err or "unknown error")
            .. "\n"
        )
        return
    end
end
