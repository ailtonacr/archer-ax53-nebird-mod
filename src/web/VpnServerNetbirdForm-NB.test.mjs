import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const original = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8");

for (const token of [
  'stockComponent(this, "su-form")',
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
  'const identityPresent = ref(null)',
  'identityPresent.value = !!r.identityPresent',
  'enrollment_token: enrollmentToken.value || ""',
  'stage_setup_key',
  '"onUpdate:modelValue": onSetupKey',
  'onInput: onSetupKey',
  'A identidade deste perfil já existe. Deixe a Setup Key em branco para mantê-la',
  's.advertise_lan === "1" && s.disable_server_routes !== "0"',
  's.advertise_lan === "1" && s.disable_firewall !== "0"',
  'Permitir roteamento da LAN',
  '_h(SuForm, { model: s }, { default: () => items })',
]) assert.ok(original.includes(token), `missing authored token ${token}`);

for (const token of [
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
  identityPresent: true,
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
    if (body && body.operation === "stage_setup_key") return { enrollment_token: "0123456789abcdef0123456789abcdef" };
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

// Rendering must create the local TP-Link su-form provider required by
// su-form-item/su-password. This protects the hardware failure where the
// dynamic provider boundary did not forward the parent's injected form context.
const stockComponents = {
  "su-form": "SuForm",
  "su-form-item": "SuFormItem",
  "su-input": "SuInput",
  "su-password": "SuPassword",
  "su-checkbox": "SuCheckbox",
  "su-form-content-item": "SuFormContentItem",
  "su-button": "SuButton",
  "su-alert": "SuAlert",
  "su-spin": "SuSpin",
  "su-space": "SuSpace",
};
const vmState = new Proxy({ ...state, $: { type: { components: stockComponents }, appContext: { components: {} } } }, {
  get(target, prop) {
    const value = target[prop];
    return value && typeof value === "object" && Object.prototype.hasOwnProperty.call(value, "value")
      ? value.value
      : value;
  },
});
const rendered = context.component.render.call(vmState);
assert.equal(rendered.tag, "SuSpin");
const localForm = rendered.children.default();
assert.equal(localForm.tag, "SuForm");
assert.equal(localForm.props.model, state.draft.value);
assert.ok(Array.isArray(localForm.children.default()), "local su-form must wrap provider items");

const renderedItems = localForm.children.default();
const setupItem = renderedItems.find(node => node && node.props && node.props.name === "setup_key");
assert.ok(setupItem, "Setup Key form item must render");
const setupPassword = setupItem.children.default();
assert.equal(setupPassword.tag, "SuPassword");
assert.equal(typeof setupPassword.props["onUpdate:value"], "function");
assert.equal(typeof setupPassword.props["onUpdate:modelValue"], "function");
assert.equal(typeof setupPassword.props.onInput, "function");
setupPassword.props["onUpdate:modelValue"]("bound-from-password-component");
assert.equal(state.setupKey.value, "bound-from-password-component");
setupPassword.props.onInput({ target: { value: "bound-from-native-input" } });
assert.equal(state.setupKey.value, "bound-from-native-input");

// CREATE remains stock-owned. validate() stages the secret through the provider
// endpoint and getForm() contributes only the opaque enrollment token to the
// normal stock Save payload.
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
assert.equal(requests.filter(r => r.operation === "stage_setup_key").length, 1);
assert.equal(requests.some(r => r.operation === "stage_setup_key" && r.setup_key === "setup-key-only-for-save"), true);

const addForm = exposed.getForm();
for (const field of ["key", "id", "type", "description", "enable", "enabled", "enrolled"])
  assert.equal(field in addForm, false, `provider subform must not own generic field ${field}`);
assert.equal(addForm.management_url, "https://netbird.example");
assert.equal(addForm.enrollment_token, "0123456789abcdef0123456789abcdef");
assert.equal("setup_key" in addForm, false, "secret must never enter stock Save payload");

// A persisted stock key alone proves Edit. Diagnostics are profile-scoped. An
// already enrolled profile may save with no staged token; entering a new Setup
// Key stages a fresh token for explicit re-enrollment.
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
assert.equal(state.identityPresent.value, true);

const editForm = exposed.getForm();
assert.equal(editForm.management_url, "https://netbird.example");
assert.equal(editForm.server, "https://netbird.example");
assert.equal(editForm.enrollment_token, "");
assert.equal("setup_key" in editForm, false);
for (const field of ["key", "id", "type", "description", "enable", "enabled", "enrolled"])
  assert.equal(field in editForm, false, `protocol subform must not own TP-Link field ${field}`);

// An existing stock row without identity must still require a Setup Key. The
// authority is backend identityPresent, not a stale/enrolled field in the row.
response = { ...response, identityPresent: false, settings: { ...response.settings, enrolled: "0" } };
assert.equal(exposed.setForm({
  key: "existing-without-identity", type: "netbirdvpn", server: "https://netbird.example",
  management_url: "https://netbird.example", enable: "on", enrolled: "1",
  advertise_lan: "0", disable_server_routes: "1", disable_firewall: "1", wireguard_port: "51820",
}), true);
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(state.identityPresent.value, false);
await assert.rejects(() => exposed.validate(), /Setup Key/);

// Return to an enrolled profile for the remaining edit/routing assertions.
response = { ...response, identityPresent: true, settings: { ...response.settings, enrolled: "1" } };
assert.equal(exposed.setForm({
  key: "arbitrary-stock-key", type: "netbirdvpn", server: "https://netbird.example",
  management_url: "https://netbird.example", enable: "on", enrolled: "1",
  advertise_lan: "1", advertise_cidr: "192.168.10.0/24", disable_server_routes: "0",
  disable_firewall: "0", wireguard_port: "51820",
}), true);
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(state.identityPresent.value, true);

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
console.log("netbird stock-create/staged-setup-key/multi-profile/draft contract ok");
