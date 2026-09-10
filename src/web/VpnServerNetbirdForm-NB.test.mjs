import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const original = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8");

for (const token of [
  'stockComponent(this, "su-form-item")',
  'stockComponent(this, "su-input")',
  'stockComponent(this, "su-password")',
  'stockComponent(this, "su-checkbox")',
  'stockComponent(this, "su-button")',
  'stockComponent(this, "su-alert")',
  'stockComponent(this, "su-spin")',
  'const creating = ref(true)',
  'const existing = !!(value && (value.key || value.id))',
  'const profileKey = ref("")',
  'setup_key: setupKey.value || ""',
  'A Setup Key será usada para enrollment durante o SALVAR stock da TP-Link',
  's.advertise_lan === "1" && s.disable_server_routes !== "0"',
  's.advertise_lan === "1" && s.disable_firewall !== "0"',
  'Permitir roteamento da LAN',
  'return _h(SuSpin, { spinning: this.busy }, { default: () => items })',
]) assert.ok(original.includes(token), `missing authored token ${token}`);

for (const token of [
  'stockComponent(this, "su-form")',
  "NETBIRD_CSS", 'type: "checkbox"', 'class: "netbird-input"', "syncNativeSaveButton", "unknown error",
  'value.type === "netbirdvpn"', 'value.type === "netbird"', "const creating = ref(false)",
  'Anunciar rede local', 'Já existe um perfil NetBird', 'async function enroll()', 'async function afterStockSave()',
  'enable: s.enable === "1" ? "on" : "off"',
]) assert.equal(original.includes(token), false, `generic/legacy UI token leaked: ${token}`);

const source = original
  .replace(/^import .*?;\nimport .*?;\n/s, "")
  .replace("export default defineComponent(", "globalThis.component = defineComponent(");

const timers = [];
const requests = [];
let exposed = null;
let response = {
  code: "connected",
  profileExists: true,
  settings: {
    enrolled: "1", management_url: "https://netbird.example", advertise_cidr: "192.168.10.0/24",
    disable_dns: "1", disable_firewall: "0", disable_client_routes: "1",
    disable_server_routes: "0", disable_ipv6: "1", network_monitor: "0",
    advertise_lan: "1", enable: "1", wireguard_port: "51820", hostname: "",
  },
  netbird: { netbirdIp: "100.64.0.1", peersConnected: 1, peersTotal: 2 },
  traffic: { uploadSpeed: 125000, downloadSpeed: 250000 },
  payload: { state: "READY", version: "0.77.1" },
};

const context = {
  defineComponent: value => value,
  ref: value => ({ value }),
  onMounted: fn => context.mounted = fn,
  onUnmounted: fn => context.unmounted = fn,
  _h: (tag, props, children) => ({ tag, props: props || {}, children: children || [] }),
  setInterval: fn => { timers.push(fn); return timers.length; },
  clearInterval: () => {},
  URL,
  api: { request: async (path, body) => {
    requests.push({ path, ...body });
    return response;
  } },
};
vm.runInNewContext(source, context, { filename: "VpnServerNetbirdForm-NB.js" });

const state = context.component.setup({ disabled: false }, { expose: value => { exposed = value; } });
context.mounted();
await new Promise(resolve => setTimeout(resolve, 0));

assert.ok(exposed, "component must expose stock dynamic-form methods");
assert.equal(typeof exposed.isChanged, "object");
for (const key of ["validate", "setForm", "getForm", "resetForm", "clearValidate"])
  assert.equal(typeof exposed[key], "function", `${key} must be exposed`);
assert.equal(typeof context.component.render, "function");

