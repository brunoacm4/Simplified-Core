#!/bin/sh
# Memória de cada função do core, parado e sem dispositivos, ao longo de várias horas.
#
# Pergunta: a memória da SCP e da NRF cresce ~4–5 MiB por hora cada uma (medido em 4 corridas de 1 h).
# Estabiliza — memória que o processo reserva e depois reutiliza — ou cresce sem limite, ou seja, uma
# fuga? Sem dispositivos, só os heartbeats (cada função → NRF, a cada 10 s) estão a acontecer.
#
# Uso: [VARIANTE=baseline] [HORAS=3] [INTERVALO=300] ./scripts/memoria-repouso.sh <pasta> <nome>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1"); NAME=$2
VARIANTE=${VARIANTE:-baseline}
HORAS=${HORAS:-3}
INTERVALO=${INTERVALO:-300}
if [ "$VARIANTE" = baseline ]; then export COMPOSE_FILE=docker-compose.yml
else export COMPOSE_FILE=docker-compose.yml:variantes/$VARIANTE/compose.yml; fi
mkdir -p "$OUT"
F="$OUT/$NAME.memoria.tsv"; : > "$F"

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
CORE=$(docker compose config --services | grep -vxE 'ue|gnb' | tr '\n' ' ')
docker compose up -d $CORE >/dev/null 2>&1

FIM=$(($(date +%s) + HORAS * 3600))
while [ "$(date +%s)" -lt "$FIM" ]; do
    agora=$(date +%s)
    for s in $(docker compose ps --services --status running); do
        id=$(docker compose ps -q "$s")
        printf '%s\t%s\t%s\n' "$agora" "$s" \
            "$(cat /sys/fs/cgroup/system.slice/docker-$id.scope/memory.current)"
    done >> "$F"
    sleep "$INTERVALO"
done
echo "$NAME ($VARIANTE, ${HORAS} h): $F"
