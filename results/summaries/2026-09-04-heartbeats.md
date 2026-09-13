# Custo fixo da arquitetura SBA: heartbeats NF↔NRF

Open5GS `v2.7.7` (commit `318eeb49a7dc`) · core em repouso, sem RAN salvo indicação.
Reproduzível por `analysis/heartbeats.sh`, `analysis/failure-matrix.sh`,
`analysis/cpu-cost.sh` e `analysis/set-heartbeat.py`.

> **Conclusão em duas linhas.** A otimização é real, está dentro da norma e foi
> verificada — e **não vale a pena**: poupa 66 segundos de CPU por dia. O valor
> deste trabalho não é o ganho; é a regra de método que ele estabelece e a
> direção para onde aponta.

> **Ressalva acrescentada a 2026-09-12 — ler antes de usar estes números.**
> Todas as medições abaixo foram feitas com o Open5GS na sua configuração por
> omissão, que arranca **11 funções de rede**. Um levantamento da norma mostrou
> depois que **quatro delas são opcionais** — NSSF, PCF, BSF e SCP, cada uma com
> base normativa explícita (ver
> [`../../docs/analise/procedimentos.md`](../../docs/analise/procedimentos.md),
> secção "Funções de rede dispensáveis por norma").
>
> Consequência: parte do custo aqui atribuído à arquitetura SBA é **auto-infligido
> pela configuração por omissão**, e não intrínseco. Os 9 instâncias a enviar
> heartbeat seriam 6 ou 7 num deployment minimamente configurado — cerca de um
> terço menos, sem escrever uma linha de código. Os 27 pedidos SBI por registo
> incluem saltos pelo SCP e chamadas a PCF e BSF que um deployment mínimo não faz.
>
> **Os números continuam válidos como observação, mas não servem de referência.**
> Qualquer ganho futuro tem de ser medido contra o conjunto mínimo, não contra isto.

---

## 1. O que o core faz quando não faz nada

Run `20260904-151620`, janela de 420 s com zero mensagens de ou para dispositivos:

| Grandeza | Valor |
|---|---:|
| Instâncias de NF a enviar heartbeat | 9 |
| Intervalo por NF | 10,0 s (declarado: 10 s) |
| Ritmo agregado no NRF | 0,88 transações/s |
| **Extrapolado por dia** | **~78 000 transações · ~66 MB** |
| Contando os dois saltos NF→SCP→NRF | ~156 000 pedidos · ~132 MB/dia |

Referência: ligar **um** dispositivo custa 28 pedidos SBI e **~71 KB**.

O custo escala com o **número de funções de rede**, não com o número de
dispositivos. Numa rede pública dilui-se; numa fábrica com poucos terminais
estáticos seria, em contagem de mensagens, o termo dominante.

## 2. O intervalo é configurável — e o NRF não o limita

`time.nf_instance.heartbeat`. Experiência com **grupo de controlo dentro da
mesma captura**: alterado só no AMF, as outras oito mantidas em 10 s.

| | previsto | medido |
|---|---:|---:|
| AMF a 60 s, restantes a 10 s | ~0,82 tx/s | **0,83 tx/s** |
| AMF a 60 s | — | 5 heartbeats em 275 s (60,0 s) |

Testado também a **3600 s**: o NRF aceitou sem substituir por valor local, o AMF
manteve-se `REGISTERED` e descobrível, e o `make run` completo passou.

## 3. O que a norma permite (TS 29.510)

- O mecanismo é **obrigatório** — *"each NF ... **shall** contact the NRF
  periodically"*. Não há flag nem valor reservado para o desligar.
- O **valor não é limitado**. A NF propõe-o; o NRF aceita ou substitui por
  configuração local. Numa rede privada, ambas as pontas são nossas.
- Consequência do incumprimento (cl. 5.2.2.3.2): o NRF marca a NF como
  `SUSPENDED` e deixa de a devolver em descoberta.

**Portanto:** desativar sai da norma; **aumentar não sai**. O intervalo é,
literalmente, a janela de pior caso em que o NRF anuncia uma NF morta.

## 4. O preço dessa janela

`docker kill` (SIGKILL) e não `docker stop` — o mecanismo existe para *crashes*;
um encerramento limpo desregista-se explicitamente.

| Cenário | Deteção | Custo de uma tentativa de registo |
|---|---|---|
| heartbeat 10 s, NF morta | **10 s** (um intervalo) | < 1 ms (falha imediata, HTTP 504) |
| heartbeat 3600 s, container morto | não deteta | < 1 ms — **artefacto**: o IP desaparece da rede |
| heartbeat 3600 s, NF **congelada** (`docker pause`) | não deteta | **10,0 s de bloqueio, por tentativa** |

O terceiro é o cenário realista: viva na rede, aceita ligações TCP, nunca
responde. Os 10 s são o temporizador de ligação SBI do Open5GS, ele próprio
configurável.

