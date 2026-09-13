# PANIC -- laboratorio 5G baseline
#
#   make host-check    verifica pre-requisitos do host
#   make build         compila as imagens (Open5GS e UERANSIM) a partir do fonte
#   make run           caminho completo: core -> subscritores -> capturas -> RAN -> verificacao
#   make verify        verificacao ponta-a-ponta
#   make down          para tudo
#
# 'make run' e o comando que reproduz o baseline do zero. Se ele passa numa
# maquina limpa, o laboratorio e reproduzivel -- que e o requisito central deste passo.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENVFILE  := lab/params.env
PROJECT  := panic
COMPOSE  := docker compose --env-file $(ENVFILE) -p $(PROJECT) \
              -f lab/compose/core.yaml -f lab/compose/ran.yaml
COMPOSE_CAP := $(COMPOSE) -f lab/compose/capture.yaml

RUN_FILE := results/pcap/.current
OPEN5GS_TAG  := $(shell grep -E '^OPEN5GS_TAG='  $(ENVFILE) | cut -d= -f2)
UERANSIM_TAG := $(shell grep -E '^UERANSIM_TAG=' $(ENVFILE) | cut -d= -f2)

# Todos os alvos que invocam compose com o ficheiro de capturas precisam de
# RUN_ID definido, senao a interpolacao avisa e o caminho do pcap fica errado.
RUN_ID ?= $(shell cat $(RUN_FILE) 2>/dev/null || echo current)
export RUN_ID

.PHONY: help host-check check-params build up-core provision capture-start \
        capture-stop up-ran run verify status logs ue-shell down clean

help:
	@echo "PANIC -- laboratorio 5G baseline (Open5GS $(OPEN5GS_TAG) + UERANSIM $(UERANSIM_TAG))"
	@echo
	@grep -E '^#   make' $(MAKEFILE_LIST) | sed 's/^#   /  /'
	@echo
	@echo "  Granulares: up-core provision capture-start up-ran capture-stop"
	@echo "  Diagnostico: status | logs SVC=amf | ue-shell"

# ----------------------------------------------------------------- verificacoes
host-check:
	@bash lab/scripts/host-check.sh

check-params:
	@bash lab/scripts/check-params.sh

# ---------------------------------------------------------------------- imagens
build:
	@echo ">> Open5GS $(OPEN5GS_TAG) a partir do codigo-fonte"
	docker build --build-arg OPEN5GS_TAG=$(OPEN5GS_TAG) \
	    -t panic/open5gs:$(OPEN5GS_TAG) lab/images/open5gs
	@echo ">> UERANSIM $(UERANSIM_TAG) a partir do codigo-fonte"
	docker build --build-arg UERANSIM_TAG=$(UERANSIM_TAG) \
	    -t panic/ueransim:$(UERANSIM_TAG) lab/images/ueransim
	@echo ">> Ferramentas de analise (tshark)"
	docker build -t panic/analysis:latest lab/images/analysis

# ------------------------------------------------------------------- laboratorio
up-core:
	@echo ">> Core 5G (aguarda healthy de todas as NFs)"
	$(COMPOSE) up -d --wait mongo nrf scp udr udm ausf pcf nssf bsf amf smf upf

provision:
	@bash lab/scripts/provision-subscribers.sh $(or $(N),1)

capture-start:
	@mkdir -p results/pcap
	@date +%Y%m%d-%H%M%S > $(RUN_FILE)
	@RID=$$(cat $(RUN_FILE)); echo ">> Capturas do nucleo (run $$RID)"; \
	  RUN_ID=$$RID $(COMPOSE_CAP) up -d cap-amf cap-smf cap-upf cap-nrf cap-scp

capture-stop:
	@RID=$$(cat $(RUN_FILE) 2>/dev/null || echo current); \
	  RUN_ID=$$RID $(COMPOSE_CAP) stop cap-amf cap-smf cap-upf cap-nrf cap-scp cap-gnb 2>/dev/null || true; \
	  echo ">> Capturas paradas (run $$RID)"
	@# Os sidecars correm como root; devolve os ficheiros ao utilizador para
	@# poderem ser abertos no Wireshark sem sudo.
	docker run --rm -v $(PWD)/results/pcap:/pcap panic/open5gs:$(OPEN5GS_TAG) \
	    chown -R $(shell id -u):$(shell id -g) /pcap
	@RID=$$(cat $(RUN_FILE) 2>/dev/null || echo current); ls -lh results/pcap/$$RID/ 2>/dev/null || true

up-ran:
	@RID=$$(cat $(RUN_FILE) 2>/dev/null || echo current); \
	  echo ">> gNB"; RUN_ID=$$RID $(COMPOSE) up -d --wait gnb; \
	  echo ">> Captura do gNB (antes do UE registar, para nao perder o procedimento)"; \
	  RUN_ID=$$RID $(COMPOSE_CAP) up -d cap-gnb; \
	  sleep 1; \
	  echo ">> UE"; RUN_ID=$$RID $(COMPOSE) up -d --wait ue

# Caminho completo. Duas coisas importam aqui:
#
#  1. Comeca sempre por 'down'. Sem isso, correr 'make run' com o laboratorio ja
#     de pe nao produz registo nenhum (os containers ja estao a correr), a
#     captura apanha uma rede em repouso, e a verificacao falha sem que haja
#     nada de errado com o laboratorio. Custa ~20s e garante que 'make run'
#     significa sempre a mesma coisa: reproduzir o baseline do zero.
#
#  2. A ORDEM do resto: as capturas tem de estar a correr antes de o UE
#     registar, senao perde-se exatamente o procedimento que queremos medir.
run: down host-check check-params up-core provision capture-start up-ran
	@sleep 3
	@$(MAKE) --no-print-directory capture-stop
	@$(MAKE) --no-print-directory verify

# Igual ao 'run', mas com o AMF compilado sem a maquinaria de handover.
# A unica variavel entre 'run' e 'run-nomob' e o binario do AMF.
run-nomob: COMPOSE := $(COMPOSE) -f lab/compose/amf-nomob.yaml
run-nomob: COMPOSE_CAP := $(COMPOSE) -f lab/compose/amf-nomob.yaml -f lab/compose/capture.yaml
run-nomob: run

verify:
	@bash lab/scripts/verify-e2e.sh

# ------------------------------------------------------------------ diagnostico
status:
	@$(COMPOSE) ps

logs:
	@docker logs --tail 80 panic-$(or $(SVC),amf)

ue-shell:
	@docker exec -it panic-ue /bin/bash

# ----------------------------------------------------------------------- limpeza
down:
	@RUN_ID=current $(COMPOSE_CAP) down --remove-orphans

clean: down
	@docker volume rm panic-mongo-data 2>/dev/null || true
	@echo "Volumes removidos. As capturas em results/pcap/ ficam."
