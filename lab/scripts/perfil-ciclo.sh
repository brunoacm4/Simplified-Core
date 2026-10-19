#!/bin/sh
# Perfil de CPU do ciclo acordar/adormecer: em que trabalho gastam o AMF, o SMF e o UPF (e a SCP, na
# baseline) o seu CPU quando N dispositivos acordam e adormecem? Responde a "quanto do custo do ciclo
# é HTTP/JSON entre funções" (notes/core/historia-fabrica.md, junção AMF+SMF).
#
# Carga: N_UES dispositivos a enviar de PERIODO em PERIODO s (PERIODO > temporizador de inatividade
# do gNB, 10 s, para cada envio ser um ciclo completo) durante DURACAO s. Durante a carga corre um
# perf record por função (contentor auxiliar core-simplified/perf:<IMAGEM> no espaço de processos da
# função, ver images/perf/Dockerfile). Os ciclos são contados na captura do N2.
#
#   IMAGEM=o2  build como em produção (-O2, a baseline do lab desde 2026-10-15)
#   IMAGEM=o0  build sem otimização (variante o0, como nas medições até 2026-10-15)
#
# Pilhas desenroladas com DWARF: as bibliotecas do sistema (libc, libcurl, libnghttp2) não têm frame
# pointers, e com -g as pilhas que passam por elas perdiam o chamador (tentado a 2026-10-11).
#
# Saída: <nome>[-repouso]-<função>.data (perf) e .script (pilhas em texto), <nome>[-repouso].cpu-antes/
# -depois (usage_usec dos cgroups), <nome>.pcapng (N2), <nome>.meta.
# Análise: scripts/analisar-perfil.py <pasta>/<nome>.meta
#
# Uso: [IMAGEM=o2] [VARIANTE=sem-scp|baseline] [N_UES=100] [PERIODO=15] [DURACAO=300] [FREQ=999] \
#        ./scripts/perfil-ciclo.sh <pasta> <nome>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1"); NOME=$2
IMAGEM=${IMAGEM:-o2}; VARIANTE=${VARIANTE:-sem-scp}
export N_UES=${N_UES:-100}
PERIODO=${PERIODO:-15}; DURACAO=${DURACAO:-300}; FREQ=${FREQ:-999}
REPOUSO=${REPOUSO:-60}   # janela sem tráfego, perfilada antes da carga e descontada na análise
mkdir -p "$OUT"

F=docker-compose.yml
[ "$VARIANTE" != baseline ] && F=$F:variantes/$VARIANTE/compose.yml
F=$F:variantes/idle/compose.yml
[ "$IMAGEM" = o0 ] && F=$F:variantes/o0/compose.yml
export COMPOSE_FILE=$F
NFS="amf smf upf"; [ "$VARIANTE" = baseline ] && NFS="$NFS scp"

cpu() {
    for s in $NFS; do
        id=$(docker compose ps -q "$s")
        awk -v s="$s" '/^usage_usec/ { print s "\t" $2 }' "/sys/fs/cgroup/system.slice/docker-$id.scope/cpu.stat"
    done
}

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up -d $(docker compose config --services | grep -vx ue) >/dev/null 2>&1
sleep 25
docker compose up -d ue >/dev/null 2>&1
espera=0
until [ "$(docker compose logs ue 2>/dev/null | grep -c 'PDU Session establishment is successful')" -ge "$N_UES" ]; do
    espera=$((espera + 5)); [ "$espera" -gt 240 ] && { echo "AVISO: nem todos os UEs têm sessão" >&2; break; }
    sleep 5
done
sleep 20                                      # adormecem todos antes de começar

# perf record em cada função durante <segundos>; os ficheiros ficam <nome><sufixo>-<função>.data
perfilar() {  # <sufixo> <segundos>
    PERFS=""
    for s in $NFS; do
        docker run --rm --pid="container:lab-$s-1" --cap-add PERFMON --cap-add SYS_PTRACE \
            --security-opt seccomp=unconfined -v "$OUT":/out "core-simplified/perf:$IMAGEM" \
            record -F "$FREQ" --call-graph dwarf,16384 -p 1 -o "/out/$NOME$1-$s.data" -- sleep "$2" \
            > "$OUT/$NOME$1-$s.perf.log" 2>&1 &
        PERFS="$PERFS $!"
    done
}

# Repouso: todos registados e a dormir, sem tráfego (heartbeats, temporizadores, Diameter...)
cpu > "$OUT/$NOME-repouso.cpu-antes"
perfilar -repouso "$REPOUSO"
wait $PERFS
cpu > "$OUT/$NOME-repouso.cpu-depois"

# Carga
dumpcap -q -i br-n2 -f sctp -w "$OUT/$NOME.pcapng" >/dev/null 2>&1 &
CAP=$!
cpu > "$OUT/$NOME.cpu-antes"
perfilar "" $((DURACAO + 12))
sleep 2
T0=$(date +%s.%N)
docker compose exec -T ue sh -s "$PERIODO" "$DURACAO" < scripts/trafego.sh >/dev/null 2>&1 || true
wait $PERFS
cpu > "$OUT/$NOME.cpu-depois"
T1=$(date +%s.%N)
kill $CAP; wait $CAP 2>/dev/null || true

for s in $NFS; do
    for x in "" -repouso; do
        docker run --rm -v "$OUT":/out "core-simplified/perf:$IMAGEM" \
            script -i "/out/$NOME$x-$s.data" -F ip,sym,dso > "$OUT/$NOME$x-$s.script" 2>/dev/null
    done
done
{
    echo "imagem=$IMAGEM"; echo "variante=$VARIANTE"; echo "compose_file=$COMPOSE_FILE"
    echo "n_ues=$N_UES"; echo "periodo=$PERIODO"; echo "duracao=$DURACAO"; echo "freq=$FREQ"
    echo "repouso=$REPOUSO"
    echo "funcoes=$NFS"; echo "t_inicio=$T0"; echo "t_fim=$T1"
    (cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)")
} > "$OUT/$NOME.meta"
COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
echo "$NOME ($IMAGEM, $VARIANTE): $N_UES UEs, período ${PERIODO}s, ${DURACAO}s -> $OUT"
