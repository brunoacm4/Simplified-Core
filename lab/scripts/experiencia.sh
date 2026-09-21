#!/bin/sh
# Compara a baseline com uma variante: N corridas de cada, alternadas (baseline, variante, baseline, ...)
# para que variações da máquina ao longo do tempo afetem as duas por igual.
#
# Uso: ./scripts/experiencia.sh <pasta> <variante> <N>
#   ex.: ./scripts/experiencia.sh ../notes/experiencias/2026-09-18-sem-scp sem-scp 5
# Resultado: <pasta>/baseline/ e <pasta>/<variante>/ com capturas e métricas;
#            comparação com ./scripts/comparar.py <pasta>/baseline <pasta>/<variante>
set -e
cd "$(dirname "$0")/.."
PASTA=$1; VAR=$2; N=$3
mkdir -p "$PASTA/baseline" "$PASTA/$VAR"
i=1
while [ "$i" -le "$N" ]; do
    for v in baseline "$VAR"; do
        VARIANTE=$v ./scripts/capturar-registo.sh "$PASTA/$v" "corrida$i"
        ./scripts/analisar.py "$PASTA/$v/corrida$i.pcapng" | tail -n +2 | sed "s/^/    /"
    done
    i=$((i + 1))
done
./scripts/comparar.py "$PASTA/baseline" "$PASTA/$VAR"
