#!/usr/bin/env bash
# Mede o PRECO de um intervalo de heartbeat longo: quanto tempo o NRF continua a
# anunciar uma funcao de rede que ja morreu.
#
# Pela TS 29.510 (clausula 5.2.2.3.2), o NRF marca a NF como SUSPENDED se ela nao
# atualizar o perfil dentro de um periodo configuravel superior ao intervalo de
# heartbeat. A partir dai deixa de ser elegivel para descoberta. O intervalo de
# heartbeat e, portanto, a janela de pior caso de anuncio de uma NF morta.
#
# IMPORTANTE: usa-se 'docker kill' (SIGKILL) e nao 'docker stop' (SIGTERM). Com
# SIGTERM o Open5GS desregista-se ordeiramente e o heartbeat nunca entra em jogo
# -- o mecanismo existe para CRASHES.
#
# Uso:  analysis/nf-failure.sh <NF> [segundos_max]     ex: analysis/nf-failure.sh ausf 180

set -uo pipefail

NF="${1:-ausf}"
MAXWAIT="${2:-180}"
UP=$(echo "$NF" | tr '[:lower:]' '[:upper:]')
C="panic-$NF"

q() { docker exec panic-scp curl -s -m 3 --http2-prior-knowledge "$1" 2>/dev/null; }
NRF="http://10.55.0.10:7777"

docker ps --format '{{.Names}}' | grep -qx "$C" || { echo "$C nao esta a correr."; exit 1; }

# --- perfil antes -------------------------------------------------------------
ID=$(q "$NRF/nnrf-nfm/v1/nf-instances" | grep -o "nf-instances/[0-9a-f-]*" | cut -d/ -f2 | sort -u | \
     while read i; do
       q "$NRF/nnrf-nfm/v1/nf-instances/$i" | grep -q "\"nfType\":\"$UP\"" && { echo "$i"; break; }
     done)
[[ -n "$ID" ]] || { echo "Nao encontrei instancia $UP no NRF."; exit 1; }
HB=$(q "$NRF/nnrf-nfm/v1/nf-instances/$ID" | sed -E 's/.*"heartBeatTimer":([0-9]+).*/\1/;t;d')

echo "======================================================================"
echo " Falha abrupta de $UP    instancia ${ID:0:13}    heartBeatTimer=${HB}s"
echo "======================================================================"
echo
printf "  %6s  %-12s  %s\n" "t" "descoberta" "estado no NRF"
printf "  %6s  %-12s  %s\n" "------" "------------" "-------------"

# --- matar --------------------------------------------------------------------
docker kill "$C" >/dev/null 2>&1
T0=$(date +%s)
echo "  [SIGKILL enviado a $C]"

# --- sondar -------------------------------------------------------------------
detected=""
while :; do
    t=$(( $(date +%s) - T0 ))
    (( t > MAXWAIT )) && break

    disc=$(q "$NRF/nnrf-disc/v1/nf-instances?target-nf-type=$UP&requester-nf-type=SCP")
    st=$(q "$NRF/nnrf-nfm/v1/nf-instances/$ID" | sed -E 's/.*"nfStatus":"([A-Z]+)".*/\1/;t;d')

    if grep -q "\"nfInstanceId\":\"$ID\"" <<<"$disc"; then found="ANUNCIADA"; else found="removida"; fi
    printf "  %5ds  %-12s  %s\n" "$t" "$found" "${st:-<sem perfil>}"

    if [[ "$found" != "ANUNCIADA" || "${st:-}" != "REGISTERED" ]]; then
        detected="$t"; break
    fi
    sleep 5
done

echo
if [[ -n "$detected" ]]; then
    echo "  >> O NRF deixou de a anunciar ao fim de ${detected}s (heartBeatTimer=${HB}s)."
else
    echo "  >> Ainda ANUNCIADA como REGISTERED ao fim de ${MAXWAIT}s, apesar de morta."
    echo "     Com heartBeatTimer=${HB}s, era o esperado."
fi
echo
echo "  Para repor:  docker start $C"
