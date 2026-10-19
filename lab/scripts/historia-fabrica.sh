#!/bin/sh
# História completa de uma fábrica de três dispositivos (variante fabrica3), para ver tudo o que o
# core faz, por fase e por dispositivo (notes/core/historia-fabrica.md).
#
#   fase arranque-core  o core arranca sem dispositivos (NRF, associação PFCP, NG Setup)
#   fase ligar          os três dispositivos ligam ao mesmo tempo: registo + sessão
#   fase normal (7 min) sensor rápido envia de 30 em 30 s; atuador recebe um comando de 50 em 50 s
#                       e responde (ping a partir da rede do UPF); sensor lento envia de 3 em 3 min
#   fase incidentes     o sensor lento perde a cobertura (tc netem) até o AMF o desregistar; 1 min
#                       depois de perder a cobertura, o atuador é desligado (deregister switch-off)
#   fase regresso       o sensor lento volta, pede uma sessão nova e envia uma vez
#
# Tempo acelerado: T3512 = 60 s (variante t3512-60s) em vez de 9 min, e sensor lento de 3 em 3 min em
# vez de 15. O atuador é de 50 em 50 s para nunca ficar mais de 60 s parado (num T3512 real de 9 min,
# um comando de 2 em 2 min também não provocaria registos periódicos). O sensor rápido é real.
#
# Cada envio de um sensor são 2 pings: o UERANSIM em CM-IDLE descarta o primeiro pacote (só pede a
# ligação), o segundo chega à rede. Um modem real guardava o primeiro.
#
# Saída: <nome>.pcapng (N2, SBI, N4, N3), <nome>.eventos ("<início> <fim> <nome>"), <nome>-logs/.
# Análise: scripts/analisar-historia.py <pasta>/<nome>.pcapng
#
# Uso: [VARIANTE=sem-scp] ./scripts/historia-fabrica.sh <pasta-de-saída> [nome]
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1"); NOME=${2:-historia}
mkdir -p "$OUT"
# Variante do core; as outras são sempre aplicadas. ATENÇÃO: a t3512-60s traz o seu amf.yaml (com SCP),
# que anula o de variantes que também mudam o amf.yaml (sem-scp): essas não combinam com a história.
VARIANTE=${VARIANTE:-baseline}
F=docker-compose.yml
[ "$VARIANTE" != baseline ] && F=$F:variantes/$VARIANTE/compose.yml
export COMPOSE_FILE=$F:variantes/t3512-60s/compose.yml:variantes/idle/compose.yml:variantes/fabrica3/compose.yml
DISPOSITIVOS="sensor-rapido atuador sensor-lento"
EV="$OUT/$NOME.eventos"
NORMAL=${NORMAL:-420}

