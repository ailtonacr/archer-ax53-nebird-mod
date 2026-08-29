-- Load-time registration of NetBird in TP-Link's stock VPN Client controller.
-- No HTTP route is registered here. Requiring the vendor controller initializes
-- its global registries; install() then appends the fifth type in-place before
-- /admin/vpn requests use those registries.
module("luci.controller.admin.netbird_native", package.seeall)

local native = require "luci.model.netbird_vpn_native"

function index()
    local ok, err = native.install()
    if not ok then
        error("failed to register native NetBird VPN type: " .. tostring(err or "unknown error"))
    end
end
