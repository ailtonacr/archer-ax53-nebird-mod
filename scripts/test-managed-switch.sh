#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail(){ echo "FAIL: $*" >&2; exit 1; }

mods="$(find mods -maxdepth 1 -type f -name '[0-9][0-9][0-9]-*.sh' -printf '%f\n' | sort)"
expected="011-devssh.sh
020-managed-switch.sh"
[ "$mods" = "$expected" ] || { echo "$mods" >&2; fail "branch must contain only SSH and managed-switch mods"; }

command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required to validate SPA module/bundle"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
fake_root="$tmp/rootfs"
mkdir -p "$fake_root/etc/rc.d" "$fake_root/etc/dropbear" "$fake_root/www/webpages/js"

# Minimal syntactically-valid fixture containing the stock contracts observed on
# hardware in index-D26yCMJF.js.gz:
# - route declarations live in `k` and end immediately before class H;
# - navConfig builds a visible menu by filtering the selected stock menu tree.
python3 - "$fake_root/www/webpages/js/index-D26yCMJF.js.gz" <<'PY'
import gzip, sys
text = r'''const C=(e)=>e;
const k=[{name:"networkStatus",path:"networkStatus",component:()=>C((()=>import("./status.js")),[],import.meta.url)},{name:"lanAdv",path:"lanAdv",component:()=>C((()=>import("./lan.js")),[],import.meta.url)},{name:"iptvAdv",path:"iptvAdv",component:()=>C((()=>import("./iptv.js")),[],import.meta.url)}];class H{static getTopMenuInfo(e,t){return e.find((({key:e})=>e===t))}static getExcludedMenu(e,t){return e}}
const de=t("navConfig",(()=>{const{setting:e,deviceConfig:t}=o(T()),{currentDialType:n,mode:r}=o(ie()),a=i((()=>{const t=O.base,n=e.value.region.toLowerCase();if(0===n.length)return t;const i=O[n];return i?{...t,...i}:t})),s=i((()=>{const e=t.value.supportOperationMode[0];return a.value[r.value]||a.value[e]||[]})),u=i((()=>{const e=[...t.value.hiddenFunction.modules,...oe.getToHideModules(n.value),...le.getHideMenus()];return H.getExcludedMenu(s.value,e)}));return{modeMenu:s,menu:u}}));
'''
with gzip.GzipFile(sys.argv[1], "wb", mtime=0) as gz:
    gz.write(text.encode())
PY

ROOTFS_DIR="$fake_root" bash -e mods/011-devssh.sh >/dev/null
ROOTFS_DIR="$fake_root" bash -e mods/020-managed-switch.sh >/dev/null

[ -x "$fake_root/etc/init.d/devssh" ] || fail "devssh not packaged"
[ -x "$fake_root/usr/sbin/ax53-switch" ] || fail "ax53-switch not packaged"
[ -x "$fake_root/etc/init.d/managed-switch" ] || fail "managed-switch init not packaged"
[ -x "$fake_root/etc/hotplug.d/switch/99-managed-switch" ] || fail "managed-switch hotplug not packaged"
[ -f "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" ] || fail "LuCI controller not packaged"
[ -f "$fake_root/www/webpages/js/ManagedSwitchPage-AX.js.gz" ] || fail "stock-context SPA module not packaged"
[ ! -e "$fake_root/www/webpages/managed-switch.html" ] || fail "legacy standalone page must not be packaged"
[ -L "$fake_root/etc/rc.d/S55devssh" ] || fail "S55devssh missing"
[ -L "$fake_root/etc/rc.d/S99managed-switch" ] || fail "S99managed-switch missing"

grep -Fq 'call("_index")' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "controller route is not stock-dispatch style"
grep -Fq 'controller._index(dispatch)' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "TP-Link stock controller transport missing"
grep -Fq 'function dispatch(body)' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "controller dispatch missing"
grep -Fq 'cpu_wan == "1" and wan_vid ~= "4094"' "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "controller CPU/WAN constraint missing"

python3 - "$fake_root/www/webpages/js/ManagedSwitchPage-AX.js.gz" <<'PY'
import gzip, sys
with gzip.open(sys.argv[1], "rt", encoding="utf-8") as fh:
    text=fh.read()
required=[
 'import { s as api } from "./update-store-DQkZxaRI.js"',
 'const API = "/admin/managed_switch"',
 'api.request(API',
 'preventError: true',
 'export function openManagedSwitch()',
 'Resposta de status incompleta do roteador.',
]
missing=[x for x in required if x not in text]
if missing: raise SystemExit("missing stock SPA module tokens: "+", ".join(missing))
if 'fetch(' in text or '/cgi-bin/luci/;stok=' in text:
    raise SystemExit("managed-switch module bypasses TP-Link stock API transport")
PY

