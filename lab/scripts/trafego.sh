#!/bin/sh
# Gera tráfego periódico em cada túnel do UE, para simular dispositivos industriais
# que transmitem de vez em quando e adormecem pelo meio.
#
# Corre DENTRO do contentor do UE:
#   docker compose exec -T ue sh -s <periodo> <duracao> < scripts/trafego.sh
#
# Cada interface uesimtunN envia um pacote de <periodo> em <periodo> segundos, com um
# desfasamento inicial aleatório para os dispositivos não transmitirem todos no mesmo instante
# (numa fábrica real não estão sincronizados, e sincronizá-los criaria picos artificiais).
#
# TODO: passar de ping para UDP só de subida. Um sensor real só envia; o ping gera resposta,
# logo há tráfego também na descida. Não afeta o temporizador de inatividade (as duas direções
# acontecem no mesmo instante), mas é menos realista em bytes e em número de pacotes.
PERIODO=${1:-30}
DURACAO=${2:-300}
DESTINO=${3:-10.45.0.1}

FIM=$(($(date +%s) + DURACAO))

for IF in $(ls /sys/class/net | grep '^uesimtun'); do
    (
        # desfasamento inicial: 0..PERIODO segundos
        sleep $(( $(od -An -N2 -tu2 < /dev/urandom | tr -d ' ') % PERIODO ))
        while [ "$(date +%s)" -lt "$FIM" ]; do
            ping -c 1 -W 2 -q -I "$IF" "$DESTINO" >/dev/null 2>&1
            sleep "$PERIODO"
        done
    ) &
done

wait
