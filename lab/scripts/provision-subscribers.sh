#!/usr/bin/env bash
# Provisiona subscritores diretamente no MongoDB do Open5GS.
#
# Por script e nao pela WebUI: um baseline so vale se for reproduzivel a partir
# do zero por um comando. E parametrizado no numero de subscritores porque no
# passo 2 vamos precisar de N UEs para medir escalabilidade da sinalizacao.
#
# Uso:  provision-subscribers.sh [N]     (N por omissao = 1)
set -euo pipefail

N="${1:-1}"
LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$LAB/params.env"; set +a

echo "A provisionar $N subscritor(es) a partir do IMSI $TEST_IMSI ..."

# Constroi o array de documentos. O esquema e o do Open5GS 2.7 -- se mudar numa
# versao futura, e aqui que se sente.
docs=""
for ((i=0; i<N; i++)); do
    imsi=$(printf '%015d' $((10#$TEST_IMSI + i)))
    [[ -n "$docs" ]] && docs+=","
    docs+=$(cat <<EOF

{
  schema_version: 1,
  imsi: "$imsi",
  msisdn: [], imeisv: [], mme_host: [], mme_realm: [], purge_flag: [],
  security: { k: "$TEST_KI", op: null, opc: "$TEST_OPC", amf: "$TEST_AMF_KEY" },
  ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
  slice: [{
    sst: $SST,
    default_indicator: true,
    session: [{
      name: "$DNN",
      type: 3,
      qos: { index: 9, arp: { priority_level: 8,
                              pre_emption_capability: 1,
                              pre_emption_vulnerability: 1 } },
      ambr: { downlink: { value: 1, unit: 3 }, uplink: { value: 1, unit: 3 } },
      pcc_rule: []
    }]
  }],
  access_restriction_data: 32,
  subscriber_status: 0,
  network_access_mode: 0,
  subscribed_rau_tau_timer: 12,
  __v: 0
}
EOF
)
done

# Via --eval e nao por stdin: por stdin o mongosh comporta-se como sessao
# interativa e enche o ecra de prompts, o que torna o output do 'make' ilegivel.
js=$(cat <<EOF
db = db.getSiblingDB('open5gs');
const subs = [ $docs ];
for (const s of subs) {
    db.subscribers.replaceOne({ imsi: s.imsi }, s, { upsert: true });
}
print("subscritores na base de dados: " + db.subscribers.countDocuments());
EOF
)

docker exec -i panic-mongo mongosh --quiet --eval "$js"
