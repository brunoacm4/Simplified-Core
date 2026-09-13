# Fase 1 do AMF modular: compilar sem a maquinaria NGAP de handover

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

## O que ficou por remover, e porquê

Construtores, funções de envio, e as ramificações de handover no
`nsmf-handler.c`. Com os pontos de entrada NGAP removidos, esse código fica
**inalcançável** — o handover nunca pode ser iniciado — mas continua compilado.

Daí o binário encolher apenas 1,6 %.

Separá-lo de facto exige tratar o acoplamento com a gestão de sessões, e é a
**fase 1b**.

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
