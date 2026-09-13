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
 "ngap-build.c":   ["ngap_build_path_switch_ack", "ngap_build_handover_request",
                    "ngap_build_handover_preparation_failure", "ngap_build_handover_command",
                    "ngap_build_handover_cancel_ack", "ngap_build_downlink_ran_status_transfer"],
 "ngap-path.c":    ["ngap_send_path_switch_ack", "ngap_send_handover_request",
                    "ngap_send_handover_preparation_failure", "ngap_send_handover_command",
                    "ngap_send_handover_cancel_ack", "ngap_send_downlink_ran_status_transfer"],
 # --- fase 2: transferencia de contexto entre AMFs (N14) -------------------
 "namf-handler.c": ["amf_namf_comm_handle_ue_context_transfer_request",
                    "amf_namf_comm_handle_ue_context_transfer_response",
                    "amf_namf_comm_handle_registration_status_update_request",
                    "amf_namf_comm_handle_registration_status_update_response",
                    # auxiliares estaticas usadas so pelas funcoes acima
                    "amf_namf_comm_base64_decode_5gmm_capability",
                    "amf_namf_comm_base64_encode_5gmm_capability",
                    "amf_namf_comm_decode_ue_mm_context_list",
                    "amf_namf_comm_decode_ue_session_context_list",
                    "amf_namf_comm_encode_ue_mm_context_list",
                    "amf_namf_comm_encode_ue_session_context_list",
                    "amf_namf_comm_base64_decode_ue_security_capability",
                    "amf_namf_comm_base64_encode_ue_security_capability"],
 "namf-build.c":   ["amf_namf_comm_build_ue_context_transfer",
                    "amf_namf_comm_build_registration_status_update",
                    "amf_ue_to_context_id", "ogs_guti_to_string"],
 "gmm-handler.c":  ["gmm_registration_request_from_old_amf"],
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

def find_defs(lines):
    """Indice da linha inicial -> nome, para definicoes de funcao de topo.

    Duas formas no Open5GS: assinatura toda numa linha, e tipo numa linha com o
    nome indentado na seguinte (usada em assinaturas longas). A segunda escapava
    ao detetor e deixava funcoes auxiliares por guardar.
    """
    defs = {}
    for i, l in enumerate(lines):
        n = func_name(l)
        if n:
            defs[i] = n
        elif (i and re.match(r"^(static\s+)?[\w_]+\s*\**\s*$", lines[i-1])
              and re.match(r"^\s+\w+\s*\(", l)
              and not l.rstrip().endswith(";")):
            defs[i-1] = re.match(r"^\s+(\w+)\s*\(", l).group(1)
    return defs

def wrap_functions(path, names):
    lines = path.read_text().splitlines(keepends=True)
    defs = find_defs(lines)
    starts = set(defs)
    out, i, n = [], 0, 0
    while i < len(lines):
        if i in starts:
            name = defs[i]
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


# --- fase 1b: ramos de handover dentro de funcoes partilhadas ---------------
# Descoberto ao ligar: o handover nao vive so na interface do RAN. Ramifica
# dentro da gestao de sessoes PDU (nsmf-handler.c) e da accao de libertacao de
# contexto (ngap-handler.c). Todo o acoplamento esta em pontos de DESPACHO --
# casos de switch e cadeias else-if -- e nao entrelacado na logica.

def wrap_switch_cases(path, labels):
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        m = re.match(r"^\s*case\s+(\w+)\s*:", lines[i])
        if m and m.group(1) in labels:
            end = next((j for j in range(i, len(lines))
                        if re.match(r"^\s*break;", lines[j])), None)
            if end is not None:
                out += [GUARD_OPEN] + lines[i:end+1] + [GUARD_CLOSE]
                i = end + 1; n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

