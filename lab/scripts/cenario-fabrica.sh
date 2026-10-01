#!/bin/sh
# Cenário "fábrica" (S2): N dispositivos registam-se, transmitem de PERIODO em PERIODO segundos
# e adormecem pelo meio (temporizador de inatividade do gNB ligado, variante 'idle').
#
# Mede a fase de regime, não o arranque: o registo inicial de todos os dispositivos fica fora
# da janela de medição.
#
# Uso: [VARIANTE=sem-scp] [N_UES=20] [PERIODO=30] [DURACAO=300] \
#        ./scripts/cenario-fabrica.sh <pasta-de-saída> <nome>
#
# Para uma população mista (T3512 dinâmico), todas desligadas por omissão:
#   POPULACAO="30:10 900:10"  um período por dispositivo, por ordem de IMSI (aqui 10 de 30 s e
#                             depois 10 de 15 min); substitui PERIODO e tem de somar N_UES
#   APRENDIZAGEM=1800         segundos de tráfego antes da janela de medição, para um core que se
#                             ajusta aos dispositivos ser medido já ajustado
#   VITIMAS="30:2 900:2"      contentor extra de dispositivos (variantes/vitimas), que transmitem até
#                             ao fim da janela e são então desligados de repente; a corrida continua
#                             até o AMF os dar a todos como desregistados (ou DETECAO_MAX segundos)
# (Não se chama PERIODOS porque o varrimento-fabrica.sh já usa esse nome, e os filhos herdam-no.)
#
# Gera em <pasta>:
#   <nome>.pcapng        captura (br-n2, br-sbi, br-n4) de toda a corrida
#   <nome>.recursos.tsv  CPU acumulada e memória por serviço em 2 instantes (I=início, F=fim da janela)
#   <nome>.meta          parâmetros da corrida, incluindo os limites da janela de medição
#   <nome>-logs/         logs de cada serviço
# Os assinantes têm de existir na base de dados (ver scripts/add-subscribers.sh).
set -e
cd "$(dirname "$0")/.."

OUT=$(realpath "$1"); NAME=$2
VARIANTE=${VARIANTE:-baseline}    # variante do CORE (baseline, sem-scp, ...); o 'idle' é sempre aplicado
export N_UES=${N_UES:-20}
PERIODO=${PERIODO:-30}            # segundos entre transmissões de cada dispositivo; 0 = sem tráfego
DURACAO=${DURACAO:-300}           # duração da janela de medição, em segundos
ESPERA_CORE=${ESPERA_CORE:-25}    # segundos entre o arranque do core e os UEs
ESPERA_REGISTO=${ESPERA_REGISTO:-180}  # tempo máximo à espera que todos os UEs tenham sessão
# Janela em repouso (dispositivos registados e a dormir) antes do tráfego. Por omissão é um quarto
# da janela de medição, entre 60 e 300 s: com 60 s fixos, extrapolar o custo de fundo para uma janela
# de 30 minutos tinha erro maior do que o próprio valor que se quer medir.
REPOUSO=${REPOUSO:-0}
if [ "$REPOUSO" -eq 0 ]; then
    REPOUSO=$((DURACAO / 4))
    [ "$REPOUSO" -lt 60 ] && REPOUSO=60
    [ "$REPOUSO" -gt 300 ] && REPOUSO=300
fi
POPULACAO=${POPULACAO:-}
APRENDIZAGEM=${APRENDIZAGEM:-0}
VITIMAS=${VITIMAS:-}
DETECAO_MAX=${DETECAO_MAX:-4500}  # 75 min: chega para o T3512 de 30 min (desregisto aos 68 min)

# Número de dispositivos de uma especificação "período:quantos ..."
soma() { echo "$1" | tr ' ' '\n' | awk -F: '{ n += $2 } END { print n + 0 }'; }
if [ -n "$POPULACAO" ] && [ "$(soma "$POPULACAO")" -ne "$N_UES" ]; then
    echo "POPULACAO tem $(soma "$POPULACAO") dispositivos e N_UES é $N_UES" >&2
    exit 1
fi
export N_VITIMAS=$(soma "$VITIMAS")

if [ "$VARIANTE" = baseline ]; then
    export COMPOSE_FILE=docker-compose.yml:variantes/idle/compose.yml
