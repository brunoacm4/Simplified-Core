#!/bin/sh
# Mede os procedimentos do grupo 1 que ainda não tinham números (notes/core/procedimentos-grupo1.md),
# com um único dispositivo e o gNB com temporizador de inatividade (variante idle):
#
#   corrida "paging"    acordares pelo UE (ping do UE para o UPF) intercalados com acordares pela
#                       rede (ping do UPF para o UE: paging + Service Request), N de cada
#   corrida "regresso"  T3512 = 60 s (variante t3512-60s). O dispositivo perde a cobertura e volta
#                       (a) antes de o AMF dar por isso e (b) depois do desregisto implícito
#
# A perda de cobertura é um netem com 100% de perda na interface do UE na rede ran: o processo
# continua a correr com todo o seu estado (5G-GUTI, contexto de segurança, sessão) e passa a
# MM-REGISTERED/NO-CELL-AVAILABLE, como um dispositivo que fica sem rede e depois recupera.
# Alternativas que não servem (tentadas a 2026-10-08):
#   - reiniciar o contentor: o UERANSIM não guarda nada e volta com o SUCI, ao contrário de um modem
#     real (TS 33.501 §6.8.1.1);
#   - docker pause: ao acordar, o UERANSIM vê a célula como nova a meio do registo periódico, apaga o
#     contexto de segurança e faz um registo inicial (ficou em regresso-pause.*);
#   - ip link set down: o nr-ue aborta com LibError no envio e o contentor reinicia.
#
# Cada acontecimento fica numa linha "<início> <fim> <nome>" (epoch) em <nome>.eventos, para o
# scripts/analisar-grupo1.py contar as mensagens de cada um.
#
# Uso: [N=5] [CORRIDAS="paging regresso"] ./scripts/medir-grupo1.sh <pasta-de-saída>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
N=${N:-5}
ESPERA_CORE=${ESPERA_CORE:-25}
CORRIDAS=${CORRIDAS:-paging regresso}
export N_UES=1
mkdir -p "$OUT"

agora() { date +%s.%N; }

arrancar() {  # <nome>: lab limpo, captura a correr, dispositivo registado e adormecido
    COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
    docker compose up --no-start >/dev/null 2>&1
    dumpcap -q -i br-n2 -i br-sbi -i br-n4 -w "$OUT/$1.pcapng" >/dev/null 2>&1 &
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
    UE_IP=$(docker compose exec -T ue ip -4 -o addr show uesimtun0 | awk '{ sub(/\/.*/, "", $4); print $4 }')
    sleep 20                                  # o gNB liberta-o ao fim de 10 s sem tráfego
    : > "$OUT/$1.eventos"
}

terminar() {  # <nome>
    sleep 2
    kill $CAP; wait $CAP 2>/dev/null || true
    mkdir -p "$OUT/$1-logs"
    for s in $(docker compose config --services); do
        docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$1-logs/$s.log" 2>&1
    done
    echo "compose_file=$COMPOSE_FILE" > "$OUT/$1.meta"
    (cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)") >> "$OUT/$1.meta"
    (cd ../UERANSIM && echo "ueransim=$(git describe --tags --dirty)") >> "$OUT/$1.meta"
}

# --- Corrida 1: acordar pelo UE contra acordar pela rede ---
if echo "$CORRIDAS" | grep -qw paging; then
export COMPOSE_FILE=docker-compose.yml:variantes/idle/compose.yml
arrancar paging
UPF=$(docker compose ps -q upf)
for i in $(seq 1 "$N"); do
    # Pelo UE: o UERANSIM em CM-IDLE descarta o pacote e só pede a ligação (ver o README da
    # experiência de 2026-09-28); interessa a sinalização, não a resposta.
    t0=$(agora)
    docker compose exec -T ue ping -c 1 -W 5 -I uesimtun0 10.45.0.1 >> "$OUT/paging.ping-ue" 2>&1 || true
    sleep 15
    echo "$t0 $(agora) ue-$i" >> "$OUT/paging.eventos"
    # Pela rede: ping a partir da rede do UPF (a imagem do Open5GS não tem ping; o contentor
    # auxiliar partilha o namespace de rede do UPF e sai pela ogstun como o tráfego de N6)
    t0=$(agora)
    docker run --rm --network "container:$UPF" core-simplified/ueransim:v3.3.0 \
        ping -c 1 -W 10 "$UE_IP" >> "$OUT/paging.ping-rede" 2>&1 || true
    sleep 15
    echo "$t0 $(agora) rede-$i" >> "$OUT/paging.eventos"
done
terminar paging
fi

# --- Corrida 2: regresso de um dispositivo congelado, antes e depois do desregisto implícito ---
if echo "$CORRIDAS" | grep -qw regresso; then
# Com T3512 = 60 s: mobile reachable = 60 + 240 = 300 s; desregisto implícito 300 s depois.
export COMPOSE_FILE=docker-compose.yml:variantes/t3512-60s/compose.yml:variantes/idle/compose.yml
arrancar regresso
IF_RAN=$(docker compose exec -T ue ip -4 -o addr show | awk '$4 ~ /^10\.100\.5\./ { print $2 }')
cobertura() {  # up | down
    if [ "$1" = down ]; then
        docker compose exec -T ue tc qdisc add dev "$IF_RAN" root netem loss 100%
    else
        docker compose exec -T ue tc qdisc del dev "$IF_RAN" root
    fi
}

# (a) Sem cobertura 120 s: o T3512 do UE expira, o mobile reachable do AMF ainda não
t0=$(agora); cobertura down; sleep 120
t1=$(agora); cobertura up
echo "$t0 $t1 sem-cobertura-curto" >> "$OUT/regresso.eventos"
sleep 30
echo "$t1 $(agora) regresso-antes" >> "$OUT/regresso.eventos"
sleep 20
docker compose exec -T ue ip -4 -o addr show uesimtun0 >/dev/null 2>&1 || echo "AVISO: sem sessão PDU antes de (b)"

# (b) Sem cobertura até o AMF o desregistar implicitamente
t0=$(agora); cobertura down
espera=0
until docker compose logs amf 2>/dev/null | grep -q "Implicit De-registered"; do
    espera=$((espera + 5)); [ "$espera" -gt 900 ] && { echo "sem desregisto implícito" >&2; break; }
    sleep 5
done
sleep 10
t1=$(agora); cobertura up
echo "$t0 $t1 sem-cobertura-longo" >> "$OUT/regresso.eventos"
sleep 40
echo "$t1 $(agora) regresso-depois" >> "$OUT/regresso.eventos"
terminar regresso
fi

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
echo "grupo 1 -> $OUT ($CORRIDAS)"
