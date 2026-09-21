# Laboratório 5G SA — Open5GS + UERANSIM

Open5GS **v2.8.0** e UERANSIM **v3.3.0**, compilados a partir dos clones locais
(`../open5gs`, `../UERANSIM`), sobre Ubuntu **jammy**.

## Topologia

Um contentor por componente e uma rede Docker por interface 3GPP.

| Rede | Sub-rede | Bridge no host | Quem está ligado |
|---|---|---|---|
| sbi | 10.100.1.0/24 | `br-sbi` | NRF .10, SCP .200, AMF .5, SMF .4, AUSF .11, UDM .12, PCF .13, NSSF .14, BSF .15, UDR .20, MongoDB .100 |
| n2 | 10.100.2.0/24 | `br-n2` | AMF .5, gNB .50 |
| n3 | 10.100.3.0/24 | `br-n3` | UPF .7, gNB .50 |
| n4 | 10.100.4.0/24 | `br-n4` | SMF .4, UPF .7 |
| ran | 10.100.5.0/24 | `br-ran` | gNB .50, UE .60 |

Pool de IPs dos UEs: `10.45.0.0/16` (gateway `10.45.0.1` na `ogstun` do UPF).
PLMN 999/70, TAC 1, SST 1. SEPP não incluído. N6 não configurado.

## Utilização

```bash
cd lab
docker compose build              # compila as imagens (necessário após alterar código)
docker compose up -d              # arranca tudo
./scripts/add-subscriber.sh       # regista o assinante por defeito e reinicia o UE
docker compose logs -f ue         # ver o registo e a sessão PDU
docker compose exec ue ping -c 4 -I uesimtun0 10.45.0.1   # validar plano de utilizador
docker compose down               # parar (o assinante fica no volume mongodb-data)
```

Capturar uma interface no host: `dumpcap -i br-n2 -w n2.pcapng` (sem sudo se o utilizador estiver no
grupo `wireshark`), ou Wireshark na bridge.

## Variantes

Uma variante é um conjunto de alterações por cima da baseline, em `variantes/<nome>/`, aplicado com um
compose adicional (`docker compose -f docker-compose.yml -f variantes/<nome>/compose.yml ...`).

| Variante | O que muda | Código? |
|---|---|---|
| `sem-scp` | Sem SCP: as NFs falam diretamente entre si e usam a NRF (modelo B, TS 23.501 Anexo E) | Não (só configuração) |

## Medições

```bash
# uma corrida "do zero" (derruba o lab, captura desde o arranque, mede CPU/memória, arranca o UE)
[VARIANTE=sem-scp] ./scripts/capturar-registo.sh <pasta> corrida1
./scripts/analisar.py <pasta>/corrida1.pcapng            # métricas -> corrida1.metricas.json

# experiência completa: N corridas alternadas baseline/variante + comparação
./scripts/experiencia.sh ../notes/experiencias/<data>-<variante> <variante> 5
./scripts/comparar.py <pasta>/baseline <pasta>/<variante> [--md resultados.md]
```

Métricas por corrida: mensagens NGAP e pedidos/mensagens SBI por fase (arranque, registo, sessão PDU),
pedidos de gestão na NRF, latência do lado do core, bytes por interface (em repouso e com UE),
CPU e memória por serviço (lidas nos cgroups do host; CPU "líquida" = janela com UE − janela em repouso).

A análise usa a imagem `core-simplified/tshark:jammy` (`images/tshark/`), para não instalar nada no host.
(`scripts/analisar-captura.sh` é a versão anterior, usada na validação de `notes/registo/02-captura.md`.)

## Ficheiros

- `images/` — Dockerfiles em duas fases (build + runtime).
- `config/` — configurações baseadas nos templates do upstream; só mudam endereços
  (e o logging do Open5GS vai só para stdout).
- `scripts/` — criação da `ogstun` no UPF e registo de assinantes.