python3 - "$fake_root/www/webpages/js/index-D26yCMJF.js.gz" <<'PY'
import gzip, sys
with gzip.open(sys.argv[1], "rt", encoding="utf-8") as fh: text=fh.read()
required=[
 "/*__AX53_MANAGED_SWITCH_NATIVE_MENU_V6__*/",
 'name:"managedSwitch"',
 'path:"managedSwitch"',
 "ManagedSwitchPage-AX.js?v=",
 "ManagedSwitchRoute",
 "ax53ManagedSwitchMenu",
 'findIndex((e=>"iptvAdv"===e.key))',
 '{key:"managedSwitch",text:"Switch / VLAN"}',
 'return ax53ManagedSwitchMenu(n),n',
 'return H.getExcludedMenu(s.value,e)',
 "e.openManagedSwitch()",
 "window.history.back()",
]
missing=[x for x in required if x not in text]
if missing: raise SystemExit("missing native route/menu tokens: "+", ".join(missing))
if text.count('name:"managedSwitch"') != 1: raise SystemExit("managed-switch route is not unique")
if text.count('key:"managedSwitch"') != 1: raise SystemExit("managed-switch menu node is not unique")
if text.count("/*__AX53_MANAGED_SWITCH_NATIVE_MENU_V6__*/") != 1: raise SystemExit("native menu marker is not unique")
for forbidden in (
    "__AX53_MANAGED_SWITCH_MENU__",
    "MutationObserver",
    "cloneNode(",
    "leafIptv",
    "rowFor",
    "/webpages/managed-switch.html",
):
    if forbidden in text:
        raise SystemExit("retired DOM/standalone integration remains: "+forbidden)
PY

gzip -dc "$fake_root/www/webpages/js/index-D26yCMJF.js.gz" | node --input-type=module --check

python3 scripts/patch-managed-switch-menu.py "$fake_root" >/dev/null
python3 - "$fake_root/www/webpages/js/index-D26yCMJF.js.gz" <<'PY'
import gzip, sys
with gzip.open(sys.argv[1], "rt", encoding="utf-8") as fh: text=fh.read()
if text.count('name:"managedSwitch"') != 1: raise SystemExit("second patch duplicated route")
if text.count('key:"managedSwitch"') != 1: raise SystemExit("second patch duplicated menu node")
if text.count("/*__AX53_MANAGED_SWITCH_NATIVE_MENU_V6__*/") != 1: raise SystemExit("second patch duplicated native marker")
if text.count("ManagedSwitchPage-AX.js?v=") != 1: raise SystemExit("second patch duplicated module import")
PY

grep -Fxq 'enabled=0' "$fake_root/etc/managed-switch/default.conf" || fail "default must be disabled"
grep -Fxq 'wan_vid=4094' "$fake_root/etc/managed-switch/default.conf" || fail "WAN VID must preserve stock interface"
grep -Fxq 'lan_vid=2' "$fake_root/etc/managed-switch/default.conf" || fail "LAN VID must preserve stock interface"

state="$tmp/tp_data"; log="$tmp/driver.log"
CLI="$fake_root/usr/sbin/ax53-switch"
ENV="MS_ETC_ROOT=$fake_root/etc MS_TP_DATA_ROOT=$state MS_TEST_LOG=$log"

env $ENV "$CLI" init >/dev/null
env $ENV "$CLI" check | grep -Fxq OK || fail "config validation failed"

: > "$log"
env $ENV "$CLI" apply >/dev/null
[ ! -s "$log" ] || fail "disabled profile unexpectedly touched switch"

env $ENV "$CLI" apply --force >/dev/null
grep -Fxq 'vlan reset' "$log" || fail "VLAN reset missing"
grep -Fxq 'vlan init' "$log" || fail "VLAN init missing"
grep -Fxq 'port ptype set 16 1' "$log" || fail "CPU tagged-frame mode missing"
grep -Fxq 'vlan set 4094 3 1' "$log" || fail "default WAN VLAN mask incorrect"
grep -Fxq 'vlan set 2 65566 28' "$log" || fail "default LAN VLAN mask incorrect"

env $ENV "$CLI" configure 4094 2 2 "1 3 4" 1 0 >/dev/null
grep -Fxq 'trunk_port=2' "$state/managed-switch/config" || fail "atomic configure did not move trunk"
grep -Fq 'access_ports="1 3 4"' "$state/managed-switch/config" || fail "atomic configure did not update access ports"
: > "$log"
env $ENV "$CLI" apply --force >/dev/null
grep -Fxq 'vlan set 4094 5 1' "$log" || fail "WAN VLAN did not follow LAN2 trunk"
grep -Fxq 'vlan set 2 65566 26' "$log" || fail "LAN mask did not follow access update"

env $ENV "$CLI" configure 4094 2 2 "2 3 4" 1 0 >/dev/null 2>&1 && fail "invalid trunk/access overlap accepted"
env $ENV "$CLI" configure 100 2 2 "1 3 4" 1 1 >/dev/null 2>&1 && fail "cpu_wan accepted with non-stock WAN VID"
env $ENV "$CLI" configure 4094 100 2 "1 3 4" 1 0 >/dev/null 2>&1 && fail "cpu_lan accepted with non-stock LAN VID"
env $ENV "$CLI" check | grep -Fxq OK || fail "rejected candidate corrupted persistent config"

: > "$log"
env $ENV "$CLI" rollback >/dev/null
grep -Fxq 'vlan set 4094 65537 1' "$log" || fail "fallback WAN layout missing"
grep -Fxq 'vlan set 2 65566 30' "$log" || fail "fallback LAN layout missing"
grep -Fq 'enabled="0"' "$state/managed-switch/config" || fail "rollback did not persist disabled state"

if command -v luac >/dev/null 2>&1; then
    luac -p "$fake_root/usr/lib/lua/luci/controller/admin/managed_switch.lua" || fail "LuCI controller syntax invalid"
fi

echo "OK: managed-switch CLI + stock TP-Link SPA/API contract + native route/nav menu model"
