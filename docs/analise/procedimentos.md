# Auditoria de procedimentos — o que sobra do core 5G sem mobilidade

Documento vivo. É daqui que deve sair a figura central do artigo.

**Regra:** cada linha nasce de evidência — uma captura nossa, uma leitura da
especificação, ou uma medição. Enquanto não houver evidência, fica marcada
como hipótese. Não se classifica nada por intuição.

---

## Método

Quatro lentes sobre cada mecanismo, sempre pela mesma ordem:

1. **Norma** — o que a especificação diz que é, e sobretudo *que problema
   resolve*. Sem isto arriscamo-nos a remover algo sem perceber para que servia.
2. **Observação** — vê-lo acontecer numa captura nossa.
3. **Código** — onde vive no Open5GS, que estado mantém, o que custaria retirá-lo.
4. **Experiência** — alterar e medir a diferença. É o que transforma opinião em
   resultado.

## Níveis de intervenção

Distinguir isto evita confundir ganhos de ordens de grandeza diferentes.

| Nível | O que é | Ganho esperado |
|---|---|---|
| **0 — configuração** | não instalar funções de rede que a norma já torna opcionais | **não é contribuição — é o baseline honesto** |
| **1 — parâmetros** | mudar valores que a norma já permite variar | limitado, risco de compatibilidade nulo |
| **2 — procedimentos** | deixar de executar procedimentos inteiros que só servem casos que aqui nunca ocorrem | médio; exige verificar o que a norma torna opcional |
| **3 — arquitetura e código** | remover o estado e o código que suportam a generalidade não usada | ordens de grandeza; invisível no ar, visível em memória, CPU e complexidade |

**Restrição transversal, não negociável:** o UE é comercial e **não se
modifica**. Podem mudar-se temporizadores e políticas. Não se podem mudar
formatos de mensagens, porque o dispositivo do outro lado deixaria de os ler.

Corolário importante: otimizar a **mensagem** rende bytes; otimizar a
**maquinaria por trás da mensagem** rende ordens de grandeza.

### O nível 0 não é contribuição — é o ponto de partida

Qualquer operador competente remove as funções de rede opcionais com um ficheiro
de configuração. Reivindicar isso como resultado seria reclamar crédito por algo
que a norma já dá de graça, e um revisor diria — com razão — que desligámos
componentes opcionais.

**Regra que daí decorre: qualquer ganho reivindicado tem de ser medido contra o
nível 0, nunca contra a configuração por omissão do Open5GS.**

A contribuição vive no nível 3: retirar maquinaria de dentro de uma função de
rede, o que nenhuma configuração consegue fazer.

## Regra das três unidades

**Nunca classificar um mecanismo como "removível com ganho" a partir de contagens
de mensagens.** Estabelecida a 2026-09-04, a custo: os heartbeats NF↔NRF geram
78 000 transações por dia — e custam 66 segundos de CPU. A contagem sugeria um
ganho enorme; a medição mostrou um ganho irrelevante.

Toda a entrada desta tabela tem de passar por:

| Unidade | Porquê |
|---|---|
| **Transações** | quantidade de trabalho de plano de controlo |
| **Bytes** | carga de rede e de serialização |
| **CPU** | o que decide hardware, energia e escalabilidade real |

Quando as três discordam — e discordam — vale a última.

---

## Funções de rede dispensáveis por norma (nível 0)

Levantamento documental de 2026-09-12. **O 3GPP não define nenhum perfil mínimo
do 5GC** — verificado contra as listas de *study* e *work items* do SA2 para
Rel-18 e Rel-19. A afirmação defensável é que *nenhum SID/WID dedicado visa um
perfil reduzido*; a afirmação larga, de que o 3GPP nunca considerou
simplificação, não se sustenta e não é necessária.

Conjunto mínimo com base normativa: **AMF, SMF, UPF, AUSF, UDM, UDR, NRF**.

| NF | Base normativa da opcionalidade |
|---|---|
| **PCF** | TS 23.502 cl. 4.3.2.2.1 passo 7a — sem PCC dinâmico, *"the SMF may apply local policy"*, e gera a *default QoS rule* a partir de configuração local |
| **BSF** | TS 23.501 cl. 6.2.20 — só é exigido quando existem múltiplos PCFs separadamente endereçáveis |
| **SCP** | TS 23.501 Annex E — os modelos de comunicação A e B são diretos e não o usam |
| **NSSF** | TS 23.501 cl. 5.15 — só consultado quando o AMF não determina localmente a *Allowed NSSAI*. Confere com a medição: 0 pedidos em 659 |

