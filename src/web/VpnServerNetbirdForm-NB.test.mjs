import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8")
  .replace(/^import .*?;\nimport .*?;\n/s, "")
  .replace("export default defineComponent(", "globalThis.component = defineComponent(");

const timers = [];
const requests = [];
let exposed = null;
let failNextSettings = false;
let response = {
  code: "connected",
  settings: {
    enrolled: "1", management_url: "https://netbird.example", advertise_cidr: "192.168.10.0/24",
    disable_dns: "1", disable_firewall: "1", disable_client_routes: "1",
    disable_server_routes: "1", disable_ipv6: "1", network_monitor: "0",
    advertise_lan: "1", enable: "1",
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
  window: { confirm: () => true },
  api: { request: async (_path, body) => {
    requests.push(body.operation);
    if (body.operation === "settings_set") {
      if (failNextSettings) {
        failNextSettings = false;
        throw { data: { error: "invalid value for advertise_cidr" } };
      }
      response = { ...response, settings: { ...response.settings, ...body } };
      return { settings: response.settings };
    }
    return response;
  } },
};
vm.runInNewContext(source, context, { filename: "VpnServerNetbirdForm-NB.js" });

const render = context.component.setup({ disabled: false }, { expose: value => { exposed = value; } });
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

assert.ok(exposed, "component must expose the stock TP-Link form contract");
assert.equal(typeof exposed.validate, "function");
assert.equal(typeof exposed.setForm, "function");
assert.equal(typeof exposed.getForm, "function");
assert.equal(await exposed.validate(), true);
assert.equal(exposed.setForm({}), true);
assert.equal(hasText(render(), "1.00 Mbps"), true, "upload rate should be rendered from wt0 counters");
assert.equal(hasText(render(), "2.00 Mbps"), true, "download rate should be rendered from wt0 counters");

let cidr = input(render(), "Ex.: 192.168.10.0/24");
cidr.props.onInput({ target: { value: "192.168." } });
response = { ...response, settings: { ...response.settings, advertise_cidr: "10.0.0.0/24" } };
for (let i = 0; i < 3; i++) await timers[0]();
cidr = input(render(), "Ex.: 192.168.10.0/24");
assert.equal(cidr.props.value, "192.168.", "polling must retain a partial CIDR draft");
assert.equal(requests.filter(op => op === "settings_set").length, 0, "editing must not save implicitly");
assert.equal(render().props.class, "netbird-form", "runtime updates must not restore the loading view");
assert.equal(typeof context.window.__netbirdSaveDraft, "function", "stock modal save bridge must be registered");
assert.equal(walk(render()).some(node => node.tag === "button" && node.children === "Salvar"), false, "sub-form must not render a duplicate Save button");

await context.window.__netbirdSaveDraft();
assert.equal(requests.filter(op => op === "settings_set").length, 1, "stock footer bridge persists the draft exactly once");
assert.equal(input(render(), "Ex.: 192.168.10.0/24").props.value, "192.168.");

response = { ...response, code: "payload_missing", payload: { state: "PAYLOAD_NOT_DOWNLOADED" } };
await timers[0]();
assert.equal(hasText(render(), "Ainda não baixado"), true, "payload state must be translated for the UI");
assert.equal(hasText(render(), "PAYLOAD_NOT_DOWNLOADED"), false, "raw payload token must not be displayed");

cidr = input(render(), "Ex.: 192.168.10.0/24");
cidr.props.onInput({ target: { value: "bad" } });
failNextSettings = true;
await assert.rejects(() => context.window.__netbirdSaveDraft());
assert.equal(hasText(render(), "invalid value for advertise_cidr"), true);
await timers[0]();
assert.equal(hasText(render(), "invalid value for advertise_cidr"), false, "healthy polling clears stale diagnostics");
assert.equal(input(render(), "Ex.: 192.168.10.0/24").props.value, "bad", "failed save must preserve the user's draft");

context.unmounted();
assert.equal(context.window.__netbirdSaveDraft, undefined, "save bridge must be removed on unmount");

console.log("netbird form polling/save/error/payload/traffic/form-contract behavior ok");
