#!/bin/sh
# Varrimento do cenário fábrica: cruza o período de transmissão dos dispositivos com o
# temporizador de inatividade do gNB.
#
# É a relação entre os dois que decide a carga do core: se o temporizador for maior do que o
# período, os dispositivos nunca adormecem e o ciclo desaparece.
#
# Uso:
#   matriz completa:  [TEMPORIZADORES="5 10 30 60"] [PERIODOS="30 120 300 900"] \
#                       ./scripts/varrimento-fabrica.sh <pasta-de-saída>
#   pontos escolhidos: PONTOS="10:30 60:30 10:900" ./scripts/varrimento-fabrica.sh <pasta>
#                      (cada ponto é temporizador:período, em segundos)
#
#   Opções comuns: [N_UES=20] [VARIANTE=baseline] [REPETICOES=1] [LIMPAR=1]
#
# A janela de cada ponto é 6x o período, entre 5 minutos e 1 hora, para o regime pesar mais do
# que as pontas. A matriz completa por omissão são 16 pontos e cerca de 8 horas.
#
# Com REPETICOES > 1 as corridas são INTERCALADAS: todos os pontos uma vez, depois todos outra vez.
# Assim, uma deriva lenta do hospedeiro ao longo da noite (o custo de fundo subiu de 1,6 para
# 2,2 ms/s numa noite) afeta todos os pontos por igual, em vez de se confundir com um deles.
#
# LIMPAR=1 apaga a captura depois de a analisar (ficam as métricas e os registos).
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
CONF=variantes/idle/config/ueransim/gnb.yaml
ORIGINAL=$(awk '/^inactivityTimer:/{print $2}' "$CONF")
trap 'sed -i "s/^inactivityTimer: [0-9]*/inactivityTimer: $ORIGINAL/" "$CONF"' EXIT INT TERM

if [ -z "$PONTOS" ]; then
    for T in ${TEMPORIZADORES:-5 10 30 60}; do
        for P in ${PERIODOS:-30 120 300 900}; do
            PONTOS="$PONTOS $T:$P"
        done
    done
fi
REPETICOES=${REPETICOES:-1}

mkdir -p "$OUT"
echo "### $(date +%H:%M:%S)  pontos:$PONTOS  repetições: $REPETICOES"
R=1
while [ "$R" -le "$REPETICOES" ]; do
    for PONTO in $PONTOS; do
        T=${PONTO%%:*}
        P=${PONTO##*:}
        sed -i "s/^inactivityTimer: [0-9]*/inactivityTimer: $T/" "$CONF"

        # Janela de 6 períodos, entre 5 minutos e 1 hora. Com 3 períodos, os dispositivos esparsos só
        # transmitiam duas vezes e os registos periódicos das pontas da janela pesavam tanto como os
        # do regime (60% em vez de 50% dos despertares, com p=15 min).
        D=$((P * 6))
        [ "$D" -lt 300 ] && D=300
        [ "$D" -gt 3600 ] && D=3600

        NOME="t${T}s-p${P}s"
        [ "$REPETICOES" -gt 1 ] && NOME="$NOME-r$R"
        echo "### $(date +%H:%M:%S)  [$R/$REPETICOES] temporizador ${T}s, período ${P}s, janela ${D}s"
        N_UES=${N_UES:-20} PERIODO=$P DURACAO=$D VARIANTE=${VARIANTE:-baseline} \
            ./scripts/cenario-fabrica.sh "$OUT" "$NOME" || { echo "FALHOU: $NOME"; continue; }
        ./scripts/analisar-fabrica.py "$OUT/$NOME.pcapng" || true
        [ "${LIMPAR:-0}" = 1 ] && rm -f "$OUT/$NOME.pcapng"
        echo
    done
    R=$((R + 1))
done
echo "### $(date +%H:%M:%S) varrimento terminado"
