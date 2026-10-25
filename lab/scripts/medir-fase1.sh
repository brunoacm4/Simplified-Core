#!/bin/sh
# Fase 1 (notes/core/fase1-nao-esquecer.md): quanto custa ao core guardar dispositivos ausentes, e o
# que acontece aos pacotes que a rede lhes manda.
#
#   frota   N UEs registados e parados → sem cobertura (tc netem no contentor dos UEs, que guardam o
#           GUTI, o contexto de segurança e a sessão) → inalcançáveis → desregisto implícito →
#           cobertura de volta. Amostras: S0 só o core, S1 registados, S2 inalcançáveis (contexto
#           guardado), S3 desregistados (contexto apagado, processos vivos), S4 de volta. No fim as
#           funções param com SIGTERM e o log de cada uma traz o relatório talloc do que ficou vivo
#           (lib/core/ogs-memory.c, ogs_mem_final). Com N=0 é o controlo: mesmas fases, sem UEs.
#   dl      1 UE sem cobertura: pacotes da rede para ele antes de ficar inalcançável (paging), o
#           regresso, um pacote da rede depois do regresso e um envio do UE no fim (pacotes guardados
#           entregues atrasados, contados no N3).
#   ausencia  1 UE sem cobertura 15 min (etapa 4, antes/depois dos patches 0007–0009): espera que o
#           AMF o dê como inalcançável (mobile reachable timer), manda-lhe pacotes da rede, devolve a
#           cobertura aos 15 min (na referência o desregisto implícito foi aos 10 min) e mede o
#           regresso, um pacote da rede depois do regresso e um envio do UE.
#   manutencao  N UEs sem cobertura 15 min (manutenção do gNB): regresso em massa e o primeiro envio
#           de cada um. Amostras S1 registados, S2 inalcançáveis, S3 antes do regresso, S4 depois do
#           regresso, S5 depois do envio (CPU de cada fase pela diferença do cpu_usec).
#   reinicio  N UEs: o contentor dos UEs reinicia (o UERANSIM volta com o SUCI) com cobertura (R1) e
#           depois de o core os dar como inalcançáveis (R2): os pools não podem acumular contextos.
#   ciclos  N UEs, 3 ciclos de desregisto implícito e regresso com sessão nova (amostras C0..C3
#           registados, D1..D3 desregistados): o heap que fica depois de cada ciclo estabiliza?
#
# Cada amostra, por função do core: memory.current/peak e memory.stat (anon, file, kernel, slab,
# sock) do cgroup, CPU, e pelo gdb (contentor auxiliar core-simplified/perf:o2, --pid container:):
# heap talloc (bytes e blocos), mallinfo2 e lugares ocupados nos pools.
#
# Core: base + AMF_VARIANTE (por omissão t3512-60s: T3512 = 60 s, inalcançável 300 s depois de
# adormecer, desregisto implícito 300 s depois) + idle, com SCP. Com AMF_VARIANTE=fase1, BRACO escolhe
# as opções dos patches 0007–0009 (ref, 0007, 0008, 0009; ver variantes/fase1/compose.yml).
#
# Uso: [N=100] [CORRIDAS="frota dl ausencia"] [AMF_VARIANTE=t3512-60s] [BRACO=ref]
#      ./scripts/medir-fase1.sh <pasta> [sufixo]
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1"); SUF=${2:+-$2}
N=${N:-100}
CORRIDAS=${CORRIDAS:-frota dl}
AMF_VARIANTE=${AMF_VARIANTE:-t3512-60s}
export COMPOSE_FILE=docker-compose.yml:variantes/$AMF_VARIANTE/compose.yml:variantes/idle/compose.yml
CORE="nrf scp amf smf upf ausf udm udr pcf nssf bsf"
mkdir -p "$OUT"

