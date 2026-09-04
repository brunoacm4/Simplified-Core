# Open5GS compilado a partir do codigo-fonte, numa tag fixa.
#
# Porque compilamos em vez de usar imagens de terceiros: vamos modificar o AMF
# (mobilidade como plugin) e os numeros que publicarmos tem de ser rastreaveis a
# um commit exato. Uma unica imagem serve todas as NFs -- o que as distingue e o
# comando e o ficheiro de configuracao.

ARG UBUNTU_VERSION=22.04

# ---------------------------------------------------------------- build stage
FROM ubuntu:${UBUNTU_VERSION} AS build

ARG OPEN5GS_TAG=v2.7.7
ENV DEBIAN_FRONTEND=noninteractive

# Lista de dependencias de compilacao documentada pelo projeto Open5GS (Ubuntu).
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates \
        python3-pip python3-setuptools python3-wheel \
        ninja-build build-essential flex bison cmake meson \
        libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libidn-dev \
        libmongoc-dev libbson-dev libyaml-dev libnghttp2-dev \
        libmicrohttpd-dev libcurl4-gnutls-dev libtins-dev libtalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${OPEN5GS_TAG} https://github.com/open5gs/open5gs.git . \
    && git rev-parse HEAD > /open5gs.commit

RUN meson setup build --prefix=/opt/open5gs \
    && ninja -C build \
    && ninja -C build install

# O script oficial de gestao de subscritores viaja com a imagem, para termos
# uma alternativa a mongosh se dela precisarmos.
RUN cp misc/db/open5gs-dbctl /opt/open5gs/bin/ && chmod +x /opt/open5gs/bin/open5gs-dbctl

# -------------------------------------------------------------- runtime stage
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive

# Bibliotecas de runtime + utilitarios de rede. As ferramentas de diagnostico
# (ss, ping, tcpdump, curl) sao deliberadas: isto e um laboratorio de medicao,
# nao uma imagem de producao, e queremos poder inspecionar de dentro.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libsctp1 libgnutls30 libgcrypt20 libssl3 libidn12 \
        libmongoc-1.0-0 libbson-1.0-0 libyaml-0-2 libnghttp2-14 \
        libmicrohttpd12 libcurl3-gnutls libtalloc2 libtins4.0 \
        iproute2 iptables iputils-ping netcat-openbsd curl ca-certificates tcpdump \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/open5gs /opt/open5gs
COPY --from=build /open5gs.commit /open5gs.commit

ENV PATH=/opt/open5gs/bin:$PATH
ENV LD_LIBRARY_PATH=/opt/open5gs/lib/x86_64-linux-gnu

# Falha ALTO na build, e nao misteriosamente em runtime, se faltar alguma
# biblioteca partilhada no stage de runtime.
RUN set -e; \
    fail=0; \
    for b in /opt/open5gs/bin/open5gs-*d; do \
        if ldd "$b" 2>/dev/null | grep -q "not found"; then \
            echo "BIBLIOTECA EM FALTA em $b:"; ldd "$b" | grep "not found"; fail=1; \
        fi; \
    done; \
    [ "$fail" -eq 0 ] || exit 1; \
    echo "Todos os binarios Open5GS resolveram as suas dependencias."

WORKDIR /opt/open5gs
