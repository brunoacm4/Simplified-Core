#!/usr/bin/env python3
"""Torna a maquinaria NGAP de handover opcional em tempo de compilacao.

Envolve em `#ifndef PANIC_NO_MOBILITY` os tratadores, construtores, envios e
casos de despacho identificados no mapeamento da fronteira
(docs/analise/procedimentos.md). Compilar com -DPANIC_NO_MOBILITY produz um AMF
sem suporte de handover.

Feito por script e nao por patch porque um patch fica preso a numeros de linha e
parte com qualquer atualizacao do upstream; isto localiza as funcoes pelo nome.

Uso:  make-mobility-optional.py <caminho-para-src/amf>
"""
import re, sys, pathlib

SRC = pathlib.Path(sys.argv[1])
GUARD_OPEN  = "#ifndef PANIC_NO_MOBILITY  /* PANIC: modulo de mobilidade */\n"
GUARD_CLOSE = "#endif /* PANIC_NO_MOBILITY */\n"

# --- funcoes a envolver, por ficheiro ---------------------------------------
FUNCS = {
 "ngap-handler.c": ["ngap_handle_ue_radio_capability_info_indication",
                    "ngap_handle_uplink_ran_configuration_transfer",
                    "ngap_handle_path_switch_request", "ngap_handle_handover_required",
                    "ngap_handle_handover_request_ack", "ngap_handle_handover_failure",
                    "ngap_handle_handover_cancel", "ngap_handle_uplink_ran_status_transfer",
                    "ngap_handle_handover_notification"],
}

# NAO se envolvem os construtores de ngap-build.c nem os envios de ngap-path.c.
# Motivo, descoberto ao ligar: tres deles (path_switch_ack, handover_request,
# handover_command) sao chamados a partir de nsmf-handler.c, que ramifica em
# estados como AMF_UPDATE_SM_CONTEXT_HANDOVER_REQUIRED. O handover NAO esta
# confinado a interface do RAN -- esta entrelacado com a gestao de sessoes PDU
# pelo SBI. Remover os construtores sem tratar esse acoplamento nao liga.
#
# Com os pontos de entrada NGAP removidos, esse codigo fica INALCANCAVEL: o
# handover nunca pode ser iniciado. Separa-lo de facto e a fase 1b.

def func_name(line):
    """Nome da funcao definida nesta linha, ou None.

    Extrai-se o ultimo identificador antes do parentesis em vez de o capturar
    por regex: com um grupo guloso o motor devolve so o ultimo caractere.
    """
    if not re.match(r"^[A-Za-z_]", line) or "(" not in line:
        return None
    if line.rstrip().endswith(";"):          # declaracao, nao definicao
        return None
    ids = re.findall(r"\w+", line.split("(")[0])
    return ids[-1] if ids else None

def wrap_functions(path, names):
    lines = path.read_text().splitlines(keepends=True)
    starts = {i for i, l in enumerate(lines) if func_name(l)}
    out, i, n = [], 0, 0
    while i < len(lines):
        if i in starts:
            name = func_name(lines[i])
            if name in names:
                end = next((j for j in range(i, len(lines)) if lines[j].startswith("}")), i)
                out += [GUARD_OPEN] + lines[i:end+1] + [GUARD_CLOSE]
                i = end + 1; n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

total = 0
for fname, names in FUNCS.items():
    c = wrap_functions(SRC / fname, set(names))
    print(f"  {fname:<18} {c}/{len(names)} funcoes envolvidas")
    total += c

# --- casos do despacho em ngap-sm.c -----------------------------------------
MOB_CASES = ["UERadioCapabilityInfoIndication", "PathSwitchRequest",
             "UplinkRANConfigurationTransfer", "HandoverPreparation",
             "UplinkRANStatusTransfer", "HandoverNotification",
             "HandoverCancel", "HandoverResourceAllocation"]
p = SRC / "ngap-sm.c"
lines = p.read_text().splitlines(keepends=True)
out, i, cases = [], 0, 0
while i < len(lines):
    m = re.match(r"^(\s*)case NGAP_ProcedureCode_id_(\w+)\s*:", lines[i])
    if m and m.group(2) in MOB_CASES:
        end = next((j for j in range(i, len(lines))
                    if re.match(r"^\s*break;", lines[j])), i)
        out += [GUARD_OPEN] + lines[i:end+1] + [GUARD_CLOSE]
        i = end + 1; cases += 1
        continue
    out.append(lines[i]); i += 1
# A variavel local 'pkbuf' de ngap_state_operational() so e usada pelo caso
# UplinkRANConfigurationTransfer; sem ele fica orfa e o -Werror do Open5GS
# recusa compilar. Unico acoplamento encontrado fora das funcoes e dos casos.
t = "".join(out)
decl = "    ogs_pkbuf_t *pkbuf = NULL;\n"
if decl in t:
    t = t.replace(decl, GUARD_OPEN + decl + GUARD_CLOSE, 1)
    p.write_text(t)
    print(f"  {'ngap-sm.c':<18} {cases} casos + declaracao de 'pkbuf' envolvidos")
else:
    print(f"  {'ngap-sm.c':<18} {cases} casos de despacho envolvidos")
# --- injeta o define APENAS no alvo do AMF ----------------------------------
# Fazer -Dc_args global obrigaria a recompilar o projeto inteiro. Limitando ao
# alvo 'amf', so o AMF e reconstruido.
mb = SRC / "meson.build"
t = mb.read_text()
anchor = "libamf = static_library('amf',\n    sources : libamf_sources,"
if "PANIC_NO_MOBILITY" not in t:
    assert anchor in t, "declaracao de libamf nao encontrada"
    t = t.replace(anchor, anchor + "\n    c_args : ['-DPANIC_NO_MOBILITY'],", 1)
    mb.write_text(t)
    print("  meson.build        define injetado no alvo 'amf'")

print(f"\nTotal: {total} funcoes + {cases} casos")
