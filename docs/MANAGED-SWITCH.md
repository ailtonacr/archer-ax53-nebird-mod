# Archer AX53 V1 — Managed switch / router-on-a-stick

## Escopo

Esta branch mantém somente:

- firmware stock como base;
- SSH de desenvolvimento em TCP 2222, limitado ao endereço LAN;
- pipeline local de aplicação de mods, teste e geração de firmware;
- camada L2 de switch gerenciável para o RTL8367S;
- integração da UI dentro do SPA stock TP-Link.

Não há integração VPN customizada nesta linha de desenvolvimento.

## FATO — dataplane stock

O código vendor do AX53 V1 define:

- WAN física: PHY 0;
- LAN1: PHY 1;
- LAN2: PHY 2;
- LAN3: PHY 3;
- LAN4: PHY 4;
- CPU: porta lógica 16;
- WAN default VID: 4094;
- LAN default VID: 2;
- interface WAN stock: `eth1.4094`;
- interface LAN stock: `eth1.2`.

O firmware TP-Link programa o RTL8367S através de:

- `/proc/driver/rtl8367s/vlan`;
- `/proc/driver/rtl8367s/port`.

O pipeline stock IPTV/VLAN já usa reset/init, membership mask, untagged mask e PVID. O managed-switch reutiliza essas mesmas primitives.

## DECISÃO — primeiro perfil

O primeiro perfil mantém os VIDs stock para não exigir uma segunda reescrita da pilha Linux/Wi-Fi:

```text
Internet/upstream
      |
      | untagged
      v
AX53 WAN / PHY0
      |
      | VLAN 4094
      v
RTL8367S
      |
      +---- LAN1 / PHY1 ---- trunk tagged VLAN 4094 + VLAN 2 ---- Proxmox
      |
      +---- LAN2 / PHY2 ---- access VLAN 2
      +---- LAN3 / PHY3 ---- access VLAN 2
      +---- LAN4 / PHY4 ---- access VLAN 2
      |
      +---- CPU / 16 -------- tagged VLAN 2 ---- eth1.2 / br-lan / Wi-Fi
```

A CPU fica fora da WAN por padrão (`cpu_wan=0`).

## Persistência

Template de fábrica:

```text
/etc/managed-switch/default.conf
```

Estado persistente:

```text
/tp_data/managed-switch/config
```

O firmware é instalado com `enabled=0`. Flash/boot não deve transformar a topologia automaticamente.

## CLI

```sh
ax53-switch init
ax53-switch check
ax53-switch status
ax53-switch configure <wan_vid> <lan_vid> <trunk_port> "<access_ports>" <cpu_lan> <cpu_wan>
ax53-switch enable
ax53-switch apply
ax53-switch rollback
```

`configure` grava o perfil inteiro atomicamente, evitando estados intermediários inválidos ao trocar trunk/access ports.

## Interface web — arquitetura stock

A interface **não é uma página standalone**.

A revisão inicial tentou usar `/webpages/managed-switch.html` com `fetch()` direto para LuCI. Em hardware real a resposta veio como payload cifrado (`{"data":"..."}`), comprovando que o transporte TP-Link não pode ser ignorado. Essa abordagem foi removida.

A implementação atual replica o padrão já validado na outra branch:

```text
TP-Link SPA /webpages/index.html#/
        |
        +-- Rede
             +-- Switch / VLAN
                    |
                    v
        ManagedSwitchPage-AX.js
                    |
                    | import stock
                    v
        update-store-DQkZxaRI.js
                    |
                    | api.request()
                    v
          /admin/managed_switch
                    |
                    v
   luci.model.controller._index(dispatch)
                    |
                    v
             ax53-switch
                    |
                    v
               RTL8367S
```

Frontend authored:

```text
src/web/ManagedSwitchPage-AX.js
```

No firmware ele é instalado comprimido em:

```text
/www/webpages/js/ManagedSwitchPage-AX.js.gz
```

O módulo importa o singleton stock:

```js
import { s as api } from "./update-store-DQkZxaRI.js";
```

e usa:

```js
api.request("/admin/managed_switch", ...)
```

Não existe `fetch()` cru nem URL manual `/cgi-bin/luci/;stok=...` no módulo.

Backend:

```text
/usr/lib/lua/luci/controller/admin/managed_switch.lua
```

O controller segue o contrato stock:

```lua
function _index()
    return controller._index(dispatch)
end
```

Isso deixa o transporte/session/crypto com a própria infraestrutura TP-Link.

## Menu Rede — engenharia reversa do bundle stock

### EVIDÊNCIA — bundle observado no hardware

O bundle `/www/webpages/js/index-D26yCMJF.js.gz` foi extraído do AX53 via DEV SSH em 2026-09-17.

- SHA256 do `.gz`: `95b11ac5181775faaf25e4e880663f3ba23c8d82589b20acb44e8ea5f35e88ad`.
- Conteúdo descompactado observado: `20.988` caracteres.
- A imagem em execução ainda continha o injetor V5 anterior no final do arquivo.
- Removendo somente o bloco delimitado pelo marcador legado, o trecho vendor/stock restante possui `17.682` caracteres.

