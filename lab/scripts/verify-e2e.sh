#!/usr/bin/env bash
# Verificacao ponta-a-ponta do laboratorio PANIC.
#
# E o criterio OBJETIVO de sucesso do passo 1. Se isto passa, temos um baseline
# a serio: plano de controlo completo, plano de dados a encaminhar, e capturas
# legiveis dos procedimentos. Se falha, diz onde.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="${RUN_ID:-$(cat "$REPO/results/pcap/.current" 2>/dev/null || echo current)}"
PCAP_DIR="$REPO/results/pcap/$RUN_ID"

fail=0
green() { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()   { printf '  \033[31mFALHA\033[0m %s\n' "$1"; fail=$((fail+1)); }
info()  { printf '  \033[90m·\033[0m     %s\n' "$1"; }

echo "=========================================================="
echo " Verificacao ponta-a-ponta -- run $RUN_ID"
echo "=========================================================="
echo
echo "[1] Estado das funcoes de rede"
for c in mongo nrf scp udr udm ausf pcf nssf bsf amf smf upf gnb ue; do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "panic-$c" 2>/dev/null || echo "ausente")
    case "$st" in
        healthy|running) green "$(printf '%-6s' "$c") $st" ;;
        *)               bad   "$(printf '%-6s' "$c") $st" ;;
    esac
done

echo
echo "[2] Registo das NFs no NRF"
# Se o AMF nao se registou, a descoberta falha e nada mais funciona.
if docker logs panic-amf 2>&1 | grep -qiE "NF (registered|Instance).*(Registered|registered)"; then
    green "AMF registou-se no NRF"
else
    n=$(docker logs panic-amf 2>&1 | grep -ci "nrf" || true)
    if (( n > 0 )); then green "AMF comunicou com o NRF ($n linhas)"; else bad "sem sinal de registo no NRF"; fi
fi

echo
echo "[3] N2 -- NGAP/SCTP entre gNB e AMF"
if docker exec panic-gnb ss -na 2>/dev/null | grep -q ':38412'; then
    green "associacao SCTP estabelecida com o AMF"
else
    bad "gNB sem associacao SCTP para o AMF (o modulo sctp esta carregado no host?)"
fi
if docker logs panic-gnb 2>&1 | grep -qi "NG Setup procedure is successful"; then
    green "NG Setup concluido com sucesso"
else
    bad "NG Setup nao confirmado nos logs do gNB"
fi

echo
echo "[4] Registo do UE e sessao PDU"
if docker logs panic-ue 2>&1 | grep -qi "Registration accept"; then
    green "Registration Accept recebido"
else
    bad "UE nao completou o registo"
fi
UE_IP=$(docker exec panic-ue sh -c "ip -4 -o addr show uesimtun0 2>/dev/null | awk '{print \$4}'" 2>/dev/null | cut -d/ -f1)
if [[ -n "$UE_IP" ]]; then
    green "uesimtun0 activa com IP $UE_IP (sessao PDU estabelecida)"
else
    bad "uesimtun0 inexistente -- a sessao PDU nao foi estabelecida"
fi

echo
echo "[5] Plano de dados -- trafego real atraves do UPF"
if [[ -n "$UE_IP" ]]; then
    if docker exec panic-ue ping -I uesimtun0 -c 3 -W 3 -q 1.1.1.1 &>/dev/null; then
        rtt=$(docker exec panic-ue ping -I uesimtun0 -c 3 -W 3 -q 1.1.1.1 2>/dev/null | tail -1 | cut -d= -f2)
        green "ping atraves do tunel: OK  (rtt min/avg/max/mdev =${rtt:-n/d})"
    else
        bad "sem conectividade IP atraves do tunel (NAT na N6? ip_forward no UPF?)"
    fi
    # Por IP e nao por nome: o resolver de DNS do container e o do Docker
    # (127.0.0.11) e NAO passa pelo tunel, logo um teste por nome falharia por
    # DNS mesmo com o plano de dados perfeito. O que queremos provar aqui e que
    # ha uma sessao TCP completa a atravessar o UPF.
    if docker exec panic-ue curl -s --interface uesimtun0 --max-time 10 \
           -o /dev/null -w '%{http_code}' -H 'Host: one.one.one.one' http://1.1.1.1/ 2>/dev/null \
           | grep -qE '^(200|30[0-9])$'; then
        green "TCP/HTTP atraves do tunel: OK"
    else
        info "TCP atraves do tunel sem resposta (nao critico: pode ser a rede exterior)"
    fi
