#!/bin/sh
# Pegada do core: o que ocupa, sem o correr. É a métrica que mede o que o CPU não mede — código
# adormecido, bibliotecas que se carregam sem se usar, funções que se instalam e não se executam.
#
# Uso: ./scripts/pegada.sh [imagem] > pegada.tsv
#      (por omissão core-simplified/open5gs:v2.8.0; não toca no lab que estiver a correr)
#
# Por função de rede:
#   linhas     linhas de código em src/<nf>/ no clone local (o que foi compilado para a imagem)
#   binario    tamanho do executável, em bytes
#   libs       soma do tamanho das bibliotecas do Open5GS que o executável carrega (ldd)
#   libs_4g    parte dessas bibliotecas que é só do EPC/4G: Diameter, freeDiameter, S1AP.
#              (A biblioteca GTP não conta: tem também o GTP-U que o UPF usa na interface N3 do 5G.)
#   config     número de parâmetros no ficheiro de configuração do lab: linhas "chave: valor",
#              incluindo as que estão dentro de listas ("- chave: valor"). É uma contagem aproximada.
# No fim: tamanho da imagem e o que nela nunca é executado por um core 5G.
set -e
cd "$(dirname "$0")/.."
IMG=${1:-core-simplified/open5gs:v2.8.0}
NFS5G="amf smf upf ausf udm udr pcf bsf nrf nssf scp sepp"
NFS4G="mme hss pcrf sgwc sgwu"

printf 'nf\tlinhas\tbinario\tlibs\tlibs_4g\tconfig\n'
for nf in $NFS5G; do
    linhas=$(cat ../open5gs/src/$nf/*.c ../open5gs/src/$nf/*.h ../open5gs/src/$nf/*.cpp 2>/dev/null | wc -l)
    conf=lab/config/open5gs/$nf.yaml; [ -f "config/open5gs/$nf.yaml" ] && conf=config/open5gs/$nf.yaml
    config=$(grep -cE '^\s*(- )?[A-Za-z_][A-Za-z0-9_]*:\s*[^ #]' "$conf" 2>/dev/null || echo 0)
    docker run --rm --entrypoint sh "$IMG" -c "
        b=/opt/open5gs/bin/open5gs-${nf}d
        bin=\$(stat -c %s \$b)
        libs=0; libs4g=0
        for l in \$(ldd \$b | awk '/\/opt\/open5gs\/lib/ {print \$3}'); do
            t=\$(stat -L -c %s \$l); libs=\$((libs + t))
            case \$l in *diameter*|*libfd*|*s1ap*) libs4g=\$((libs4g + t));; esac
        done
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' $nf $linhas \$bin \$libs \$libs4g $config"
done

docker run --rm --entrypoint sh "$IMG" -c "
    t=0; for nf in $NFS4G; do t=\$((t + \$(stat -c %s /opt/open5gs/bin/open5gs-\${nf}d))); done
    echo \"# binários 4G na imagem (nunca executados num core 5G): \$t bytes\"
    echo \"# bibliotecas do Open5GS na imagem: \$(du -sb /opt/open5gs/lib | cut -f1) bytes\""
echo "# imagem $IMG: $(docker image inspect "$IMG" --format '{{.Size}}') bytes"
