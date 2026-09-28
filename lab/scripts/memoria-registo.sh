#!/bin/sh
# Memória por função do core ao longo de um ciclo registo → desregisto.
#
# Pergunta: a memória que cada função ganha por dispositivo é estado que se liberta quando o
# dispositivo sai, ou memória que o processo reservou e não devolve? Com a SCP ganhava 239 KiB por
# dispositivo, mais do que o próprio AMF, só para reencaminhar mensagens.
#
# Uso: [VARIANTE=baseline] [N_UES=100] [CICLOS=1] ./scripts/memoria-registo.sh <pasta-de-saída> <nome>
#
# Instantes lidos (memória de cada contentor, nos cgroups do hospedeiro):
#   0     core sozinho, sem dispositivos
#   r<c>  no ciclo c, com N dispositivos registados e com sessão
#   d<c>  no ciclo c, um minuto depois de todos se desregistarem (switch-off)
#   fim   cinco minutos depois do último desregisto, sem nada a acontecer
#
# Com CICLOS > 1 separa-se retenção de fuga: se a memória cresce o mesmo em cada ciclo, não está a ser
# reutilizada (fuga); se estabiliza depois do primeiro, o processo guardou-a e volta a usá-la.
# Entre instantes passam poucos minutos; a SCP e a NRF crescem ~4–5 MiB/hora sozinhas (heartbeats),
# o que dá menos de 1 MiB no total desta corrida.
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1"); NAME=$2
VARIANTE=${VARIANTE:-baseline}
export N_UES=${N_UES:-100}
if [ "$VARIANTE" = baseline ]; then export COMPOSE_FILE=docker-compose.yml
else export COMPOSE_FILE=docker-compose.yml:variantes/$VARIANTE/compose.yml; fi
mkdir -p "$OUT"
F="$OUT/$NAME.memoria.tsv"; : > "$F"

snap() {
    for s in $(docker compose ps --services --status running); do
        id=$(docker compose ps -q "$s")
        printf '%s\t%s\t%s\t%s\n' "$1" "$(date +%s)" "$s" \
            "$(cat /sys/fs/cgroup/system.slice/docker-$id.scope/memory.current)"
    done >> "$F"
}

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
CORE=$(docker compose config --services | grep -vxE 'ue|gnb' | tr '\n' ' ')
docker compose up -d $CORE gnb >/dev/null 2>&1
sleep 60
snap 0

c=1
while [ "$c" -le "${CICLOS:-1}" ]; do
    docker compose up -d --force-recreate ue >/dev/null 2>&1
    espera=0
    while [ "$espera" -lt 240 ]; do
        [ "$(docker compose logs ue 2>/dev/null | grep -c 'PDU Session establishment is successful')" -ge "$N_UES" ] && break
        sleep 5; espera=$((espera + 5))
    done
    sleep 60
    snap "r$c"

    # Desregistar todos: switch-off é o que um dispositivo faz ao ser desligado.
    for ue in $(docker compose exec -T ue nr-cli --dump); do
        docker compose exec -T ue nr-cli "$ue" -e "deregister switch-off" >/dev/null 2>&1 || true
    done
    sleep 60
    snap "d$c"
    c=$((c + 1))
done
sleep 300
snap fim

docker compose logs --no-color amf 2>/dev/null | grep -ciE "deregist" > "$OUT/$NAME.desregistos" || true
echo "$NAME ($VARIANTE, $N_UES dispositivos): $F"