O piso teórico é ainda mais baixo: o **UDR** pode ser colocado com o UDM e o
**NRF** é dispensável em comunicação direta com configuração estática (modelo A),
o que daria 5 funções de rede. O Open5GS não o permite sem alterações de código.

**Consequência para as medições já feitas.** Tudo o que medimos até 2026-09-04
foi contra o Open5GS com as **11 funções que arranca por omissão**, das quais
quatro são opcionais. Os números continuam válidos como observação, mas **não
servem de referência**: parte do custo que atribuímos à arquitetura SBA é, na
verdade, auto-infligido pela configuração por omissão. Ver a nota em
[`../../results/summaries/2026-09-04-heartbeats.md`](../../results/summaries/2026-09-04-heartbeats.md).

**Fronteira dura descoberta no mesmo levantamento:** a *RedCap indication* chega
ao AMF por NGAP na Initial UE Message (TS 23.502 cl. 4.2.2.2.1; TS 38.413) e é
propagada a SMF, PCF e SMSF. Parece simplificação do lado do dispositivo e é,
na prática, uma obrigação do core — bom caso de estudo do que é observável do
exterior.

### Decisão 2026-09-12: trabalho de remoção PARADO

Chegou a ser planeada uma experiência para remover NSSF, PCF, BSF e SCP e
estabelecer com isso um novo baseline. **Foi parada antes de começar**, por uma
objeção que não tem resposta com o que sabemos hoje:

> Remover estas funções encerra suposições sobre o cenário que nunca declarámos
> — que há **uma só fatia de rede** e que **não é precisa política de QoS
> diferenciada**. Nenhuma das duas está justificada. Uma fábrica real pode
> perfeitamente querer várias fatias (controlo de movimento, vídeo, sensores) e
> quase de certeza precisa de tratamento diferenciado entre elas.

Consequência direta: **não há baseline possível enquanto o cenário alvo não
estiver definido** — quantas fatias, que classes de serviço, que requisitos
temporais. Isso depende da TS 22.104 e da orientação, não de medição.

Corolário para a entrada do NSSF mais abaixo: "nunca é invocado" é verdade
**num deployment de uma fatia**. Não é uma propriedade de redes industriais.

O que fica desta linha de trabalho, e é sólido por ser independente do cenário:
a base normativa da opcionalidade (tabela acima) e o achado sobre o SMF do
Open5GS (a seguir).

### Achado de implementação: o SMF do Open5GS exige sempre PCF

Verificado no código-fonte, tag `v2.7.7`, commit `318eeb49a7dc` — o mesmo que
corre nas nossas imagens.

A TS 23.502 cl. 4.3.2.2.1 passo 7a permite que, sem PCC dinâmico, *"the SMF may
apply local policy"*. **O Open5GS não implementa essa alternativa.** Em
`src/smf/nudm-handler.c`, a chamada ao PCF é incondicional:

```c
r = smf_sbi_discover_and_send(
        OGS_SBI_SERVICE_TYPE_NPCF_SMPOLICYCONTROL, NULL,
        smf_npcf_smpolicycontrol_build_create, sess, stream, 0, NULL);
```

Não há ramo alternativo nem caminho de política local.

**Pista falsa a evitar:** existe uma família de parâmetros `no_pcf`, `no_nssf`,
`no_bsf`, `no_scp` em `lib/app/ogs-config.c`. **Não são interruptores de
funcionamento** — são usados apenas em `tests/app/`, onde um único binário
arranca as NFs como threads para testes automáticos, e dizem-lhe quais arrancar.

**Consequência:** mínimo normativo = 7 NFs; mínimo alcançável no Open5GS só por
configuração = 9, talvez 8. A diferença é o PCF, e o BSF por arrasto.

**Oportunidade de contribuição:** implementar no SMF o caminho de política local
que a norma já prevê. É conforme por construção, remove uma função de rede do
deployment, é submetível ao projeto Open5GS, e mede uma distância concreta entre
o que a norma permite e o que as implementações fazem — que é o que o enunciado
pede na comparação entre cores.

