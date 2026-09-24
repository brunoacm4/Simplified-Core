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

# Cada dispositivo dorme no máximo até FIM, nunca mais do que isso.
#
# Na primeira versão, cada ciclo dormia um período inteiro depois da última transmissão, e a janela
# de medição ficava com uma cauda sem tráfego (até 46% com períodos de 15 minutos). Matar os ciclos no
# fim também não resolvia: o 'sleep' de cada ciclo ficava órfão, agarrado à saída do docker exec, e
# o docker exec só terminava quando o último acabava de dormir. Limitar cada espera ao tempo que
# falta até FIM elimina a cauda na origem.
espera() {
    resto=$((FIM - $(date +%s)))
    [ "$resto" -le 0 ] && return 1
    if [ "$1" -lt "$resto" ]; then sleep "$1"; else sleep "$resto"; return 1; fi
}

for IF in $(ls /sys/class/net | grep '^uesimtun'); do
    (
        # desfasamento inicial: 0..PERIODO segundos
        espera $(( $(od -An -N2 -tu2 < /dev/urandom | tr -d ' ') % PERIODO )) || exit 0
        while [ "$(date +%s)" -lt "$FIM" ]; do
            ping -c 1 -W 2 -q -I "$IF" "$DESTINO" >/dev/null 2>&1
            espera "$PERIODO" || break
        done
    ) </dev/null >/dev/null 2>&1 &
done

wait