// CREATE remains stock-owned. The provider contributes protocol fields plus one
// transient setup_key that is consumed by the backend callback during the same
// /admin/vpn Save. It must not call /admin/netbird before the profile exists.
assert.equal(exposed.setForm({
  type: "netbirdvpn", management_url: "https://netbird.example",
  advertise_lan: "0", disable_server_routes: "1", disable_firewall: "1", wireguard_port: "51820",
}), true);
assert.equal(state.creating.value, true);
assert.equal(state.profileKey.value, "");
await assert.rejects(() => exposed.validate(), /Setup Key/);
state.updateSetupKey("setup-key-only-for-save");
assert.equal(await exposed.validate(), true);
await timers[0]();
assert.equal(requests.length, 0, "Add mode must not use auxiliary backend before stock Save");

const addForm = exposed.getForm();
for (const field of ["key", "id", "type", "description", "enable", "enabled", "enrolled"])
  assert.equal(field in addForm, false, `provider subform must not own generic field ${field}`);
assert.equal(addForm.management_url, "https://netbird.example");
assert.equal(addForm.setup_key, "setup-key-only-for-save");

// A persisted stock key alone proves Edit. Diagnostics are profile-scoped. An
// already enrolled profile may save with setup_key blank; a populated value is
// treated as explicit re-enrollment by the provider callback.
assert.equal(exposed.setForm({
  key: "arbitrary-stock-key", type: "netbirdvpn", server: "https://netbird.example",
  management_url: "https://netbird.example", enable: "on", enrolled: "1",
  advertise_lan: "1", advertise_cidr: "192.168.10.0/24", disable_server_routes: "0",
  disable_firewall: "0", wireguard_port: "51820",
}), true);
assert.equal(state.creating.value, false);
assert.equal(state.profileKey.value, "arbitrary-stock-key");
await new Promise(resolve => setTimeout(resolve, 0));
assert.ok(requests.some(r => r.operation === "status" && r.profile_key === "arbitrary-stock-key"));
assert.equal(await exposed.validate(), true);

const editForm = exposed.getForm();
assert.equal(editForm.management_url, "https://netbird.example");
assert.equal(editForm.server, "https://netbird.example");
assert.equal(editForm.setup_key, "");
for (const field of ["key", "id", "type", "description", "enable", "enabled", "enrolled"])
  assert.equal(field in editForm, false, `protocol subform must not own TP-Link field ${field}`);

// Routing peer invariants remain provider-specific validation.
state.updateDraft("advertise_lan", "0");
state.updateDraft("disable_server_routes", "1");
state.updateDraft("disable_firewall", "1");
state.updateDraft("advertise_lan", "1");
assert.equal(state.draft.value.disable_server_routes, "0");
assert.equal(state.draft.value.disable_firewall, "0");
state.updateDraft("advertise_cidr", "192.168.10.0/24");
assert.equal(await exposed.validate(), true);
state.updateDraft("disable_server_routes", "1");
await assert.rejects(() => exposed.validate(), /Rotas de servidor/);
state.updateDraft("disable_server_routes", "0");
state.updateDraft("disable_firewall", "1");
await assert.rejects(() => exposed.validate(), /firewall do NetBird/);
state.updateDraft("disable_firewall", "0");
assert.equal(await exposed.validate(), true);

// Polling remains read-only and cannot overwrite a draft being edited.
state.updateDraft("advertise_cidr", "192.168.");
assert.equal(state.dirty.value, true);
response = { ...response, settings: { ...response.settings, advertise_cidr: "10.0.0.0/24" } };
for (let i = 0; i < 3; i++) await timers[0]();
assert.equal(state.draft.value.advertise_cidr, "192.168.");
assert.equal(requests.some(r => r.operation === "settings_set"), false);
await assert.rejects(() => exposed.validate(), /CIDR/);

state.updateDraft("advertise_lan", "0");
state.updateDraft("management_url", "https://netbird.example");
state.updateDraft("wireguard_port", "51820");
assert.equal(await exposed.validate(), true);
assert.equal(requests.some(r => r.operation === "settings_set"), false, "editing must never persist before stock dialog Save");

context.unmounted();
console.log("netbird stock-create/transient-setup-key/multi-profile/draft contract ok");