else
    export COMPOSE_FILE=docker-compose.yml:variantes/$VARIANTE/compose.yml:variantes/idle/compose.yml
fi
UES=ue
if [ -n "$VITIMAS" ]; then
    COMPOSE_FILE=$COMPOSE_FILE:variantes/vitimas/compose.yml
    UES="ue vitimas"
fi
mkdir -p "$OUT/$NAME-logs"

CORE=$(docker compose config --services | grep -vx -e ue -e vitimas | tr '\n' ' ')
TEMPORIZADOR=$(awk '/^inactivityTimer:/{print $2}' variantes/idle/config/ueransim/gnb.yaml)

snap() {
    for s in $(docker compose ps --services --status running); do
        id=$(docker compose ps -q "$s")
        cg=/sys/fs/cgroup/system.slice/docker-$id.scope
        cpu=$(awk '/^usage_usec/{print $2}' "$cg/cpu.stat")
        mem=$(cat "$cg/memory.current")
        printf '%s\t%s\t%s\t%s\n' "$1" "$s" "$cpu" "$mem"
    done >> "$OUT/$NAME.recursos.tsv"
}

# Lista túnel=período para o trafego.sh a partir de uma especificação "período:quantos ...", por
# ordem de IMSI. O túnel de cada IMSI sai do log do UE: os túneis são numerados pela ordem em que as
# sessões ficam prontas, que não é a dos IMSIs.
mapa_periodos() {  # <serviço> <especificação>
    docker compose logs --no-log-prefix "$1" 2>/dev/null \
        | sed -n 's/.*\[\([0-9]*\)|app\].*TUN interface\[\(uesimtun[0-9]*\),.*/\1 \2/p' \
        | sort -n -u -k1,1 \
        | awk -v spec="$2" '
            BEGIN { n = split(spec, g, " ")
                    for (i = 1; i <= n; i++) { split(g[i], p, ":"); for (j = 0; j < p[2]; j++) per[++k] = p[1] } }
            { printf "%s%s=%s", (NR > 1 ? "," : ""), $2, per[NR] }'
}

# Gerador de tráfego num contentor de UEs; <periodo> é um número (0 = sem tráfego) ou uma lista
# túnel=período.
trafego() {  # <serviço> <periodo> <duração>
    if [ "$2" = 0 ]; then
        sleep "$3"
    else
        docker compose exec -T "$1" sh -s "$2" "$3" < scripts/trafego.sh >/dev/null 2>&1 || true
    fi
}

COMPOSE_FILE=docker-compose.yml docker compose down --remove-orphans >/dev/null 2>&1
docker compose up --no-start >/dev/null 2>&1
: > "$OUT/$NAME.recursos.tsv"

dumpcap -q -i br-n2 -i br-sbi -i br-n4 -w "$OUT/$NAME.pcapng" >/dev/null 2>&1 &
CAP=$!
sleep 2

docker compose up -d $CORE >/dev/null 2>&1
sleep "$ESPERA_CORE"
docker compose up -d $UES >/dev/null 2>&1

# Esperar que todos os dispositivos tenham sessão PDU antes de começar a medir.
espera=0
while [ "$espera" -lt "$ESPERA_REGISTO" ]; do
    prontos=$(docker compose logs $UES 2>/dev/null | grep -c "PDU Session establishment is successful" || true)
    [ "$prontos" -ge "$((N_UES + N_VITIMAS))" ] && break
    sleep 5; espera=$((espera + 5))
done
prontos=$(docker compose logs $UES 2>/dev/null | grep -c "PDU Session establishment is successful" || true)
[ "$prontos" -ge "$((N_UES + N_VITIMAS))" ] || \
    echo "AVISO: só $prontos de $((N_UES + N_VITIMAS)) dispositivos com sessão"

# Deixar os dispositivos adormecer antes de medir: sem isto a janela apanhava a cauda do arranque.
sleep 20

# Janela em repouso: dispositivos registados e a dormir, sem tráfego nenhum. Serve para separar o
# que o core gasta por existir (heartbeats, temporizadores) do que gasta por causa dos dispositivos.
T_REPOUSO=$(date +%s.%N)
snap R
sleep "$REPOUSO"
# Com aprendizagem, o repouso acaba aqui, antes do tráfego, e não no início da janela
T_APRENDIZAGEM=
if [ "$APRENDIZAGEM" -gt 0 ]; then
    T_APRENDIZAGEM=$(date +%s.%N)
    snap A