agora() { date +%s.%N; }
conta() { docker compose logs --no-log-prefix "$1" 2>/dev/null | grep -c "$2" || true; }
espera_conta() {  # <serviço> <texto> <alvo> <limite s>
    t=0
    until [ "$(conta "$1" "$2")" -ge "$3" ]; do
        t=$((t + 5)); [ "$t" -gt "$4" ] && { echo "AVISO: '$2' em $1 não chegou a $3" >&2; return 0; }
        sleep 5
    done
}
# UEs distintos (pelo IMSI das linhas "[<imsi>|nas]") com <texto> no log do UE depois da linha <desde>:
# não conta duas vezes um UE que voltou e já fez um registo periódico
linhas_ue() { docker compose logs --no-log-prefix ue 2>/dev/null | wc -l; }
ues_com() {  # <texto> <desde>
    docker compose logs --no-log-prefix ue 2>/dev/null | tail -n +"$(($2 + 1))" | grep "$1" |
        sed -n 's/.*\[\([0-9]*\)|nas\].*/\1/p' | sort -u | wc -l
}
espera_ues() {  # <texto> <desde> <alvo> <limite s>
    t=0
    until [ "$(ues_com "$1" "$2")" -ge "$3" ]; do
        t=$((t + 2)); [ "$t" -gt "$4" ] && { echo "AVISO: só $(ues_com "$1" "$2") de $3 UEs com '$1'" >&2; return 0; }
        sleep 2
    done
}
# Um ping de cada UE ao mesmo tempo (o UERANSIM perde o primeiro pacote em CM-IDLE, mas o pacote
# provoca o Service Request ou, se o core já não tiver a sessão, uma sessão nova)
uplink_todos() {  # <n_ues>
    docker compose exec -T ue sh -c "for i in \$(seq 0 $(($1 - 1))); do
        ping -c 1 -W 3 -I uesimtun\$i 10.45.0.1 >/dev/null 2>&1 & done; wait" || true
}

# Pools a ler em cada função (lugares usados = size - avail)
pools() {
    case $1 in
        amf) echo "amf_ue_pool ran_ue_pool amf_sess_pool" ;;
        smf) echo "smf_ue_pool smf_sess_pool smf_bearer_pool ogs_pfcp_pdr_pool ogs_pfcp_far_pool" ;;
        upf) echo "upf_sess_pool ogs_pfcp_pdr_pool ogs_pfcp_far_pool" ;;
        udm) echo "udm_ue_pool udm_sess_pool" ;;
        ausf) echo "ausf_ue_pool" ;;
        pcf) echo "pcf_ue_am_pool pcf_ue_sm_pool pcf_sess_pool" ;;
        bsf) echo "bsf_sess_pool" ;;
    esac
}

# Uma amostra de todas as funções do core: linhas "<rótulo> <epoch> <serviço> <campo> <valor>"
amostra() {  # <ficheiro> <rótulo>
    t=$(agora)
    for s in $CORE; do
        id=$(docker compose ps -q "$s" 2>/dev/null)
        [ -n "$id" ] || continue
        cg=/sys/fs/cgroup/system.slice/docker-$id.scope
        {
            echo "memory_current $(cat $cg/memory.current)"
            echo "memory_peak $(cat $cg/memory.peak 2>/dev/null || echo 0)"
            awk '$1 ~ /^(anon|file|kernel|slab|sock)$/ { print $1, $2 }' $cg/memory.stat
            awk '/^usage_usec/ { print "cpu_usec", $2 }' $cg/cpu.stat
            set -- -ex 'printf "talloc_bytes %lu\n", ((unsigned long(*)(const void*))talloc_total_size)(__ogs_talloc_core)' \
                   -ex 'printf "talloc_blocks %lu\n", ((unsigned long(*)(const void*))talloc_total_blocks)(__ogs_talloc_core)' \
                   -ex 'set $m = mallinfo2()' \
                   -ex 'printf "malloc_uordblks %lu\n", $m.uordblks' \
                   -ex 'printf "malloc_fordblks %lu\n", $m.fordblks' \
                   -ex 'printf "malloc_hblkhd %lu\n", $m.hblkhd'
            for p in $(pools "$s"); do
                set -- "$@" -ex "printf \"pool_${p} %d\\n\", '$p'.size - '$p'.avail"
            done
            docker run --rm --pid="container:lab-$s-1" --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
                --entrypoint gdb core-simplified/perf:o2 -batch -iex 'set sysroot /' -p 1 \
                "/opt/open5gs/bin/open5gs-${s}d" "$@" 2>/dev/null | grep -E '^[a-z_]+ -?[0-9]+$'
        } | sed "s/^/$2 $t $s /" >> "$1"
    done
}

