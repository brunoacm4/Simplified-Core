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

## Forks (`patches/`)

Os dois projetos são compilados a partir dos clones locais, cada um no seu ramo. As nossas
alterações estão em `patches/<projeto>/`, uma por ficheiro, com a justificação e os valores
medidos no cabeçalho.

| Projeto | Clone | Ramo | Publicado em |
|---|---|---|---|
| Open5GS | `../open5gs` | `panic/v2.8.0` | https://github.com/brunoacm4/Open5GS |
| UERANSIM | `../UERANSIM` | `panic/v3.3.0` | https://github.com/brunoacm4/UERANSIM |

### Open5GS (`patches/open5gs/`)

| Patch | O que faz | Porquê |
|---|---|---|
| `0001-remover-ue-context-in-smf-data.patch` | O AMF deixa de pedir `ue-context-in-smf-data` à UDM durante o registo | A UDM responde sempre um objeto vazio e o AMF nunca lê a resposta. Medido: registo passa de 16 para 15 pedidos SBI e de 64 para 60 mensagens HTTP, sem alterar N1/N2/N3 |
| `0002-t3512-dinamico.patch` | T3512 por dispositivo: com `amf.time.t3512.dynamic`, cada registo periódico é respondido com o dobro do valor, até `max` (1 hora); os temporizadores de alcançabilidade acompanham o valor de cada dispositivo | Numa fábrica com dispositivos de ritmos diferentes nenhum T3512 fixo serve a todos: baixo gasta rádio em registos periódicos nos lentos, alto atrasa a deteção de dispositivos mortos. TS 23.501 §5.3.2 (valor por UE, política local). **Desligado por omissão** |
| `0003-hexdump-so-quando-mostrado.patch` | `ogs_log_hexdump_func` sai logo se o nível do log não mostra o dump | Formatava sempre o dump (um snprintf por byte) e só depois o descartava; o servidor SBI faz um em cada escrita HTTP/2. Medido: log do ciclo acordar/adormecer 252 → 86 µs; CPU por UE no registo −11 a −17% |
| `0004-smf-sem-novo-registo-no-udm.patch` | Numa ativação provocada pela rede (paging), o SMF já registado no UDM responde ao AMF e marca o plano de utilizador ativo, sem novo `Nudm_UECM_Registration` | Reutilizava o caminho do fim do estabelecimento da sessão: 2 SBI a mais por comando a um dispositivo adormecido e uma "sessão criada" a mais nas métricas. TS 23.502 §4.2.3.3 não tem Nudm_UECM. Medido: ciclo pela rede 9/5/6 → 9/3/6 (NGAP/SBI/PFCP) |
| `0005-smf-sessao-ja-inativa.patch` | O SMF responde sem PFCP a um pedido para desativar uma sessão já inativa | O AMF pede a desativação de todas as sessões em cada adormecer, mesmo as que nada ativou (por exemplo depois de um registo periódico). Medido: esse adormecer 3/1/2 → 3/1/0. **Precisa da 0004** |
| `0006-pcf-ligacao-bsf-por-sessao.patch` | Cada sessão apaga a sua ligação no BSF ao terminar a política | Uma verificação de 2021 mantinha a ligação quando havia outra sessão para a mesma DNN e slice; o BSF guarda-as pelo endereço do UE, por isso as das sessões libertadas ficavam lá. Medido: 4 criações e 0 remoções → 4 e 3 |
| `0007-desregisto-implicito-configuravel.patch` | Prazo do desregisto implícito configurável (`amf.time.implicit_deregistration`: segundos depois de inalcançável, ou `never`) | Fase 1: numa população conhecida, um dispositivo horas sem cobertura não deve voltar com registo inicial e sessão nova. Guardá-lo custa ~33 KiB de heap e um lugar por pool. Medido: regresso + 1.º envio 23/27/6 → 14/4/4; com 100 UEs, latência do core 84 → 3,2 ms. **Desligado por omissão; usar com a 0008 e a 0009** |
| `0008-amf-ue-not-reachable-sem-paging.patch` | PPF por UE; com `amf.reachability.reject_when_unreachable`, um N1N2MessageTransfer para um UE inalcançável recebe 504 UE_NOT_REACHABLE em vez de paging | O Open5GS fazia paging a UEs já dados como inalcançáveis (TS 23.502 §4.2.3.3). Medido: 1.º pacote 3/2/2 (3 Paging) → 0/1/2. **Desligado por omissão** |
| `0009-smf-upf-deitar-fora-buffer.patch` | Com `smf.dl_buffering.drop_when_unreachable`, o SMF manda o UPF deitar fora os pacotes guardados (PFCP DROBU) quando o UE está inalcançável ou o paging falha | O UPF só avisa do primeiro pacote guardado: sem isto, depois do regresso os comandos da rede ficavam no UPF ("sessão muda") e o UE recebia os velhos de uma vez. Medido: comando depois do regresso perdido → entregue; 7 pacotes velhos → 0; cada pacote para um UE inalcançável custa 0/1/4. **Desligado por omissão** |

