# Ferramentas de analise de capturas.
#
# Em container e nao no host de proposito: o passo 2 vai construir metricas em
# cima do tshark, e essas metricas tem de dar o MESMO resultado na minha
# maquina, numa maquina do IT e na de um revisor. Uma versao de tshark diferente
# dissecta campos de forma diferente -- fixa-la aqui elimina essa variavel.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# O tshark pergunta em debconf se utilizadores nao-root podem capturar; aqui
# so lemos ficheiros, logo respondemos "nao" e evitamos o prompt interativo.
RUN echo "wireshark-common wireshark-common/install-setuid boolean false" | debconf-set-selections \
    && apt-get update && apt-get install -y --no-install-recommends \
        tshark python3 python3-pip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /pcap
ENTRYPOINT []