## 5. Matriz de impacto de falha

Feita para corrigir um enviesamento: a primeira experiência usou o AUSF, que só
é consultado no registo — o caso mais favorável ao argumento.

| NF | Sessão já ativa | Registo novo | Sessão nova |
|---|---|---|---|
| AUSF, UDM, UDR, PCF, BSF, SMF | sobrevive | FALHA | FALHA |
| **NSSF** | sobrevive | **ok** | **ok** |
| **UPF** | **PARTE** | ok | FALHA |

**Duas conclusões estruturais:**

1. As sete NFs descobertas pelo NRF têm **todas a mesma assinatura**: quem já
   está ligado sobrevive, quem chega falha. Não foi sorte do AUSF.
2. A única cuja falha parte sessões ativas — o **UPF** — **não é descoberta pelo
   NRF**. É alcançada por PFCP com endereço estático e tem heartbeat próprio. O
   intervalo do NRF não lhe toca.

Ou seja: o mecanismo de descoberta do NRF governa exatamente a classe de falhas
a que uma fábrica de dispositivos estáticos está **menos** exposta.

**E o NSSF nunca é sequer consultado:** 0 pedidos `nnssf-*` em 659 pedidos SBI
numa captura com registo e sessão completos. Congelá-lo não parte nada.

## 6. O custo em CPU — onde a história muda

Contadores exatos do cgroup v2 (`usage_usec`), não amostragem. Mede-se o
**declive** e não a diferença entre extremos, porque os healthchecks do
laboratório geram muito mais carga do que os heartbeats e afogariam o sinal.

| Intervalo | Transações/s | CPU total |
|---:|---:|---:|
| 2 s | 5,00 | 116,3 mCPU |
| 4 s | 2,50 | 114,1 mCPU |
| 10 s | 1,00 | 113,3 mCPU |

- **Custo marginal: ~765 µs de CPU por transação de heartbeat**
- No valor por omissão: **0,765 mCPU = 66 segundos de CPU por dia**
- Base independente do heartbeat: **112,4 mCPU**, sobretudo os healthchecks do
  nosso laboratório — **150× mais** do que o mecanismo em estudo

## 7. Memória

| | |
|---|---:|
| MongoDB | 177,3 MB |
| SMF | 33,5 MB |
| UPF | 25,6 MB |
| As outras oito NFs, somadas | ~60 MB |
| **Total** | **296,6 MB** |

A base de dados é 60% do core. Remover uma função de rede poupa ~6 MB.

## 8. As três unidades

| Unidade | Custo diário | Como parece |
|---|---:|---|
| Transações | 78 141 | enorme |
| Bytes | 66 MB | relevante |
| **CPU** | **66 s (0,08% de um núcleo)** | **irrelevante** |

Setenta e oito mil transações por dia soa a muito e não é nada, porque cada uma
custa 765 microssegundos. **A contagem de transações é um mau indicador de
custo.**

Documentar "redução de 99,7% da sinalização de fundo" seria uma frase verdadeira
que dá uma impressão falsa.

## 9. O que fica

**Regra de método, para o resto da tese:** nunca reportar contagens de mensagens
sozinhas. Toda a auditoria de procedimentos passa por transações **e** bytes
**e** CPU antes de classificar algo como "removível com ganho".

**Direção:** se em repouso o core não está limitado nem por CPU nem por memória,
o argumento para um core aligeirado **não pode assentar em eficiência de estado
estacionário**. Onde um core leve se prova é no **transitório** — e o transitório
que interessa numa fábrica já está identificado: o **arranque em massa** depois
de uma falha de energia. É simultaneamente o caso adverso desta otimização e
provavelmente o único momento em que a eficiência do core importa a quem opera
a fábrica.

## Ressalvas

1. Uma execução por ponto, sem repetições nem intervalos de confiança. As
   diferenças de CPU entre pontos são pequenas (3 mCPU em 113).
2. O script de CPU assumiu 10 instâncias a enviar heartbeat; a captura mostrou 9.
   Isso desloca o custo **por transação** para ~850 µs, mas **não altera** o custo
   diário (0,765 mCPU), porque ritmo × custo é invariante.
3. A ordenada na origem mistura healthchecks com o repouso real do Open5GS. Para
   isolar o segundo seria preciso desligar os healthchecks — o que quebra as
   dependências `service_healthy` do compose.
4. Congelámos funções de rede **inteiras**. Degradação parcial teria
   comportamento diferente e provavelmente pior.
5. O Open5GS **apaga o perfil** em vez de o marcar `SUSPENDED`. Desvio face à
   norma, confirmado — material para a comparação entre cores.
6. Uma instância de cada NF. Em produção há várias, e é aí que o heartbeat
   permite failover real em vez de apenas um erro mais rápido — outra dimensão
   em que a rede privada muda a economia do mecanismo.