fi

if [ -n "$POPULACAO" ]; then
    PERIODO=$(mapa_periodos ue "$POPULACAO")
    [ "$(echo "$PERIODO" | tr ',' '\n' | grep -c =)" -eq "$N_UES" ] || \
        echo "AVISO: períodos atribuídos a menos de $N_UES dispositivos: $PERIODO"
fi

# O tráfego corre durante a aprendizagem e a janela de medição; a janela começa quando a aprendizagem
# acaba (sem aprendizagem, logo no início). Com PERIODO=0 não há tráfego de dados: os dispositivos só
# acordam por iniciativa própria (registo periódico), o que serve para medir o custo do registo
# periódico isoladamente, com um T3512 curto.
[ -n "$VITIMAS" ] && trafego vitimas "$(mapa_periodos vitimas "$VITIMAS")" $((APRENDIZAGEM + DURACAO)) &
trafego ue "$PERIODO" $((APRENDIZAGEM + DURACAO)) &
TRAFEGO=$!
sleep "$APRENDIZAGEM"

T_INICIO=$(date +%s.%N)
snap I
wait $TRAFEGO
snap F
T_FIM=$(date +%s.%N)

kill $CAP; wait $CAP 2>/dev/null || true

# Vítimas: desligadas de repente no fim da janela, sem se desregistarem. Morrem depois da janela para
# que o desregisto implícito (uma rajada de SBI e PFCP) não caia dentro dela nalgumas variantes e
# noutras não. A corrida continua até o AMF as dar a todas como desregistadas.
T_MORTE=; T_DETECAO=
if [ -n "$VITIMAS" ]; then
    IMSIS=$(docker compose logs --no-log-prefix vitimas 2>/dev/null \
        | sed -n 's/.*\[\([0-9]*\)|app\].*TUN interface.*/imsi-\1/p' | sort -u | paste -sd'|')
    T_MORTE=$(date +%s.%N)
    docker kill "$(docker compose ps -q vitimas)" >/dev/null
    espera=0; mortos=0
    while [ "$espera" -lt "$DETECAO_MAX" ]; do
        mortos=$(docker compose logs amf 2>/dev/null | grep -cE "\[($IMSIS)\] Implicit De-registered" || true)
        [ "$mortos" -ge "$N_VITIMAS" ] && break
        sleep 30; espera=$((espera + 30))
    done
    T_DETECAO=$(date +%s.%N)
    [ "$mortos" -ge "$N_VITIMAS" ] || echo "AVISO: só $mortos de $N_VITIMAS vítimas desregistadas"
fi

for s in $(docker compose config --services); do
    docker compose logs --no-log-prefix --no-color "$s" > "$OUT/$NAME-logs/$s.log" 2>&1
done

cat > "$OUT/$NAME.meta" <<EOF
cenario=fabrica
variante=$VARIANTE
data=$(date -Iseconds)
open5gs=$(git -C ../open5gs describe --tags --always --dirty)/$(git -C ../open5gs branch --show-current)
ueransim=$(git -C ../UERANSIM describe --tags --always --dirty)/$(git -C ../UERANSIM branch --show-current)
compose_file=$COMPOSE_FILE
n_ues=$N_UES
periodo=$PERIODO
temporizador=$TEMPORIZADOR
duracao=$DURACAO
ues_prontos=$prontos
t_repouso=$T_REPOUSO
repouso=$REPOUSO
t_inicio=$T_INICIO
t_fim=$T_FIM
servicos_core=$CORE
populacao=$POPULACAO
aprendizagem=$APRENDIZAGEM
t_aprendizagem=$T_APRENDIZAGEM
vitimas=$VITIMAS
n_vitimas=$N_VITIMAS
t_morte=$T_MORTE
t_detecao=$T_DETECAO
EOF
echo "$NAME (fabrica/$VARIANTE): $N_UES dispositivos, periodo ${PERIODO}s, janela ${DURACAO}s -> $OUT/$NAME.pcapng"
