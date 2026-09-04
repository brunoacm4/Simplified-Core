#!/usr/bin/env bash
# Valida os pre-requisitos do host antes de arrancar o laboratorio.
#
# Existe para que o laboratorio seja reproduzivel por outra pessoa -- o
# orientador, um revisor, ou nos proprios numa maquina do IT -- e para que as
# falhas apareçam aqui, com a correcao ao lado, em vez de aparecerem como um
# gNB que "nao liga ao AMF" sem explicacao.
set -uo pipefail

ok=0; fail=0
green() { printf '  \033[32mOK\033[0m   %s\n' "$1"; ok=$((ok+1)); }
bad()   { printf '  \033[31mFALHA\033[0m %s\n' "$1"; printf '         -> %s\n' "$2"; fail=$((fail+1)); }
warn()  { printf '  \033[33mAVISO\033[0m %s\n' "$1"; printf '         -> %s\n' "$2"; }

echo "Pre-requisitos do host para o laboratorio PANIC"
echo

# --- SCTP: a N2 (NGAP entre gNB e AMF) corre sobre SCTP -----------------------
if [[ -n "$(lsmod | grep -E '^sctp ')" ]]; then
    green "modulo sctp carregado (necessario para a N2/NGAP)"
elif modinfo sctp &>/dev/null; then
    # Verificado experimentalmente: o kernel carrega o modulo sozinho quando o
    # AMF cria o primeiro socket SCTP. Nao e bloqueante -- so o e se o modulo
    # nao existir de todo.
    green "modulo sctp disponivel (o kernel carrega-o quando o AMF abre a N2)"
else
    bad "modulo sctp indisponivel neste kernel" \
        "sudo apt install linux-modules-extra-\$(uname -r)"
fi

# --- TUN: o UPF cria a ogstun, o UE cria a uesimtun0 -------------------------
if [[ -c /dev/net/tun ]]; then
    green "/dev/net/tun presente (UPF e UE precisam de interfaces TUN)"
else
    bad "/dev/net/tun em falta" "sudo modprobe tun"
fi

# --- Docker ------------------------------------------------------------------
if docker info &>/dev/null; then
    green "daemon Docker acessivel sem sudo ($(docker --version | cut -d, -f1))"
else
    bad "daemon Docker inacessivel" \
        "sudo usermod -aG docker \$USER  (e voltar a iniciar sessao)"
fi

if docker compose version &>/dev/null; then
    green "docker compose disponivel ($(docker compose version --short 2>/dev/null))"
else
    bad "docker compose em falta" "instalar o plugin docker-compose-v2"
fi

# --- Analise -----------------------------------------------------------------
if command -v tshark &>/dev/null; then
    green "tshark presente no host (analise das capturas)"
elif docker image inspect panic/analysis:latest &>/dev/null; then
    green "tshark via container panic/analysis (nao e preciso no host)"
else
    warn "sem tshark no host nem imagem de analise" \
         "correr 'make build' (cria o container), ou 'sudo apt install -y tshark'"
fi

# --- Espaco em disco ---------------------------------------------------------
avail_gb=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
avail_gb=${avail_gb:-0}
if (( avail_gb >= 15 )); then
    green "espaco em disco: ${avail_gb} GB livres"
elif (( avail_gb >= 8 )); then
    warn "espaco em disco apertado: ${avail_gb} GB livres" \
         "as imagens ocupam ~4 GB; as capturas crescem depressa em testes de carga"
else
    bad "espaco em disco insuficiente: ${avail_gb} GB livres" "libertar espaco (minimo ~8 GB)"
fi

echo
if (( fail > 0 )); then
    echo "$fail pre-requisito(s) por satisfazer. Corrigir antes de 'make up'."
    exit 1
fi
echo "Host pronto ($ok verificacoes)."
