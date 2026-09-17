# Archer AX53 V1 — Managed switch / router-on-a-stick

## Escopo

Esta branch mantém somente:

- firmware stock como base;
- SSH de desenvolvimento em TCP 2222, limitado ao endereço LAN;
- pipeline local de aplicação de mods, teste e geração de firmware;
- camada L2 de switch gerenciável para o RTL8367S.

Não há integração VPN customizada nesta linha de desenvolvimento.

## FATO — mapeamento observado no firmware stock

O código vendor do AX53 V1 define:

- WAN física: PHY 0;
- LAN1: PHY 1;
- LAN2: PHY 2;
- LAN3: PHY 3;
- LAN4: PHY 4;
- CPU: porta lógica 16;
- WAN default VID: 4094;
- LAN default VID: 2;
- interface WAN stock: eth1.4094;
- interface LAN stock: eth1.2.

O driver vendor expõe configuração de VLAN/PVID por:

- `/proc/driver/rtl8367s/vlan`
- `/proc/driver/rtl8367s/port`

O próprio firmware stock usa essas primitives para IPTV/VLAN.

## DECISÃO — preservar os VIDs stock no primeiro perfil

O primeiro perfil router-on-a-stick usa VLAN 4094 para WAN e VLAN 2 para LAN.

Motivo: isso permite alterar somente o switch L2 sem obrigar, nesta primeira etapa, a reconfigurar a interface CPU, `br-lan` ou o binding Wi-Fi do AX53.

## Topologia alvo do perfil

```text
Internet/upstream
      |
      | untagged
      v
AX53 WAN / PHY0
      |
      | VLAN 4094
      |
RTL8367S
      |
      +---- LAN1 / PHY1 ---- trunk tagged VLAN 4094 + VLAN 2 ---- Proxmox
      |
      +---- LAN2 / PHY2 ---- access VLAN 2
      +---- LAN3 / PHY3 ---- access VLAN 2
      +---- LAN4 / PHY4 ---- access VLAN 2
      |
      +---- CPU / port 16 --- tagged VLAN 2 --- eth1.2 / br-lan / Wi-Fi
```

A CPU fica fora da VLAN WAN por padrão.

## Estado após flash

O perfil é instalado com `enabled=0`.

Isso é proposital: instalar/flashar o firmware não deve alterar a topologia ativa automaticamente.

Configuração persistente:

```text
/tp_data/managed-switch/config
```

Template de fábrica:

```text
/etc/managed-switch/default.conf
```

## Operação por CLI

Inspecionar/inicializar:

```sh
ax53-switch init
ax53-switch check
ax53-switch status
```

Configurar o perfil sem tocar no switch:

```sh
ax53-switch configure 4094 2 1 "2 3 4" 1 0
```

A CLI mantém os comandos `enable` e `apply` separados para manutenção/diagnóstico. Na interface web, porém, a ativação manual separada foi removida por segurança: o usuário salva primeiro e o botão **Aplicar agora** executa o fluxo de ativação + aplicação como uma única intenção operacional. Se a aplicação falhar, a UI solicita `disable`/restauração stock automaticamente.

Rollback manual:

```sh
ax53-switch rollback
```

A restauração prefere o pipeline stock de IPTV/switch. Existe fallback para o layout stock básico (WAN 4094 + CPU; LAN 2 + CPU).

## Interface web

A branch inclui um controller LuCI autenticado em:

```text
/admin/managed_switch
```

Controller:

```text
/usr/lib/lua/luci/controller/admin/managed_switch.lua
```

Página standalone da UI:

```text
/www/webpages/managed-switch.html
```

URL no navegador:

```text
http://<ip-do-ax53>/webpages/managed-switch.html
```

A página chama diretamente:

```text
/cgi-bin/luci/;stok=/admin/managed_switch
```

com `credentials: same-origin`. Ela não importa o `update-store` do SPA TP-Link, pois esse módulo depende do contexto Vue inicializado pelo aplicativo principal.

### Navegação no SPA TP-Link

O menu visual TP-Link é um SPA minificado; `entry()` do LuCI não cria automaticamente um item visual. O build portanto aplica um patch pequeno e idempotente no bundle principal.

