import { s as api } from "./update-store-DQkZxaRI.js";

const API = "/admin/managed_switch";
const ROOT_ID = "ax53-managed-switch-page";
const STYLE_ID = "ax53-managed-switch-style";

function req(operation, extra) {
  return api.request(API, Object.assign({ operation }, extra || {}), {
    preventSuccess: true,
    preventError: true,
  });
}

function unwrap(value) {
  if (value && value.success !== undefined && value.data !== undefined) return value.data;
  return value || {};
}

function errMsg(e) {
  if (!e) return "Falha ao executar a operação.";
  if (typeof e === "string") return e;
  const d = e.response && e.response.data;
  const candidates = [
    d && d.data && d.data.error,
    d && d.error,
    e.data && e.data.data && e.data.data.error,
    e.data && e.data.error,
    e.error,
    e.message,
    e.errorcode,
    e.errorCode,
  ];
  for (const value of candidates) if (typeof value === "string" && value) return value;
  return "Falha ao executar a operação.";
}

function ensureStyle() {
  if (document.getElementById(STYLE_ID)) return;
  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = `
#${ROOT_ID}{position:fixed;inset:0;z-index:99999;background:#f4f6f7;overflow:auto;color:#243238;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif}
#${ROOT_ID} *{box-sizing:border-box}#${ROOT_ID} header{background:#fff;border-bottom:1px solid #dfe5e8;padding:18px 22px;position:sticky;top:0;z-index:2}
#${ROOT_ID} .ms-top{max-width:1080px;margin:auto;display:flex;justify-content:space-between;align-items:center;gap:12px}#${ROOT_ID} h1{font-size:22px;margin:0}#${ROOT_ID} .ms-muted{color:#6b797f;font-size:13px}
#${ROOT_ID} main{max-width:1080px;margin:22px auto;padding:0 18px}#${ROOT_ID} .ms-grid{display:grid;grid-template-columns:1.2fr .8fr;gap:18px}#${ROOT_ID} .ms-card{background:#fff;border:1px solid #dfe5e8;border-radius:11px;padding:18px;margin-bottom:18px}
#${ROOT_ID} .ms-warn{background:#fff8df;border-left:4px solid #d59500;padding:12px 14px;border-radius:7px;margin-bottom:18px}#${ROOT_ID} .ms-fields{display:grid;grid-template-columns:1fr 1fr;gap:14px}#${ROOT_ID} .ms-field{display:flex;flex-direction:column;gap:6px}#${ROOT_ID} .ms-full{grid-column:1/-1}
#${ROOT_ID} label{font-size:13px;font-weight:650}#${ROOT_ID} input[type=number],#${ROOT_ID} select{padding:10px;border:1px solid #cbd5d9;border-radius:7px;background:#fff}#${ROOT_ID} .ms-ports{display:flex;gap:8px;flex-wrap:wrap}#${ROOT_ID} .ms-chip{border:1px solid #cbd5d9;border-radius:7px;padding:8px 10px;font-size:13px}
#${ROOT_ID} .ms-actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:18px}#${ROOT_ID} button{border:0;border-radius:7px;padding:10px 13px;font-weight:650;cursor:pointer}#${ROOT_ID} button:disabled{opacity:.45;cursor:not-allowed}#${ROOT_ID} .ms-primary{background:#1598a2;color:#fff}#${ROOT_ID} .ms-secondary{background:#e8eef0}#${ROOT_ID} .ms-warning{background:#d98612;color:#fff}#${ROOT_ID} .ms-danger{background:#b83d3d;color:#fff}
#${ROOT_ID} .ms-badge{display:inline-block;padding:5px 9px;border-radius:999px;font-size:12px;font-weight:700}#${ROOT_ID} .ms-on{background:#e3f7ed;color:#176a43}#${ROOT_ID} .ms-off{background:#edf1f3;color:#56646a}#${ROOT_ID} .ms-dirty{background:#fff1c7;color:#805900}#${ROOT_ID} .ms-toast{display:none;padding:11px 13px;border-radius:7px;margin-bottom:16px}#${ROOT_ID} .ms-toast.show{display:block}#${ROOT_ID} .ms-ok{background:#e5f7ed;color:#155f3e}#${ROOT_ID} .ms-err{background:#fdeaea;color:#8e2b2b}
#${ROOT_ID} table{width:100%;border-collapse:collapse;font-size:13px}#${ROOT_ID} th,#${ROOT_ID} td{padding:8px;border-bottom:1px solid #e7ecee;text-align:left}#${ROOT_ID} pre{background:#172026;color:#d8e4e8;padding:11px;border-radius:7px;white-space:pre-wrap;max-height:250px;overflow:auto;font-size:12px}#${ROOT_ID} .ms-advanced{margin-top:14px;display:grid;gap:9px}#${ROOT_ID} .ms-small{font-size:12px;color:#6b797f;white-space:pre-line}#${ROOT_ID} .ms-locked{display:none;margin-top:12px;padding:9px 11px;border-radius:7px;background:#edf1f3;color:#56646a;font-size:12px}#${ROOT_ID} .ms-locked.show{display:block}
@media(max-width:820px){#${ROOT_ID} .ms-grid,#${ROOT_ID} .ms-fields{grid-template-columns:1fr}#${ROOT_ID} .ms-full{grid-column:auto}}
`;
  document.head.appendChild(style);
}

