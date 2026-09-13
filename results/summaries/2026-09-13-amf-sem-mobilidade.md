# AMF modular: compilar sem mobilidade (fases 1, 1b e 2)

Primeiro artefacto de engenharia da tese. Open5GS `v2.7.7`, commit `318eeb49a7dc`.

> **Resultado: o AMF compila, liga e passa a verificação completa sem os
> tratadores NGAP de handover.** Registo, autenticação 5G-AKA, sessão PDU e
> tráfego IP funcionam com UE e gNB comerciais não modificados.

## O que foi removido

Por guardas de compilação (`#ifndef PANIC_NO_MOBILITY`), geradas por
[`lab/images/open5gs/make-mobility-optional.py`](../../lab/images/open5gs/make-mobility-optional.py).
Script e não patch, porque um patch fica preso a números de linha e parte com
qualquer atualização do upstream.

| Onde | O quê |
|---|---|
| `ngap-handler.c` | 9 tratadores (~1899 linhas): handover required/request ack/failure/cancel/notification, path switch, uplink RAN status transfer, uplink RAN configuration transfer, UE radio capability |
| `ngap-sm.c` | 9 casos do despacho NGAP, de 24 |
| `ngap-sm.c` | a declaração local `ogs_pkbuf_t *pkbuf` |

## Verificação

| | |
|---|---|
| Compilação e ligação | OK |
| `make run-nomob` (verificação de 30 pontos) | **passou por inteiro** |
| UE | `CM-CONNECTED`, `MM-REGISTERED` |
| Plano de dados | ping pelo túnel, 16,9 ms |
| Símbolos no binário | 5 tratadores de handover **ausentes**; `ngap_handle_initial_ue_message` **presente** (controlo) |
| Binário do AMF | 4 554 488 → 4 483 472 bytes (**−71 KB, −1,6 %**) |

## A correção ao mapa da fronteira

O mapeamento inicial concluiu que os tratadores de mobilidade eram folhas sem
acoplamento. **Isso é verdade para os tratadores, e insuficiente como mapa.**

Ao ligar, falharam seis símbolos. Investigado: os construtores
(`ngap_build_handover_*`, `path_switch_ack`, `downlink_ran_status_transfer`) são
chamados pelas funções de envio em `ngap-path.c`, e três destas são chamadas a
partir de **`nsmf-handler.c`** — o lado do SMF, que não estava classificado como
mobilidade. Tem **20 referências** a handover e ramifica em estados como
`AMF_UPDATE_SM_CONTEXT_HANDOVER_REQUIRED`.

> **O handover não está confinado à interface do RAN. Está entrelaçado com a
> gestão de sessões PDU pelo SBI:** durante um handover, o AMF conduz o SMF a
> mover a sessão, e as respostas do SMF conduzem a continuação do handover.

Esta é a descoberta com mais valor do dia. A medição anterior — "38 % da N2,
zero acoplamento" — media os **tratadores**, não o **procedimento**.

## Fase 1b — remover também o que ficou inalcançável

Na fase 1 ficaram compilados os construtores, as funções de envio e as
ramificações de handover no `nsmf-handler.c` — inalcançáveis, mas presentes.
A fase 1b removeu-os.

### Método: o compilador como instrumento

A fase 1 ensinou que mapear por leitura e nomes de função **não é fiável** — o
meu mapa dizia "zero acoplamento" e o ligador provou o contrário. A fase 1b usou
isso deliberadamente: estender as guardas, compilar, e **tratar cada erro como
um ponto de acoplamento**. Repetir até ligar. O conjunto do que foi preciso
tocar é o mapa, obtido empiricamente em vez de por classificação minha — que já
se mostrou enviesada a favor do que eu esperava.

Foram três iterações.

### O mapa completo do acoplamento

| Onde | O quê |
|---|---|
| `ngap-handler.c` | 9 tratadores + 3 casos do `switch` de ação de libertação de contexto (`NG_HANDOVER_COMPLETE`, `_CANCEL`, `_FAILURE`) |
| `ngap-build.c` | 6 construtores |
| `ngap-path.c` | 6 funções de envio |
| `ngap-sm.c` | 9 dos 24 casos do despacho NGAP |
| `nsmf-handler.c` | 2 casos do `switch` sobre tipo de informação N2 (`PATH_SWITCH_REQ_ACK`, `HANDOVER_CMD`) + 6 ramos `else if` sobre estado de sessão |
| Variáveis locais órfãs | `pkbuf` em `ngap-sm.c`, `r` em `ngap_handle_ue_context_release_action` |

**Total: 21 funções, 20 ramos de despacho, 2 declarações locais.**

### O resultado estrutural

> **Todo o acoplamento está em pontos de despacho — casos de `switch` e cadeias
> `else if` — exceto duas variáveis locais. Nenhum está entrelaçado na lógica
> dos algoritmos.**

Isto é a melhor notícia possível para a modularização: código que ramifica em
despacho separa-se com guardas; código entrelaçado exigiria reescrever
algoritmos. Confirma, agora empiricamente e não por contagem de linhas, que a
mobilidade é separável.

### Verificação

| | |
|---|---|
| `make run-nomob` | **passou por inteiro** |
| UE | `CM-CONNECTED`, `MM-REGISTERED`, ping 13,4 ms |
| Símbolos ausentes | tratadores, construtores **e** funções de envio de handover |
| Símbolos presentes (controlo) | `ngap_handle_initial_ue_message`, `ngap_handle_uplink_nas_transport` |
| Binário do AMF | 4 554 488 → **4 449 200** bytes (**−105 288, −2,3 %**) |

### Nota de método: um bug que quase passou

