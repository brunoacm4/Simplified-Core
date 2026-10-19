#!/bin/sh
# Mede os procedimentos do grupo 2 (sessões PDU) que o UERANSIM consegue pedir
# (notes/core/procedimentos-grupo2.md), com um dispositivo e a variante idle:
#
#   sessao-N     o UE pede uma segunda sessão PDU (nr-cli ps-establish)
#   libertar-N   o UE liberta essa sessão (nr-cli ps-release <psi>)
#
# Os pedidos são feitos com o UE acordado (ping contínuo pela primeira sessão), para a janela só ter
# o procedimento de sessão. Com o UE adormecido o UERANSIM não serve: "envia" a mensagem de sessão
# sem acordar, perde-a, e só ao fim do T3580 (16 s) faz o Service Request (tentado a 2026-10-09).
# Um modem real faria o Service Request primeiro; o custo é então o do ciclo (grupo 1) mais este.
#
# O estabelecimento dentro do registo inicial já está medido (experiencias/2026-10-08-grupo1,
# arranque.*). A modificação de sessão não se mede: o UERANSIM não a pede e o Open5GS só a inicia a
# pedido de uma aplicação (N5, npcf-policyauthorization), que o lab não tem.
#
# Mesmo formato de saída do medir-grupo1.sh; análise com scripts/analisar-grupo1.py.
#
# Uso: [N=3] ./scripts/medir-grupo2.sh <pasta-de-saída>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
N=${N:-3}
ESPERA_CORE=${ESPERA_CORE:-25}
export N_UES=1 COMPOSE_FILE=docker-compose.yml:variantes/idle/compose.yml
mkdir -p "$OUT"
NOME=sessoes

agora() { date +%s.%N; }
cli() { docker compose exec -T ue nr-cli imsi-999700000000001 -e "$1" >> "$OUT/$NOME.cli" 2>&1 || true; }

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up --no-start >/dev/null 2>&1
dumpcap -q -i br-n2 -i br-sbi -i br-n4 -w "$OUT/$NOME.pcapng" >/dev/null 2>&1 &
CAP=$!
sleep 2
docker compose up -d $(docker compose config --services | grep -vx ue) >/dev/null 2>&1
sleep "$ESPERA_CORE"
docker compose up -d ue >/dev/null 2>&1
espera=0
until docker compose logs ue 2>/dev/null | grep -q "PDU Session establishment is successful"; do
    espera=$((espera + 2)); [ "$espera" -gt 120 ] && { echo "UE sem sessão" >&2; exit 1; }
    sleep 2
done
sleep 20                                      # o gNB liberta-o ao fim de 10 s sem tráfego
: > "$OUT/$NOME.eventos"

# PSIs das sessões estabelecidas até agora, uma por linha
sessoes() {
    docker compose logs --no-log-prefix ue 2>/dev/null \
        | sed -n 's/.*PDU Session establishment is successful PSI\[\([0-9]*\)\].*/\1/p'
}

# Manter o UE acordado durante os pedidos (o gNB só o liberta ao fim de 10 s sem tráfego)
docker compose exec -T ue ping -q -I uesimtun0 -i 1 -w $((N * 40 + 10)) 10.45.0.1 >/dev/null 2>&1 &
PING=$!
sleep 5
for i in $(seq 1 "$N"); do
    # Pedido pelo nr-cli, o primeiro envio é barrado pelo UAC do UERANSIM ("No response from RRC from
    # UAC checks") e a sessão só segue na retransmissão do T3580, 16 s depois. As contagens não mudam;
    # a janela espera pela sessão nova.
    antes=$(sessoes | wc -l)
    t0=$(agora); cli "ps-establish IPv4 --sst 1 --dnn internet"
    espera=0
    until [ "$(sessoes | wc -l)" -gt "$antes" ]; do
        espera=$((espera + 1)); [ "$espera" -gt 40 ] && { echo "sessão $i não estabelecida" >&2; break; }
        sleep 1
    done
    sleep 2
    echo "$t0 $(agora) sessao-$i" >> "$OUT/$NOME.eventos"
    psi=$(sessoes | tail -1)
    sleep 3
    t0=$(agora); cli "ps-release $psi"; sleep 4
    echo "$t0 $(agora) libertar-$i" >> "$OUT/$NOME.eventos"
    sleep 3
done
wait $PING 2>/dev/null || true

sleep 2
kill $CAP; wait $CAP 2>/dev/null || true
mkdir -p "$OUT/$NOME-logs"
for s in $(docker compose config --services); do
    docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$NOME-logs/$s.log" 2>&1
done
echo "compose_file=$COMPOSE_FILE" > "$OUT/$NOME.meta"
(cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)") >> "$OUT/$NOME.meta"
(cd ../UERANSIM && echo "ueransim=$(git describe --tags --dirty)") >> "$OUT/$NOME.meta"
COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
echo "grupo 2 -> $OUT/$NOME"