function template() {
  return `
<header><div class="ms-top"><div><h1>Switch / VLAN</h1><div class="ms-muted">Archer AX53 · RTL8367S · Rede</div></div><button class="ms-secondary" data-act="close">Voltar</button></div></header>
<main>
<div data-role="toast" class="ms-toast"></div>
<div class="ms-warn"><strong>Salvar não altera o switch.</strong> O RTL8367S só é reprogramado ao clicar em <strong>Aplicar agora</strong>. No primeiro cutover, mantenha acesso por Wi-Fi ou por uma porta access. Não use o perfil gerenciado simultaneamente com IPTV/VLAN customizado da TP-Link.</div>
<div class="ms-grid"><section>
<div class="ms-card"><div style="display:flex;justify-content:space-between;align-items:center;gap:10px"><h2 style="margin:0;font-size:17px">Perfil gerenciado</h2><span data-role="badge" class="ms-badge ms-off">Carregando…</span></div>
<form data-role="form" style="margin-top:16px"><div class="ms-fields">
<div class="ms-field"><label>VLAN WAN</label><input data-f="wan" type="number" min="1" max="4094" required></div>
<div class="ms-field"><label>VLAN LAN</label><input data-f="lan" type="number" min="1" max="4094" required></div>
<div class="ms-field"><label>Porta trunk</label><select data-f="trunk"><option value="1">LAN1</option><option value="2">LAN2</option><option value="3">LAN3</option><option value="4">LAN4</option></select></div>
<div class="ms-field ms-full"><label>Portas access LAN</label><div data-role="ports" class="ms-ports"></div><span class="ms-small">A porta trunk fica tagged; as portas selecionadas ficam untagged na VLAN LAN.</span></div></div>
<div class="ms-advanced"><label><input data-f="cpuLan" type="checkbox"> CPU na VLAN LAN <span class="ms-small">(mantém eth1.2 / br-lan / Wi-Fi; exige VLAN LAN 2)</span></label><label><input data-f="cpuWan" type="checkbox"> CPU na VLAN WAN <span class="ms-small">(normalmente desligado; exige VLAN WAN 4094)</span></label></div>
<div data-role="locked" class="ms-locked">O perfil está ativo. Desabilite/restaure stock antes de editar para evitar divergência entre estado persistente e tabela L2.</div>
<div class="ms-actions"><button class="ms-primary" type="submit" data-act="save">Salvar configuração</button><button class="ms-warning" type="button" data-act="apply">Aplicar agora</button><button class="ms-danger" type="button" data-act="rollback">Rollback stock</button></div></form></div>
<div class="ms-card"><h2 style="font-size:17px;margin-top:0">Topologia resultante</h2><table><thead><tr><th>Porta</th><th>Modo</th><th>Untagged/PVID</th><th>Tagged</th></tr></thead><tbody data-role="topology"></tbody></table></div>
</section><aside><div class="ms-card"><h2 style="font-size:17px;margin-top:0">Estado persistente</h2><div data-role="summary" class="ms-small">Carregando…</div></div><div class="ms-card"><h2 style="font-size:17px;margin-top:0">Tabela VLAN ativa</h2><pre data-role="driver">Carregando…</pre></div></aside></div></main>`;
}

