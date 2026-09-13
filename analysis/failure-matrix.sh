#!/usr/bin/env bash
# Matriz de impacto de falha: para CADA funcao de rede, o que e que se parte?
#
# Existe para corrigir um enviesamento: a primeira experiencia de falha usou o
# AUSF, que so e consultado durante o registo -- o caso mais favoravel ao
# argumento. Aqui percorrem-se todas, incluindo o UPF, que NAO e descoberto pelo
# NRF e serve de contraste.
#
# Usa-se 'docker pause' (congela o processo) e nao 'kill': a funcao continua
# alcancavel na rede mas nunca responde, que e o caso realista e o pior para
# quem depende dela. Tambem mantem a entrada no NRF, que e o cenario de perfil
# obsoleto que queremos estudar.
#
# Tres perguntas por funcao de rede:
#   1. Uma sessao JA estabelecida sobrevive?      (ping pelo tunel)
#   2. Um dispositivo consegue REGISTAR-SE?        (Registration accept)
#   3. Consegue estabelecer SESSAO?                (uesimtun0 com IP)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

NFS="${*:-ausf udm udr pcf bsf nssf smf upf}"

ue_ready() {   # espera que o UE tenha tunel; devolve 0 se conseguiu
    for _ in $(seq 1 "${1:-25}"); do
        docker exec panic-ue ip -4 addr show uesimtun0 2>/dev/null | grep -q 'inet ' && return 0
        sleep 1
    done
    return 1
}

for n in ausf udm udr pcf bsf nssf smf upf amf; do docker unpause "panic-$n" >/dev/null 2>&1; done

printf '%-6s  %-22s  %-12s  %-12s\n' "NF" "sessao ja ativa" "registo novo" "sessao nova"
printf '%-6s  %-22s  %-12s  %-12s\n' "------" "----------------------" "------------" "------------"

for nf in $NFS; do
    # --- repor estado limpo antes de cada teste -----------------------------
    docker unpause "panic-$nf" >/dev/null 2>&1
    docker restart panic-ue >/dev/null 2>&1
    ue_ready 25 || { printf '%-6s  %s\n' "$nf" "(estado inicial nao recuperou -- saltado)"; continue; }

    # --- congelar a funcao de rede ------------------------------------------
    docker pause "panic-$nf" >/dev/null 2>&1

    # 1. a sessao que ja estava de pe aguenta?
    if docker exec panic-ue ping -I uesimtun0 -c 2 -W 3 -q 1.1.1.1 >/dev/null 2>&1; then
        s1="sobrevive"
    else
        s1="PARTE"
    fi

    # 2 e 3. um dispositivo consegue entrar de novo?
    # ATENCAO: os logs do container acumulam entre reinicios. Contar as linhas
    # ANTES e olhar so para as novas -- caso contrario apanha-se o registo da
    # fase de preparacao e da falso positivo.
    NLINES=$(docker logs panic-ue 2>&1 | wc -l)
    docker restart panic-ue >/dev/null 2>&1
    sleep 15
    NEW=$(docker logs panic-ue 2>&1 | tail -n +$((NLINES+1)))
    if grep -q "Registration accept received" <<<"$NEW"; then s2="ok"; else s2="FALHA"; fi
    if ue_ready 10; then s3="ok"; else s3="FALHA"; fi

    docker unpause "panic-$nf" >/dev/null 2>&1
    printf '%-6s  %-22s  %-12s  %-12s\n' "$nf" "$s1" "$s2" "$s3"
done

# repor
docker restart panic-ue >/dev/null 2>&1; ue_ready 25 >/dev/null
echo
echo "Nota: 'sessao ja ativa' testa quem ja estava ligado; as outras duas colunas"
echo "testam quem chega de novo. E essa distincao que decide o custo real."