O launcher **Switch / VLAN** fica como filho do menu stock **Rede / Network**. Não existe fallback top-level nesta versão: se o submenu Rede ainda não estiver materializado, um `MutationObserver` espera a árvore correta aparecer e injeta o item nela.

A tela permite:

- ler o estado persistente e a tabela VLAN ativa do RTL8367S;
- configurar VLAN WAN e VLAN LAN;
- escolher a porta trunk para o Proxmox;
- escolher quais LANs permanecem access/untagged;
- controlar participação da CPU nas VLANs LAN/WAN;
- visualizar a topologia resultante antes de salvar;
- salvar o perfil de forma atômica, sem alterar o hardware;
- aplicar/reaplicar explicitamente a configuração L2;
- desabilitar e restaurar o layout stock;
- executar rollback para o pipeline/layout stock.

O salvamento usa um único comando atômico:

```sh
ax53-switch configure <wan_vid> <lan_vid> <trunk_port> "<access_ports>" <cpu_lan> <cpu_wan>
```

Isso evita estados intermediários inválidos ao trocar a porta trunk.

### Segurança da UI

`Salvar configuração` altera apenas `/tp_data/managed-switch/config`.

Enquanto o perfil está ativo, os campos de configuração ficam bloqueados para evitar salvar um perfil diferente daquele que está efetivamente programado no RTL8367S e que poderia ser reaplicado automaticamente em hotplug/reboot.

Quando o perfil está desabilitado, alterações não salvas impedem `Aplicar agora`.

`Aplicar agora` é a única ação da UI que inicia a ativação do perfil. A página apresenta confirmação explícita, recomenda manter a sessão por Wi-Fi/porta access e exige que o Proxmox esteja preparado antes do cutover.

A opção de desabilitar/restaurar stock só aparece quando o perfil está ativo.

## Interação com IPTV/VLAN stock

O managed-switch substitui a tabela VLAN do RTL8367S enquanto estiver ativo. Portanto ele não deve ser usado simultaneamente com uma configuração IPTV/VLAN customizada da TP-Link.

O hook stock `65-iptv` continua sendo o dono da reconstrução padrão. Nosso hook `99-managed-switch` roda depois e reaplica o perfil somente quando `enabled=1`.

O rollback chama primeiro o pipeline stock `/etc/init.d/iptv restart`; o fallback básico só é usado quando o pipeline stock não está disponível ou falha.

## Segurança operacional

Antes do primeiro `Aplicar agora`:

1. manter acesso físico ao AX53;
2. validar SSH pela LAN/Wi-Fi;
3. preparar VLAN 4094 e VLAN 2 no Proxmox;
4. não executar o primeiro cutover a partir da porta escolhida como trunk;
5. usar uma porta access ou Wi-Fi para a sessão de manutenção;
6. manter IPTV/VLAN customizado stock desabilitado;
7. só promover o Proxmox/VM a gateway depois de validar WAN e LAN pelo trunk.

## Limite da primeira implementação

Esta etapa é exclusivamente L2. Ela não desliga automaticamente DHCP/NAT do AX53 e não promove o Proxmox a gateway.

Isso é intencional para permitir validação isolada e rollback simples.

A mudança de gateway deve ser uma etapa posterior, com teste de conectividade e plano de recuperação próprios.

## Build local

Testes:

```sh
make test-firmware
```

Build:

```sh
make firmware
```

Imagem padrão:

```text
work/Archer-AX53-ManagedSwitch-build-<N>.bin
```

## Estado de validação

- auditoria estática da branch: concluída;
- isolamento da branch contra integrações VPN customizadas: confirmado pelo diff contra a base pré-integrações;
- menu V3 escopado a Rede/Network: implementado;
- fluxo UI sem `update-store`: implementado;
- proteção contra aplicação de draft não salvo: implementada;
- build/teste offline executado nesta sessão: pendente, pois o ambiente de execução disponível não resolve `github.com` para clonar a branch;
- validação do menu V3 e do dataplane em hardware real: pendente de nova imagem/flash.
