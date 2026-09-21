#!/bin/sh
# Cenário "fábrica" (S2): N dispositivos registam-se, transmitem de PERIODO em PERIODO segundos
# e adormecem pelo meio (temporizador de inatividade do gNB ligado, variante 'idle').
#
# Mede a fase de regime, não o arranque: o registo inicial de todos os dispositivos fica fora
# da janela de medição.
#
# Uso: [VARIANTE=sem-scp] [N_UES=20] [PERIODO=30] [DURACAO=300] \
#        ./scripts/cenario-fabrica.sh <pasta-de-saída> <nome>
#
# Gera em <pasta>:
#   <nome>.pcapng        captura (br-n2, br-sbi, br-n4) de toda a corrida
#   <nome>.recursos.tsv  CPU acumulada e memória por serviço em 2 instantes (I=início, F=fim da janela)
#   <nome>.meta          parâmetros da corrida, incluindo os limites da janela de medição
#   <nome>-logs/         logs de cada serviço
# Os assinantes têm de existir na base de dados (ver scripts/add-subscribers.sh).
set -e
cd "$(dirname "$0")/.."

OUT=$(realpath "$1"); NAME=$2
VARIANTE=${VARIANTE:-baseline}    # variante do CORE (baseline, sem-scp, ...); o 'idle' é sempre aplicado
export N_UES=${N_UES:-20}
PERIODO=${PERIODO:-30}            # segundos entre transmissões de cada dispositivo
DURACAO=${DURACAO:-300}           # duração da janela de medição, em segundos
ESPERA_CORE=${ESPERA_CORE:-25}    # segundos entre o arranque do core e os UEs
ESPERA_REGISTO=${ESPERA_REGISTO:-180}  # tempo máximo à espera que todos os UEs tenham sessão

if [ "$VARIANTE" = baseline ]; then
    export COMPOSE_FILE=docker-compose.yml:variantes/idle/compose.yml
else
    export COMPOSE_FILE=docker-compose.yml:variantes/$VARIANTE/compose.yml:variantes/idle/compose.yml
fi
mkdir -p "$OUT/$NAME-logs"

CORE=$(docker compose config --services | grep -vx ue | tr '\n' ' ')

snap() {
    for s in $(docker compose ps --services --status running); do
        id=$(docker compose ps -q "$s")
        cg=/sys/fs/cgroup/system.slice/docker-$id.scope
        cpu=$(awk '/^usage_usec/{print $2}' "$cg/cpu.stat")
        mem=$(cat "$cg/memory.current")
        printf '%s\t%s\t%s\t%s\n' "$1" "$s" "$cpu" "$mem"
    done >> "$OUT/$NAME.recursos.tsv"
}

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up --no-start >/dev/null 2>&1
: > "$OUT/$NAME.recursos.tsv"

dumpcap -q -i br-n2 -i br-sbi -i br-n4 -w "$OUT/$NAME.pcapng" >/dev/null 2>&1 &
CAP=$!
sleep 2

docker compose up -d $CORE >/dev/null 2>&1
sleep "$ESPERA_CORE"
docker compose up -d ue >/dev/null 2>&1

# Esperar que todos os dispositivos tenham sessão PDU antes de começar a medir.
espera=0
while [ "$espera" -lt "$ESPERA_REGISTO" ]; do
    prontos=$(docker compose logs ue 2>/dev/null | grep -c "PDU Session establishment is successful" || true)
    [ "$prontos" -ge "$N_UES" ] && break
    sleep 5; espera=$((espera + 5))
done
prontos=$(docker compose logs ue 2>/dev/null | grep -c "PDU Session establishment is successful" || true)
[ "$prontos" -ge "$N_UES" ] || echo "AVISO: só $prontos de $N_UES dispositivos com sessão"

# Deixar os dispositivos adormecer antes de medir: sem isto a janela apanhava a cauda do arranque.
sleep 20

T_INICIO=$(date +%s.%N)
snap I
docker compose exec -T ue sh -s "$PERIODO" "$DURACAO" < scripts/trafego.sh >/dev/null 2>&1 || true
snap F
T_FIM=$(date +%s.%N)

kill $CAP; wait $CAP 2>/dev/null || true

for s in $(docker compose config --services); do
    docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$NAME-logs/$s.log" 2>&1
done

cat > "$OUT/$NAME.meta" <<EOF
cenario=fabrica
variante=$VARIANTE
data=$(date -Iseconds)
open5gs=$(git -C ../open5gs describe --tags)
ueransim=$(git -C ../UERANSIM describe --tags --always)
compose_file=$COMPOSE_FILE
n_ues=$N_UES
periodo=$PERIODO
duracao=$DURACAO
ues_prontos=$prontos
t_inicio=$T_INICIO
t_fim=$T_FIM
servicos_core=$CORE
EOF
echo "$NAME (fabrica/$VARIANTE): $N_UES dispositivos, periodo ${PERIODO}s, janela ${DURACAO}s -> $OUT/$NAME.pcapng"
