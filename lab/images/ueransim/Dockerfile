# UERANSIM -- gNB e UE simulados, compilados a partir do codigo-fonte numa tag fixa.
#
# E o nosso "RAN" e o nosso "terminal". Interessa-nos sobretudo porque gera
# procedimentos NAS/NGAP reais e reproduziveis, que e o que vamos medir.

ARG UBUNTU_VERSION=22.04

# ---------------------------------------------------------------- build stage
FROM ubuntu:${UBUNTU_VERSION} AS build

ARG UERANSIM_TAG=v3.3.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates make gcc g++ cmake libsctp-dev lksctp-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${UERANSIM_TAG} https://github.com/aligungr/UERANSIM.git . \
    && git rev-parse HEAD > /ueransim.commit

RUN make -j"$(nproc)"

# -------------------------------------------------------------- runtime stage
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        libsctp1 lksctp-tools iproute2 iptables iputils-ping \
        netcat-openbsd curl ca-certificates tcpdump \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/ /usr/local/bin/
COPY --from=build /ueransim.commit /ueransim.commit

ENV LD_LIBRARY_PATH=/usr/local/bin

RUN set -e; \
    for b in /usr/local/bin/nr-gnb /usr/local/bin/nr-ue /usr/local/bin/nr-cli; do \
        if ldd "$b" 2>/dev/null | grep -q "not found"; then \
            echo "BIBLIOTECA EM FALTA em $b:"; ldd "$b" | grep "not found"; exit 1; \
        fi; \
    done; \
    echo "Binarios UERANSIM resolveram as suas dependencias."

WORKDIR /usr/local/bin