export function openManagedSwitch() {
  const existing = document.getElementById(ROOT_ID);
  if (existing) return existing.__managedSwitchRefresh && existing.__managedSwitchRefresh();

  ensureStyle();
  const root = document.createElement("div");
  root.id = ROOT_ID;
  root.innerHTML = template();
  document.body.appendChild(root);
  document.body.style.overflow = "hidden";

  const q = s => root.querySelector(s);
  const qa = s => Array.from(root.querySelectorAll(s));
  let state = null;
  let busy = false;
  let draftAccess = new Set(["2", "3", "4"]);
  let currentTrunk = "1";

  const f = {
    wan: q('[data-f="wan"]'), lan: q('[data-f="lan"]'), trunk: q('[data-f="trunk"]'),
    cpuLan: q('[data-f="cpuLan"]'), cpuWan: q('[data-f="cpuWan"]'),
  };

  function close() {
    document.body.style.overflow = "";
    root.remove();
  }
  function toast(msg, ok) {
    const el = q('[data-role="toast"]');
    el.textContent = msg;
    el.className = "ms-toast show " + (ok ? "ms-ok" : "ms-err");
  }
  function selectedAccess() { return [...draftAccess].filter(p => p !== f.trunk.value).sort(); }
  function draft() { return { wan_vid:String(f.wan.value), lan_vid:String(f.lan.value), trunk_port:String(f.trunk.value), access_ports:selectedAccess().join(" "), cpu_lan:f.cpuLan.checked?"1":"0", cpu_wan:f.cpuWan.checked?"1":"0" }; }
  function dirty() {
    if (!state) return false;
    const d = draft();
    return d.wan_vid!==String(state.wan_vid)||d.lan_vid!==String(state.lan_vid)||d.trunk_port!==String(state.trunk_port)||d.access_ports!==String(state.access_ports||"").trim()||d.cpu_lan!==String(Number(state.cpu_lan)||0)||d.cpu_wan!==String(Number(state.cpu_wan)||0);
  }
  function enabled() { return !!state && Number(state.enabled) === 1; }
  function syncControls() {
    const on = enabled(), changed = dirty();
    [f.wan,f.lan,f.trunk,f.cpuLan,f.cpuWan].forEach(el => el.disabled = busy || on);
    qa('[data-role="ports"] input').forEach(el => el.disabled = busy || on || el.value === f.trunk.value);
    q('[data-act="save"]').disabled = busy || on || !state || !changed;
    q('[data-act="apply"]').disabled = busy || !state || changed;
    q('[data-act="rollback"]').disabled = busy || !state;
    q('[data-role="locked"]').className = "ms-locked" + (on ? " show" : "");
    const badge = q('[data-role="badge"]');
    if (changed && !on) { badge.textContent="Alterações não salvas"; badge.className="ms-badge ms-dirty"; }
    else { badge.textContent=on?"Perfil ativo":"Perfil desabilitado"; badge.className="ms-badge "+(on?"ms-on":"ms-off"); }
  }
  function renderPorts() {
    const trunk = f.trunk.value;
    draftAccess.delete(trunk);
    const box=q('[data-role="ports"]'); box.innerHTML="";
    ["1","2","3","4"].forEach(p=>{const l=document.createElement("label");l.className="ms-chip";const i=document.createElement("input");i.type="checkbox";i.value=p;i.checked=p!==trunk&&draftAccess.has(p);i.onchange=()=>{i.checked?draftAccess.add(p):draftAccess.delete(p);renderTopology();syncControls()};l.append(i,document.createTextNode(" LAN"+p));box.appendChild(l)});
    renderTopology(); syncControls();
  }
  function renderTopology() {
    const wan=f.wan.value||"—",lan=f.lan.value||"—",trunk=f.trunk.value,access=selectedAccess(),rows=[["WAN","Access",wan,"—"]];
    ["1","2","3","4"].forEach(p=>{if(p===trunk)rows.push(["LAN"+p,"Trunk",lan+" (PVID)",lan+", "+wan]);else if(access.includes(p))rows.push(["LAN"+p,"Access",lan,"—"]);else rows.push(["LAN"+p,"Sem membro","—","—"])});
    const tagged=[];if(f.cpuLan.checked)tagged.push(lan);if(f.cpuWan.checked)tagged.push(wan);rows.push(["CPU / 16","CPU","—",tagged.join(", ")||"—"]);
    q('[data-role="topology"]').innerHTML=rows.map(r=>`<tr><td>${r[0]}</td><td>${r[1]}</td><td>${r[2]}</td><td>${r[3]}</td></tr>`).join("");
  }
  function validate() {
    const wan=Number(f.wan.value),lan=Number(f.lan.value),access=selectedAccess();
    if(!Number.isInteger(wan)||wan<1||wan>4094)return "VLAN WAN deve estar entre 1 e 4094";
    if(!Number.isInteger(lan)||lan<1||lan>4094)return "VLAN LAN deve estar entre 1 e 4094";
    if(wan===lan)return "VLAN WAN e VLAN LAN devem ser diferentes";
    if(!access.length)return "Selecione ao menos uma porta access";
    if(f.cpuLan.checked&&lan!==2)return "Com CPU na LAN habilitada, a VLAN LAN deve permanecer 2";
    if(f.cpuWan.checked&&wan!==4094)return "Com CPU na WAN habilitada, a VLAN WAN deve permanecer 4094";
    return "";
  }
  function fill(value) {
    const d=unwrap(value);
    if(!d || d.wan_vid===undefined || d.lan_vid===undefined || d.trunk_port===undefined) throw new Error("Resposta de status incompleta do roteador.");
    state=d; f.wan.value=d.wan_vid; f.lan.value=d.lan_vid; currentTrunk=String(d.trunk_port); f.trunk.value=currentTrunk;
    draftAccess=new Set(String(d.access_ports||"").split(/\s+/).filter(Boolean)); draftAccess.delete(currentTrunk);
    f.cpuLan.checked=Number(d.cpu_lan)===1; f.cpuWan.checked=Number(d.cpu_wan)===1;
    q('[data-role="summary"]').textContent="Perfil: "+(d.profile||"—")+"\nConfig: "+(d.config||"—")+"\nTrunk: LAN"+d.trunk_port+"\nAccess: "+(d.access_ports||"—")+"\nCPU LAN: "+(Number(d.cpu_lan)===1?"sim":"não")+"\nCPU WAN: "+(Number(d.cpu_wan)===1?"sim":"não");
    q('[data-role="driver"]').textContent=d.driver_vlan||"Tabela não disponível";
    renderPorts();
  }
  async function refresh() {
    busy=true;syncControls();
    try { fill(await req("status")); }
    catch(e){ toast(errMsg(e),false); }
    finally { busy=false;syncControls(); }
  }
  async function action(operation, payload, success) {
    busy=true;syncControls();
    try { const r=await req(operation,payload); if (r) { const u=unwrap(r); if(u&&u.wan_vid!==undefined) fill(u); else await refresh(); } toast(success,true); return true; }
    catch(e){ toast(errMsg(e),false); return false; }
    finally { busy=false;syncControls(); }
  }

  q('[data-act="close"]').onclick=close;
  f.trunk.onchange=()=>{const next=f.trunk.value;if(currentTrunk&&currentTrunk!==next)draftAccess.add(currentTrunk);draftAccess.delete(next);currentTrunk=next;renderPorts()};
  [f.wan,f.lan,f.cpuLan,f.cpuWan].forEach(el=>el.oninput=()=>{renderTopology();syncControls()});
  q('[data-role="form"]').onsubmit=e=>{e.preventDefault();if(enabled())return toast("Desabilite/restaure stock antes de editar.",false);const error=validate();if(error)return toast(error,false);action("save",draft(),"Configuração salva; switch físico não foi alterado.")};
  q('[data-act="apply"]').onclick=async()=>{if(!state)return;if(dirty())return toast("Salve as alterações antes de aplicar.",false);if(!confirm("Isso reprograma o RTL8367S imediatamente. Confirme que o Proxmox está preparado, IPTV/VLAN custom está desabilitado e sua sessão não está na porta trunk. Aplicar agora?"))return;const ok=enabled()||await action("enable",{},"Perfil habilitado; aplicando…");if(ok)await action("apply",{},"Perfil aplicado ao switch.")};
  q('[data-act="rollback"]').onclick=()=>{if(confirm("Executar rollback para o pipeline/layout stock e desabilitar o perfil gerenciado?"))action("rollback",{},"Rollback solicitado; perfil gerenciado desabilitado.")};
  root.__managedSwitchRefresh=refresh;
  refresh();
  return root;
}

export default { openManagedSwitch };
