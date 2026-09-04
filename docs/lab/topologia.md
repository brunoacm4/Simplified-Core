# Laboratório PANIC — topologia, desvios e decisões

Documento de referência do baseline. Tudo o que aqui está afeta a interpretação
das medições, por isso qualquer alteração a estes valores obriga a repetir as
medições que dela dependem.

**Versões fixadas:** Open5GS `v2.7.7` (commit `318eeb49a7dc`), UERANSIM `v3.3.0`,
tshark `3.6.2`. Host: Ubuntu 22.04, kernel 6.8, Docker 29.7.

---

## 1. Topologia

```
                    net-uu (10.55.3.0/24)          net-n2n3 (10.55.1.0/24)
   ┌────────┐   rádio simulado   ┌────────┐   N2 (NGAP/SCTP)   ┌────────┐
   │   UE   │───────────────────▶│  gNB   │───────────────────▶│  AMF   │
   │  .60   │                    │  .50   │                    │  .30   │
   └────────┘                    └────────┘                    └────────┘
   uesimtun0                         │  N3 (GTP-U)                  │
   10.45.0.2                         ▼                              │ SBI
                                 ┌────────┐   N4 (PFCP)   ┌────────┐│
                                 │  UPF   │◀─────────────▶│  SMF   ││
                                 │  .40   │  net-n4        │  .31   ││
                                 └────────┘  10.55.2.0/24  └────────┘│
                                     │ N6                       │    │
                                     ▼ NAT                      ▼    ▼
                                 Internet         net-sbi (10.55.0.0/24)
                                                  ┌──────────────────────┐
                                                  │ NRF SCP AUSF UDM UDR │
                                                  │ PCF NSSF BSF  MongoDB│
                                                  └──────────────────────┘
```

**Porque estão as redes separadas.** Cada interface 3GPP tem a sua bridge. Isso
permite contar mensagens *por procedimento e por interface* — que é a métrica
central da tese — sem ter de desemaranhar tudo de uma captura única. Todas as
redes são `internal` exceto a N6, o que garante duas coisas: nenhum tráfego
externo contamina as medições, e a rota por omissão dos containers é
determinística (via `priority` no attachment da N6 do UPF).

**IPs estáticos em todo o lado.** Elimina a ambiguidade do bind em NFs
multi-homed e torna as capturas legíveis sem tabela de tradução. A fonte única é
[`lab/params.env`](../../lab/params.env); `make check-params` confirma que as
configurações não divergiram dela.

---

## 2. Estratégia de captura

**Uma bridge Docker não é um hub.** Um container "sniffer" ligado a uma rede não
vê o tráfego unicast entre os outros containers — só broadcast e o que lhe é
endereçado. Ligar um `tcpdump` à `net-sbi` produz uma captura quase vazia, e
demora a perceber porquê.

A solução usada são **sidecars que partilham o namespace de rede da NF-alvo**
(`network_mode: "service:<nf>"`), correndo `tcpdump -i any`. Cada sidecar vê
exatamente o que a sua NF envia e recebe, em todas as interfaces dela. Como
partilham o relógio do host, os *timestamps* são comparáveis entre ficheiros —
é isso que permitirá decompor latências por interface no passo 2.

Sidecars em `amf`, `smf`, `upf`, `nrf`, `scp` e `gnb`. O do SCP é o mais
informativo: com comunicação indireta, **todo** o plano de controlo SBI passa por
ele, logo um único ficheiro contém-no por inteiro.

**Ordem de arranque.** As capturas do núcleo arrancam antes do gNB, e a do gNB
antes do UE. Se o UE registar antes de os sidecars estarem de pé, perde-se
exatamente o procedimento que queremos medir. É por isso que `make run` tem os
passos na ordem que tem, e não é uma questão de estilo.

---

## 3. Dois parâmetros do tshark sem os quais as capturas parecem vazias

Descobertos a custo. Estão no `verify-e2e.sh` e devem estar em qualquer análise
futura, incluindo as do passo 2.

| Parâmetro | Porquê |
|---|---|
| `-o nas-5gs.null_decipher:TRUE` | Vem **desligado** por omissão. Sem ele, tudo o que segue o Security Mode Command aparece como `UplinkNASTransport` opaco — perdem-se o Registration Accept, a sessão PDU, tudo. É este parâmetro que torna útil o desvio para NEA0. |
| `-d tcp.port==7777,http2` | O SBI corre na porta 7777, que o Wireshark não associa a HTTP/2. Sem isto, zero pacotes SBI reconhecidos — e o SBI é metade do que queremos medir. |

---

## 4. Desvios deliberados face a um deployment de produção

Os três primeiros são revertíveis por configuração e o custo que removem será
medido isoladamente mais à frente.

| Desvio | Motivo | Efeito nas medições |
|---|---|---|
| **Cifra NAS = NEA0** (integridade mantida em NIA2) | Manter as mensagens NAS em claro nas capturas, indispensável para auditar procedimentos | **Não** altera a contagem de sinalização. Altera o custo criptográfico — logo qualquer medição de CPU do AMF sub-estima o caso real |
| **SBI sem TLS** | Tornar os corpos JSON das chamadas entre NFs inspecionáveis | Idem: contagens iguais, custo de CPU e de bytes menor que em produção |
| **SUPI com esquema de proteção nulo** | SUCI legível na captura de registo | Remove uma operação ECIES por registo |
| **RAN e UE simulados** | Não há espectro nem hardware nesta fase | O plano rádio não é modelado. Latências absolutas não são transponíveis para a realidade; **diferenças** entre configurações do core são |
| **Tudo numa máquina** | Sem acesso a VMs no IT nesta fase | Sem latência de rede real entre NFs. Reforça o ponto anterior: medir deltas, não absolutos |

---

## 5. Observações do primeiro arranque

**Ressincronização de SQN no primeiro registo.** Num subscritor acabado de
provisionar, o primeiro Authentication Request é respondido com
`Authentication failure (Synch failure)`, seguido de novo Authentication Request
já com o SQN correto. São **duas mensagens NAS extra** e uma ida adicional ao
UDM/UDR. É comportamento normal do 5G-AKA, mas tem de ser contabilizado: um
"primeiro registo" e um "registo subsequente" não custam o mesmo, e comparar um
com o outro produziria uma diferença falsa.

**Cuidado ao contar pedidos SBI no SCP.** Como o SCP é um relay, a captura no
namespace dele vê cada pedido **duas vezes** — a receber e a reencaminhar. Os
números brutos têm de ser divididos por dois, e os heartbeats para o NRF
(`PATCH /nnrf-nfm/...`) separados do que é sinalização de UE. Formalizar isto é
trabalho do passo 2.

**DNS não atravessa o túnel.** O resolver do container UE é o do Docker
(127.0.0.11), que não é alcançável por `uesimtun0`. Um teste de conectividade
por *nome* falha mesmo com o plano de dados perfeito. Testar sempre por IP.

---

## 6. O que ainda não está aqui

- **free5GC** — o UPF exige o módulo de kernel `gtp5g`, ausente neste host e
  impossível de instalar de dentro de um container. Fica para o passo 3, e
  provavelmente numa VM.
- **Múltiplos UEs** — `make provision N=<n>` já provisiona N subscritores, mas
  falta o lado do UERANSIM. Necessário para o passo 2.
- **Métricas de recursos** — CPU/RAM por NF e estado por UE. É o passo 2.