### UERANSIM (`patches/ueransim/`)

| Patch | O que faz | Porquê |
|---|---|---|
| `0001-reverter-selecao-amf-por-slice.patch` | Reverte a seleção de AMF por slice no gNB (commits upstream `2da35a6` e `ef42482`) | Sem isto um UE não consegue voltar do modo idle: o gNB falha a seleção de AMF num Service Request. Afeta as tags v3.2.7 a v3.3.0; corrigido só no master. O commit também punha o UE a enviar o Requested NSSAI sem proteção, contra a TS 24.501 §4.4.6 |
| `0002-ngksi-no-registo-de-mobilidade.patch` | `sendMobilityRegistration()` passa a preencher o ngKSI a partir do contexto de segurança atual | Sem isto o UE declara não ter chave (ngKSI = 7) em todos os registos de mobilidade e periódicos: o core faz uma autenticação 5G-AKA completa e destrói as sessões PDU. Medido: 9 NGAP e ~21 pedidos SBI, contra 5 NGAP e 0 SBI com o patch. Por corrigir no upstream |
| `0003-temporizador-de-inatividade-no-gnb.patch` | Acrescenta ao gNB um temporizador de inatividade: liberta o contexto do UE ao fim de N segundos sem tráfego do utilizador (causa NGAP `user inactivity`) | Sem isto o UE nunca vai a CM-IDLE e os procedimentos do ciclo de inatividade não existem. **Desligado por omissão** (`inactivityTimer: 0`), para não alterar as medições já feitas; liga-se na variante `idle` |
| `0004-limpar-dados-pendentes-ao-ligar.patch` | Limpa o estado "dados de subida pendentes" ao entrar em CM-CONNECTED | Sem isto um dispositivo que transmita um pacote de cada vez só acorda **uma vez**: o sinalizador fica preso a `true` e os pacotes seguintes já não pedem ligação. Sintoma: `ps-list` mostra `data-pending: true` com o UE em CM-IDLE. Por corrigir no upstream |

### Montar a partir de uma máquina limpa

```bash
git clone -b panic/v2.8.0 https://github.com/brunoacm4/Open5GS.git open5gs
git clone -b panic/v3.3.0 https://github.com/brunoacm4/UERANSIM.git UERANSIM
cd lab && docker compose build
```

Ou, partindo dos clones do upstream, aplicando os patches à mão:

```bash
cd ../open5gs && git checkout -b panic/v2.8.0 v2.8.0
for p in ../lab/patches/open5gs/*.patch; do git apply "$p"; done
cd ../UERANSIM && git checkout -b panic/v3.3.0 v3.3.0
for p in ../lab/patches/ueransim/*.patch; do git apply "$p"; done
cd ../lab && docker compose build
```

Verificação: uma corrida de registo tem de dar **9 mensagens NGAP e 15 pedidos SBI**
(eram 16 antes do patch 0001 do Open5GS).

## Variantes

Uma variante é um conjunto de alterações por cima da baseline, em `variantes/<nome>/`, aplicado com um
compose adicional (`docker compose -f docker-compose.yml -f variantes/<nome>/compose.yml ...`).

