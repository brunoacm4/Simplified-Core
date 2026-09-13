#!/usr/bin/env bash
# Mede o custo de sinalizacao de fundo do core: os heartbeats que cada funcao de
# rede envia ao NRF para dizer que continua viva.
#
# Porque isto importa: este custo escala com o NUMERO DE FUNCOES DE REDE, nao com
# o numero de dispositivos. Numa rede publica dilui-se; numa fabrica com poucos
# terminais estaticos torna-se o termo dominante.
#
# NOTA METODOLOGICA: conta-se no NRF e POR IDENTIFICADOR DE INSTANCIA. Contar no
# SCP por IP de origem da resultados errados -- ligacoes ja estabelecidas quando
# a captura comeca nao sao dissecadas como HTTP/2.
#
# Uso:  analysis/heartbeats.sh [RUN_ID] [SEGUNDOS_A_IGNORAR_NO_INICIO]

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${1:-$(cat "$REPO/results/pcap/.current" 2>/dev/null || echo current)}"
SKIP="${2:-25}"
DIR="$REPO/results/pcap/$RUN"
PCAP="$DIR/nrf.pcap"
MAP="$DIR/nf-map.txt"

[[ -f "$PCAP" ]] || { echo "Sem captura do NRF em $PCAP"; exit 1; }

# --- mapa instancia -> tipo de NF -------------------------------------------
# Constroi-se consultando o NRF ao vivo e guarda-se na pasta da run, para que a
# reanalise funcione mais tarde com o laboratorio ja desligado.
if [[ ! -s "$MAP" ]]; then
    if docker ps --format '{{.Names}}' | grep -qx panic-nrf; then
        echo "A consultar o NRF para mapear instancias..." >&2
        # O SBI e HTTP/2 em claro: o curl precisa de --http2-prior-knowledge.
        docker exec panic-scp sh -c '
          curl -s -m 5 --http2-prior-knowledge http://10.55.0.10:7777/nnrf-nfm/v1/nf-instances \
          | grep -o "nf-instances/[0-9a-f-]*" | cut -d/ -f2 | sort -u |
          while read id; do
            curl -s -m 5 --http2-prior-knowledge "http://10.55.0.10:7777/nnrf-nfm/v1/nf-instances/$id" \
            | sed -E "s/.*\"nfType\":\"([A-Z]+)\".*/\1/;t;d" | xargs -I{} echo "$id {}"
          done' > "$MAP" 2>/dev/null
        # heartBeatTimer declarado por cada NF, para comparar com o medido
        docker exec panic-scp sh -c '
          curl -s -m 5 --http2-prior-knowledge http://10.55.0.10:7777/nnrf-nfm/v1/nf-instances \
          | grep -o "nf-instances/[0-9a-f-]*" | cut -d/ -f2 | sort -u |
          while read id; do
            hb=$(curl -s -m 5 --http2-prior-knowledge "http://10.55.0.10:7777/nnrf-nfm/v1/nf-instances/$id" \
                 | sed -E "s/.*\"heartBeatTimer\":([0-9]+).*/\1/;t;d")
            echo "$id ${hb:--}"
          done' > "$DIR/nf-hb.txt" 2>/dev/null
    else
        echo "Laboratorio desligado e sem mapa guardado: os IDs aparecem sem nome." >&2
    fi
fi

# --- contagem ----------------------------------------------------------------
TS() { docker run --rm -v "$DIR":/pcap:ro panic/analysis:latest \
         tshark -d tcp.port==7777,http2 "$@" 2>/dev/null; }

DATA=$(TS -r /pcap/nrf.pcap \
        -Y "http2.headers.method == \"PATCH\" && frame.time_relative > $SKIP" \
        -T fields -e frame.time_relative -e http2.headers.path)

[[ -n "$DATA" ]] || { echo "Nenhum heartbeat encontrado depois de ${SKIP}s."; exit 0; }

echo "======================================================================"
echo " Sinalizacao de fundo NF->NRF   run $RUN   (ignorados os primeiros ${SKIP}s)"
echo "======================================================================"
echo

awk -v mapf="$MAP" -v hbf="$DIR/nf-hb.txt" '
BEGIN {
    FS="\t"
    while ((getline line < mapf) > 0) { split(line,a," "); name[a[1]]=a[2] }
    while ((getline line < hbf)  > 0) { split(line,a," "); decl[a[1]]=a[2] }
}
{
    t=$1; sub(",", ".", t) + 0
    id=$2; sub(/.*nf-instances\//, "", id); sub(/\?.*/, "", id)
    n[id]++
    if (first[id]=="" ) first[id]=t
    last[id]=t
    if (gmin=="" || t+0 < gmin) gmin=t+0
    if (t+0 > gmax) gmax=t+0
    total++
}
END {
    printf "  %-6s %-14s %8s %12s %12s\n", "NF", "instancia", "hbeats", "intervalo", "declarado"
    printf "  %-6s %-14s %8s %12s %12s\n", "------", "--------------", "--------", "------------", "------------"
    # tabela ordenada por nome de NF; o sumario sai depois, fora do sort
    for (id in n) {
        span = last[id]+0 - first[id]+0
        iv = (n[id] > 1) ? span/(n[id]-1) : 0
        printf "  %-6s %-14s %8d %10.1fs %10ss\n", \
               (id in name ? name[id] : "?"), substr(id,1,13), n[id], iv, (id in decl ? decl[id] : "-") | "sort"
    }
    close("sort")
    span = gmax - gmin
    printf "\n  %d instancias, %d transacoes em %.0fs\n", length(n), total, span
    if (span > 0) {
        rate = total/span
        printf "  ritmo agregado no NRF: %.2f transacoes/s\n", rate
        printf "  extrapolado por dia:   %.0f transacoes\n", rate*86400
        printf "  contando os dois saltos NF->SCP->NRF: %.0f pedidos SBI/dia\n", rate*86400*2
    }
}' <<< "$DATA"

echo
echo "  Ressalva: contam-se TRANSACOES, nao custo. Falta medir bytes e CPU."