**Por verificar:** as citações acima vieram de um levantamento que usou em parte
*mirrors* e fontes secundárias. Cada uma tem de ser confirmada no PDF oficial
antes de sustentar qualquer afirmação da tese, e fixada numa única Release.

## Classificação

### Contexto de UE no AMF — estado permanente por dispositivo

Estrutura `amf_ue_s`, `src/amf/context.h` linhas 301–678 (Open5GS v2.7.7,
commit `318eeb49a7dc`). **378 linhas de estado, mantidas enquanto o dispositivo
estiver registado** — meses, num cenário estático. Escala com o número de
dispositivos. É o custo contínuo mais diretamente ligado à mobilidade que
identificámos até hoje.

**Classificação provisória (2026-09-12):**

| Família | Campos |
|---|---|
| **Identidade e segurança** | SUPI, SUCI, PEI/IMEISV, MSISDN, PLMN de origem, `kamf`, `knas_int`, `knas_enc`, `kgnb`, `rand`, `autn`, `xres_star`, `hxres_star`, `abba`, contadores UL/DL, algoritmos selecionados, capacidades de segurança |
| **Mobilidade** | `handover{...}`, `old_guti`, `amf_ue_context_transfer_state`, `to_release_session_list`, `guami`, `nr_tai`, `nr_cgi`, `ue_location_timestamp`, `last_visited_plmn_id`, `ran_ue_holding_id`, `ueRadioCapability`, `gmm_capability{ho_attach, s1_mode}`, temporizadores `mobile_reachable`, `implicit_deregistration`, `t3513` (paging) |
| **Fatiamento** | `requested_nssai`, `allowed_nssai`, `rejected_nssai`, `slice[]` — todos dimensionados a `OGS_MAX_NUM_OF_SLICE` |
| **Política** | `policy_association` |
| **Sessão e subscrição** | `sess_list`, `ue_ambr`, `rat_restrictions` |
| **Gestão interna** | objeto SBI, máquina de estados, `memento` (cópia para restauro após transação falhada), `data_change_subscription` |

**Observações:**

- O **GUTI não é classificável de uma vez.** A identidade temporária é
  necessária — é assim que o dispositivo é referido sem expor o identificador
  permanente. Mas a sua *estrutura* (Região, Set e Pointer do AMF) é
  encaminhamento para o caso de reaparecer noutro AMF. Com um AMF, é constante.
  O campo fica; o conteúdo degenera.
- **Oito temporizadores declarados na mesma linha**, cada um com buffer, timer e
  contador de retentativas: `t3513, t3522, t3550, t3555, t3560, t3570,
  mobile_reachable, implicit_deregistration`. Pelo menos três são de mobilidade
  ou alcançabilidade.
- Os campos de fatiamento reservam espaço para o máximo de fatias suportado,
  independentemente de quantas existam no deployment.

**Medição (2026-09-12).** Tamanhos exatos extraídos com `pahole` sobre os
binários compilados com informação DWARF, a partir da etapa de compilação da
nossa própria imagem — logo, o mesmo código que corre no laboratório.

`amf_ue_s` = **8752 bytes**, 77 membros. Mais **1800 bytes** por sessão PDU
(`amf_sess_s`). Um dispositivo registado com uma sessão custa ~**10,3 KB**.

| Família | bytes | % |
|---|---:|---:|
| **Fatiamento** | 5512 | **63,0 %** |
| Gestão interna (objeto SBI 1544, memento 484, máquina de estados) | 2097 | 24,0 % |
| Identidade e segurança | 603 | 6,9 % |
| **Mobilidade** | **291** | **3,3 %** |
| Outros temporizadores | 120 | 1,4 % |
| Sessão e subscrição | 40 | 0,5 % |
| Política | 32 | 0,4 % |

Para 200 dispositivos: **2,1 MB** no total, dos quais **57 KB** de mobilidade.

**Conclusão: a hipótese não se confirma em estado.** O AMF não está dominado por
maquinaria de mobilidade — são 3,3 %. É a quarta medição consecutiva a apontar
no mesmo sentido, depois do CPU dos heartbeats, da memória do core e do custo
das funções de rede desnecessárias.

**O que domina é o fatiamento, e é desperdício de implementação.** O campo
`slice[8]` ocupa 5312 bytes — 61 % da estrutura sozinho — por ser um array
dimensionado para o máximo de fatias suportado, alocado sempre. Com uma fatia,
~4,6 KB por dispositivo ficam alocados e por usar. **Não é exigência da norma**:
é uma escolha de implementação do Open5GS, tal como a ausência de política local
no SMF.

