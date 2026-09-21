#!/bin/sh
# Analisa uma captura do lab: lista NGAP (com NAS) e todos os pedidos SBI (todas as pernas),
# separando a fase de arranque do core da fase do UE (instante em <nome>.t_ue).
#
# Uso: ./scripts/analisar-captura.sh <captura.pcapng>
# Saída: <captura>.ngap.tsv, <captura>.sbi.tsv e um resumo no stdout.
set -e
PCAP=$(realpath "$1"); DIR=$(dirname "$PCAP"); BASE=$(basename "$PCAP" .pcapng)
T_UE=$(cat "$DIR/$BASE.t_ue" 2>/dev/null || echo 0)

TSHARK="docker run --rm -v $DIR:/cap -w /cap core-simplified/tshark:jammy tshark \
  -o nas-5gs.null_decipher:TRUE -d tcp.port==7777,http2 -r $BASE.pcapng"

# Nomes das NFs a partir dos IPs do lab (ver lab/README.md)
NOMES='
10.100.1.5 AMF
10.100.2.5 AMF
10.100.1.4 SMF
10.100.4.4 SMF
10.100.4.7 UPF
10.100.1.10 NRF
10.100.1.200 SCP
10.100.1.11 AUSF
10.100.1.12 UDM
10.100.1.20 UDR
10.100.1.13 PCF
10.100.1.14 NSSF
10.100.1.15 BSF
10.100.2.50 gNB'

# --- NGAP: uma linha por trama, NAS descodificado na coluna Info ---
# Só SCTP: o SMF também transporta blocos NGAP dentro do JSON SBI (n1-n2-messages), que não são N2.
$TSHARK -Y "ngap && sctp" -T fields -E separator='	' -e frame.time_epoch -e ip.src -e ip.dst -e _ws.col.Info 2>/dev/null \
 | sort -n \
 | awk -F'\t' -v t="$T_UE" -v nomes="$NOMES" '
    BEGIN { n=split(nomes, l, "\n"); for (i=1;i<=n;i++) { split(l[i], a, " "); nm[a[1]]=a[2] } }
    { info=$4; gsub(/SACK \([^)]*\) , /, "", info)
      print (($1 < t) ? "arranque" : "ue") "\t" $1 "\t" nm[$2] "\t" nm[$3] "\t" info }' \
 > "$DIR/$BASE.ngap.tsv"

# --- SBI: um pedido HTTP/2 por linha (uma trama pode levar vários) ---
# Método pode vir vazio (tshark 3.6 nem sempre descodifica PUT/DELETE/PATCH via HPACK) -> "?"
$TSHARK -Y "http2.headers.path" -T fields -E separator='	' -E aggregator='#' \
    -e frame.time_epoch -e ip.src -e ip.dst -e http2.headers.method -e http2.headers.path 2>/dev/null \
 | sort -n \
 | awk -F'\t' -v t="$T_UE" -v nomes="$NOMES" '
    BEGIN { n=split(nomes, l, "\n"); for (i=1;i<=n;i++) { split(l[i], a, " "); nm[a[1]]=a[2] } }
    { np=split($5, p, "#"); nm_=split($4, m, "#")
      for (i=1;i<=np;i++) {
        q=p[i]; sub(/\?.*/, "", q)
        gsub(/imsi-[0-9]+/, "{supi}", q); gsub(/suci-[0-9-]+/, "{suci}", q)
        gsub(/nf-instances\/[0-9a-f-]+/, "nf-instances/{id}", q)
        gsub(/subscriptions\/[0-9a-f-]+/, "subscriptions/{id}", q)
        met=(nm_==np && m[i]!="") ? m[i] : "?"
        print (($1 < t) ? "arranque" : "ue") "\t" $1 "\t" nm[$2] "\t" nm[$3] "\t" met "\t" q } }' \
 > "$DIR/$BASE.sbi.tsv"

echo "=== $BASE ==="
awk -F'\t' '
  FNR==NR { ngap[$1]++; next }                       # 1.º ficheiro: NGAP
  {
    fase=$1; src=$3; dst=$4; met=$5; path=$6
    nrf = (path ~ /^\/nnrf-nfm\//)
    if (src != "SCP") {                               # perna de origem (NF -> SCP)
      if (!nrf) { proc[fase]++; next }
      if (src == "NRF")                        tipo="notificação (NRF->)"
      else if (path ~ /subscriptions/)         tipo="subscrição"
      else if (path ~ /nf-instances$/)         tipo="lista de NFs (GET)"
      else if (met == "PUT")                   tipo="registo (PUT)"
      else if (met == "PATCH")                 tipo="heartbeat (PATCH)"
      else if (met == "GET")                   tipo="perfil de NF (GET)"
      else                                     tipo="nf-instances, método " met
      mgmt[fase "\t" tipo]++; nf_para_nrf[fase] += (src != "NRF")
    } else {                                          # perna SCP -> destino
      if (dst == "NRF") scp_nrf[fase]++
      else if (!nrf)    fwd[fase]++
    }
  }
  END {
    split("arranque ue", F, " ")
    for (k=1; k<=2; k++) { f=F[k]
      printf "\n[fase: %s]\n", f
      printf "  N2 (NGAP sobre SCTP):                 %d\n", ngap[f]
      printf "  SBI do procedimento (origem->SCP):    %d\n", proc[f]
      printf "  SBI do procedimento (SCP->destino):   %d   <- deve ser igual (verificação cruzada)\n", fwd[f]
      printf "  Gestão NRF (pedidos das NFs):         %d\n", nf_para_nrf[f]
      printf "  SCP->NRF (reencaminhados + próprios): %d   => próprios da SCP: %d\n", scp_nrf[f], scp_nrf[f]-nf_para_nrf[f]
      for (x in mgmt) { split(x, a, "\t"); if (a[1]==f) printf "      %-28s %d\n", a[2], mgmt[x] }
    }
  }' "$DIR/$BASE.ngap.tsv" "$DIR/$BASE.sbi.tsv"
