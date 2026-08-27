module("luci.controller.admin.netbird", package.seeall)
local nixio=require"nixio"; local http=require"luci.http"; local model=require"luci.model.netbird"; local controller=require"luci.model.controller"
function index() entry({"admin","netbird"},call("_index")).leaf=true end
function _index() return controller._index(dispatch) end
local function reply(t)return{success=true,data=t}end
local function error_reply(c,m)return{success=false,errorcode=c,data={error=m or c,code=c}}end
local function scalar(v) if type(v)=="table" then return v[#v] end; if v==nil then return nil end; return tostring(v) end
local function request_value(b,k) if b and b[k]~=nil then return scalar(b[k]) end; return http.formvalue(k) end
local function request_settings(b) local c={}; local src=b or http.formvaluetable() or {}; for k,v in pairs(src) do if k~="operation" and k~="setup_key" then c[k]=scalar(v) end end; return c end
local function classify(s,st)
 if not model.payload_ok() then return"payload_missing" end
 local d=st and st.daemonStatus or""
 if d=="NeedsLogin" then return"enrollment_required" elseif d=="Connected" then return"connected" elseif d=="Connecting" or d=="Restarting" then return"connecting" elseif d=="Idle" or d=="Disconnected" or d=="Down" then return s.enable=="1" and"disconnected" or"disabled" end
 return s.enable=="1" and"stopped" or"disabled"
end
local function reconcile(s,st)
 if not st then return s end; local d=st.daemonStatus or""; local p=nil
 if d=="NeedsLogin" and s.enrolled~="0" then p={enrolled="0"}
 elseif d=="Connected" or d=="Connecting" or d=="Restarting" then p={}; if s.enrolled~="1" then p.enrolled="1" end; if s.enable~="1" then p.enable="1" end
 elseif (d=="Idle" or d=="Disconnected" or d=="Down") and s.enrolled~="1" then p={enrolled="1"} end
 if p and next(p) then local u=model.set_internal_settings(p); if u then return u end end; return s
end
local function op_status()
 local s=model.get_settings(); local st=model.status(); s=reconcile(s,st); local nb={}
 if st then nb={daemonStatus=st.daemonStatus or"",cliVersion=st.cliVersion or"",daemonVersion=st.daemonVersion or"",netbirdIp=st.netbirdIp or"",publicKey=st.publicKey or"",fqdn=st.fqdn or"",wireguardPort=st.wireguardPort or 0,managementConnected=st.management and st.management.connected or false,managementUrl=st.management and st.management.url or"",signalConnected=st.signal and st.signal.connected or false,peersTotal=st.peers and st.peers.total or 0,peersConnected=st.peers and st.peers.connected or 0} end
 return reply({code=classify(s,st),settings=s,netbird=nb,payload={version=model.payload_version(),state=model.payload_state(),provisioned=model.payload_ok()}})
end
local function op_settings_set(b)
 local prev=model.get_settings(); local cur,e=model.set_settings(request_settings(b)); if not cur then return error_reply("bad_request",e or"invalid settings") end
 local o,r
 if prev.enable~=cur.enable then if cur.enable=="1" then o,r=model.control("start"); if r==0 then cur=model.set_internal_settings({enrolled="1",enable="1"}) or cur end else o,r=model.control("stop"); if r==0 then cur=model.set_internal_settings({enable="0"}) or cur end end
 elseif cur.enable=="1" then o,r=model.control("restart"); if r==0 then cur=model.set_internal_settings({enrolled="1",enable="1"}) or cur end end
 if r~=nil and r~=0 then return error_reply("apply_failed","settings saved but apply failed: "..(o or"failed to apply settings"):gsub("%s+$","")) end
 return reply({settings=cur})
end
local function op_enroll(b)
 local k=request_value(b,"setup_key"); if not k or k=="" then return error_reply("bad_request","setup key required") end
 local m=request_value(b,"management_url"); if m and m~="" then local c,e=model.set_settings({management_url=m}); if not c then return error_reply("bad_request",e or"invalid management url") end end
 local t="/tmp/nb-setup-key-"..tostring(os.time()).."-"..tostring(math.random(0x7fffffff)); local lfs=require"luci.fs"; if not lfs.writefile(t,k) then return error_reply("internal","failed to stage setup key") end; nixio.fs.chmod(t,384)
 local o,r=model.control("enroll",t); nixio.fs.unlink(t); if r~=0 then return error_reply("enroll_failed",(o or"enrollment failed"):gsub("%s+$","")) end
 local c,e=model.set_internal_settings({enrolled="1",enable="1"}); if not c then return error_reply("internal",e or"failed to persist enrollment state") end; return reply({result="ok",settings=c})
end
local function op_control(op) local o,r=model.control(op); if r~=0 then return error_reply("control_failed",(o or op):gsub("%s+$","")) end; if op=="start" or op=="restart" then model.set_internal_settings({enrolled="1",enable="1"}) elseif op=="stop" then model.set_internal_settings({enable="0"}) end; return reply({result="ok",output=o and o:gsub("%s+$","") or""}) end
local function op_clean() model.control("stop"); model.control("clean"); local c,e=model.set_internal_settings({enrolled="0",enable="0"}); if not c then return error_reply("internal",e or"failed to reset NetBird state") end; return reply({result="ok",settings=c}) end
function dispatch(b) local op=request_value(b,"operation") or"status"; local ok,res=pcall(function() if op=="status" then return op_status() elseif op=="settings_get" then return reply({settings=model.get_settings()}) elseif op=="settings_set" then return op_settings_set(b) elseif op=="enroll" then return op_enroll(b) elseif op=="start" or op=="stop" or op=="restart" then return op_control(op) elseif op=="clean" then return op_clean() elseif op=="log" then return reply({lines=model.log(tonumber(request_value(b,"lines") or"100") or 100)}) elseif op=="payload_status" then return reply({version=model.payload_version(),provisioned=model.payload_ok(),state=model.payload_state()}) else return error_reply("bad_request","unknown operation") end end); if not ok then return error_reply("internal",tostring(res)) end; return res end
