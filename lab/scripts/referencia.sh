#!/bin/sh
# Referência do lab: as medições que servem de "antes" para cada alteração ao core, com a mesma
# configuração (Open5GS -O2 da baseline do docker-compose.yml). Cerca de 1 h 45.
#
#   registo/   S1: 1, 20 e 100 UEs, baseline (com SCP) e sem-scp alternadas, REPETICOES vezes
#              (scripts/experiencia.sh) — mensagens, CPU, memória e latência do registo
#   fabrica/   S2: 20 e 100 UEs a enviar de 30 em 30 s, 5 min, VARIANTE, REPETICOES vezes
#              intercaladas (scripts/cenario-fabrica.sh) — mensagens, CPU e latência do acordar e do
#              adormecer
#   historia/  a fábrica de três dispositivos (scripts/historia-fabrica.sh), sempre na baseline (com
#              SCP): a história usa a variante t3512-60s, que traz o seu amf.yaml e anula o da sem-scp.
#              As contagens de pedidos SBI lógicos não dependem da SCP.
#
# Uso: [VARIANTE=sem-scp] [REPETICOES=3] ./scripts/referencia.sh <pasta-de-saída>
set -e
cd "$(dirname "$0")/.."
OUT=$(realpath "$1")
VARIANTE=${VARIANTE:-sem-scp}
REPETICOES=${REPETICOES:-3}
mkdir -p "$OUT/registo" "$OUT/fabrica" "$OUT/historia"
echo "início $(date '+%F %T')"

for n in 1 20 100; do
    N_UES=$n ./scripts/experiencia.sh "$OUT/registo/${n}ues" sem-scp "$REPETICOES" \
        > "$OUT/registo/${n}ues.txt" 2>&1
    echo "registo ${n} UEs: $(date '+%T')"
done

for r in $(seq 1 "$REPETICOES"); do
    for n in 20 100; do
        N_UES=$n VARIANTE=$VARIANTE PERIODO=30 DURACAO=300 \
            ./scripts/cenario-fabrica.sh "$OUT/fabrica" "${n}ues-r$r" > /dev/null
        ./scripts/analisar-fabrica.py "$OUT/fabrica/${n}ues-r$r.pcapng" > "$OUT/fabrica/${n}ues-r$r.txt" 2>&1
        echo "fábrica ${n} UEs, repetição $r: $(date '+%T')"
    done
done

VARIANTE=baseline ./scripts/historia-fabrica.sh "$OUT/historia" > "$OUT/historia/corrida.log" 2>&1
./scripts/analisar-historia.py "$OUT/historia/historia.pcapng" > "$OUT/historia/historia.txt" 2>&1
echo "história: $(date '+%T')"
{
    echo "variante=$VARIANTE"; echo "repeticoes=$REPETICOES"
    (cd ../open5gs && echo "open5gs=$(git describe --tags --dirty)")
    (cd ../UERANSIM && echo "ueransim=$(git describe --tags --dirty)")
    echo "imagem=$(docker compose config 2>/dev/null | sed -n 's/.*image: \(core-simplified\/open5gs:[^ ]*\).*/\1/p' | sort -u | tr '\n' ' ')"
} > "$OUT/referencia.meta"
echo "fim $(date '+%F %T')"
