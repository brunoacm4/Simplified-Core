# UERANSIM — imagem em duas fases (build + runtime)
# Contexto de build: ../UERANSIM (código local, v3.3.0)

# ---------- Fase 1: compilação ----------
FROM ubuntu:jammy AS build

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential cmake libsctp-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . /src/ueransim
WORKDIR /src/ueransim
RUN make

# ---------- Fase 2: runtime ----------
FROM ubuntu:jammy

# iproute2 + iputils-ping para validar a sessão PDU a partir do UE
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libsctp1 iproute2 iputils-ping && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /src/ueransim/build/ /opt/ueransim/

ENV PATH=/opt/ueransim:$PATH
WORKDIR /opt/ueransim
