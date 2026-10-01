#!/bin/sh
# Experiência do T3512 dinâmico: as três variantes na mesma população mista, com vítimas.
#
#   baseline         T3512 fixo de 9 min (Open5GS por omissão)
#   t3512-30min      T3512 fixo de 30 min
#   t3512-dinamico   9 min à partida, duplicado a cada registo periódico, até 1 hora
#
# População (decisão de 2026-09-28): 10 dispositivos que transmitem de 30 em 30 s e 10 de 15 em
# 15 min, mais 4 vítimas (2 + 2) desligadas de repente no fim da janela. Cada corrida: aprendizagem
# de 30 min, janela de 1 hora, e depois a espera até o AMF dar as vítimas como desregistadas (até
# 68 min com o T3512 de 30 min). Cerca de 7 horas por ronda.
#
# Com REPETICOES > 1 as variantes são intercaladas (todas uma vez, depois todas outra vez), como no
# varrimento, para uma deriva lenta do hospedeiro afetar as três por igual.
#
# Uso: [REPETICOES=1] ./scripts/experiencia-t3512.sh <pasta-de-saída>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
REPETICOES=${REPETICOES:-1}
export N_UES=20 POPULACAO="30:10 900:10" VITIMAS="30:2 900:2" APRENDIZAGEM=1800 DURACAO=3600
mkdir -p "$OUT"

for r in $(seq 1 "$REPETICOES"); do
    for v in baseline t3512-30min t3512-dinamico; do
        VARIANTE=$v ./scripts/cenario-fabrica.sh "$OUT" "$v-r$r"
        # Uma análise que falhe não pode parar a noite: as capturas e os logs ficam para repetir
        ./scripts/analisar-fabrica.py "$OUT/$v-r$r.pcapng" > "$OUT/$v-r$r.fabrica.txt" 2>&1 || true
        ./scripts/analisar-t3512.py "$OUT/$v-r$r.meta" > "$OUT/$v-r$r.t3512.txt" 2>&1 || true
    done
done

COMPOSE_FILE=docker-compose.yml:variantes/vitimas/compose.yml docker compose down --remove-orphans >/dev/null 2>&1
