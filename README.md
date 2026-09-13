# PANIC — Private Advanced Network Industrial Core

Dissertação de mestrado, Universidade de Aveiro / Instituto de Telecomunicações.
Orientação: Daniel Nunes Corujo, Rui L. Aguiar.

**Objetivo:** avaliar a arquitetura e os procedimentos do core 5G, localizar e
implementar otimizações específicas de redes privadas, e produzir uma versão
aligeirada do core adequada a cenários industriais — mantendo compatibilidade
retroativa para operações inter-domínio.

O ângulo concreto: **como fica o core 5G quando se remove o pressuposto de
mobilidade?** O artefacto-alvo é um AMF modular em que o suporte de mobilidade é
instalável como plugin.

---

## Estado

**Passo 1 — laboratório baseline: concluído.** Core 5G completo (Open5GS
v2.7.7), gNB e UE simulados (UERANSIM v3.3.0), a correr em Docker com captura
integral e legível de todos os procedimentos. Primeiros números em
[`results/summaries/`](results/summaries/).

Próximo: passo 2 — formalizar a metodologia de medição.

---

## Arranque rápido

```bash
make host-check    # pré-requisitos do host
make build         # compila Open5GS e UERANSIM a partir do código-fonte (~15 min)
make run           # core → subscritores → capturas → RAN → verificação
```

`make run` reproduz o baseline do zero. Se passa numa máquina limpa, o
laboratório é reproduzível — que é o requisito central deste passo.

Outros alvos: `make verify`, `make status`, `make logs SVC=amf`, `make ue-shell`,
`make down`, `make clean`. `make` sem argumentos lista tudo.

## Onde está o quê

| Caminho | Conteúdo |
|---|---|
| [`lab/params.env`](lab/params.env) | **Fonte de verdade** dos parâmetros (PLMN, TAC, slice, IPs). `make check-params` valida a coerência com as configurações |
| [`lab/images/`](lab/images/) | Dockerfiles — Open5GS e UERANSIM compilados de raiz em tags fixas |
| [`lab/compose/`](lab/compose/) | `core.yaml` (11 NFs + MongoDB), `ran.yaml` (gNB + UE), `capture.yaml` (sidecars tcpdump) |
| [`lab/configs/`](lab/configs/) | Configuração de cada NF e do UERANSIM, versionada |
| [`lab/scripts/`](lab/scripts/) | `host-check`, `check-params`, `provision-subscribers`, `verify-e2e` |
| [`docs/lab/topologia.md`](docs/lab/topologia.md) | **Ler antes de interpretar qualquer medição** — topologia, desvios deliberados, armadilhas |
| [`docs/analise/procedimentos.md`](docs/analise/procedimentos.md) | **Auditoria de procedimentos** — classificação do que é necessário, degenerado ou removível sem mobilidade |
| [`docs/meetings/`](docs/meetings/) | Notas de reunião |
| [`results/summaries/`](results/summaries/) | Resultados versionados (as capturas em bruto ficam fora do git) |

## Notas de reprodutibilidade

Versões fixadas em `lab/params.env`; um rebuild dá o mesmo código. As imagens
guardam o commit exato em `/open5gs.commit` e `/ueransim.commit`. As análises
usam um tshark containerizado, para que a versão do dissetor não varie com a
máquina.

O laboratório corre com **desvios deliberados** face a um deployment de produção
(cifra NAS nula, SBI sem TLS, RAN simulado). Estão todos listados e justificados
em [`docs/lab/topologia.md`](docs/lab/topologia.md) — condicionam o que os
números querem dizer.
