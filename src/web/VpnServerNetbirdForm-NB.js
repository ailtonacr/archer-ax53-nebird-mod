import { d as defineComponent, r as ref, e as onMounted, O as onUnmounted, h as _h } from "./vendor-BrE4IMR2.js";
import { s as api } from "./update-store-DQkZxaRI.js";

// Profile CRUD intentionally goes through the stock VPN page/model.  This
// dedicated endpoint is only for NetBird-specific runtime actions that have no
// equivalent in TP-Link's generic VPN CRUD contract.
const NB = "/admin/netbird";

const NETBIRD_CSS = ".netbird-form{display:grid;gap:16px;max-width:760px;color:inherit}.netbird-section{padding:16px;border:1px solid rgba(128,128,128,.2);border-radius:6px;background:rgba(128,128,128,.035)}.netbird-heading{margin:0 0 14px;font-size:14px;font-weight:600}.netbird-connection{display:grid;gap:10px}.netbird-status-main{display:flex;align-items:center;justify-content:space-between;gap:12px}.netbird-status-label,.netbird-field-label{color:#8b95a7;font-size:13px}.netbird-status-value{padding:4px 10px;border-radius:999px;background:rgba(74,203,214,.13);color:#168c98;font-size:13px}.netbird-status-detail,.netbird-status-grid{display:flex;justify-content:space-between;gap:12px;font-size:12px;color:#667085}.netbird-field{display:grid;grid-template-columns:minmax(150px,30%) minmax(0,1fr);align-items:center;gap:14px;margin-top:12px}.netbird-field-control{min-width:0}.netbird-input{box-sizing:border-box;width:100%;min-height:34px;padding:7px 10px;border:1px solid rgba(128,128,128,.35);border-radius:4px;background:transparent;color:inherit;outline:0}.netbird-input:focus{border-color:#27b8c7;box-shadow:0 0 0 2px rgba(39,184,199,.12)}.netbird-feature-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 24px}.netbird-switch{display:flex;align-items:center;gap:9px;min-width:0;font-size:13px;cursor:pointer}.netbird-switch-input{width:15px;height:15px;accent-color:#27b8c7;flex:0 0 auto}.netbird-switch-input:disabled{cursor:not-allowed}.netbird-switch-label{line-height:1.35}.netbird-actions{display:flex;flex-wrap:wrap;gap:8px}.netbird-button{min-height:32px;padding:0 14px;border:1px solid transparent;border-radius:4px;font-size:13px;cursor:pointer}.netbird-button:disabled{opacity:.55;cursor:not-allowed}.netbird-button-primary{background:#27b8c7;color:#fff}.netbird-button-secondary{border-color:rgba(128,128,128,.4);background:transparent;color:inherit}.netbird-diagnostics{display:grid;gap:8px}.netbird-feedback{padding:9px 10px;border-radius:4px;background:rgba(128,128,128,.07);font-size:12px;line-height:1.45}.netbird-feedback-error{color:#c94444;background:rgba(220,74,74,.08)}.netbird-log{max-height:190px;overflow:auto;margin:0;padding:10px;border-radius:4px;background:rgba(0,0,0,.06);font-size:12px;white-space:pre-wrap}@media(max-width:560px){.netbird-field{grid-template-columns:1fr;gap:6px}.netbird-feature-grid{grid-template-columns:1fr}.netbird-status-detail,.netbird-status-grid{flex-direction:column;gap:4px}}";

function nbReq(operation, extra) {
  return api.request(NB, Object.assign({ operation: operation }, extra || {}), { preventSuccess: true, preventError: true });
}

function errMsg(e) {
  if (!e) return "unknown error";
  if (typeof e === "string") return e;
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
  return "unknown error";
}

function as01(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  if (value === true || value === 1 || value === "1" || value === "on" || value === "true") return "1";
  if (value === false || value === 0 || value === "0" || value === "off" || value === "false") return "0";
  return fallback;
}

function copySettings(value) { return Object.assign({}, value || {}); }

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

