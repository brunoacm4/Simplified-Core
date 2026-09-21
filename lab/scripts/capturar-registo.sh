#!/bin/sh
# Corrida "do zero": derruba o lab, captura N2/SBI/N4 desde o arranque do core,
# mede CPU/memória por contentor, arranca o UE depois de o core estabilizar e guarda tudo.
#
# Uso: [VARIANTE=sem-scp] [N_UES=50] ./scripts/capturar-registo.sh <pasta-de-saída> <nome>
#   ex.: ./scripts/capturar-registo.sh ../notes/experiencias/x/baseline corrida1
#        VARIANTE=sem-scp ./scripts/capturar-registo.sh ../notes/experiencias/x/sem-scp corrida1
#
# Gera em <pasta>:
#   <nome>.pcapng       captura (br-n2, br-sbi, br-n4)
#   <nome>.t_ue         instante (epoch) em que o UE foi arrancado
#   <nome>.recursos.tsv CPU acumulada e memória por serviço em 3 instantes:
#                       A = t_ue - JANELA, B = t_ue, C = t_ue + JANELA
#   <nome>.meta         variante, versões e parâmetros da corrida
#   <nome>-logs/        logs de cada serviço
# O assinante tem de existir na base de dados (volume mongodb-data).
set -e
cd "$(dirname "$0")/.."

OUT=$(realpath "$1"); NAME=$2
VARIANTE=${VARIANTE:-baseline}
export N_UES=${N_UES:-1}          # nº de UEs simulados (IMSIs consecutivos; têm de existir na BD)
ESPERA_CORE=${ESPERA_CORE:-25}   # segundos entre o arranque do core e o UE
JANELA=${JANELA:-10}             # janela de medição de fundo (antes do UE) e com UE (depois)

if [ "$VARIANTE" = baseline ]; then
    export COMPOSE_FILE=docker-compose.yml
else
    export COMPOSE_FILE=docker-compose.yml:variantes/$VARIANTE/compose.yml
fi
mkdir -p "$OUT/$NAME-logs"

CORE=$(docker compose config --services | grep -vx ue | tr '\n' ' ')

# CPU acumulada (µs) e memória (bytes) de cada contentor, lidas no host (cgroup v2),
# para não gastar CPU dentro dos contentores ao medir.
snap() {
    for s in $(docker compose ps --services --status running); do
        id=$(docker compose ps -q "$s")
        cg=/sys/fs/cgroup/system.slice/docker-$id.scope
        cpu=$(awk '/^usage_usec/{print $2}' "$cg/cpu.stat")
        mem=$(cat "$cg/memory.current")
        printf '%s\t%s\t%s\t%s\n' "$1" "$s" "$cpu" "$mem"
    done >> "$OUT/$NAME.recursos.tsv"
}

# Derruba SEMPRE o lab completo (modelo da baseline), senão serviços que a variante desativa
# (ex.: a SCP) ficariam a correr da corrida anterior e contaminariam as medições.
COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up --no-start >/dev/null 2>&1          # cria redes/bridges sem arrancar nada
: > "$OUT/$NAME.recursos.tsv"

dumpcap -q -i br-n2 -i br-sbi -i br-n4 -w "$OUT/$NAME.pcapng" >/dev/null 2>&1 &
CAP=$!
sleep 2

docker compose up -d $CORE >/dev/null 2>&1
sleep $((ESPERA_CORE - JANELA))
snap A
sleep "$JANELA"
snap B
date +%s.%N > "$OUT/$NAME.t_ue"
docker compose up -d ue >/dev/null 2>&1
sleep "$JANELA"
snap C

kill $CAP; wait $CAP 2>/dev/null || true

for s in $(docker compose config --services); do
    docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$NAME-logs/$s.log" 2>&1
done

cat > "$OUT/$NAME.meta" <<EOF
variante=$VARIANTE
data=$(date -Iseconds)
open5gs=$(git -C ../open5gs describe --tags)
ueransim=$(git -C ../UERANSIM describe --tags)
compose_file=$COMPOSE_FILE
espera_core=$ESPERA_CORE
janela=$JANELA
n_ues=$N_UES
servicos_core=$CORE
EOF
echo "$NAME ($VARIANTE): $OUT/$NAME.pcapng"
