import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8")
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
    disable_server_routes: "1", disable_ipv6: "1", network_monitor: "0",
    advertise_lan: "1", enable: "1", wireguard_port: "51820", hostname: "",
  },
  netbird: { netbirdIp: "100.64.0.1", peersConnected: 1, peersTotal: 2 },
  traffic: { uploadSpeed: 125000, downloadSpeed: 250000 },
  payload: { state: "READY" },
};

const context = {
  defineComponent: value => value,
  ref: value => ({ value }),
  onMounted: fn => context.mounted = fn,
  onUnmounted: fn => context.unmounted = fn,
  _h: (tag, props, children) => ({ tag, props: props || {}, children: children || [] }),
  setInterval: fn => { timers.push(fn); return timers.length; },
  clearInterval: () => {},
  queueMicrotask: fn => fn(),
  URL,
  api: { request: async (_path, body) => {
    requests.push(body.operation);
    if (body.operation === "enroll") return { settings: { ...response.settings, enrolled: "1", enable: "1" } };
    return response;
  } },
};
vm.runInNewContext(source, context, { filename: "VpnServerNetbirdForm-NB.js" });

const render = context.component.setup({ disabled: false }, {
  expose: value => { exposed = value; },
  emit: () => {},
});
context.mounted();
await new Promise(resolve => setTimeout(resolve, 0));

function walk(node, result = []) {
  if (Array.isArray(node)) {
    for (const child of node) walk(child, result);
    return result;
  }
  if (!node || typeof node !== "object") return result;
  result.push(node);
  for (const child of node.children || []) walk(child, result);
  return result;
}
function input(tree, placeholder) {
  return walk(tree).find(node => node.tag === "input" && node.props.placeholder === placeholder);
}
function hasText(tree, text) {
  return walk(tree).some(node => typeof node.children === "string" && node.children.includes(text));
}

assert.ok(exposed, "component must expose the dynamic-form methods");
assert.equal(typeof exposed.validate, "function");
assert.equal(typeof exposed.setForm, "function");
assert.equal(typeof exposed.getForm, "function");
assert.equal(typeof exposed.resetForm, "function");
assert.equal(typeof exposed.clearValidate, "function");

assert.equal(exposed.setForm({
  key: "netbird", type: "netbird", server: "https://netbird.example",
  enable: "on", enrolled: "1", advertise_lan: "1", advertise_cidr: "192.168.10.0/24",
}), true);
assert.equal(await exposed.validate(), true);

const form = exposed.getForm();
assert.equal(form.key, "netbird");
assert.equal(form.type, "netbird");
assert.equal(form.management_url, "https://netbird.example");
assert.equal(form.server, "https://netbird.example");
assert.equal(form.enable, "on");

assert.equal(hasText(render(), "1.00 Mbps"), true, "upload rate should be rendered from wt0 counters");
assert.equal(hasText(render(), "2.00 Mbps"), true, "download rate should be rendered from wt0 counters");
assert.equal(hasText(render(), "PAYLOAD_NOT_DOWNLOADED"), false, "raw payload token must never leak in READY state");

let cidr = input(render(), "Ex.: 192.168.10.0/24");
cidr.props.onInput({ target: { value: "192.168." } });

response = { ...response, settings: { ...response.settings, advertise_cidr: "10.0.0.0/24" } };
for (let i = 0; i < 3; i++) await timers[0]();
cidr = input(render(), "Ex.: 192.168.10.0/24");
assert.equal(cidr.props.value, "192.168.", "polling must retain a partial CIDR draft");
assert.equal(requests.includes("settings_set"), false, "editing must never persist before the stock dialog saves");
assert.equal("__netbirdSaveDraft" in context, false, "component must not install the abandoned global save bridge");

assert.equal(await exposed.validate(), false, "partial CIDR is invalid when LAN routing is enabled");
assert.equal(hasText(render(), "Informe uma rede LAN válida"), true);

exposed.setForm({
  key: "netbird", type: "netbird", management_url: "https://netbird.example",
  enable: "on", enrolled: "1", advertise_lan: "1", advertise_cidr: "192.168.10.0/24",
});
assert.equal(await exposed.validate(), true);

response = { ...response, code: "payload_missing", payload: { state: "PAYLOAD_NOT_DOWNLOADED" } };
await timers[0]();
assert.equal(hasText(render(), "Ainda não baixado"), true, "payload state must be translated for the UI");
assert.equal(hasText(render(), "PAYLOAD_NOT_DOWNLOADED"), false, "raw payload token must not be displayed");

response = { ...response, profileExists: false, settings: { ...response.settings, enrolled: "0", enable: "0" } };
await timers[0]();
assert.equal(hasText(render(), "Salve o perfil primeiro"), true);
assert.equal(requests.includes("settings_set"), false);

context.unmounted();
console.log("netbird form/status/payload/traffic/draft contract behavior ok");