**O que esta medição NÃO diz, e é o essencial.** Mediu-se **estado, não código**.
Que o campo `handover` ocupe 64 bytes nada diz sobre quantas linhas, estados da
máquina de estados e procedimentos existem no AMF por causa da mobilidade. E o
AMF modular é sobre **remover código e procedimentos**, não sobre poupar bytes.
O resultado não invalida esse trabalho — diz que **o argumento não pode ser a
memória**. A medição que falta é de complexidade.

**Ressalvas levantadas na revisão:**

1. **Tudo isto é específico do Open5GS.** O `slice[8]` estático é uma decisão
   deste projeto; outro core terá outros números. A afirmação "63 % é
   fatiamento" descreve o Open5GS, não o 5G. Isto é, por si só, um argumento
   para a comparação entre cores que o enunciado pede — se o free5GC alocar
   dinamicamente, o desperdício é defeito de implementação e não propriedade da
   arquitetura.
2. **Não se simulou funcionamento realista.** Um dispositivo, sem carga, sem
   padrões de tráfego reais. Estes números descrevem estrutura, não impacto.
3. Contabiliza-se o tamanho **estático** da estrutura. O que está pendurado em
   ponteiros (cadeias de caracteres, buffers de temporizadores, capacidades
   rádio) não está incluído.

> **PROVISÓRIA — a revisitar.** As fronteiras desta classificação são
> discutíveis e foram traçadas por leitura, sem seguir o uso de cada campo no
> código. O caso mais duvidoso é o **`ueRadioCapability`**: foi posto em
> mobilidade por ser o que se transfere na preparação de handover, mas também
> serve para a rede configurar o rádio — classificá-lo sem ler quem o consome é
> exatamente o tipo de erro que já cometemos três vezes, sempre a favor da
> hipótese que queríamos confirmar. Outros a confirmar: `guami`, `t3513`,
> `gmm_capability`.
>
> Qualquer número derivado desta classificação muda se ela mudar, e tem de ser
> reportado com essa dependência explícita.

### Complexidade do AMF — quanto código existe para mobilidade

Medido a 2026-09-12 sobre `src/amf/` do Open5GS v2.7.7 (33 751 linhas no total,
30 919 em `.c`). Contagem por função, classificando pelo nome: `handover`,
`path_switch`, `ran_status_transfer`, `paging`, `ue_context_transfer`,
`ue_radio_capability`, `mobility`, `tracking_area`.

| Ficheiro | linhas | mobilidade | % |
|---|---:|---:|---:|
| `ngap-handler.c` | 4935 | 1899 | **38 %** |
| `ngap-build.c` | 2805 | 891 | 32 % |
| `namf-handler.c` | 1971 | 286 | 15 % |
| `ngap-path.c` | 778 | 232 | 30 % |
| `namf-build.c` | 155 | 37 | 24 % |
| `context.c` | 3146 | 27 | 1 % |
| **Total `.c`** | **30 919** | **3372** | **10,9 %** |

**Contagem independente, por procedimento.** O AMF trata **26 procedimentos
NGAP** distintos. Destes, existem para mobilidade: `HandoverPreparation`,
`HandoverResourceAllocation`, `HandoverCancel`, `HandoverNotification`,
`PathSwitchRequest`, `UplinkRANStatusTransfer`, `DownlinkRANStatusTransfer`,
`Paging`, `UERadioCapabilityInfoIndication`, e os dois de
`RANConfigurationTransfer` — **cerca de 10 em 26, ou 38 %**.

Duas medições independentes — linhas de código e contagem de procedimentos —
dão **38 % para a interface N2**. Convergem.

**Máquina de estados 5GMM: 9 estados**, nenhum específico de mobilidade
(`initial`, `de_registered`, `authentication`, `security_mode`,
`initial_context_setup`, `registered`, `exception`, `ue_context_will_remove`,
`final`). Das 16 mensagens NAS tratadas, apenas 2 a 3 são de mobilidade
(`REGISTRATION_TYPE_MOBILITY_UPDATING`, `REGISTRATION_TYPE_PERIODIC_UPDATING`,
e `SERVICE_REQUEST` como adjacente).