| Variante | O que muda | Código? |
|---|---|---|
| `sem-scp` | Sem SCP: as NFs falam diretamente entre si e usam a NRF (modelo B, TS 23.501 Anexo E) | Não (só configuração) |
| `idle` | `inactivityTimer: 10` no gNB: os UEs adormecem 10 s depois do último pacote e acordam com um Service Request. Exercita o ciclo de inatividade | Sim (patch 0003 no UERANSIM) |
| `t3512-30min` | T3512 de 30 min, acima do período de reporte dos dispositivos (candidato C10a) | Não (só configuração) |
| `t3512-60s` | T3512 de 1 min, para gerar registos periódicos densos e medir o custo de cada um | Não (só configuração) |
| `smf-sem-diameter` | SMF sem a ligação Diameter (freeDiameter) do EPC | Não (só configuração) |
| `t3512-dinamico` | Cada dispositivo começa com T3512 de 9 min; a cada registo periódico o AMF duplica-lhe o valor, até 1 hora (`amf.time.t3512.dynamic`/`max`) | Sim (patch do T3512 dinâmico no Open5GS) |
| `fase1` | T3512 de 1 min (como a `t3512-60s`) e as opções dos patches 0007–0009 em braços cumulativos escolhidos com `BRACO=` (`ref`, `0007`, `0008`, `0009`) | Sim (patches 0007–0009 no Open5GS) |
| `vitimas` | Não é uma variante do core: contentor extra de UEs (IMSIs a partir de …021) que o cenário "fábrica" desliga de repente para medir o tempo de deteção. Ligado com `VITIMAS=` | Não |

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

# população mista, fase de aprendizagem e vítimas (experiência do T3512 dinâmico)
VARIANTE=t3512-dinamico N_UES=20 POPULACAO="30:10 900:10" APRENDIZAGEM=1800 DURACAO=3600 \
  VITIMAS="30:2 900:2" ./scripts/cenario-fabrica.sh <pasta> corrida1
./scripts/analisar-t3512.py <pasta>/corrida1.meta          # por classe e vítimas -> corrida1.t3512.json

# procedimentos isolados, 1 dispositivo: acordar pela rede (paging) e perda de rede com regresso
# antes/depois do desregisto implícito (tc netem no UE); mensagens por acontecimento
[N=5] [CORRIDAS="paging regresso"] ./scripts/medir-grupo1.sh <pasta>
./scripts/analisar-grupo1.py <pasta>/paging.pcapng
[N=3] ./scripts/medir-grupo2.sh <pasta>                      # segunda sessão PDU e libertação
./scripts/analisar-grupo1.py <pasta>/sessoes.pcapng

# história completa de uma fábrica de 3 dispositivos (variante fabrica3, tempo acelerado, ~21 min)
./scripts/historia-fabrica.sh <pasta>
./scripts/analisar-historia.py <pasta>/historia.pcapng       # -> historia.historia.json

# perfil de CPU do ciclo acordar/adormecer (perf com DWARF num contentor auxiliar, images/perf/)
docker build --build-arg BASE=core-simplified/open5gs:v2.8.0-o2 -t core-simplified/perf:o2 images/perf   # e :o0 com BASE=...:v2.8.0
[IMAGEM=o2] [VARIANTE=sem-scp|baseline] ./scripts/perfil-ciclo.sh <pasta> <nome>
./scripts/analisar-perfil.py <pasta>/<nome>.meta              # µs de CPU por ciclo, por categoria

# fase 1 (dispositivos ausentes): memória por dentro das funções (gdb no contentor perf: heap talloc,
# mallinfo2, pools), perda de cobertura com tc netem; corridas frota, dl, ausencia, manutencao,
# reinicio, ciclos (descritas no cabeçalho do script)
[N=100] [CORRIDAS="frota dl"] [AMF_VARIANTE=fase1 BRACO=0009] ./scripts/medir-fase1.sh <pasta> [sufixo]
./scripts/analisar-fase1.py <pasta>/<nome>.meta              # tabelas por amostra, CPU, latência, logs
./scripts/analisar-grupo1.py <pasta>/<nome>.pcapng           # mensagens por acontecimento
```

**Build -O2 (desde 2026-10-15).** Até essa data a imagem do Open5GS foi compilada com o buildtype por
omissão do meson ("debug", -O0, imagem `core-simplified/open5gs:v2.8.0`). As contagens de mensagens não
dependem disso; o CPU sim (−19% por ciclo com -O2). A baseline passou a ser
`core-simplified/open5gs:v2.8.0-o2` (`docker compose build` já passa os `MESON_ARGS`). Para reproduzir
as medições antigas: variante `o0` (só troca a imagem; combina com qualquer outra).

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
