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

- /proc/driver/rtl8367s/vlan
- /proc/driver/rtl8367s/port

O próprio firmware stock usa essas primitives para IPTV/VLAN.

## DECISÃO — preservar os VIDs stock no primeiro perfil

O primeiro perfil router-on-a-stick usa VLAN 4094 para WAN e VLAN 2 para LAN.

Motivo: isso permite alterar somente o switch L2 sem obrigar, nesta primeira etapa, a reconfigurar a interface CPU, br-lan ou o binding Wi-Fi do AX53.

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

## Operação

Inspecionar/inicializar:

```sh
ax53-switch init
ax53-switch check
ax53-switch status
```

Persistir habilitação sem aplicar imediatamente:

```sh
ax53-switch enable
```

Aplicar após o trunk do Proxmox estar pronto:

```sh
ax53-switch apply
```

Rollback:

```sh
ax53-switch rollback
```

A restauração prefere o pipeline stock de IPTV/switch. Existe fallback para o layout stock básico (WAN 4094 + CPU; LAN 2 + CPU).

## Segurança operacional

Antes de `apply`:

1. manter acesso físico ao AX53;
2. validar SSH pela LAN/Wi-Fi;
3. preparar VLAN 4094 e VLAN 2 no Proxmox;
4. não executar o primeiro cutover a partir da LAN1, pois ela mudará para trunk;
5. usar LAN2/LAN3/LAN4 ou Wi-Fi para a sessão de manutenção;
6. validar que o roteador virtual possui WAN e LAN antes de desativar DHCP/gateway do AX53.

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