**O resultado estrutural — e é o primeiro positivo.** A mobilidade **não está
espalhada** pelo AMF: está **concentrada na interface virada para o RAN**. São
3,3 % do estado, 11 % do código total, mas **38 % da N2**, e zero estados
dedicados na máquina de estados.

Isto é boa notícia para a modularidade. Código difuso a 11 % por todo o lado
seria muito mais difícil de separar do que código concentrado numa fronteira.
**A mobilidade é separável** — e separabilidade, não poupança de recursos, é o
argumento que sustenta o AMF modular.

São ~3400 linhas num componente de 33 mil. Torná-las opcionais é uma alteração
de engenharia real, e a máquina de estados não precisa de ser reestruturada.

**Ressalvas:** a classificação por nome de função é grosseira — há tratamento de
mobilidade dentro de funções sem nome revelador (o registo distingue tipos, um
dos quais é *mobility updating*), o que **subconta**. Linhas de código são um
indicador fraco de complexidade. E tudo isto é específico do Open5GS.

### Fronteira do módulo de mobilidade no AMF

Mapeada a 2026-09-13. Responde à pergunta de desenho do plugin: **por onde é que
o resto do AMF toca no código de mobilidade?**

#### Metade limpa — maquinaria NGAP de handover (~3000 linhas)

**Pontos de entrada: 9 casos, todos num único `switch`** em `ngap-sm.c` (de 24
no total): `PathSwitchRequest`, `HandoverPreparation`,
`HandoverResourceAllocation` (êxito e insucesso), `HandoverCancel`,
`HandoverNotification`, `UplinkRANStatusTransfer`,
`UplinkRANConfigurationTransfer`, `UERadioCapabilityInfoIndication`.

**Zero chamadas de qualquer outro sítio** — verificados os oito tratadores um a
um: nada no resto do AMF lhes toca.

> **CORREÇÃO (2026-09-13), descoberta ao tentar compilar sem eles.** Isto é
> verdade para os **tratadores** e é um mapa insuficiente do **procedimento**.
> Os construtores em `ngap-build.c` são chamados pelas funções de envio em
> `ngap-path.c`, e três destas são chamadas a partir de **`nsmf-handler.c`** —
> o lado do SMF, que não estava classificado como mobilidade e tem 20
> referências a handover, ramificando em estados como
> `AMF_UPDATE_SM_CONTEXT_HANDOVER_REQUIRED`.
>
> **O handover está entrelaçado com a gestão de sessões PDU pelo SBI.** Ver
> [`../../results/summaries/2026-09-13-amf-sem-mobilidade.md`](../../results/summaries/2026-09-13-amf-sem-mobilidade.md).

Estão **fisicamente contíguos**: `ngap-handler.c` linhas 2586–4324, mais os
construtores correspondentes em `ngap-build.c` (`ngap_build_path_switch_ack`,
`handover_request`, `handover_preparation_failure`, `handover_command`,
`handover_cancel_ack`, `downlink_ran_status_transfer`) e os envios em
`ngap-path.c`.

#### Metade entrelaçada — transferência de contexto entre AMFs (N14)

Quando um dispositivo se apresenta com um GUTI atribuído por outro AMF, o AMF
atual vai buscar-lhe o contexto pela N14 — e isso acontece **dentro do fluxo de
registo**. `amf_namf_comm_handle_ue_context_transfer_response` é chamado a partir
do `gmm-sm.c`, a máquina de estados.

**35 pontos de contacto** espalhados pelo caminho do registo: 24 referências em
`gmm-sm.c`, 11 em `gmm-handler.c`. Mais ~320 linhas nos ficheiros `namf-*`.

Não é folha. Está tecido no procedimento que não podemos remover.

#### Consequência: plano por fases

**Cerca de 90 % do código de mobilidade é limpo de separar; os restantes 10 %
exigem refactorização do caminho de registo.**

| Fase | O quê | Risco |
|---|---|---|
| **1** | Maquinaria NGAP de handover — 9 pontos de corte, zero acoplamento | baixo |
| **2** | Transferência de contexto entre AMFs — isolar 35 pontos de contacto no registo | alto; é aqui que está a substância de engenharia |

Nota para o artigo: "separámos código que já estava separado" não é
interessante. "Identificámos e isolámos o acoplamento entre mobilidade e
registo" é. A fase 2 é a contribuição; a fase 1 é a demonstração.

