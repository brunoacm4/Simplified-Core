# perf e gdb para observar as funções do Open5GS por dentro: perfil de CPU (scripts/perfil-ciclo.sh)
# e heap/pools/tamanhos das estruturas (scripts/medir-fase1.sh, com --entrypoint gdb).
#
# Construída POR CIMA da imagem do Open5GS a perfilar, para o perf encontrar os binários e as
# bibliotecas nos mesmos caminhos (/opt/open5gs, /usr/lib/x86_64-linux-gnu) e resolver os símbolos.
# Corre como contentor auxiliar no espaço de processos da função (--pid=container:<função>), com
# CAP_PERFMON e CAP_SYS_PTRACE: o anfitrião tem kernel.perf_event_paranoid=4 e o perf não corre sem
# privilégios.
#
# O perf é o do Ubuntu jammy (5.15); funciona com o kernel 6.8 do anfitrião.
#
#   docker build --build-arg BASE=core-simplified/open5gs:v2.8.0    -t core-simplified/perf:o0 images/perf
#   docker build --build-arg BASE=core-simplified/open5gs:v2.8.0-o2 -t core-simplified/perf:o2 images/perf
ARG BASE=core-simplified/open5gs:v2.8.0
FROM ${BASE}

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends linux-tools-generic libc6-dbg gdb && \
    rm -rf /var/lib/apt/lists/* && \
    ln -sf "$(ls -d /usr/lib/linux-tools/*/perf | head -1)" /usr/local/bin/perf

ENTRYPOINT ["perf"]