arrancar() {  # <nome> <n_ues>
    COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
    docker compose up --no-start >/dev/null 2>&1
    : > "$OUT/$1.eventos"; : > "$OUT/$1.memoria.tsv"
    dumpcap -q -i br-n2 -i br-sbi -i br-n4 -i br-n3 -w "$OUT/$1.pcapng" >/dev/null 2>&1 &
    CAP=$!
    sleep 2
    docker compose up -d $CORE mongodb gnb >/dev/null 2>&1
    sleep 40
    amostra "$OUT/$1.memoria.tsv" S0
    if [ "$2" -gt 0 ]; then
        t0=$(agora)
        N_UES=$2 docker compose up -d ue >/dev/null 2>&1
        espera_conta ue "PDU Session establishment is successful" "$2" 300
        echo "$t0 $(agora) registo" >> "$OUT/$1.eventos"
        sleep 20                              # o gNB liberta-os ao fim de 10 s sem tráfego
        IF_RAN=$(docker compose exec -T ue ip -4 -o addr show | awk '$4 ~ /^10\.100\.5\./ { print $2 }')
    fi
}

cobertura() {  # up | down (todos os UEs do contentor 'ue' de uma vez)
    if [ "$1" = down ]; then
        docker compose exec -T ue tc qdisc add dev "$IF_RAN" root netem loss 100%
    else
        docker compose exec -T ue tc qdisc del dev "$IF_RAN" root
    fi
}

terminar() {  # <nome>
    # SIGTERM às funções: ao sair, cada uma escreve no log o relatório talloc do que ficou vivo
    docker compose stop -t 30 $CORE >/dev/null 2>&1 || true
    sleep 2
    kill $CAP; wait $CAP 2>/dev/null || true
    mkdir -p "$OUT/$1-logs"
    for s in $(docker compose config --services); do
        docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$1-logs/$s.log" 2>&1
    done
    {
        echo "compose_file=$COMPOSE_FILE"
        echo "braco=${BRACO:-}"
        echo "n_ues=${2:-0}"
        (cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)")
        (cd ../UERANSIM && echo "ueransim=$(git describe --tags --dirty)")
        echo "imagem=$(docker compose config 2>/dev/null | sed -n 's/.*image: \(core-simplified\/open5gs:[^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')"
    } > "$OUT/$1.meta"
    COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
}

ue_ip() { docker compose exec -T ue ip -4 -o addr show uesimtun0 | awk '{ sub(/\/.*/, "", $4); print $4 }'; }

# Um ping da rede (no espaço de rede do UPF) para o UE, registado como acontecimento <rótulo>.
# Usa $UPF, $UE_IP e $NOME da corrida.
ping_rede() {  # <rótulo>
    t0=$(agora)
    docker run --rm --network "container:$UPF" core-simplified/ueransim:v3.3.0 \
        ping -c 1 -W 3 "$UE_IP" >> "$OUT/$NOME.ping-rede" 2>&1 || true
    sleep 8
    echo "$t0 $(agora) $1" >> "$OUT/$NOME.eventos"
}

# --- frota: memória e capacidade de N dispositivos guardados, apagados e de volta ---
if echo "$CORRIDAS" | grep -qw frota; then
    NOME=frota-n$N$SUF
    arrancar "$NOME" "$N"
    sleep 120                                 # janela calma: registados e parados
    amostra "$OUT/$NOME.memoria.tsv" S1
    t0=$(agora)
    [ "$N" -gt 0 ] && cobertura down
    if [ "$N" -gt 0 ]; then
        espera_conta amf "Mobile Reachable Timer Expired" "$N" 600
    else
        sleep 300
    fi
    sleep 30
    echo "$t0 $(agora) sem-cobertura" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S2
    t0=$(agora)
    if [ "$N" -gt 0 ]; then
        espera_conta amf "Implicit De-registered" "$N" 600
    else
        sleep 300
    fi
    echo "$t0 $(agora) desregisto" >> "$OUT/$NOME.eventos"
    sleep 120
    amostra "$OUT/$NOME.memoria.tsv" S3
    t0=$(agora)
    if [ "$N" -gt 0 ]; then
        antes=$(conta ue "Registration is successful")
        cobertura up
        espera_conta ue "Registration is successful" $((antes + N)) 300
    fi
    echo "$t0 $(agora) regresso" >> "$OUT/$NOME.eventos"
    sleep 60
    amostra "$OUT/$NOME.memoria.tsv" S4
    terminar "$NOME" "$N"
