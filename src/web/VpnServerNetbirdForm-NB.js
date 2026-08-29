import { d as defineComponent, r as ref, e as onMounted, O as onUnmounted, h as _h } from "./vendor-BrE4IMR2.js";
import { s as api } from "./update-store-DQkZxaRI.js";

// NetBird protocol subform rendered by TP-Link's stock VPN Client dialog.
// The outer dialog owns Description, VPN Type, Save/Cancel and row deletion.
// This subform resolves TP-Link's registered su-* components instead of drawing
// native HTML controls or maintaining a parallel CSS/design system.
const NB = "/admin/netbird";

function nbReq(operation, extra) {
  return api.request(NB, Object.assign({ operation: operation }, extra || {}), { preventSuccess: true, preventError: true });
}

function errMsg(e) {
  if (!e) return "Falha ao executar a operação.";
  if (typeof e === "string" && e) return e;
  const responseData = e.response && e.response.data;
  const candidates = [
    responseData && responseData.data && responseData.data.error,
    responseData && responseData.error,
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

function as01(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  if (value === true || value === 1 || value === "1" || value === "on" || value === "true") return "1";
  if (value === false || value === 0 || value === "0" || value === "off" || value === "false") return "0";
  return fallback;
}

function normalizeForm(value, fallback) {
  const v = value || {};
  const base = fallback || {};
  return {
    enable: as01(v.enable !== undefined ? v.enable : v.enabled, base.enable || "0"),
    enrolled: as01(v.enrolled, base.enrolled || "0"),
    management_url: v.management_url || v.server || base.management_url || "https://netbird.ailton.dev.br",
    hostname: v.hostname !== undefined ? String(v.hostname || "") : (base.hostname || ""),
    disable_dns: as01(v.disable_dns, base.disable_dns || "1"),
    disable_firewall: as01(v.disable_firewall, base.disable_firewall || "1"),
    disable_client_routes: as01(v.disable_client_routes, base.disable_client_routes || "1"),
    disable_server_routes: as01(v.disable_server_routes, base.disable_server_routes || "1"),
    disable_ipv6: as01(v.disable_ipv6, base.disable_ipv6 || "1"),
    network_monitor: as01(v.network_monitor, base.network_monitor || "0"),
    advertise_lan: as01(v.advertise_lan, base.advertise_lan || "0"),
    advertise_cidr: v.advertise_cidr !== undefined ? String(v.advertise_cidr || "") : (base.advertise_cidr || ""),
    wireguard_port: v.wireguard_port !== undefined ? String(v.wireguard_port || "51820") : (base.wireguard_port || "51820"),
  };
}

function validManagementUrl(value) {
  try {
    const u = new URL(String(value || ""));
    return (u.protocol === "https:" || u.protocol === "http:") && !!u.hostname;
  } catch (_) { return false; }
}

function validHostname(value) {
  const s = String(value || "");
  return s.length <= 64 && /^[A-Za-z0-9._-]*$/.test(s);
}

function validWireGuardPort(value) {
  const raw = String(value || "").trim();
  if (!/^\d+$/.test(raw)) return false;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= 65535;
}

function validCidr(value) {
  const m = String(value || "").match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/);
  if (!m) return false;
  for (let i = 1; i <= 4; i += 1) if (Number(m[i]) > 255) return false;
  const prefix = Number(m[5]);
  return prefix >= 0 && prefix <= 32;
}

const STATUS_LABEL = {
  connected: "Conectado", connecting: "Conectando", disconnected: "Desconectado",
  disabled: "Desativado", enrollment_required: "Enrollment necessário",
  payload_missing: "Componente indisponível", stopped: "Parado", error: "Erro",
};
const PAYLOAD_LABEL = {
  READY: "Pronto", PAYLOAD_NOT_DOWNLOADED: "Ainda não baixado",
  PAYLOAD_DOWNLOAD_FAILED: "Falha no download", PAYLOAD_INVALID: "Payload inválido",
  UNKNOWN: "Estado desconhecido",
};
function payloadLabel(state) { return PAYLOAD_LABEL[state] || PAYLOAD_LABEL.UNKNOWN; }
function speedLabel(bytesPerSecond) {
  const kbps = Math.max(0, Number(bytesPerSecond) || 0) * 8 / 1000;
  return kbps >= 1000 ? (kbps / 1000).toFixed(2) + " Mbps" : kbps.toFixed(kbps >= 10 ? 0 : 1) + " Kbps";
}

function componentCandidates(name) {
  const camel = name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
  const pascal = camel.charAt(0).toUpperCase() + camel.slice(1);
  return [name, camel, pascal];
}

function stockComponent(vm, name) {
  const internal = vm && vm.$;
  const local = internal && internal.type && internal.type.components || {};
  const global = internal && internal.appContext && internal.appContext.components || {};
  for (const key of componentCandidates(name)) {
    if (local[key]) return local[key];
    if (global[key]) return global[key];
  }
  throw new Error("Componente TP-Link não registrado: " + name);
}

function textSlot(text) { return { default: () => String(text == null ? "" : text) }; }

export default defineComponent({
  name: "VpnServerNetbirdForm",
  props: { disabled: { type: Boolean, default: false } },

  setup(props, context) {
    const settings = ref(null);
    const draft = ref(normalizeForm({}, {}));
    const status = ref(null);
    const netbird = ref({});
    const payload = ref({});
    const traffic = ref({ uploadSpeed: 0, downloadSpeed: 0 });
    const profileExists = ref(false);
    const setupKey = ref("");
    const log = ref("");
    const busy = ref(false);
    const message = ref("");
    const error = ref("");
    const showLog = ref(false);
    const dirty = ref(false);
    const creating = ref(false);
    let statusRequestPending = false;

    function updateDraft(key, value) {
      draft.value[key] = value;
      dirty.value = true;
      error.value = "";
      message.value = "";
    }

    async function load(clearStaleError = true) {
      if (statusRequestPending) return;
      statusRequestPending = true;
      try {
        const r = await nbReq("status");
        settings.value = r.settings || settings.value || {};
        profileExists.value = !!r.profileExists;
        if (!dirty.value && !creating.value) {
          draft.value = normalizeForm(draft.value, settings.value);
          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";
          draft.value.enable = settings.value.enable || draft.value.enable || "0";
        }
        netbird.value = r.netbird || {};
        payload.value = r.payload || {};
        traffic.value = r.traffic || { uploadSpeed: 0, downloadSpeed: 0 };
        status.value = r.code;
        if (clearStaleError) error.value = "";
      } catch (e) { error.value = errMsg(e); }
      finally { statusRequestPending = false; }
    }

    async function enroll() {
      if (creating.value && profileExists.value) { error.value = "Já existe um perfil NetBird. Exclua-o antes de criar outro."; return; }
      if (!setupKey.value) return;
      if (!profileExists.value || dirty.value) { error.value = "Salve o perfil antes de fazer o enrollment."; return; }
      busy.value = true; error.value = ""; message.value = "";
      try {
        const r = await nbReq("enroll", { setup_key: setupKey.value });
        setupKey.value = "";
        settings.value = r.settings || settings.value;
        draft.value.enrolled = settings.value && settings.value.enrolled || "1";
        draft.value.enable = settings.value && settings.value.enable || "0";
        message.value = "Enrollment concluído.";
      } catch (e) { error.value = errMsg(e); }
      finally { busy.value = false; await load(false); }
    }

    async function restart() {
      if (dirty.value) { error.value = "Salve as alterações antes de reiniciar o NetBird."; return; }
      busy.value = true; error.value = ""; message.value = "";
      try { await nbReq("restart"); message.value = "NetBird reiniciado."; }
      catch (e) { error.value = errMsg(e); }
      finally { busy.value = false; await load(false); }
    }

    async function fetchLog() {
      showLog.value = !showLog.value;
      if (!showLog.value) return;
      try { const r = await nbReq("log", { lines: 100 }); log.value = r.lines || ""; }
      catch (e) { error.value = errMsg(e); log.value = ""; }
    }

    async function validate() {
      error.value = "";
      const s = draft.value || {};
      if (creating.value && profileExists.value) { error.value = "Já existe um perfil NetBird. Exclua-o antes de criar outro."; throw new Error(error.value); }
      if (!validHostname(s.hostname)) { error.value = "Hostname inválido. Use letras, números, ponto, hífen ou sublinhado (máx. 64 caracteres)."; throw new Error(error.value); }
      if (!validWireGuardPort(s.wireguard_port)) { error.value = "Informe uma porta WireGuard entre 1 e 65535."; throw new Error(error.value); }
      if (!validManagementUrl(s.management_url)) { error.value = "Informe uma URL de gerenciamento válida (http:// ou https://)."; throw new Error(error.value); }
      if (s.advertise_lan === "1" && !validCidr(s.advertise_cidr)) { error.value = "Informe uma rede LAN válida em CIDR, por exemplo 192.168.10.0/24."; throw new Error(error.value); }
      return true;
    }

    function setForm(value) {
      const existing = !!(value && (value.type === "netbirdvpn" || value.type === "netbird" || value.key === "netbird" || value.id === "netbird"));
      creating.value = !existing;
      draft.value = normalizeForm(value || {}, creating.value ? {} : (settings.value || {}));
      if (creating.value) { draft.value.enable = "0"; draft.value.enrolled = "0"; }
      dirty.value = false; error.value = ""; message.value = "";
      return true;
    }

    function getForm() {
      const s = draft.value || {};
      return {
        enable: s.enable === "1" ? "on" : "off", enabled: s.enable === "1", enrolled: s.enrolled || "0",
        management_url: s.management_url || "", server: s.management_url || "", hostname: s.hostname || "",
        disable_dns: s.disable_dns || "1", disable_firewall: s.disable_firewall || "1",
        disable_client_routes: s.disable_client_routes || "1", disable_server_routes: s.disable_server_routes || "1",
        disable_ipv6: s.disable_ipv6 || "1", network_monitor: s.network_monitor || "0",
        advertise_lan: s.advertise_lan || "0", advertise_cidr: s.advertise_cidr || "",
        wireguard_port: s.wireguard_port || "51820",
      };
    }

    function resetForm() { draft.value = normalizeForm(settings.value || {}, settings.value || {}); dirty.value = false; error.value = ""; message.value = ""; return true; }
    function clearValidate() { error.value = ""; return true; }

    context.expose({ isChanged: dirty, validate, setForm, getForm, resetForm, clearValidate });

    let timer = null;
    onMounted(function () { load(); timer = setInterval(function () { if (!busy.value) load(false); }, 5000); });
    onUnmounted(function () { if (timer) clearInterval(timer); });

    return { props, settings, draft, status, netbird, payload, traffic, profileExists, setupKey, log, busy, message, error, showLog, dirty, creating, updateDraft, enroll, restart, fetchLog };
  },

  render() {
    const SuForm = stockComponent(this, "su-form");
    const SuFormItem = stockComponent(this, "su-form-item");
    const SuInput = stockComponent(this, "su-input");
    const SuPassword = stockComponent(this, "su-password");
    const SuCheckbox = stockComponent(this, "su-checkbox");
    const SuFormContentItem = stockComponent(this, "su-form-content-item");
    const SuButton = stockComponent(this, "su-button");
    const SuAlert = stockComponent(this, "su-alert");
    const SuSpin = stockComponent(this, "su-spin");
    const SuSpace = stockComponent(this, "su-space");

    const s = this.draft || {};
    const disabled = !!(this.disabled || this.busy);
    const edit = !this.creating;
    const active = s.enable === "1";
    const items = [];

    if (edit) {
      items.push(_h(SuFormItem, { label: "Status" }, textSlot(STATUS_LABEL[this.status] || STATUS_LABEL.stopped)));
      const version = this.payload && this.payload.version ? " · NetBird " + this.payload.version : "";
      items.push(_h(SuFormItem, { label: "Payload" }, textSlot(payloadLabel(this.payload && this.payload.state) + version)));
      if (this.netbird && this.netbird.netbirdIp) items.push(_h(SuFormItem, { label: "IP NetBird" }, textSlot(this.netbird.netbirdIp)));
      items.push(_h(SuFormItem, { label: "Tráfego" }, textSlot("↑ " + speedLabel(this.traffic && this.traffic.uploadSpeed) + "  ↓ " + speedLabel(this.traffic && this.traffic.downloadSpeed))));
    }

    items.push(_h(SuFormItem, { label: "Management URL", name: "management_url" }, { default: () => _h(SuInput, { value: s.management_url || "", "onUpdate:value": value => this.updateDraft("management_url", value), disabled, placeholder: "https://netbird.example.com" }) }));
    items.push(_h(SuFormItem, { label: "Hostname", name: "hostname", optional: "" }, { default: () => _h(SuInput, { value: s.hostname || "", "onUpdate:value": value => this.updateDraft("hostname", value), disabled, placeholder: "archer-ax53" }) }));
    items.push(_h(SuFormItem, { label: "Porta WireGuard", name: "wireguard_port" }, { default: () => _h(SuInput, { value: s.wireguard_port || "51820", "onUpdate:value": value => this.updateDraft("wireguard_port", value), disabled }) }));

    const flags = [
      ["Habilitar DNS do NetBird", "disable_dns", s.disable_dns === "0", true],
      ["Habilitar firewall do NetBird", "disable_firewall", s.disable_firewall === "0", true],
      ["Rotas de cliente", "disable_client_routes", s.disable_client_routes === "0", true],
      ["Rotas de servidor", "disable_server_routes", s.disable_server_routes === "0", true],
      ["IPv6", "disable_ipv6", s.disable_ipv6 === "0", true],
      ["Monitor de rede", "network_monitor", s.network_monitor === "1", false],
      ["Anunciar rede local", "advertise_lan", s.advertise_lan === "1", false],
    ];
    for (const [label, key, checked, inverted] of flags) {
      items.push(_h(SuFormContentItem, null, { default: () => _h(SuCheckbox, { checked, "onUpdate:checked": value => this.updateDraft(key, inverted ? (value ? "0" : "1") : (value ? "1" : "0")), disabled }, textSlot(label)) }));
    }

    if (s.advertise_lan === "1") {
      items.push(_h(SuFormItem, { label: "Rede local / CIDR", name: "advertise_cidr" }, { default: () => _h(SuInput, { value: s.advertise_cidr || "", "onUpdate:value": value => this.updateDraft("advertise_cidr", value), disabled, placeholder: "192.168.10.0/24" }) }));
    }

    if (edit) {
      items.push(_h(SuFormItem, { label: "Setup key", optional: "" }, { default: () => _h(SuPassword, { value: this.setupKey || "", "onUpdate:value": value => { this.setupKey = value; }, disabled, placeholder: "Setup key para enrollment/re-enrollment" }) }));
      const actions = [
        _h(SuButton, { type: "primary", secondary: "", loading: this.busy, disabled: disabled || !this.setupKey || this.dirty || !this.profileExists, onClick: this.enroll }, textSlot(s.enrolled === "1" ? "Re-enroll" : "Enrollment")),
        _h(SuButton, { secondary: "", loading: this.busy, disabled: disabled || this.dirty || !active, onClick: this.restart }, textSlot("Reiniciar")),
        _h(SuButton, { secondary: "", disabled, onClick: this.fetchLog }, textSlot(this.showLog ? "Ocultar logs" : "Logs")),
      ];
      items.push(_h(SuFormContentItem, null, { default: () => _h(SuSpace, { size: 8 }, { default: () => actions }) }));
    }

    if (this.error) items.push(_h(SuAlert, { closable: "" }, textSlot(this.error)));
    else if (this.message) items.push(_h(SuAlert, { closable: "" }, textSlot(this.message)));

    if (edit && this.showLog && this.log) items.push(_h(SuFormItem, { label: "Logs" }, { default: () => _h(SuInput, { value: this.log, disabled: true, type: "textarea" }) }));

    return _h(SuSpin, { spinning: this.busy }, { default: () => _h(SuForm, { model: s, "label-width": { span: 10 }, "content-width": { span: 10 } }, { default: () => items }) });
  },
});
