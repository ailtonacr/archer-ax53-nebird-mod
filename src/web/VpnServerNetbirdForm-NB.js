import { d as defineComponent, r as ref, e as onMounted, O as onUnmounted, h as _h, q as resolveComponent } from "./vendor-BrE4IMR2.js";
import { s as api } from "./update-store-DQkZxaRI.js";

const NB = "/admin/netbird";

// Presentation-only styles scoped to this lazily loaded form.
const NETBIRD_CSS = ".netbird-form{display:grid;gap:16px;max-width:760px;color:inherit}.netbird-section{padding:16px;border:1px solid rgba(128,128,128,.2);border-radius:6px;background:rgba(128,128,128,.035)}.netbird-heading{margin:0 0 14px;font-size:14px;font-weight:600}.netbird-connection{display:grid;gap:10px}.netbird-status-main{display:flex;align-items:center;justify-content:space-between;gap:12px}.netbird-status-label,.netbird-field-label{color:#8b95a7;font-size:13px}.netbird-status-value{padding:4px 10px;border-radius:999px;background:rgba(74,203,214,.13);color:#168c98;font-size:13px}.netbird-status-detail,.netbird-status-grid{display:flex;justify-content:space-between;gap:12px;font-size:12px;color:#667085}.netbird-field{display:grid;grid-template-columns:minmax(150px,30%) minmax(0,1fr);align-items:center;gap:14px;margin-top:12px}.netbird-field-control{min-width:0}.netbird-input{box-sizing:border-box;width:100%;min-height:34px;padding:7px 10px;border:1px solid rgba(128,128,128,.35);border-radius:4px;background:transparent;color:inherit;outline:0}.netbird-input:focus{border-color:#27b8c7;box-shadow:0 0 0 2px rgba(39,184,199,.12)}.netbird-feature-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 24px}.netbird-switch{display:flex;align-items:center;gap:9px;min-width:0;font-size:13px;cursor:pointer}.netbird-switch-input{width:15px;height:15px;accent-color:#27b8c7;flex:0 0 auto}.netbird-switch-input:disabled{cursor:not-allowed}.netbird-switch-label{line-height:1.35}.netbird-actions{display:flex;flex-wrap:wrap;gap:8px}.netbird-button{min-height:32px;padding:0 14px;border:1px solid transparent;border-radius:4px;font-size:13px;cursor:pointer}.netbird-button:disabled{opacity:.55;cursor:not-allowed}.netbird-button-primary{background:#27b8c7;color:#fff}.netbird-button-secondary{border-color:rgba(128,128,128,.4);background:transparent;color:inherit}.netbird-button-danger{border-color:rgba(220,74,74,.5);background:transparent;color:#c94444}.netbird-diagnostics{display:grid;gap:8px}.netbird-feedback{padding:9px 10px;border-radius:4px;background:rgba(128,128,128,.07);font-size:12px;line-height:1.45}.netbird-feedback-error{color:#c94444;background:rgba(220,74,74,.08)}.netbird-log{max-height:190px;overflow:auto;margin:0;padding:10px;border-radius:4px;background:rgba(0,0,0,.06);font-size:12px;white-space:pre-wrap}@media(max-width:560px){.netbird-field{grid-template-columns:1fr;gap:6px}.netbird-feature-grid{grid-template-columns:1fr}.netbird-status-detail,.netbird-status-grid{flex-direction:column;gap:4px}}";

function nbReq(operation, extra) {
  return api.request(NB, Object.assign({ operation: operation }, extra || {}), {
    preventSuccess: true,
    preventError: true,
  });
}

function errMsg(e) {
  if (!e) return "unknown error";
  if (typeof e === "string") return e;
  if (e.response && e.response.data && e.response.data.error) return e.response.data.error;
  if (e.message) return e.message;
  return "unknown error";
}