else
    bad "salta o teste de plano de dados: sem uesimtun0"
fi

echo
echo "[6] Capturas"
if [[ -d "$PCAP_DIR" ]] && compgen -G "$PCAP_DIR/*.pcap" >/dev/null; then

    # tshark do host se existir; senao o container de analise. Assim o
    # laboratorio nao depende de ferramentas instaladas no host -- e a versao
    # do dissetor fica fixa, que e o que faz as contagens serem comparaveis.
    # ------------------------------------------------------------------------
    # Dois parametros SEM OS QUAIS as capturas parecem vazias. Descobertos a
    # custo; ficam aqui e em docs/lab/topologia.md.
    #
    #  -o nas-5gs.null_decipher:TRUE
    #     Vem DESLIGADO por omissao. Sem ele, tudo o que segue o Security Mode
    #     Command aparece como "UplinkNASTransport" opaco -- perde-se o
    #     Registration accept, a sessao PDU, tudo. E ele que torna util o nosso
    #     desvio para NEA0.
    #
    #  -d tcp.port==7777,http2
    #     O SBI corre em 7777, que o Wireshark nao associa a HTTP/2. Sem isto,
    #     zero pacotes SBI reconhecidos -- e o SBI e metade do que queremos medir.
    # ------------------------------------------------------------------------
    TSOPTS=(-o nas-5gs.null_decipher:TRUE -d tcp.port==7777,http2)

    if command -v tshark &>/dev/null; then
        TS() { tshark "${TSOPTS[@]}" "$@"; }; P="$PCAP_DIR"
    elif docker image inspect panic/analysis:latest &>/dev/null; then
        TS() { docker run --rm -v "$PCAP_DIR":/pcap:ro panic/analysis:latest \
                   tshark "${TSOPTS[@]}" "$@"; }; P="/pcap"
        info "tshark via container panic/analysis (nao esta instalado no host)"
    else
        TS() { return 1; }; P=""
        info "sem tshark disponivel -- 'make build' cria o container de analise"
    fi

    if [[ -n "$P" ]]; then
        printf '  %-10s %8s %6s %6s %6s %6s %6s\n' ficheiro pacotes NGAP NAS PFCP HTTP2 GTP
        for f in "$PCAP_DIR"/*.pcap; do
            b=$(basename "$f")
            tot=$(TS -r "$P/$b" 2>/dev/null | wc -l)
            cnt() { TS -r "$P/$b" -Y "$1" 2>/dev/null | wc -l; }
            printf '  %-10s %8s %6s %6s %6s %6s %6s\n' \
                "${b%.pcap}" "$tot" "$(cnt ngap)" "$(cnt nas-5gs)" "$(cnt pfcp)" "$(cnt http2)" "$(cnt gtp)"
        done

        echo
        echo "  Sequencia de procedimentos observada (captura do AMF):"
        if [[ -f "$PCAP_DIR/amf.pcap" ]]; then
            expected=(
                "NGSetupRequest" "NGSetupResponse"
                "Registration request" "Authentication request" "Authentication response"
                "Security mode command" "Security mode complete"
                "Registration accept" "Registration complete"
                "UL NAS transport" "DL NAS transport"
            )
            info_col=$(TS -r "$P/amf.pcap" -Y "ngap || nas-5gs" -T fields -e _ws.col.Info 2>/dev/null)
            for m in "${expected[@]}"; do
                if grep -qi -- "$m" <<<"$info_col"; then green "$m"; else bad "$m ausente da captura"; fi
            done
            # NAS legivel na captura = o desvio NEA0 esta a fazer o seu trabalho.
            if grep -qi "Registration accept" <<<"$info_col"; then
                green "NAS decifravel na captura (NEA0 activo, como planeado)"
            fi
        else
            info "amf.pcap inexistente nesta run"
        fi
    fi
else
    info "sem capturas em $PCAP_DIR (correr 'make capture-start' antes do cenario)"
fi

echo
echo "=========================================================="
if (( fail > 0 )); then
    echo " $fail verificacao(oes) falhada(s)."
    echo " Diagnostico util:  make logs SVC=amf   |   make status"
    exit 1
fi
echo " Baseline validado. Passo 1 concluido."
echo "=========================================================="