function stockForm(settings) {
  const s = settings || {};
  return {
    key: "netbird",
    id: "netbird",
    name: "NetBird",
    des: "NetBird",
    description: "NetBird",
    type: "netbird",
    proto: "netbird",
    vendor: "manual",
    server: s.management_url || "",
    management_url: s.management_url || "",
    hostname: s.hostname || "",
    enable: s.enable === "1" ? "on" : "off",
    enabled: s.enable === "1",
    enrolled: s.enrolled || "0",
    disable_dns: s.disable_dns || "1",
    disable_firewall: s.disable_firewall || "1",
    disable_client_routes: s.disable_client_routes || "1",
    disable_server_routes: s.disable_server_routes || "1",
    disable_ipv6: s.disable_ipv6 || "1",
    network_monitor: s.network_monitor || "0",
    advertise_lan: s.advertise_lan || "0",
    advertise_cidr: s.advertise_cidr || "",
    wireguard_port: s.wireguard_port || "51820",
  };
}

function validManagementUrl(value) {
  try {
    const u = new URL(String(value || ""));
    return (u.protocol === "https:" || u.protocol === "http:") && !!u.hostname;
  } catch (_) { return false; }
}

function validCidr(value) {
  const m = String(value || "").match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)\/(\d+)$/);
  if (!m) return false;
  for (let i = 1; i <= 4; i += 1) if (Number(m[i]) > 255) return false;
  const prefix = Number(m[5]);
  return prefix >= 0 && prefix <= 32;
}