export default defineComponent({
  name: "VpnServerNetbirdForm",
  props: { disabled: { type: Boolean, default: false } },
  setup(props) {
    const settings = ref(null);
    const draft = ref(null);
    const status = ref(null);
    const netbird = ref({});
    const payload = ref({});
    const setupKey = ref("");
    const log = ref("");
    const busy = ref(false);
    const message = ref("");
    const error = ref("");
    const showLog = ref(false);
    let statusRequestPending = false;

    function copySettings(value) {
      return Object.assign({}, value || {});
    }

    function updateDraft(key, value) {
      if (!draft.value) return;
      draft.value[key] = value;
      dirty.value = true;
    }

    const dirty = ref(false);

    async function load() {
      if (statusRequestPending) return;
      statusRequestPending = true;
      try {
        const r = await nbReq("status");
        settings.value = r.settings || null;
        // Runtime polling must never replace a draft that the user is editing.
        if (!draft.value && r.settings) draft.value = copySettings(r.settings);
        netbird.value = r.netbird || {};
        payload.value = r.payload || {};
        status.value = r.code;
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        statusRequestPending = false;
      }
    }

    async function saveDraft() {
      if (!draft.value || !dirty.value) return;
      busy.value = true;
      error.value = "";
      message.value = "";
      try {
        const r = await nbReq("settings_set", copySettings(draft.value));
        settings.value = r.settings || settings.value;
        draft.value = copySettings(settings.value);
        dirty.value = false;
        message.value = "saved";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load();
      }
    }

    async function enroll() {
      if (!setupKey.value) return;
      busy.value = true;
      error.value = "";
      message.value = "";
      try {
        await nbReq("enroll", { setup_key: setupKey.value, management_url: draft.value.management_url });
        setupKey.value = "";
        message.value = "enrolled";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load();
      }
    }

    async function control(op) {
      busy.value = true;
      error.value = "";
      try {
        await nbReq(op);
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load();
      }
    }

    async function reEnroll() {
      if (!window.confirm("Re-enroll removes the current NetBird identity and requires a new setup key. Continue?")) return;
      busy.value = true;
      try {
        await nbReq("clean");
        updateDraft("enable", "0");
        await saveDraft();
        status.value = "enrollment_required";
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load();
      }
    }

    async function removeProfile() {
      if (!window.confirm("Delete the NetBird client? This stops the process and removes its configuration.")) return;
      busy.value = true;
      try {
        await nbReq("clean");
      } catch (e) {
        error.value = errMsg(e);
      } finally {
        busy.value = false;
        await load();
      }
    }

    async function fetchLog() {
      showLog.value = !showLog.value;
      if (showLog.value) {
        try {
          const r = await nbReq("log", { lines: 100 });
          log.value = r.lines || "";
        } catch (e) {
          log.value = errMsg(e);
        }
      }
    }

    const STATUS_LABEL = {
      connected: "Connected",
      connecting: "Connecting",
      disconnected: "Disconnected",
      disabled: "Disabled",
      enrollment_required: "Enrollment required",
      payload_missing: "Payload not ready",
      stopped: "Stopped",
      error: "Error",
    };

    let timer = null;
    onMounted(function () {
      load();
      timer = setInterval(load, 5000);
    });
    onUnmounted(function () {
      if (timer) clearInterval(timer);
    });

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
          type: "checkbox",
          checked: on,
          disabled: props.disabled || busy.value,
          class: "netbird-switch-input",
          onChange: function (ev) {
            const checked = ev.target.checked;
            const v = invert ? (checked ? "0" : "1") : checked ? "1" : "0";
            updateDraft(key, v);
          },
        }),
        _h("span", { class: "netbird-switch-label" }, label),
      ]);
    }

    return function () {
      if (!settings.value || !draft.value) {
        return _h("div", { class: "p-4 text-text-400" }, "Carregando status do NetBird...");
      }

      const s = draft.value;
      const st = status.value || "stopped";
      const nb = netbird.value;
      const pv = payload.value;

      const statusRows = [
        _h("div", { class: "netbird-status-main" }, [
          _h("span", { class: "netbird-status-label" }, "Status"),
          _h("strong", { class: "netbird-status-value" }, STATUS_LABEL[st] || st),
        ]),
      ];
      if (pv && pv.state) statusRows.push(_h("div", { class: "netbird-status-detail" }, [
        _h("span", null, "Componente"),
        _h("strong", null, pv.state === "READY" ? "Pronto" : pv.state),
      ]));
      if (st === "connected") statusRows.push(_h("div", { class: "netbird-status-grid" }, [
        _h("span", null, "IP NetBird: " + (nb.netbirdIp || "-")),
        _h("span", null, "Peers: " + (nb.peersConnected || 0) + " / " + (nb.peersTotal || 0)),
      ]));

      const serverFields = [field("URL de gerenciamento",
        _h("input", {
          type: "text",
          value: s.management_url || "",
          disabled: props.disabled || busy.value,
          class: "netbird-input",
          onInput: function (ev) { updateDraft("management_url", ev.target.value); },
        }))];

      if (s.enrolled !== "1") {
        serverFields.push(field("Chave de configuração",
          _h("input", {
            type: "password",
            value: setupKey.value,
            disabled: props.disabled || busy.value,
            class: "netbird-input",
            placeholder: "Cole a chave de configuração (não é armazenada)",
            onInput: function (ev) { setupKey.value = ev.target.value; },
          })));
        serverFields.push(
          _h("button", {
            type: "button",
            disabled: props.disabled || busy.value || !setupKey.value,
            class: "netbird-button netbird-button-primary",
            onClick: enroll,
          }, "Fazer enrollment")
        );
      } else {
        serverFields.push(
          _h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-secondary", onClick: reEnroll }, "Refazer enrollment")
        );
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
        toggleBox("Anunciar rede local", "advertise_lan", false),
        field("Rede local / CIDR",
        _h("input", {
          type: "text",
          value: s.advertise_cidr || "",
          disabled: props.disabled || busy.value,
          class: "netbird-input",
          placeholder: "Ex.: 192.168.10.0/24",
          onInput: function (ev) { updateDraft("advertise_cidr", ev.target.value); },
        }))
      ];

      const actions = [];
      actions.push(_h("button", {
        type: "button",
        disabled: props.disabled || busy.value || !dirty.value,
        class: "netbird-button netbird-button-primary",
        onClick: saveDraft,
      }, "Salvar"));
      if (st !== "connected") {
        actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-primary", onClick: function () { control("start"); } }, "Iniciar"));
      } else {
        actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-primary", onClick: function () { control("stop"); } }, "Parar"));
        actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-secondary", onClick: function () { control("restart"); } }, "Reiniciar"));
      }
      actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-secondary", onClick: fetchLog }, "Logs"));
      actions.push(_h("button", { type: "button", disabled: props.disabled || busy.value, class: "netbird-button netbird-button-danger", onClick: removeProfile }, "Excluir"));

      const feedback = [];
      if (st === "payload_missing") feedback.push(_h("div", { class: "netbird-feedback text-text-400" }, "O componente do NetBird será baixado automaticamente quando necessário."));
      if (message.value) feedback.push(_h("div", { class: "netbird-feedback text-text-200" }, message.value));
      if (error.value) feedback.push(_h("div", { class: "netbird-feedback netbird-feedback-error" }, error.value));
      if (showLog.value) feedback.push(_h("pre", { class: "netbird-log" }, log.value || "(vazio)"));

      return _h("div", { class: "netbird-form" }, [
        _h("style", null, NETBIRD_CSS),
        _h("section", { class: "netbird-section netbird-connection" }, [_h("h3", { class: "netbird-heading" }, "Estado da conexão")].concat(statusRows)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Servidor NetBird")].concat(serverFields)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Recursos"), _h("div", { class: "netbird-feature-grid" }, featureFields)]),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Compartilhamento da LAN")].concat(lanFields)),
        _h("section", { class: "netbird-section" }, [_h("h3", { class: "netbird-heading" }, "Ações"), _h("div", { class: "netbird-actions" }, actions)]),
        feedback.length ? _h("section", { class: "netbird-section netbird-diagnostics" }, [_h("h3", { class: "netbird-heading" }, "Diagnóstico")].concat(feedback)) : null,
      ]);
    };
  },
});