fi

# --- dl: pacotes da rede para um dispositivo ausente e depois do regresso ---
if echo "$CORRIDAS" | grep -qw dl; then
    NOME=dl$SUF
    arrancar "$NOME" 1
    UPF=$(docker compose ps -q upf)
    UE_IP=$(ue_ip)
    T=$(agora)
    cobertura down
    sleep 60
    for i in 1 2 3 4 5 6; do ping_rede "dl-ausente-$i"; sleep 12; done
    # Antes de o mobile reachable timer expirar (300 s depois de adormecer): o UE volta com um
    # registo periódico (o seu T3512 expirou sem cobertura)
    cobertura up
    sleep 30
    echo "$T $(agora) ausencia" >> "$OUT/$NOME.eventos"
    ping_rede dl-regresso
    sleep 15
    t0=$(agora)
    docker compose exec -T ue ping -c 1 -W 3 -I uesimtun0 10.45.0.1 >> "$OUT/$NOME.ping-ue" 2>&1 || true
    sleep 15
    echo "$t0 $(agora) ul-regresso" >> "$OUT/$NOME.eventos"
    echo "ue_ip=$UE_IP" > "$OUT/$NOME.ue_ip"
    terminar "$NOME" 1
fi

# --- ausencia: 15 min sem cobertura, pacotes para o dispositivo inalcançável e o regresso ---
if echo "$CORRIDAS" | grep -qw ausencia; then
    NOME=ausencia$SUF
    arrancar "$NOME" 1
    UPF=$(docker compose ps -q upf)
    UE_IP=$(ue_ip)
    T=$(agora)
    cobertura down
    espera_conta amf "Mobile Reachable Timer Expired" 1 600
    sleep 10
    echo "$T $(agora) ate-inalcancavel" >> "$OUT/$NOME.eventos"
    # Inalcançável: na referência o AMF ainda chama (paging); com a 0008 responde "UE not reachable"
    for i in 1 2 3 4 5 6; do ping_rede "dl-inalcancavel-$i"; sleep 12; done
    amostra "$OUT/$NOME.memoria.tsv" S2
    # Sem cobertura até 900 s depois de a perder (o desregisto implícito da referência é aos ~600 s)
    resto=$(python3 -c "print(max(0, int(900 - ($(agora) - $T))))")
    sleep "$resto"
    t0=$(agora)
    antes=$(conta ue "Registration is successful")
    cobertura up
    espera_conta ue "Registration is successful" $((antes + 1)) 120
    sleep 20                                  # o gNB liberta-o ao fim de 10 s sem tráfego
    echo "$T $t0 ausencia" >> "$OUT/$NOME.eventos"
    echo "$t0 $(agora) regresso" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S4
    # Depois do regresso: um pacote da rede (paging, se o core ainda tiver a sessão) e um do UE
    ping_rede dl-regresso
    sleep 15
    t0=$(agora)
    docker compose exec -T ue ping -c 1 -W 3 -I uesimtun0 10.45.0.1 >> "$OUT/$NOME.ping-ue" 2>&1 || true
    sleep 15
    echo "$t0 $(agora) ul-regresso" >> "$OUT/$NOME.eventos"
    echo "ue_ip=$UE_IP" > "$OUT/$NOME.ue_ip"
    terminar "$NOME" 1
fi

