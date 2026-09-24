#!/bin/sh
# Varrimento do cenário fábrica: cruza o período de transmissão dos dispositivos com o
# temporizador de inatividade do gNB.
#
# É a relação entre os dois que decide a carga do core: se o temporizador for maior do que o
# período, os dispositivos nunca adormecem e o ciclo desaparece.
#
# Uso: [N_UES=20] [VARIANTE=baseline] [TEMPORIZADORES="5 10 30 60"] [PERIODOS="30 120 300 900"] \
#        [LIMPAR=1] ./scripts/varrimento-fabrica.sh <pasta-de-saída>
#
# A janela de cada ponto é 6x o período, entre 5 minutos e 1 hora, para o regime pesar mais do
# que as pontas. Com os valores por omissão são 16 pontos e cerca de 8 horas.
# LIMPAR=1 apaga a captura depois de a analisar (ficam as métricas); poupa muito disco.
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
CONF=variantes/idle/config/ueransim/gnb.yaml
ORIGINAL=$(awk '/^inactivityTimer:/{print $2}' "$CONF")
trap 'sed -i "s/^inactivityTimer: [0-9]*/inactivityTimer: $ORIGINAL/" "$CONF"' EXIT INT TERM

mkdir -p "$OUT"
for T in ${TEMPORIZADORES:-5 10 30 60}; do
    sed -i "s/^inactivityTimer: [0-9]*/inactivityTimer: $T/" "$CONF"
    for P in ${PERIODOS:-30 120 300 900}; do
        # Janela de 6 períodos, entre 5 minutos e 1 hora. Com 3 períodos, os dispositivos esparsos só
        # transmitiam duas vezes e os registos periódicos das pontas da janela pesavam tanto como os
        # do regime (60% em vez de 50% dos despertares, com p=15 min).
        D=$((P * 6))
        [ "$D" -lt 300 ] && D=300
        [ "$D" -gt 3600 ] && D=3600
        NOME="t${T}s-p${P}s"
        echo "### $(date +%H:%M:%S)  temporizador ${T}s, período ${P}s, janela ${D}s"
        N_UES=${N_UES:-20} PERIODO=$P DURACAO=$D VARIANTE=${VARIANTE:-baseline} \
            ./scripts/cenario-fabrica.sh "$OUT" "$NOME" || { echo "FALHOU: $NOME"; continue; }
        ./scripts/analisar-fabrica.py "$OUT/$NOME.pcapng" || true
        [ "${LIMPAR:-0}" = 1 ] && rm -f "$OUT/$NOME.pcapng"
        echo
    done
done
echo "### $(date +%H:%M:%S) varrimento terminado"
