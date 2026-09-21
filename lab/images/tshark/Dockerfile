# Ferramenta de análise de capturas (tshark), para não instalar nada no host.
# Uso: docker run --rm -v "$PWD":/cap -w /cap core-simplified/tshark:jammy tshark -r ficheiro.pcapng
FROM ubuntu:jammy
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tshark && \
    rm -rf /var/lib/apt/lists/*