def wrap_else_if(path, conds):
    """Envolve o CORPO de ramos '} else if (cond) {', nao o ramo inteiro.

    Remover o ramo todo exigiria reescrever a cadeia: numa sequencia
    if/else-if, o '}' de cada linha fecha o ramo ANTERIOR, e as linhas
    '} else if' sao neutras em chavetas -- uma contagem de profundidade
    ingenua passa ao lado do fim do ramo e engole o resto da cadeia,
    incluindo ramos que nao sao de mobilidade.

    Guardar so o corpo mantem a cadeia estruturalmente intacta e deixa o ramo
    sem efeito. Sobra a avaliacao da condicao, que para um estado de handover
    que nunca pode ocorrer e inofensiva.
    """
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        m = re.match(r"^(\s*)\}\s*else if\s*\((.*)\)\s*\{\s*$", lines[i])
        if m and any(c in m.group(2) for c in conds):
            indent = m.group(1)
            end = next((j for j in range(i + 1, len(lines))
                        if re.match(r"^" + re.escape(indent) + r"\}", lines[j])), None)
            if end is not None:
                out += [lines[i], GUARD_OPEN] + lines[i+1:end] + [GUARD_CLOSE]
                i = end
                n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

c1 = wrap_switch_cases(SRC / "ngap-handler.c", {
    "NGAP_UE_CTX_REL_NG_HANDOVER_COMPLETE",
    "NGAP_UE_CTX_REL_NG_HANDOVER_CANCEL",
    "NGAP_UE_CTX_REL_NG_HANDOVER_FAILURE"})
c2 = wrap_switch_cases(SRC / "nsmf-handler.c", {
    "OpenAPI_n2_sm_info_type_PATH_SWITCH_REQ_ACK",
    "OpenAPI_n2_sm_info_type_HANDOVER_CMD"})
c3 = wrap_else_if(SRC / "nsmf-handler.c", [
    "AMF_UPDATE_SM_CONTEXT_HANDOVER_", "AMF_UPDATE_SM_CONTEXT_PATH_SWITCH_"])
print(f"  {'ngap-handler.c':<18} {c1} casos de libertacao de contexto envolvidos")
print(f"  {'nsmf-handler.c':<18} {c2} casos N2 + {c3} ramos de estado envolvidos")

def wrap_ogs_switch_all_cases(path, labels):
    """Envolve blocos SWITCH..END cujos CASE sao TODOS de mobilidade.

    Necessario porque a macro SWITCH do Open5GS declara uma variavel interna;
    se todos os seus CASE forem removidos, ela fica sem uso e o -Werror recusa.
    Conta profundidade SWITCH/END para nao confundir blocos aninhados.
    """
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        if re.match(r"^(\s*)SWITCH\(", lines[i]):
            depth, j, cases = 1, i, []
            while depth and j + 1 < len(lines):
                j += 1
                if re.match(r"^\s*SWITCH\(", lines[j]):
                    depth += 1
                elif re.match(r"^\s*END\b", lines[j]):
                    depth -= 1
                elif depth == 1:
                    c = re.match(r"^\s*CASE\((\w+)\)", lines[j])
                    if c:
                        cases.append(c.group(1))
            if cases and all(c in labels for c in cases):
                out += [GUARD_OPEN] + lines[i:j+1] + [GUARD_CLOSE]
                i = j + 1; n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

def wrap_ogs_case(path, labels):
    """Envolve blocos CASE(...) das macros SWITCH/CASE/END do Open5GS.

    O fim do bloco e o 'break;' a indentacao do CASE + 4. Escolher pelo
    primeiro 'break;' seria errado: estes blocos contem SWITCH aninhados, cujos
    'break;' internos estao mais indentados.
    """
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        m = re.match(r"^(\s*)CASE\((\w+)\)", lines[i])
        if m and m.group(2) in labels:
            want = " " * (len(m.group(1)) + 4) + "break;"
            end = next((j for j in range(i + 1, len(lines))
                        if lines[j].rstrip("\n") == want), None)
            if end is not None:
                out += [GUARD_OPEN] + lines[i:end+1] + [GUARD_CLOSE]
                i = end + 1; n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