### Configuration Update Command — **removível** (nível 2)

- **O que é.** Procedimento NAS que a rede executa após o registo.
- **Observado em.** Run `20260902-124045`, `nas_5gs.mm.message_type == 0x54`.
- **Conteúdo integral observado:** nome da rede em versão longa (`PANIC`), nome
  da rede em versão curta (`PANIC`), fuso horário, data e hora universal,
  horário de verão.
- **Porque existe.** Num telemóvel: põe o nome da operadora na barra de estado
  e acerta o relógio.
- **Neste cenário.** Um sensor aparafusado a uma máquina não tem ecrã nem
  precisa do nome do operador. Se precisar de sincronismo temporal — e em
  ambiente industrial muitos precisam — não é por aqui que o obtém com a
  precisão necessária, mas por PTP ou TSN.
- **Por verificar.** Se remover `network_name` da configuração do AMF faz o
  procedimento desaparecer, ou se o Open5GS continua a enviá-lo só com a hora.
  Se continuar, passa de nível 2 para nível 3.
- **Ganho.** Um procedimento NAS completo por registo, por dispositivo.

### Registo periódico (T3512) — **candidato forte a remoção** (nível 1)

- **O que é.** A rede exige que o dispositivo se volte a registar de X em X
  segundos, mesmo sem nada a comunicar.
- **Observado em.** Registration Accept, IE `GPRS Timer 3 - T3512 value`.
  Baseline: 540 s = 9 minutos.
- **Escala.** 1440 ÷ 9 = **160 registos periódicos por dispositivo por dia**.
  Mil sensores fixos → 160 mil procedimentos/dia cujo conteúdo informativo é
  "continuo aqui".
- **Porque existe.** É como a rede deteta que um dispositivo morreu — ficou sem
  cobertura, sem bateria, foi desligado — para libertar recursos.
- **O que a norma parece permitir.** A codificação do GPRS Timer 3 tem unidades
  até 320 horas e, aparentemente, uma combinação que significa *temporizador
  desativado*. **A confirmar na especificação** antes de assumir.
- **O argumento.** Não estamos a remover uma salvaguarda: numa fábrica a
  informação "este equipamento está vivo" já existe por outra via — o sistema
  de supervisão sabe, e o protocolo industrial que corre por cima quase de
  certeza já tem o seu próprio heartbeat. O mecanismo celular está a duplicar,
  mais caro, informação que o deployment já tem.
- **Bloqueado empiricamente.** O T3512 arranca e expira, mas o registo periódico
  não é despoletado porque o UE nunca entra em modo idle. Cadeia causal completa
  e testes feitos em [`../lab/topologia.md`](../lab/topologia.md) §6.

### Tracking Area Identity list — **degenerado** (nível 3)

- **O que é.** A lista de zonas onde o dispositivo pode circular **sem ter de
  avisar a rede**. É um contrato: "move-te à vontade aqui dentro; avisa quando
  saíres".
- **Observado em.** Registration Accept, `5GS tracking area identity list`:
  `Number of elements: 1`, `TAC: 1`, com o tipo de lista mais geral que existe
  (`list of TAIs belonging to different PLMNs`), pensado para terminais que
  circulam entre operadores.
- **Neste cenário.** Contrato negociado, codificado e transmitido a cada
  registo, que delimita um conjunto de um elemento do qual o dispositivo nunca
  sai.
- **Onde está mesmo o custo.** Não no campo — são bytes. Na maquinaria por
  trás: estruturas para listas de N elementos, código para detetar saída da
  área, o procedimento de Tracking Area Update que dispararia, e o âmbito do
  paging. Nada disto executa; está tudo lá em memória, ciclos e complexidade.
- **Por isso é nível 3**, e é exatamente o tipo de coisa que o AMF modular
  resolve.

### 5G-GUTI — **formato necessário, política discutível** (nível 2)

- **O que é.** Identidade temporária atribuída ao dispositivo.
- **Observado em.** Registration Accept: `AMF Region ID: 2`, `AMF Set ID: 1`,
  `AMF Pointer: 0`, `5G-TMSI`.
- **Porque tem esta estrutura.** Os três primeiros campos são **informação de
  encaminhamento**: permitem que uma antena qualquer, ao receber o GUTI, saiba
  a que AMF entregar o pedido.