agora() { date +%s.%N; }
dormir_ate() { python3 -c "import sys,time; time.sleep(max(0.0, float(sys.argv[1]) - time.time()))" "$1"; }
mais() { python3 -c "import sys; print(f'{float(sys.argv[1]) + float(sys.argv[2]):.3f}')" "$1" "$2"; }
evento() { echo "$1 $2 $3" >> "$EV"; }   # <início> <fim> <nome>
cli() { docker compose exec -T "$1" nr-cli "imsi-99970000000000$2" -e "$3" >> "$OUT/$NOME.cli" 2>&1 || true; }
ip_tun() { docker compose exec -T "$1" ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^uesimtun/ { sub(/\/.*/, "", $4); ip = $4 } END { print ip }'; }
tun() { docker compose exec -T "$1" ip -4 -o addr show 2>/dev/null | awk '$2 ~ /^uesimtun/ { t = $2 } END { print t }'; }

# Um envio de um sensor: 2 pings para o UPF pelo túnel mais recente
enviar() {  # <serviço> <rótulo>
    t0=$(agora)
    docker compose exec -T "$1" ping -c 2 -i 0.5 -W 2 -I "$(tun "$1")" 10.45.0.1 >> "$OUT/$NOME.ping-$1" 2>&1 || true
    evento "$t0" "$(agora)" "$2"
}

# Ciclo de envios de um dispositivo, com horas absolutas: <início> + <desvio> + k × <período> < <fim>
ciclo() {  # <início> <desvio> <período> <fim> <comando...>
    ini=$1; desvio=$2; periodo=$3; fim=$4; shift 4
    k=0
    while :; do
        alvo=$(mais "$ini" "$(python3 -c "print($desvio + $k * $periodo)")")
        python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$alvo" "$fim" || break
        dormir_ate "$alvo"
        "$@"
        k=$((k + 1))
    done
}

comando_atuador() {
    t0=$(agora)
    docker run --rm --network "container:$UPF" core-simplified/ueransim:v3.3.0 \
        ping -c 1 -W 5 "$IP_ATUADOR" >> "$OUT/$NOME.ping-comando" 2>&1 || true
    evento "$t0" "$(agora)" atuador-comando
}

# --- arranque do core ---
COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up --no-start >/dev/null 2>&1
: > "$EV"
dumpcap -q -i br-n2 -i br-sbi -i br-n4 -i br-n3 -w "$OUT/$NOME.pcapng" >/dev/null 2>&1 &
CAP=$!
sleep 2
t0=$(agora)
docker compose up -d $(docker compose config --services | grep -vx -e ue -e sensor-rapido -e atuador -e sensor-lento) >/dev/null 2>&1
sleep 25
evento "$t0" "$(agora)" fase:arranque-core

# --- os três dispositivos ligam ---
t0=$(agora)
docker compose up -d $DISPOSITIVOS >/dev/null 2>&1
for d in $DISPOSITIVOS; do
    espera=0
    until docker compose logs "$d" 2>/dev/null | grep -q "PDU Session establishment is successful"; do
        espera=$((espera + 1)); [ "$espera" -gt 60 ] && { echo "$d sem sessão" >&2; exit 1; }
        sleep 1
    done
done
UPF=$(docker compose ps -q upf)
IP_ATUADOR=$(ip_tun atuador)
sleep 20                                      # adormecem ao fim de 10 s sem tráfego
evento "$t0" "$(agora)" fase:ligar

# --- funcionamento normal ---
T_N=$(agora); FIM_N=$(mais "$T_N" "$NORMAL")
ciclo "$T_N" 0 30 "$FIM_N" enviar sensor-rapido rapido-envio &
R1=$!
ciclo "$T_N" 17 50 "$FIM_N" comando_atuador &
A1=$!
ciclo "$T_N" 24 180 "$FIM_N" enviar sensor-lento lento-envio &
L1=$!
wait $A1 $L1
dormir_ate "$FIM_N"
evento "$T_N" "$(agora)" fase:normal

# --- incidentes: o sensor rápido continua; o lento perde a cobertura; o atuador é desligado ---
T_I=$(agora)
wait $R1
ciclo "$T_I" 0 30 "$(mais "$T_I" 3600)" enviar sensor-rapido rapido-envio &
R2=$!
IF_LENTO=$(docker compose exec -T sensor-lento ip -4 -o addr show | awk '$4 ~ /^10\.100\.5\./ { print $2 }')
docker compose exec -T sensor-lento tc qdisc add dev "$IF_LENTO" root netem loss 100%
T_SEM=$(agora)
dormir_ate "$(mais "$T_I" 60)"
t0=$(agora); cli atuador 2 "deregister switch-off"; sleep 2
evento "$t0" "$(agora)" atuador-desligar
espera=0
until docker compose logs amf 2>/dev/null | grep -q "imsi-999700000000003\] Implicit De-registered"; do
    espera=$((espera + 5)); [ "$espera" -gt 1200 ] && { echo "sensor lento sem desregisto implícito" >&2; break; }
    sleep 5
done
sleep 10
docker compose exec -T sensor-lento tc qdisc del dev "$IF_LENTO" root
T_VOLTA=$(agora)
evento "$T_SEM" "$T_VOLTA" lento-sem-cobertura
evento "$T_I" "$T_VOLTA" fase:incidentes

# --- regresso do sensor lento ---
# O UERANSIM ignora o "PDU session status" do Registration Accept (fica com o túnel antigo sem sessão
# no core); um modem real pedia logo uma sessão nova, aqui pede-se à mão. O pedido pelo nr-cli é
# barrado à primeira pelo UAC do UERANSIM e só segue numa retransmissão do T3580.
sleep 5
antes=$(docker compose logs sensor-lento 2>/dev/null | grep -c "PDU Session establishment is successful" || true)
t0=$(agora); cli sensor-lento 3 "ps-establish IPv4 --sst 1 --dnn internet"
espera=0
until [ "$(docker compose logs sensor-lento 2>/dev/null | grep -c "PDU Session establishment is successful")" -gt "$antes" ]; do
    espera=$((espera + 1)); [ "$espera" -gt 90 ] && { echo "sensor lento sem sessão nova" >&2; break; }
    sleep 1
done
evento "$t0" "$(agora)" lento-nova-sessao
sleep 20
enviar sensor-lento lento-envio
sleep 60
kill $R2 2>/dev/null || true
sleep 12
evento "$T_VOLTA" "$(agora)" fase:regresso

# --- fim ---
sleep 2
kill $CAP; wait $CAP 2>/dev/null || true
mkdir -p "$OUT/$NOME-logs"
for s in $(docker compose config --services); do
    docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$NOME-logs/$s.log" 2>&1
done
{
    echo "compose_file=$COMPOSE_FILE"
    (cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)")
    (cd ../UERANSIM && echo "ueransim=$(git describe --tags --dirty)")
    echo "ip_atuador=$IP_ATUADOR"
} > "$OUT/$NOME.meta"
for d in sensor-rapido sensor-lento; do
    echo "ips_$d=$(grep -o 'TUN interface\[uesimtun[0-9]*, [0-9.]*\]' "$OUT/$NOME-logs/$d.log" | sed 's/.*, //; s/\]//' | tr '\n' ' ')" >> "$OUT/$NOME.meta"
done
COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
echo "historia -> $OUT/$NOME"
