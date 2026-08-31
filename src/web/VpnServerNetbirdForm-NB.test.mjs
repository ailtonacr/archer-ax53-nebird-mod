import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const original = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8");

// Authored source contract: real TP-Link controls and final native semantics.
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
  's.advertise_lan === "1" && s.disable_server_routes !== "0"',
]) assert.ok(original.includes(token), `missing authored token ${token}`);
for (const token of [
  "NETBIRD_CSS", 'type: "checkbox"', 'class: "netbird-input"', "syncNativeSaveButton", "unknown error",
  'value.type === "netbirdvpn"', 'value.type === "netbird"', "const creating = ref(false)",
]) assert.equal(original.includes(token), false, `legacy/custom UI token leaked: ${token}`);

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
    disable_dns: "1", disable_firewall: "1", disable_client_routes: "1",
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
  api: { request: async (_path, body) => {
    requests.push(body.operation);
    if (body.operation === "enroll") return { settings: { ...response.settings, enrolled: "1", enable: "0" } };
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

// Type exists in both Add and Edit. Without persisted key/id this is CREATE.
state.profileExists.value = false;
assert.equal(exposed.setForm({
  type: "netbirdvpn", management_url: "https://netbird.example",
  advertise_lan: "0", disable_server_routes: "1", wireguard_port: "51820",
}), true);
assert.equal(state.creating.value, true);
assert.equal(await exposed.validate(), true);

// A persisted stock key proves EDIT and the protocol form must not own key/type.
state.profileExists.value = true;
assert.equal(exposed.setForm({
  key: "arbitrary-stock-key", type: "netbirdvpn", server: "https://netbird.example",
  management_url: "https://netbird.example", enable: "on", enrolled: "1",
  advertise_lan: "1", advertise_cidr: "192.168.10.0/24", disable_server_routes: "0",
  wireguard_port: "51820",
}), true);
assert.equal(state.creating.value, false);
assert.equal(await exposed.validate(), true);

const form = exposed.getForm();
assert.equal(form.management_url, "https://netbird.example");
assert.equal(form.server, "https://netbird.example");
assert.equal(form.enable, "on");
assert.equal("key" in form, false, "protocol subform must not own TP-Link profile key");
assert.equal("type" in form, false, "protocol subform must not own TP-Link profile type");

// Enabling LAN routing also enables server routes because a NetBird routing peer
// must accept server routes from management.
state.updateDraft("advertise_lan", "0");
state.updateDraft("disable_server_routes", "1");
state.updateDraft("advertise_lan", "1");
assert.equal(state.draft.value.disable_server_routes, "0");
state.updateDraft("advertise_cidr", "192.168.10.0/24");
assert.equal(await exposed.validate(), true);
state.updateDraft("disable_server_routes", "1");
await assert.rejects(() => exposed.validate(), /Rotas de servidor/);
state.updateDraft("disable_server_routes", "0");

// Polling is read-only and cannot clobber an in-progress form draft.
state.updateDraft("advertise_cidr", "192.168.");
assert.equal(state.dirty.value, true);
response = { ...response, settings: { ...response.settings, advertise_cidr: "10.0.0.0/24" } };
for (let i = 0; i < 3; i++) await timers[0]();
assert.equal(state.draft.value.advertise_cidr, "192.168.");
assert.equal(requests.includes("settings_set"), false);
await assert.rejects(() => exposed.validate(), /CIDR/);

state.updateDraft("advertise_lan", "0");
state.updateDraft("management_url", "https://netbird.example");
state.updateDraft("wireguard_port", "51820");
assert.equal(await exposed.validate(), true);
assert.equal(requests.includes("settings_set"), false, "editing must never persist before stock dialog Save");

context.unmounted();
console.log("netbird authored final native form/routing/draft contract ok");
