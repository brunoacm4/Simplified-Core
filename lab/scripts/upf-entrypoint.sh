#!/bin/sh
# Prepara o plano de dados do UPF antes de arrancar o daemon.
#
# O open5gs-upfd consegue criar a ogstun sozinho, mas fazemo-lo aqui de forma
# explicita para que o estado da interface seja deterministico e visivel -- num
# laboratorio de medicao nao queremos passos implicitos.
set -e

UE_SUBNET="${UE_SUBNET:-10.45.0.0/16}"
UE_GATEWAY_CIDR="${UE_GATEWAY_CIDR:-10.45.0.1/16}"

# TUN por onde entram e saem os pacotes do UE, ja desencapsulados de GTP-U.
ip tuntap add name ogstun mode tun 2>/dev/null || true
ip addr replace "${UE_GATEWAY_CIDR}" dev ogstun
ip link set ogstun up

# NAT para a N6. Sem isto o UE tem IP mas nao chega a lado nenhum.
# -C testa primeiro para o arranque ser idempotente.
if ! iptables -t nat -C POSTROUTING -s "${UE_SUBNET}" ! -o ogstun -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s "${UE_SUBNET}" ! -o ogstun -j MASQUERADE
fi

echo "[upf] ogstun pronta, NAT para N6 ativo, a arrancar open5gs-upfd"
exec /opt/open5gs/bin/open5gs-upfd -c /etc/open5gs/upf.yaml