- **Neste cenário.** Com um AMF, `Region 2 / Set 1 / Pointer 0` é constante —
  todos os dispositivos transportam o endereço de um destino que nunca varia.
- **O que NÃO se pode mudar.** O formato. É fixo pela norma e o UE tem de o ler.
- **O que se pode discutir.** A política de reatribuição: cada troca de
  identidade custa um procedimento. Existe por privacidade — uma identidade
  estável no ar permitiria seguir o dispositivo. Numa fábrica, com a máquina à
  vista e presa ao chão, o modelo de ameaça é outro. **Mas é um argumento de
  segurança, e esses fazem-se com muito cuidado.**

### Comunicação indireta SBI (SCP) — **medido, por experimentar** (nível 2/3)

- **O que é.** No Open5GS, por omissão, as chamadas entre funções de rede não
  vão diretamente de uma para a outra: passam por um intermediário, o SCP
  (Modelo D da norma).
- **Medido.** Run `20260901-184920`: **27 pedidos SBI internos** para ligar um
  único dispositivo, contra 13 mensagens NAS trocadas com o próprio
  dispositivo. Cerca de duas transações internas por cada mensagem que chega a
  sair. Ver [`../../results/summaries/2026-09-01-baseline.md`](../../results/summaries/2026-09-01-baseline.md).
- **Experiência pendente.** Configurar comunicação direta (sem SCP) e medir a
  diferença. É o próximo resultado quantificado ao nosso alcance.
- **Adjacente.** A descoberta dinâmica via NRF: procurar em tempo de execução
  quem já se sabe onde está, num sistema onde tudo é conhecido no momento da
  instalação.

### Heartbeats NF↔NRF — **redutível dentro da norma, mas sem ganho relevante**

Não é sobre mobilidade. É sobre a arquitetura SBA, e pode ser o achado mais
forte até agora.

- **O que é.** Cada função de rede confirma periodicamente ao NRF que continua
  viva, com um `PATCH /nnrf-nfm/v1/nf-instances/<id>`.
- **Medido.** Run `20260904-151620`, janela de 420 s com a rede em **repouso
  absoluto** — zero mensagens NAS e zero NGAP depois do segundo 17:

  | Grandeza | Valor |
  |---|---:|
  | Instâncias de NF registadas | 9 |
  | Heartbeats por NF | 41 em 420 s → **um a cada 10,0 s** |
  | Transações de heartbeat no NRF | 369 em 420 s ≈ **0,88/s** |
  | Extrapolado por dia | **~76 000 transações** |
  | Contando os dois saltos (NF→SCP→NRF) | ~152 000 pedidos SBI/dia |
  | Heartbeats PFCP (SMF↔UPF) no mesmo período | 74 pares |
  | Mensagens com dispositivos | **0** |

- **A comparação que interessa.** Ligar um dispositivo custa **27** pedidos SBI.
  Ligar 200 sensores de uma fábrica inteira custa ~5 400 — **menos do que duas
  horas** do core a falar consigo próprio em repouso.
- **Porque é estrutural.** Este custo escala com o **número de funções de rede**,
  não com o número de dispositivos. Numa rede pública com milhões de terminais
  dilui-se até ao irrelevante; numa fábrica com duzentos sensores fixos que se
  ligam uma vez e ficam, torna-se o **termo dominante**.
- **O mesmo padrão de sempre.** O heartbeat existe para detetar funções de rede
  mortas. Num deployment onde todas correm no mesmo host sob um orquestrador
  (Docker, systemd, Kubernetes), essa informação **já existe e é mais barata**.
  Mecanismo genérico a duplicar conhecimento que o deployment já tem — tal como
  o T3512.
