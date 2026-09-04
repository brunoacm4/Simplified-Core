#!/usr/bin/env bash
# Verifica que os parametros de identidade da rede nao divergiram entre
# lab/params.env, as configuracoes do Open5GS e as do UERANSIM.
#
# Porque existe: PLMN, TAC e slice desalinhados entre AMF, gNB e UE sao a causa
# numero 1 de falhas de registo, e falham de forma silenciosa -- o UE
# simplesmente nao regista, sem mensagem util. Cinco segundos aqui poupam uma
# tarde de depuracao.
set -uo pipefail

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$LAB/params.env"; set +a

fail=0
check() {  # check <descricao> <esperado> <obtido> <ficheiro>
    if [[ "$2" == "$3" ]]; then
        printf '  \033[32mOK\033[0m   %-28s %s\n' "$1" "$2"
    else
        printf '  \033[31mFALHA\033[0m %-28s esperado=%s obtido=%s  (%s)\n' "$1" "$2" "$3" "$4"
        fail=$((fail+1))
    fi
}

# Extrai o valor de uma chave YAML simples, ignorando comentarios e plicas.
# O '-?' e necessario: muitas destas chaves vivem dentro de listas ("- sst: 1").
yval() { grep -E "^\s*-?\s*$2\s*:" "$1" | head -1 | sed -E "s/.*:\s*'?\"?([^'\"#]*)'?\"?\s*(#.*)?$/\1/" | xargs; }

echo "Coerencia de parametros entre params.env e as configuracoes"
echo
echo "AMF (lab/configs/open5gs/amf.yaml)"
AMF="$LAB/configs/open5gs/amf.yaml"
check "MCC"  "$MCC" "$(yval "$AMF" mcc)" "$AMF"
check "MNC"  "$MNC" "$(yval "$AMF" mnc)" "$AMF"
check "TAC"  "$TAC" "$(yval "$AMF" tac)" "$AMF"
check "SST"  "$SST" "$(yval "$AMF" sst)" "$AMF"
check "IP NGAP" "$IP_AMF_NGAP" "$(grep -A2 '^  ngap:' "$AMF" | yval /dev/stdin address)" "$AMF"

echo
echo "gNB (lab/configs/ueransim/gnb.yaml)"
GNB="$LAB/configs/ueransim/gnb.yaml"
check "MCC"  "$MCC" "$(yval "$GNB" mcc)" "$GNB"
check "MNC"  "$MNC" "$(yval "$GNB" mnc)" "$GNB"
check "TAC"  "$TAC" "$(yval "$GNB" tac)" "$GNB"
check "SST"  "$SST" "$(yval "$GNB" sst)" "$GNB"
check "aponta ao AMF" "$IP_AMF_NGAP" "$(grep -A1 '^amfConfigs:' "$GNB" | yval /dev/stdin address)" "$GNB"

echo
echo "UE (lab/configs/ueransim/ue.yaml)"
UE="$LAB/configs/ueransim/ue.yaml"
check "MCC"  "$MCC" "$(yval "$UE" mcc)" "$UE"
check "MNC"  "$MNC" "$(yval "$UE" mnc)" "$UE"
check "SUPI" "imsi-$TEST_IMSI" "$(yval "$UE" supi)" "$UE"
check "Ki"   "$TEST_KI"  "$(yval "$UE" key)" "$UE"
check "OPc"  "$TEST_OPC" "$(yval "$UE" op)"  "$UE"
check "DNN"  "$DNN" "$(yval "$UE" apn)" "$UE"
check "procura o gNB em" "$IP_GNB_RADIO" "$(grep -A1 '^gnbSearchList:' "$UE" | tail -1 | tr -d ' -')" "$UE"

echo
if (( fail > 0 )); then
    echo "$fail divergencia(s). O registo do UE vai falhar silenciosamente -- corrigir primeiro."
    exit 1
fi
echo "Parametros coerentes."
