#!/bin/sh
# Garante que existem N assinantes com IMSIs consecutivos a partir de 999700000000001,
# clonando o perfil do primeiro (mesma chave K/OPc, como o UERANSIM usa com "nr-ue -n N").
# O primeiro assinante tem de existir (ver add-subscriber.sh). Requer o serviço mongodb a correr.
#
# Uso: ./scripts/add-subscribers.sh <N>
set -e
cd "$(dirname "$0")/.."
N=$1
docker compose exec -T mongodb mongosh --quiet mongodb://localhost/open5gs --eval "
  const base = db.subscribers.findOne({imsi: '999700000000001'});
  if (!base) { print('Falta o assinante 999700000000001'); quit(1); }
  delete base._id;
  let novos = 0;
  for (let i = 1; i <= $N; i++) {
    const imsi = '99970' + String(i).padStart(10, '0');
    if (!db.subscribers.findOne({imsi: imsi})) {
      db.subscribers.insertOne(Object.assign({}, base, {imsi: imsi}));
      novos++;
    }
  }
  print('assinantes criados: ' + novos + ', total: ' + db.subscribers.countDocuments({}));
"