**Veredicto: não vale a pena.** O ganho é real e conforme à norma, mas mede-se
em 66 segundos de CPU por dia. Fica documentado como resultado negativo e como
origem da [regra das três unidades](#regra-das-três-unidades).

- **Custo medido nas três unidades.** 78 000 transações/dia · 66 MB/dia ·
  **66 s de CPU/dia (0,08% de um núcleo)**. Para comparar: os healthchecks do
  nosso próprio laboratório custam 150× mais.
- **A norma (TS 29.510).** O mecanismo é obrigatório (`shall`) e não pode ser
  desligado; mas o valor não é limitado e o NRF aceitou 3600 s sem o substituir.
  Aumentar é conforme; desligar não é.
- **O preço do intervalo longo.** É a janela em que o NRF anuncia uma NF morta.
  Medido: 10 s de bloqueio por tentativa de registo, contra <1 ms quando o NRF
  já sabe. Só afeta **quem chega**, nunca quem já está ligado — confirmado em
  sete de sete NFs descobertas pelo NRF.
- **A ligação à tese.** O preço é proporcional à taxa de procedimentos, e a
  mobilidade é o principal motor dessa taxa. Sem mobilidade, o preço colapsa.
  Segunda ligação: o benefício de um heartbeat curto é proporcional à
  **redundância** — com uma instância de cada NF, saber que morreu não permite
  recuperação nenhuma, apenas um erro mais rápido.
- **Experiência (2026-09-04).** O intervalo é configurável em
  `time.nf_instance.heartbeat`. Alterado **só no AMF** para 60 s, com as outras
  oito NFs como grupo de controlo na mesma captura: AMF passou a 5 heartbeats em
  275 s (60,0 s medidos), as restantes mantiveram 10,0 s. `make run` completo
  continua a passar — não quebra funcionalidade. Extrapolando para todas as NFs
  a 60 s: **redução de 83 %**, de ~78 000 para ~13 000 transações/dia. Detalhe e
  ressalvas em
  [`../../results/summaries/2026-09-04-heartbeats.md`](../../results/summaries/2026-09-04-heartbeats.md).

**Ressalvas.** Contam-se transações, não custo: falta medir bytes e CPU, e um
heartbeat é uma mensagem pequena. São valores por omissão, que em produção se
afinariam. E 9 é a decomposição do Open5GS — outro core tem outro N.

**Nota metodológica (importante).** A contagem correta faz-se **no NRF, por
identificador de instância**. Contar no SCP por IP de origem deu resultados
errados (três NFs apareciam com 4 heartbeats em vez de 41), por artefacto da
dissecação HTTP/2 em ligações já estabelecidas quando a captura começou.

### NSSF — **nunca invocado** (nível 3)

O caso mais limpo de função de rede que existe sem fazer nada.

- **Medido.** **0 pedidos `nnssf-*` em 659 pedidos SBI**, numa captura com
  registo completo e estabelecimento de sessão.
- **Confirmado por falha.** Congelar o NSSF (`docker pause`) não impede registo
  nem estabelecimento de sessão. Única NF descoberta pelo NRF em que isso
  acontece — ver a matriz em
  [`../../results/summaries/2026-09-04-heartbeats.md`](../../results/summaries/2026-09-04-heartbeats.md).
- **Porquê.** A sua função é escolher entre fatias de rede. Com uma única fatia,
  escolher é uma operação vazia, e o AMF resolve o slice a partir da própria
  configuração (`plmn_support.s_nssai`).
- **Base normativa (2026-09-12).** TS 23.501 cl. 5.15: o NSSF só é consultado
  quando o AMF não consegue determinar localmente a *Allowed NSSAI*. É portanto
  **opcional por norma**, e a sua remoção é nível 0 — configuração, não
  contribuição.
- **Custo que gera.** Regista-se no NRF, envia heartbeat de 10 em 10 segundos
  para sempre, ocupa ~5,8 MB.
- **Ressalva, pela regra das três unidades.** O ganho de a remover é ~6 MB e uma
  fração de mCPU. **Também é pequeno.** O argumento para a remover não é
  eficiência — é redução de complexidade, de superfície de ataque e de
  componentes a certificar e a manter. Esse argumento é válido mas é de outra
  natureza, e tem de ser feito como tal.

### Ressincronização de SQN — **não removível, mas a contabilizar**

- **Observado em.** Todas as runs: primeiro `Authentication Request` respondido
  com `Authentication failure (Synch failure)`, seguido de nova autenticação.
- **Custo.** Duas mensagens NAS extra e uma ida adicional ao UDM/UDR.
- **Consequência metodológica.** Um "primeiro registo" e um "registo
  subsequente" não custam o mesmo. Qualquer comparação tem de distinguir os dois
  casos, sob pena de produzir uma diferença falsa.

---

## Por classificar

Mecanismos identificados mas ainda sem trabalho feito: paging, Service Request,
handover (Xn e N2), relocação de AMF, seleção de slice (NSSF), política (PCF),
tarifação, interface inter-domínio com o operador.