A primeira tentativa de guardar os ramos `else if` contava chavetas para achar o
fim do ramo. Numa cadeia `if/else if`, as linhas `} else if` são **neutras em
chavetas** — o contador passava ao lado do fim do ramo e **engolia o resto da
cadeia, incluindo ramos que não são de mobilidade**. Teria removido
silenciosamente tratamento de estados normais de sessão.

Detetado por inspeção do ficheiro transformado antes de compilar. A correção foi
mudar de abordagem: guardar apenas o **corpo** do ramo, deixando a cadeia
estruturalmente intacta.

Lição: transformações automáticas de código têm de ser inspecionadas no
resultado, não só validadas por o compilador aceitar.

## Âmbito da afirmação

Isto demonstra que o código é separável e que a rede funciona sem ele **num
cenário de dispositivo estático em cobertura de uma célula**, onde a
funcionalidade removida nunca é invocada. Não demonstra correção num cenário
com várias células — aí o handover seria exercitado e falharia. Essa é
exatamente a premissa da tese, e tem de ser reportada assim.

## Ressalvas

1. Uma execução da verificação. Sem repetições.
2. O ganho em binário (1,6 %) não é o resultado — o resultado é a separabilidade
   demonstrada e o acoplamento identificado.
3. Específico do Open5GS.


---

# Fase 2 — transferência de contexto entre AMFs (N14)

A parte que o mapeamento tinha classificado como **entrelaçada no caminho do
registo**, com 35 pontos de contacto em `gmm-sm.c` e `gmm-handler.c`. Ao
contrário do handover, esta entra por um procedimento que acontece sempre.

## O que a torna removível

Antes de mexer, foi preciso responder a uma pergunta: **num deployment com um só
AMF, este caminho alguma vez é percorrido?**

Toda a maquinaria N14 pende de **uma única função booleana**,
`gmm_registration_request_from_old_amf()` (`gmm-handler.c`). Devolve `true`
apenas se se verificarem três condições em simultâneo: o UE apresenta-se com
GUTI (não SUCI); o GUTI não é um valor de reserva a zeros; e o par PLMN+AMF-ID
do GUTI **não corresponde a nenhum GUAMI servido por este AMF**.

Com um só AMF e configuração estável, o GUTI apresentado foi emitido por nós,
corresponde sempre, e a função devolve `false`. **Reiniciar o AMF é seguro** — o
GUAMI vem da configuração, não do estado em memória.

E há um segundo facto que torna a remoção segura: o bloco imediatamente a seguir
ao teste é `if (!AMF_UE_HAVE_SUCI(amf_ue))` → **pedido de identidade**. Ou seja,
**o caminho alternativo previsto pela norma já está implementado**. Um
dispositivo com GUTI estrangeiro não parte nada: faz um registo completo, com
autenticação de raiz. Mais lento, mas correto.

> A remoção é segura porque a alternativa já existe no código, e não porque
> estejamos a inventar comportamento novo.

## O acoplamento, obtido em seis iterações

| Iteração | O que o compilador revelou |
|---|---|
| 1 | 7 auxiliares estáticas sem uso — exclusivas do N14 |
| 2 | assinaturas em duas linhas escapavam ao detetor de funções |
| 3 | protótipos `static` declarados mas não definidos; mais 3 auxiliares órfãs |
| 4 | 5 símbolos por resolver: chamadas em `amf-sm.c` e `gmm-sm.c`, dentro de blocos `CASE` das macros do Open5GS |
| 5 | a macro `SWITCH` declara uma variável interna; blocos cujos `CASE` foram todos removidos deixavam-na sem uso |
| 6 | 2 blocos `if (amf_ue_context_transfer_state == ...)` que enviam actualização de estado de registo |

**Total guardado na fase 2:** 13 funções, 7 auxiliares estáticas, 6 protótipos,
6 blocos `CASE`, 4 blocos `SWITCH` inteiros, 3 blocos `if`.

## A correção estrutural

Eu tinha previsto que a fase 2 seria qualitativamente mais difícil, por o
acoplamento estar "tecido no caminho do registo". **Estava errado.**

> **Também o N14 está acoplado em pontos de despacho** — blocos `CASE` das
> macros `SWITCH` do Open5GS, mais três blocos `if`. Os 35 pontos de contacto
> que eu tinha contado são, na maioria, verificações de estado **dentro** desses
> blocos, e desaparecem com eles.

A conclusão passa a ser mais forte do que a da fase 1b:

> **Todo o acoplamento da mobilidade no AMF — handover e transferência entre
> AMFs — está em pontos de despacho. Nada está entrelaçado na lógica dos
> algoritmos.**

## Resultados

| | Binário do AMF | vs baseline |
|---|---:|---:|
| Baseline | 4 554 488 | — |
| Fase 1 (tratadores NGAP) | 4 483 472 | −1,6 % |
| Fase 1b (handover completo) | 4 449 200 | −2,3 % |
| **Fase 2 (+ N14)** | **4 330 376** | **−4,9 %** |

**224 112 bytes removidos no total.**

### Verificação

| | |
|---|---|
| `make run-nomob` | **passou por inteiro** |
| UE | `CM-CONNECTED`, `MM-REGISTERED`, ping 13,8 ms |
| Símbolos ausentes | `gmm_registration_request_from_old_amf`, `amf_namf_comm_handle_ue_context_transfer_request`, `amf_namf_comm_build_ue_context_transfer`, e toda a maquinaria de handover |
| Símbolo de controlo presente | `ngap_handle_initial_ue_message` |

Note-se que esta fase mexe no **caminho do registo**, que é exercitado em todas
as execuções — ao contrário do handover, aqui uma regressão seria visível.
Não houve.