export default defineComponent({
  name: "VpnServerNetbirdForm",
  props: { disabled: { type: Boolean, default: false } },
  setup(props, context) {
    const settings = ref(null);
    const draft = ref(null);
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
    let stockFormInitialized = false;
    let statusRequestPending = false;

    function notifyParent() {
      if (context && typeof context.emit === "function") {
        // Different TP-Link form components use different event names across
        // builds. Emitting both is harmless and lets the stock modal notice a
        // custom form mutation without taking over persistence.
        context.emit("change", stockForm(draft.value));
        context.emit("update", stockForm(draft.value));
      }
    }

    function updateDraft(key, value) {
      if (!draft.value) draft.value = normalizeForm({}, settings.value || {});
      draft.value[key] = value;
      dirty.value = true;
      message.value = "";
      notifyParent();
    }

    async function load(clearStaleError = true) {
      if (statusRequestPending) return;
      statusRequestPending = true;
      try {
        const r = await nbReq("status");
        settings.value = r.settings || settings.value || {};
        profileExists.value = !!r.profileExists;
        if (!draft.value) draft.value = normalizeForm({}, settings.value);
        else if (!dirty.value && !stockFormInitialized) draft.value = normalizeForm({}, settings.value);
        else if (!dirty.value) {
          // Runtime-owned metadata may change while the modal is open. Keep
          // stock-loaded profile fields, but reconcile enrollment/enabled state.
          draft.value.enrolled = settings.value.enrolled || draft.value.enrolled || "0";
          draft.value.enable = settings.value.enable || draft.value.enable || "0";
        }
        netbird.value = r.netbird || {};
        payload.value = r.payload || {};
        traffic.value = r.traffic || { uploadSpeed: 0, downloadSpeed: 0 };
        status.value = r.code;
        if (clearStaleError) error.value = "";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        statusRequestPending = false;
      }
    }

    async function enroll() {
      if (!setupKey.value) return;
      if (!profileExists.value || dirty.value) {
        error.value = "Salve o perfil NetBird pelo botão SALVAR antes de fazer o enrollment.";
        return;
      }
      busy.value = true;
      error.value = "";
      message.value = "";
      try {
        const r = await nbReq("enroll", { setup_key: setupKey.value });
        setupKey.value = "";
        settings.value = r.settings || settings.value;
        if (draft.value && settings.value) {
          draft.value.enrolled = settings.value.enrolled || "1";
          draft.value.enable = settings.value.enable || "1";
        }
        message.value = "Enrollment concluído";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load(false);
      }
    }

    async function restart() {
      if (dirty.value) {
        error.value = "Salve as alterações antes de reiniciar o NetBird.";
        return;
      }
      busy.value = true;
      error.value = "";
      message.value = "";
      try {
        await nbReq("restart");
        message.value = "NetBird reiniciado";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load(false);
      }
    }

    async function fetchLog() {
      showLog.value = !showLog.value;
      if (showLog.value) {
        try { const r = await nbReq("log", { lines: 100 }); log.value = r.lines || ""; }
        catch (e) { log.value = errMsg(e); }
      }
    }

    // Native TP-Link dynamic form contract. The parent owns persistence and
    // sends getForm() through its ordinary /admin/vpn?form=server path.
    async function validate() {
      error.value = "";
      const s = draft.value || settings.value || {};
      if (!validManagementUrl(s.management_url)) {
        error.value = "Informe uma URL de gerenciamento válida (http:// ou https://).";
        return false;
      }
      if (s.advertise_lan === "1" && !validCidr(s.advertise_cidr)) {
        error.value = "Informe uma rede LAN válida em CIDR, por exemplo 192.168.10.0/24.";
        return false;
      }
      return true;
    }

    function setForm(value) {
      stockFormInitialized = true;
      draft.value = normalizeForm(value || {}, settings.value || {});
      dirty.value = false;
      error.value = "";
      message.value = "";
      return true;
    }

    function getForm() { return stockForm(draft.value || settings.value || {}); }

    function resetForm() {
      draft.value = normalizeForm(settings.value || {}, settings.value || {});
      dirty.value = false;
      error.value = "";
      message.value = "";
      return true;
    }

    function clearValidate() { error.value = ""; return true; }

    if (context && typeof context.expose === "function") {
      context.expose({ validate, setForm, getForm, resetForm, clearValidate });
    }

    const STATUS_LABEL = {
      connected: "Conectado", connecting: "Conectando", disconnected: "Desconectado",
      disabled: "Desativado", enrollment_required: "Enrollment necessário",
      payload_missing: "Componente indisponível", stopped: "Parado", error: "Erro",
    };
    const PAYLOAD_LABEL = {
      READY: "Pronto", PAYLOAD_NOT_DOWNLOADED: "Ainda não baixado",
      PAYLOAD_DOWNLOAD_FAILED: "Falha ao baixar o componente",
      PAYLOAD_INVALID: "Componente inválido", UNKNOWN: "Estado desconhecido",
    };
    function payloadLabel(state) { return PAYLOAD_LABEL[state] || "Estado desconhecido"; }
    function speedLabel(bytesPerSecond) {
      const kbps = Math.max(0, Number(bytesPerSecond) || 0) * 8 / 1000;
      return kbps >= 1000 ? (kbps / 1000).toFixed(2) + " Mbps" : kbps.toFixed(kbps >= 10 ? 0 : 1) + " Kbps";
    }

    let timer = null;
    onMounted(function () {
      load();
      timer = setInterval(load, 5000);
    });
    onUnmounted(function () { if (timer) clearInterval(timer); });

    function field(label, node) {
      return _h("div", { class: "netbird-field" }, [
        _h("span", { class: "netbird-field-label" }, label),
        _h("div", { class: "netbird-field-control" }, [node]),
      ]);
    }

    function toggleBox(label, key, invert) {
      const s = draft.value || {};
      const raw = s[key];
      const on = invert ? raw !== "1" : raw === "1";
      return _h("label", { class: "netbird-switch" }, [
        _h("input", {
          type: "checkbox", checked: on, disabled: props.disabled || busy.value,
          class: "netbird-switch-input",
          onChange: function (ev) {
            const checked = ev.target.checked;
            updateDraft(key, invert ? (checked ? "0" : "1") : checked ? "1" : "0");
          },
        }),
        _h("span", { class: "netbird-switch-label" }, label),
      ]);
    }

    return function () {
      if (!draft.value) return _h("div", { class: "p-4 text-text-400" }, "Carregando status do NetBird...");
      const s = draft.value;
      const st = status.value || "stopped";
      const nb = netbird.value || {};
      const pv = payload.value || {};
      const tr = traffic.value || {};

      const statusRows = [
        _h("div", { class: "netbird-status-main" }, [
          _h("span", { class: "netbird-status-label" }, "Status"),
          _h("strong", { class: "netbird-status-value" }, STATUS_LABEL[st] || st),
        ]),
      ];
      if (pv.state) statusRows.push(_h("div", { class: "netbird-status-detail" }, [
        _h("span", null, "Componente"), _h("strong", null, payloadLabel(pv.state)),
      ]));
      if (st === "connected") {
        statusRows.push(_h("div", { class: "netbird-status-grid" }, [
          _h("span", null, "IP NetBird: " + (nb.netbirdIp || "-")),
          _h("span", null, "Peers: " + (nb.peersConnected || 0) + " / " + (nb.peersTotal || 0)),
        ]));
        statusRows.push(_h("div", { class: "netbird-status-grid" }, [
          _h("span", null, "↑ " + speedLabel(tr.uploadSpeed)),
          _h("span", null, "↓ " + speedLabel(tr.downloadSpeed)),
        ]));
      }

      const serverFields = [field("URL de gerenciamento", _h("input", {
        type: "text", value: s.management_url || "", disabled: props.disabled || busy.value,
        class: "netbird-input", onInput: function (ev) { updateDraft("management_url", ev.target.value); },
      }))];

      if (s.enrolled !== "1") {
        serverFields.push(field("Chave de configuração", _h("input", {
          type: "password", value: setupKey.value, autocomplete: "new-password",
          disabled: props.disabled || busy.value, class: "netbird-input",
          placeholder: "Cole a chave de configuração (não é armazenada)",
          onInput: function (ev) { setupKey.value = ev.target.value; },
        })));
        serverFields.push(_h("button", {
          type: "button",
          disabled: props.disabled || busy.value || !setupKey.value || dirty.value || !profileExists.value,
          class: "netbird-button netbird-button-primary", onClick: enroll,
        }, "Fazer enrollment"));
      }

      const featureFields = [
        toggleBox("Usar DNS do NetBird", "disable_dns", true),
        toggleBox("Firewall do NetBird", "disable_firewall", true),
        toggleBox("Rotas de cliente", "disable_client_routes", true),
        toggleBox("Rotas de servidor", "disable_server_routes", true),
        toggleBox("IPv6", "disable_ipv6", true),
        toggleBox("Monitor de rede", "network_monitor", false),
      ];

      const lanFields = [
        toggleBox("Permitir roteamento da LAN", "advertise_lan", false),
        field("Rede LAN permitida / CIDR", _h("input", {
          type: "text", value: s.advertise_cidr || "",
          disabled: props.disabled || busy.value || s.advertise_lan !== "1",
          class: "netbird-input", placeholder: "Ex.: 192.168.10.0/24",
          onInput: function (ev) { updateDraft("advertise_cidr", ev.target.value); },
        })),
        _h("div", { class: "netbird-feedback text-text-400" }, "Esta opção habilita e restringe o encaminhamento local no AX53. A Network/Resource correspondente também deve existir no NetBird Management com este AX53 selecionado como routing peer."),
      ];

      const actions = [
        _h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-secondary", onClick: fetchLog }, "Logs"),
      ];
      if (s.enrolled === "1") {
        actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value || dirty.value, class: "netbird-button netbird-button-secondary", onClick: restart }, "Reiniciar"));
      }

      const feedback = [];
      if (st === "payload_missing") feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "O componente do NetBird será baixado automaticamente quando necessário."));
      if (!profileExists.value) feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "Salve o perfil primeiro. Depois, reabra-o para fazer o enrollment. A configuração do perfil é salva pela rota VPN nativa do roteador."));
      else if (dirty.value) feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "Há alterações não salvas. Use SALVAR no rodapé deste diálogo. O enrollment fica bloqueado até salvar."));
      if (message.value) feedback.push(_h("div", { class: "netbird-feedback text-text-200" }, message.value));
      if (error.value) feedback.push(_h("div", { class: "netbird-feedback netbird-feedback-error" }, error.value));
      if (showLog.value) feedback.push(_h("pre", { class: "netbird-log" }, log.value || "(vazio)"));

      return _h("div", { class: "netbird-form" }, [
        _h("style", null, NETBIRD_CSS),
        _h("section", { class: "netbird-section netbird-connection" }, [_h("h3", { class: "netbird-heading" }, "Estado da conexão")].concat(statusRows)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Servidor NetBird")].concat(serverFields)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Recursos"), _h("div", { class: "netbird-feature-grid" }, featureFields)]),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Roteamento da LAN")].concat(lanFields)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Ações NetBird") , _h("div", { class: "netbird-actions" }, actions)]),
        feedback.length ? _h("section", { class: "netbird-section netbird-diagnostics" }, [_h("h3", { class: "netbird-heading" }, "Diagnóstico")].concat(feedback)) : null,
      ]);
    };
  },
});
