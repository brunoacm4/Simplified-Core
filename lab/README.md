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

## Fork do UERANSIM (`patches/`)

O UERANSIM é compilado a partir do clone local (`../UERANSIM`), que está no ramo **`panic/v3.3.0`**
(a partir da tag v3.3.0). As nossas alterações estão em `patches/`, uma por ficheiro, com a
justificação no cabeçalho:

| Patch | O que faz | Porquê |
|---|---|---|
| `0001-reverter-selecao-amf-por-slice.patch` | Reverte a seleção de AMF por slice no gNB (commits upstream `2da35a6` e `ef42482`) | Sem isto um UE não consegue voltar do modo idle: o gNB falha a seleção de AMF num Service Request. Afeta as tags v3.2.7 a v3.3.0; corrigido só no master. O commit também punha o UE a enviar o Requested NSSAI sem proteção, contra a TS 24.501 §4.4.6 |
| `0002-ngksi-no-registo-de-mobilidade.patch` | `sendMobilityRegistration()` passa a preencher o ngKSI a partir do contexto de segurança atual | Sem isto o UE declara não ter chave (ngKSI = 7) em todos os registos de mobilidade e periódicos: o core faz uma autenticação 5G-AKA completa e destrói as sessões PDU. Medido: 9 NGAP e ~21 pedidos SBI, contra 5 NGAP e 0 SBI com o patch. Por corrigir no upstream |
| `0003-temporizador-de-inatividade-no-gnb.patch` | Acrescenta ao gNB um temporizador de inatividade: liberta o contexto do UE ao fim de N segundos sem tráfego do utilizador (causa NGAP `user inactivity`) | Sem isto o UE nunca vai a CM-IDLE e os procedimentos do ciclo de inatividade não existem. **Desligado por omissão** (`inactivityTimer: 0`), para não alterar as medições já feitas; liga-se na variante `idle` |
| `0004-limpar-dados-pendentes-ao-ligar.patch` | Limpa o estado "dados de subida pendentes" ao entrar em CM-CONNECTED | Sem isto um dispositivo que transmita um pacote de cada vez só acorda **uma vez**: o sinalizador fica preso a `true` e os pacotes seguintes já não pedem ligação. Sintoma: `ps-list` mostra `data-pending: true` com o UE em CM-IDLE. Por corrigir no upstream |

O ramo está publicado em **https://github.com/brunoacm4/UERANSIM** (fork de `aligungr/UERANSIM`),
ramo `panic/v3.3.0`, commit `0e29cfd`.

A partir de uma máquina limpa:

```bash
git clone -b panic/v3.3.0 https://github.com/brunoacm4/UERANSIM.git UERANSIM
cd lab && docker compose build gnb           # a mesma imagem serve gNB e UE
```

Ou, partindo de um clone do upstream, aplicando os patches à mão:

```bash
cd ../UERANSIM
git checkout -b panic/v3.3.0 v3.3.0
git apply ../lab/patches/0001-reverter-selecao-amf-por-slice.patch
git apply ../lab/patches/0002-ngksi-no-registo-de-mobilidade.patch
git apply ../lab/patches/0003-temporizador-de-inatividade-no-gnb.patch
git apply ../lab/patches/0004-limpar-dados-pendentes-ao-ligar.patch
cd ../lab && docker compose build gnb
```

Verificação após aplicar: uma corrida de registo tem de continuar a dar **9 NGAP e 16 pedidos SBI**.

## Variantes

Uma variante é um conjunto de alterações por cima da baseline, em `variantes/<nome>/`, aplicado com um
compose adicional (`docker compose -f docker-compose.yml -f variantes/<nome>/compose.yml ...`).

| Variante | O que muda | Código? |
|---|---|---|
| `sem-scp` | Sem SCP: as NFs falam diretamente entre si e usam a NRF (modelo B, TS 23.501 Anexo E) | Não (só configuração) |
| `idle` | `inactivityTimer: 10` no gNB: os UEs adormecem 10 s depois do último pacote e acordam com um Service Request. Exercita o ciclo de inatividade | Sim (patch 0003 no UERANSIM) |

## Medições

```bash
# uma corrida "do zero" (derruba o lab, captura desde o arranque, mede CPU/memória, arranca o UE)
[VARIANTE=sem-scp] ./scripts/capturar-registo.sh <pasta> corrida1
./scripts/analisar.py <pasta>/corrida1.pcapng            # métricas -> corrida1.metricas.json

# experiência completa: N corridas alternadas baseline/variante + comparação
./scripts/experiencia.sh ../notes/experiencias/<data>-<variante> <variante> 5
./scripts/comparar.py <pasta>/baseline <pasta>/<variante> [--md resultados.md]

# cenário "fábrica" (S2): dispositivos que transmitem e adormecem pelo meio
[VARIANTE=sem-scp] N_UES=20 PERIODO=30 DURACAO=300 \
  ./scripts/cenario-fabrica.sh <pasta> corrida1
./scripts/analisar-fabrica.py <pasta>/corrida1.pcapng    # -> corrida1.fabrica.json
```

**Dois cenários:**

| | O que é | Para que serve |
|---|---|---|
| S1 "arranque" | N UEs registam-se e ficam ligados (`capturar-registo.sh`) | Comparável com tudo o que já medimos e com a literatura |
| S2 "fábrica" | Temporizador de inatividade ligado; cada dispositivo transmite de PERIODO em PERIODO segundos durante DURACAO | O realista: é o ciclo que domina a carga de uma rede industrial |

**Duas referências**, reportadas lado a lado em cada experiência: **Open5GS por omissão** (referência
externa, para os totais acumulados) e **sem SCP** (base de trabalho, para o ganho da SCP não
contaminar cada passo novo).

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