# --- manutencao: N dispositivos sem cobertura 15 min (manutenção do gNB) e o regresso em massa ---
if echo "$CORRIDAS" | grep -qw manutencao; then
    NOME=manutencao-n$N$SUF
    arrancar "$NOME" "$N"
    amostra "$OUT/$NOME.memoria.tsv" S1
    T=$(agora)
    cobertura down
    espera_conta amf "Mobile Reachable Timer Expired" "$N" 600
    sleep 10
    echo "$T $(agora) ate-inalcancavel" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S2
    # Sem cobertura até 900 s depois de a perder (na referência, desregisto implícito aos ~600 s)
    resto=$(python3 -c "print(max(0, int(900 - ($(agora) - $T))))")
    sleep "$resto"
    amostra "$OUT/$NOME.memoria.tsv" S3
    desde=$(linhas_ue)
    t0=$(agora)
    cobertura up
    espera_ues "Registration is successful" "$desde" "$N" 600
    sleep 20                                  # o gNB liberta-os ao fim de 10 s sem tráfego
    echo "$t0 $(agora) regresso" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S4
    # O primeiro envio de cada um: Service Request (sessão guardada) ou sessão nova (referência)
    t0=$(agora)
    uplink_todos "$N"
    sleep 30
    echo "$t0 $(agora) uplink" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S5
    terminar "$NOME" "$N"
fi

# --- reinicio: dispositivos que reiniciam (voltam com o SUCI) não deixam contextos para trás ---
if echo "$CORRIDAS" | grep -qw reinicio; then
    NOME=reinicio-n$N$SUF
    arrancar "$NOME" "$N"
    amostra "$OUT/$NOME.memoria.tsv" S1
    # (a) com cobertura: o contentor dos UEs reinicia e o UERANSIM volta sem nada guardado
    desde=$(linhas_ue)
    t0=$(agora)
    docker compose restart ue >/dev/null 2>&1
    espera_ues "PDU Session establishment is successful" "$desde" "$N" 300
    sleep 20
    echo "$t0 $(agora) reinicio-alcancavel" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" R1
    # (b) inalcançáveis (com a 0007 o core guarda-os) e depois reiniciam: o reinício recria a rede
    # do contentor, por isso a cobertura volta com ele
    IF_RAN=$(docker compose exec -T ue ip -4 -o addr show | awk '$4 ~ /^10\.100\.5\./ { print $2 }')
    antes=$(conta amf "Mobile Reachable Timer Expired")
    t0=$(agora)
    cobertura down
    espera_conta amf "Mobile Reachable Timer Expired" $((antes + N)) 600
    sleep 10
    echo "$t0 $(agora) ate-inalcancavel" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" S2
    desde=$(linhas_ue)
    t0=$(agora)
    docker compose restart ue >/dev/null 2>&1
    espera_ues "PDU Session establishment is successful" "$desde" "$N" 300
    sleep 20
    echo "$t0 $(agora) reinicio-inalcancavel" >> "$OUT/$NOME.eventos"
    amostra "$OUT/$NOME.memoria.tsv" R2
    terminar "$NOME" "$N"
fi

# --- ciclos: desregisto implícito e regresso repetidos 3 vezes (o resíduo do heap estabiliza?) ---
if echo "$CORRIDAS" | grep -qw ciclos; then
    NOME=ciclos-n$N$SUF
    arrancar "$NOME" "$N"
    amostra "$OUT/$NOME.memoria.tsv" C0
    for c in 1 2 3; do
        antes=$(conta amf "Implicit De-registered")
        t0=$(agora)
        cobertura down
        espera_conta amf "Implicit De-registered" $((antes + N)) 900
        sleep 30
        echo "$t0 $(agora) desregisto-$c" >> "$OUT/$NOME.eventos"
        amostra "$OUT/$NOME.memoria.tsv" D$c
        desde=$(linhas_ue)
        t0=$(agora)
        cobertura up
        espera_ues "Registration is successful" "$desde" "$N" 600
        sleep 20
        # sessões novas: o UERANSIM só as pede quando tem dados para enviar
        uplink_todos "$N"
        espera_ues "PDU Session establishment is successful" "$desde" "$N" 300
        sleep 30
        echo "$t0 $(agora) regresso-$c" >> "$OUT/$NOME.eventos"
        amostra "$OUT/$NOME.memoria.tsv" C$c
    done
    terminar "$NOME" "$N"
fi
echo "fase 1 -> $OUT ($CORRIDAS, N=$N)"
