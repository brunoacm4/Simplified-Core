#!/usr/bin/env bash
# Mede o custo em CPU do heartbeat NF<->NRF, variando o intervalo e medindo o
# DECLIVE em vez da diferenca entre dois extremos.
#
# Porque assim: os healthchecks do Docker correm de 2 em 2 segundos em 12
# containers -- muito mais carga do que 0,9 heartbeats/s. Comparar 10s com 3600s
# seria procurar um sinal pequeno dentro de ruido grande. Medindo com heartbeats
# MUITO frequentes o sinal fica grande, e o custo por transacao sai do declive.
# O ruido dos healthchecks e identico em todos os pontos, logo nao afeta o declive.
#
# Le contadores exatos do cgroup v2 (usage_usec), nao amostragem do 'docker stats'.
#
# Uso:  analysis/cpu-cost.sh [segundos_por_ponto] [intervalos...]

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DUR="${1:-240}"; shift || true
INTERVALS=("${@:-2 4 10}")
[[ $# -eq 0 ]] && INTERVALS=(2 4 10)

NFS="nrf scp ausf udm udr pcf nssf bsf amf smf"

cpu_total() {   # microssegundos de CPU somados sobre todas as NFs
    local t=0 v
    for nf in $NFS; do
        v=$(docker exec "panic-$nf" cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk '/^usage_usec/{print $2}')
        t=$(( t + ${v:-0} ))
    done
    echo "$t"
}

echo "=========================================================================="
echo " Custo em CPU do heartbeat NF<->NRF   (${DUR}s por ponto, core em repouso)"
echo "=========================================================================="
echo
printf '%10s %10s %14s %12s %14s\n' "intervalo" "tx/s" "CPU (s)" "mCPU" "us por tx"
printf '%10s %10s %14s %12s %14s\n' "---------" "------" "--------------" "------------" "--------------"

RESULTS=()
for iv in "${INTERVALS[@]}"; do
    python3 analysis/set-heartbeat.py "$iv" >/dev/null
    make down >/dev/null 2>&1
    make up-core >/dev/null 2>&1
    sleep 20                                    # deixar assentar o arranque

    N=$(docker exec panic-scp curl -s -m 5 --http2-prior-knowledge \
        http://10.55.0.10:7777/nnrf-nfm/v1/nf-instances 2>/dev/null \
        | grep -o "nf-instances/" | wc -l)
    N=${N:-10}

    A=$(cpu_total); sleep "$DUR"; B=$(cpu_total)

    python3 - "$iv" "$N" "$A" "$B" "$DUR" <<'PY'
import sys
iv, n, a, b, dur = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
cpu_s = (b - a) / 1e6
rate  = n / iv
print(f"{iv:9d}s {rate:9.2f} {cpu_s:14.2f} {cpu_s/dur*1000:12.1f} {'':>14}")
PY
    RESULTS+=("$iv $N $(( B - A )) $DUR")
done

echo
printf '%s\n' "${RESULTS[@]}" > /tmp/cpu-points.txt
python3 - <<'PY'
# Regressao linear: CPU/s = a * (transacoes/s) + b
# 'a' e o custo marginal por transacao; 'b' e tudo o resto (healthchecks, idle).
xs, ys = [], []
for line in open("/tmp/cpu-points.txt"):
    iv, n, dcpu, dur = (int(x) for x in line.split())
    xs.append(n / iv)                 # transacoes por segundo
    ys.append(dcpu / 1e6 / dur)       # segundos de CPU por segundo
if len(xs) >= 2:
    mx, my = sum(xs)/len(xs), sum(ys)/len(ys)
    den = sum((x-mx)**2 for x in xs)
    a = sum((x-mx)*(y-my) for x, y in zip(xs, ys))/den if den else 0
    b = my - a*mx
    print(f"  custo marginal por transacao de heartbeat: {a*1e6:.0f} us de CPU")
    print(f"  base independente do heartbeat (healthchecks, idle): {b*1000:.1f} mCPU")
    print()
    for iv, lbl in ((10, "por omissao"), (60, ""), (3600, "")):
        r = 10/iv
        print(f"  a {iv:5d}s -> {r:6.3f} tx/s -> {a*r*1000:7.3f} mCPU  "
              f"({a*r*86400:.1f} s de CPU por dia) {lbl}")
PY
python3 analysis/set-heartbeat.py default >/dev/null
echo
echo "  (configuracoes repostas no valor por omissao)"
