#!/bin/sh
# Regista o assinante por defeito do UE (valores de config/ueransim/ue.yaml)
# usando o open5gs-dbctl dentro do contentor mongodb, e reinicia o UE.
#
# Uso: ./scripts/add-subscriber.sh [IMSI KEY OPC]
set -e
cd "$(dirname "$0")/.."

IMSI=${1:-999700000000001}
KEY=${2:-465B5CE8B199B49FAA5F0A2EE238A6BC}
OPC=${3:-E8ED289DEBA952E4283B54E88E6183CA}

EXISTS=$(docker compose exec -T mongodb mongosh --quiet mongodb://localhost/open5gs \
    --eval "db.subscribers.countDocuments({imsi: '$IMSI'})")

if [ "$EXISTS" = "0" ]; then
    docker compose exec -T mongodb bash /opt/open5gs-dbctl add "$IMSI" "$KEY" "$OPC"
else
    echo "Assinante $IMSI já existe, não foi adicionado."
fi
docker compose restart ue
