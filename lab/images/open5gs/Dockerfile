# Open5GS — imagem em duas fases (build + runtime)
# Contexto de build: ../open5gs (código local, v2.8.0)

# ---------- Fase 1: compilação ----------
FROM ubuntu:jammy AS build

# Dependências de compilação (iguais a open5gs/docker/ubuntu/jammy/base/Dockerfile)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3-pip python3-setuptools python3-wheel ninja-build build-essential \
        flex bison git cmake meson pkg-config ca-certificates \
        libsctp-dev libgnutls28-dev libgcrypt-dev libssl-dev libmongoc-dev \
        libbson-dev libyaml-dev libmicrohttpd-dev libcurl4-gnutls-dev \
        libnghttp2-dev libtins-dev libtalloc-dev libidn-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . /src/open5gs
WORKDIR /src/open5gs

RUN meson setup build --prefix=/opt/open5gs --libdir=lib && \
    ninja -C build install

# ---------- Fase 2: runtime ----------
FROM ubuntu:jammy

# Só bibliotecas de runtime + ferramentas mínimas de rede (ip, para criar a ogstun no UPF)
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libsctp1 libgnutls30 libgcrypt20 libssl3 libmongoc-1.0-0 libbson-1.0-0 \
        libyaml-0-2 libmicrohttpd12 libcurl3-gnutls libnghttp2-14 libtins4.0 \
        libtalloc2 libidn12 iproute2 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/open5gs /opt/open5gs
# O subprojeto prometheus-client-c (libprom) instala em lib/x86_64-linux-gnu, ignorando --libdir
RUN printf '/opt/open5gs/lib\n/opt/open5gs/lib/x86_64-linux-gnu\n' > /etc/ld.so.conf.d/open5gs.conf && ldconfig

ENV PATH=/opt/open5gs/bin:$PATH
WORKDIR /opt/open5gs