def wrap_prototypes(path, names):
    """Guarda declaracoes 'static ... nome(...);' das funcoes ja envolvidas.

    Sem isto o compilador queixa-se de 'declared static but never defined'.
    Trata a forma de duas linhas, em que o tipo fica isolado na anterior.
    """
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        l = lines[i]
        m = re.search(r"\b(\w+)\s*\(", l)
        if m and m.group(1) in names and l.rstrip().endswith(";"):
            start = i
            if (i and re.match(r"^static\s+[\w_]+\s*\**\s*$", lines[i-1])):
                start = i - 1
                out.pop()
            out += [GUARD_OPEN] + lines[start:i+1] + [GUARD_CLOSE]
            i += 1; n += 1
            continue
        out.append(l); i += 1
    path.write_text("".join(out))
    return n

def wrap_if_block(path, conds):
    """Envolve blocos 'if (cond) { ... }' completos.

    A condicao pode ocupar varias linhas; procura-se a substring na linha do
    'if'. O fim do bloco e a proxima linha com '}' na MESMA indentacao -- nao
    se conta chavetas, pela razao explicada em wrap_else_if.
    """
    lines = path.read_text().splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        m = re.match(r"^(\s*)if\s*\(", lines[i])
        if m and any(c in lines[i] for c in conds):
            indent = m.group(1)
            end = next((j for j in range(i + 1, len(lines))
                        if re.match(r"^" + re.escape(indent) + r"\}", lines[j])), None)
            if end is not None:
                out += [GUARD_OPEN] + lines[i:end+1] + [GUARD_CLOSE]
                i = end + 1; n += 1
                continue
        out.append(lines[i]); i += 1
    path.write_text("".join(out))
    return n

def guard_decl_in_function(path, func, decl):
    """Guarda uma declaracao local que so e usada por codigo ja guardado.

    Segunda ocorrencia deste padrao (a primeira foi 'pkbuf' em ngap-sm.c): o
    Open5GS compila com -Werror, logo uma variavel que fica sem uso recusa
    compilar. Sao os unicos acoplamentos fora de pontos de despacho.
    """
    lines = path.read_text().splitlines(keepends=True)
    start = next((i for i, l in enumerate(lines) if func_name(l) == func), None)
    if start is None:
        return False
    end = next((j for j in range(start + 1, len(lines))
                if lines[j].startswith("}")), len(lines))
    for k in range(start, end):
        if lines[k].strip() == decl.strip():
            lines[k] = GUARD_OPEN + lines[k] + GUARD_CLOSE
            path.write_text("".join(lines))
            return True
    return False

pr = wrap_prototypes(SRC / "namf-handler.c", set(FUNCS["namf-handler.c"]))
if pr:
    print(f"  {'namf-handler.c':<18} {pr} prototipo(s) envolvido(s)")

N14_CASES = {"OGS_SBI_RESOURCE_NAME_TRANSFER", "OGS_SBI_RESOURCE_NAME_TRANSFER_UPDATE"}
for fn in ("amf-sm.c", "gmm-sm.c"):
    k = wrap_ogs_switch_all_cases(SRC / fn, N14_CASES)
    if k:
        print(f"  {fn:<18} {k} bloco(s) SWITCH inteiramente de N14 envolvidos")
for fn in ("amf-sm.c", "gmm-sm.c"):
    k = wrap_ogs_case(SRC / fn, N14_CASES)
    if k:
        print(f"  {fn:<18} {k} bloco(s) CASE de N14 envolvidos")

c4 = wrap_if_block(SRC / "gmm-sm.c",
                   ["gmm_registration_request_from_old_amf",
                    "amf_ue_context_transfer_state =="])
print(f"  {'gmm-sm.c':<18} {c4} bloco(s) de transferencia de contexto envolvidos")

if guard_decl_in_function(SRC / "ngap-handler.c",
                          "ngap_handle_ue_context_release_action", "int r;"):
    print(f"  {'ngap-handler.c':<18} declaracao de 'r' envolvida")

print(f"\nTotal: {total} funcoes + {cases} casos")
