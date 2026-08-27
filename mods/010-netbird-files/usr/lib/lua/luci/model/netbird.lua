module("luci.model.netbird", package.seeall)
local nixio=require"nixio"; local fs=require"luci.fs"; local sys=require"luci.sys"; local json=require"luci.json"
local function shellquote(v) local s=tostring(v or ""); return "'"..s:gsub("'","'\\''").."'" end
SETTINGS="/tp_data/netbird/settings"; CTL="/sbin/netbird-ctl"
KEYS={enable={kind="bool",default="0"},enrolled={kind="bool",default="0",readonly=true},management_url={kind="url",default="https://netbird.ailton.dev.br"},hostname={kind="name",default=""},disable_dns={kind="bool",default="1"},disable_firewall={kind="bool",default="1"},disable_client_routes={kind="bool",default="1"},disable_server_routes={kind="bool",default="1"},disable_ipv6={kind="bool",default="1"},network_monitor={kind="bool",default="0"},advertise_lan={kind="bool",default="0"},advertise_cidr={kind="cidr",default=""},wireguard_port={kind="int",default="51820"}}
local function read_settings() local t={}; local raw=fs.readfile(SETTINGS) or ""; for line in raw:gmatch("[^\r\n]+") do local k,v=line:match("^([%w_]+)=(.*)$"); if k then t[k]=(v or ""):gsub("%s+$","") end end; return t end
function get_settings() local c,o=read_settings(),{}; for k,s in pairs(KEYS) do o[k]=c[k] or s.default end; return o end
local function vb(v)return v=="0" or v=="1" end
local function vu(v) if v==nil or v=="" then return true end; return v:match("^https?://[%w%.%-]+(%.%w+)(:%d+)?(/[%w%-%.%_~/#%%&%?%=%+%,]*)?$")~=nil end
local function vn(v)return v~=nil and #v<=64 and v:match("^[%w%.%-_]*$")~=nil end
local function vc(v) if v==nil or v=="" then return true end; local ip,p=v:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)$"); if not ip then return false end; for o in ip:gmatch("%d+") do local n=tonumber(o); if not n or n>255 then return false end end; p=tonumber(p); return p and p>=0 and p<=32 end
local function vi(v,l,h)local n=tonumber(v); return n and n>=l and n<=h end
local function sanitize(c,ro) local o={}; for k,s in pairs(KEYS) do if c[k]~=nil and (ro or not s.readonly) then local v,ok=c[k],false; if s.kind=="bool" then if v==true then v="1" elseif v==false then v="0" else v=tostring(v) end; ok=vb(v) elseif s.kind=="url" then v=tostring(v or ""); ok=vu(v) elseif s.kind=="name" then v=tostring(v or ""); ok=vn(v) elseif s.kind=="cidr" then v=tostring(v or ""); ok=vc(v) elseif s.kind=="int" then ok=vi(v,1,65535); if ok then v=tostring(v) end end; if not ok then return nil,"invalid value for "..k end; o[k]=v end end; return o end
local function write(c) local l={}; for k,s in pairs(KEYS) do l[#l+1]=k.."="..(c[k] or s.default) end; fs.mkdir("/tp_data/netbird"); nixio.fs.chmod("/tp_data/netbird",448); if not fs.writefile(SETTINGS,table.concat(l,"\n").."\n") then return nil,"failed to write settings" end; nixio.fs.chmod(SETTINGS,384); return get_settings() end
function set_settings(c) local u,e=sanitize(c or {},false); if not u then return nil,e end; local cur=read_settings(); for k,v in pairs(u) do cur[k]=v end; if (cur.advertise_lan or "0")=="1" and (cur.advertise_cidr or "")=="" then return nil,"advertise_cidr required when LAN routing is enabled" end; return write(cur) end
function set_internal_settings(c) local a={}; if c and c.enrolled~=nil then a.enrolled=c.enrolled end; if c and c.enable~=nil then a.enable=c.enable end; local u,e=sanitize(a,true); if not u then return nil,e end; local cur=read_settings(); for k,v in pairs(u) do cur[k]=v end; return write(cur) end
local function run(...) local p={shellquote(CTL)}; for i=1,select("#",...) do p[#p+1]=shellquote(tostring(select(i,...))) end; return sys.exec(table.concat(p," ")) end
local function run_ex(...) local p={shellquote(CTL)}; for i=1,select("#",...) do p[#p+1]=shellquote(tostring(select(i,...))) end; local o=sys.exec(table.concat(p," ").." 2>&1; echo RC=$?"); local r=tonumber(o:match("RC=(%d+)%s*$") or ""); return o:gsub("%s*RC=%d+%s*$",""),r end
function status() local o=run("status"); if o and o~="" then local ok,x=pcall(json.decode,o); if ok and type(x)=="table" then return x end end end
function control(op,k) if op=="enroll" then return run_ex("up","--setup-key-file",k) elseif op=="start" or op=="up" then return run_ex("up") elseif op=="stop" then return run_ex("stop") elseif op=="down" then return run_ex("down") elseif op=="restart" then return run_ex("restart") elseif op=="clean" then return run_ex("clean") end end
function log(n)local l=tonumber(n) or 100;if l<1 then l=100 end;if l>500 then l=500 end;return run("log",tostring(l)) or "" end
function payload_version()return(run("payload-version") or ""):gsub("%s+$","") end
function payload_ok()local _,r=run_ex("payload-status");return r==0 end
function payload_state()local o=run("payload-status");return(o or ""):match("^%s*(%S+)") or "UNKNOWN" end