A análise mostrou que o menu não nasce do DOM. O bundle possui dois contratos separados.

Rotas são declaradas em uma tabela `k`:

```js
{name:"networkStatus",path:"networkStatus",component:...}
{name:"lanAdv",path:"lanAdv",component:...}
{name:"dhcpServerAdv",path:"dhcpServer",component:...}
{name:"iptvAdv",path:"iptvAdv",component:...}
```

`H.getRouteConfig()` coleta os `key` das folhas do menu e mantém as rotas de `k` cujo `name` aparece nessa árvore.

A navegação vem do store `navConfig`. Ele seleciona `O.base`/configuração regional e depois a árvore do modo de operação. A árvore usa nós `key`, `text` e `children`. Em seguida `H.getExcludedMenu()` clona e filtra módulos ocultos/permissões antes da renderização.

### INCIDENTE — V5 clonava o DOM renderizado

A variante anterior procurava visualmente `IPTV/VLAN`, fazia `cloneNode()` da linha e mantinha o item com `MutationObserver`. Isso produziu a renderização quebrada observada no hardware, com `IPTV/VLAN` e `Switch / VLAN` ocupando a mesma estrutura/linha do submenu.

A causa não era CSS do managed-switch: estávamos duplicando uma representação já renderizada em vez de declarar outro nó no modelo de navegação.

### DECISÃO — V6 usa o mesmo modelo do menu stock

`scripts/patch-managed-switch-menu.py` agora:

1. remove de forma explícita o injetor DOM legado, se presente;
2. adiciona uma rota normal à tabela stock:
   ```js
   {name:"managedSwitch",path:"managedSwitch",component:...}
   ```
3. adiciona ao `modeMenu` um nó stock-shaped:
   ```js
   {key:"managedSwitch",text:"Switch / VLAN"}
   ```
4. insere esse nó imediatamente depois do filho cujo `key` é `iptvAdv`;
5. preserva sem alteração o filtro stock `H.getExcludedMenu(...)`;
6. usa um wrapper de lifecycle da rota apenas para abrir/fechar `ManagedSwitchPage-AX.js`.

Não existe mais `MutationObserver`, polling de DOM, `cloneNode()`, `leafIptv` ou `rowFor` no bundle final. O menu é montado pela própria TP-Link e, portanto, herda a mesma estrutura, largura, seleção e comportamento dos outros filhos de `Rede`.

O patch é fail-closed: se os anchors de rota, `navConfig`, `modeMenu` ou filtro visível mudarem no firmware base, o build aborta em vez de aplicar um patch aproximado.

## Segurança da UI

- `Salvar configuração` apenas grava `/tp_data/managed-switch/config`.
- Alterações não salvas bloqueiam `Aplicar agora`.
- Enquanto o perfil está ativo, edição de VLAN/portas fica bloqueada.
- `Aplicar agora` pede confirmação operacional.
- Backend garante habilitação antes do apply.
- Se `apply` falhar, o backend executa `rollback` automaticamente.
- `Rollback stock` permanece disponível explicitamente.
- IPTV/VLAN customizado da TP-Link não deve ser usado simultaneamente com o perfil gerenciado.

## Rollback

`ax53-switch rollback`:

1. persiste `enabled=0`;
2. tenta restaurar pelo pipeline stock `/etc/init.d/iptv restart`;
3. se o pipeline vendor falhar/estiver indisponível, usa fallback funcional básico:
   - WAN 4094: PHY0 + CPU16;
   - LAN 2: PHY1–4 + CPU16.

O fallback é recovery funcional, não promessa de reconstrução byte-a-byte de qualquer perfil IPTV customizado anterior.

## Primeiro cutover

Pré-condições:

1. acesso físico ao AX53 disponível;
2. manutenção por Wi-Fi ou LAN2–LAN4, nunca pela futura trunk;
3. Proxmox preparado para VLAN 4094 (WAN) e VLAN 2 (LAN);
4. VM de roteamento preparada antes do apply;
5. IPTV/VLAN customizado stock desabilitado.

Stop point: não clicar em `Aplicar agora` enquanto essas condições não forem atendidas.

## Build local

```sh
make test-firmware
make firmware
```

Saída padrão:

```text
work/Archer-AX53-ManagedSwitch-build-<N>.bin
```

## Estado de validação

Comprovado em código/vendor:

- mapeamento PHY/CPU;
- primitives RTL8367S;
- VIDs stock;
- persistência/validação da CLI;
- arquitetura frontend/backend baseada no transporte stock;
- contrato real do menu/roteador SPA no bundle extraído do hardware;
- patch V6 aplicado com sucesso ao bundle real fornecido, validado por `node --check`;
- idempotência da V6 validada localmente no mesmo bundle.

Ainda requer validação na imagem/hardware da revisão atual:

- `make test-firmware` executado no clone local;
- build/repack completo;
- flash da nova imagem;
- menu `Switch / VLAN` como linha independente dentro de `Rede`;
- navegação `#/managedSwitch` e retorno pelo botão `Voltar`;
- status decriptado pelo `update-store`;
- save sem alteração do switch;
- apply real do trunk;
- reboot/hotplug;
- rollback real.
