import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("./VpnServerNetbirdForm-NB.js", import.meta.url), "utf8")
  .replace(/^import .*?;\nimport .*?;\n/s, "")
  .replace("export default defineComponent(", "globalThis.component = defineComponent(");

const timers = [];
const requests = [];
let response = {
  code: "connected",
  settings: {
    enrolled: "1", management_url: "https://netbird.example", advertise_cidr: "",
    disable_dns: "1", disable_firewall: "1", disable_client_routes: "1",
    disable_server_routes: "1", disable_ipv6: "1", network_monitor: "0",
    advertise_lan: "0", enable: "1",
  },
  netbird: { netbirdIp: "100.64.0.1", peersConnected: 1, peersTotal: 2 },
  payload: { state: "READY" },
};
const context = {
  defineComponent: value => value,
  ref: value => ({ value }),
  onMounted: fn => context.mounted = fn,
  onUnmounted: () => {},
  _h: (tag, props, children) => ({ tag, props: props || {}, children: children || [] }),
  resolveComponent: () => null,
  setInterval: fn => { timers.push(fn); return timers.length; },
  clearInterval: () => {},
  window: { confirm: () => true },
  api: { request: async (_path, body) => {
    requests.push(body.operation);
    return body.operation === "settings_set" ? { settings: { ...body } } : response;
  } },
};
vm.runInNewContext(source, context, { filename: "VpnServerNetbirdForm-NB.js" });

const render = context.component.setup({ disabled: false });
context.mounted();
await new Promise(resolve => setTimeout(resolve, 0));

function walk(node, result = []) {
  if (Array.isArray(node)) {
    for (const child of node) walk(child, result);
    return result;
  }
  if (!node || typeof node !== "object") return result;
  if (node.tag === "input" || node.tag === "button") result.push(node);
  for (const child of node.children || []) walk(child, result);
  return result;
}

function input(tree, placeholder) {
  return walk(tree).find(node => node.tag === "input" && node.props.placeholder === placeholder);
}

let cidr = input(render(), "Ex.: 192.168.10.0/24");
cidr.props.onInput({ target: { value: "192.168." } });
response = { ...response, settings: { ...response.settings, advertise_cidr: "10.0.0.0/24", disable_dns: "1" } };
for (let i = 0; i < 3; i++) await timers[0]();
cidr = input(render(), "Ex.: 192.168.10.0/24");
assert.equal(cidr.props.value, "192.168.", "polling must retain a partial CIDR draft");

const dns = walk(render()).find(node => node.tag === "input" && node.props.type === "checkbox");
dns.props.onChange({ target: { checked: true } });
for (let i = 0; i < 3; i++) await timers[0]();
assert.equal(input(render(), "Ex.: 192.168.10.0/24").props.value, "192.168.");
assert.equal(walk(render()).find(node => node.tag === "input" && node.props.type === "checkbox").props.checked, true);
assert.ok(walk(render()).find(node => node.tag === "button" && node.children === "Salvar" && !node.props.disabled));
assert.equal(requests.filter(op => op === "settings_set").length, 0, "editing must not save implicitly");
assert.equal(render().props.class, "netbird-form", "runtime updates must not restore the loading view");

await walk(render()).find(node => node.tag === "button" && node.children === "Salvar").props.onClick();
assert.equal(requests.filter(op => op === "settings_set").length, 1, "only Save persists the draft");
assert.ok(walk(render()).find(node => node.tag === "button" && node.children === "Salvar" && node.props.disabled));

console.log("draft survives runtime polling");
