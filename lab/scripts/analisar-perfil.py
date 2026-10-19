#!/usr/bin/env python3
"""Divide o CPU de cada função do core por tipo de trabalho, a partir das pilhas do perf
(scripts/perfil-ciclo.sh).

Cada amostra é atribuída assim:
  1. se a pilha passa por gestão na NRF (registo, heartbeat, notificações) -> "fundo: NRF";
     se passa por heartbeats PFCP -> "fundo: PFCP";
  2. senão, sobe-se a pilha a partir da folha, saltando o que é genérico (kernel, libc, libtalloc,
     o núcleo do Open5GS: eventos, temporizadores, memória, e os ciclos principais), e a primeira
     função não genérica decide a categoria (JSON, HTTP/SBI, NGAP/NAS, PFCP, cripto, log, Diameter,
     base de dados, lógica). Os registos (ogs_log) e o TLV (PFCP/GTP) contam mesmo dentro do núcleo;
     um símbolo desconhecido numa biblioteca conhecida (libcurl, libnghttp2) conta pela biblioteca;
  3. se não houver nenhuma, a amostra é "runtime" (eventos, memória, kernel).
Assim o malloc chamado pelo cJSON conta como JSON, e a codificação NGAP feita dentro de um pedido
HTTP conta como NGAP.

O custo do ciclo é o da carga menos o do repouso no mesmo tempo (heartbeats, temporizadores,
Diameter...), por categoria e por função, dividido pelo número de ciclos (Service Requests no N2).

Uso: ./scripts/analisar-perfil.py <pasta>/<nome>.meta
Escreve <nome>.perfil.json e imprime as tabelas.
"""
import json, os, re, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
fab = import_module('analisar-fabrica')

CATEGORIAS = ['SBI: JSON', 'SBI: HTTP/2 e mensagens', 'NGAP/NAS (SCTP + ASN.1)', 'PFCP/GTP', 'Criptografia',
              'Registos (log)', 'Diameter (freeDiameter)', 'Base de dados', 'Lógica do procedimento',
              'Runtime (eventos, memória, kernel)', 'Fundo: NRF', 'Fundo: PFCP heartbeat']

SEM_DONO = re.compile(r'\[kernel|\[unknown\]|\[vdso\]')     # sem informação: salta-se sempre
GENERICO_DSO = re.compile(r'libc\.so|libc-|ld-linux|libtalloc|libogscore|libpthread|libyaml|libm\.so|libgcc')
GENERICO_SYM = re.compile(r'^(main|amf_main|smf_main|upf_main|scp_main|thread_worker|ogs_fsm_dispatch|'
                          r'ogs_fsm_tran|ogs_app_|ogs_signal|start_thread|clone|__libc_start)')
NRF = re.compile(r'ogs_nnrf_nfm_|ogs_sbi_nf_state_|ogs_nnrf_handle_nf_|nf_instance_|ogs_sbi_nf_fsm|'
                 r'nnrf_nfm|ogs_nnrf_build_')
PFCP_HB = re.compile(r'heartbeat', re.I)


ESPECIFICO = re.compile(r'^(ogs_log|ogs_trace|ogs_hexdump|ogs_tlv_|tlv_)')   # dentro da libogscore


def categoria_frame(sym, dso):
    s, d = ('' if sym == '[unknown]' else sym or ''), dso or ''
    if re.match(r'(ogs_log|ogs_trace|ogs_hexdump)', s):
        return 'Registos (log)'
    if re.match(r'(ogs_tlv_|tlv_)', s):
        return 'PFCP/GTP'
    if re.search(r'libfdcore|libfdproto|\.fdx', d) or re.match(r'fd_', s):
        return 'Diameter (freeDiameter)'
    if re.search(r'libmongoc|libbson|libogsdbi', d):
        return 'Base de dados'
    if 'libogssbi-openapi' in d or re.match(r'(cJSON|OpenAPI_|build_json|parse_json|build_content|'
                                            r'parse_content|ogs_sbi_(build|parse)_(json|content))', s):
        return 'SBI: JSON'
    if re.search(r'libnghttp2|libmicrohttpd|libcurl|libgnutls|libnettle|libidn|libssh|libbrotli|libz\.', d) \
            or 'libogssbi' in d or re.match(r'(nghttp2_|MHD_|curl_|Curl_|ogs_sbi_)', s):
        return 'SBI: HTTP/2 e mensagens'
    if re.search(r'libogsasn1c|libogsngap|libogsnas|libogssctp|libsctp', d) or \
            re.match(r'(ogs_asn_|aper_|asn_|ogs_ngap_|ogs_nas_|ngap_build|nas_5gs_|ogs_sctp_|sctp_)', s):
        return 'NGAP/NAS (SCTP + ASN.1)'
    if re.search(r'libogspfcp|libogsgtp', d) or re.match(r'(ogs_pfcp_|ogs_gtp|ogs_tlv_)', s):
        return 'PFCP/GTP'
    if re.search(r'libogscrypt|libgcrypt|libcrypto|libssl|libgmp', d) or re.match(r'(ogs_kdf_|milenage|ecc)', s):
        return 'Criptografia'
    return 'Lógica do procedimento'


def amostras(caminho):
    """Lista de pilhas [(sym, dso)] da folha para a raiz, a partir de 'perf script -F ip,sym,dso'."""
    pilha = []
    for linha in open(caminho, errors='replace'):
        linha = linha.rstrip('\n')
        if not linha.strip():
            if pilha:
                yield pilha
            pilha = []
            continue
        m = re.match(r'\s*[0-9a-f]+\s+(.*?)\s*\((.*)\)\s*$', linha)
        if m:
            sym = re.sub(r'\+0x[0-9a-f]+$', '', m.group(1))
            pilha.append((sym, m.group(2)))
    if pilha:
        yield pilha


def classificar(pilha):
    if any(NRF.search(s or '') for s, _ in pilha):
        return 'Fundo: NRF'
    if any(PFCP_HB.search(s or '') for s, _ in pilha):
        return 'Fundo: PFCP heartbeat'
    for sym, dso in pilha:
        if SEM_DONO.search(dso or '') or not dso:
            continue
        if ESPECIFICO.match(sym or ''):
            return categoria_frame(sym, dso)
        if GENERICO_DSO.search(dso) or GENERICO_SYM.match(sym or ''):
            continue
        return categoria_frame(sym, dso)
    return 'Runtime (eventos, memória, kernel)'


def main(meta_path):
    pasta = os.path.dirname(os.path.realpath(meta_path))
    base = os.path.basename(meta_path)[:-len('.meta')]
    meta = dict(l.strip().split('=', 1) for l in open(meta_path) if '=' in l)
    freq = float(meta['freq'])
    funcoes = meta['funcoes'].split()

    # ciclos: Service Requests no N2 durante a carga
    t0, t1 = float(meta['t_inicio']), float(meta['t_fim'])
    ciclos = 0
    for t, info in fab.tshark(pasta, f'{base}.pcapng', 'ngap', ['frame.time_epoch', '_ws.col.Info']):
        if t0 <= float(t) <= t1 and 'InitialUEMessage' in info and 'Service request' in info:
            ciclos += info.count('InitialUEMessage')

    antes = dict(l.split('\t') for l in open(f'{pasta}/{base}.cpu-antes').read().split('\n') if l)
    depois = dict(l.split('\t') for l in open(f'{pasta}/{base}.cpu-depois').read().split('\n') if l)

    t_carga = float(meta['duracao']) + 12          # o perf da carga corre DURACAO + 12 s
    t_rep = float(meta.get('repouso', 0))

    def contar(nome):
        c, folhas = Counter(), Counter()
        caminho = f'{pasta}/{nome}.script'
        if not os.path.exists(caminho):
            return c, folhas
        for p in amostras(caminho):
            c[classificar(p)] += 1
            folhas[(p[0][0], os.path.basename(p[0][1]))] += 1
        return c, folhas

    R = {'meta': meta, 'ciclos': ciclos, 'funcoes': {}}
    liquido = Counter()      # amostras da carga menos o repouso no mesmo tempo, por categoria
    for f in funcoes:
        c, folhas = contar(f'{base}-{f}')
        r, _ = contar(f'{base}-repouso-{f}')
        liq = {k: c.get(k, 0) - (r.get(k, 0) * t_carga / t_rep if t_rep else 0) for k in CATEGORIAS}
        n = sum(c.values())
        cg_ms = (int(depois[f]) - int(antes[f])) / 1000
        R['funcoes'][f] = {'amostras': n, 'cpu_perf_ms': round(n / freq * 1000, 1), 'cpu_cgroup_ms': round(cg_ms, 1),
                           'repouso_ms_por_s': round(sum(r.values()) / freq * 1000 / t_rep, 2) if t_rep else None,
                           'categorias': dict(c), 'repouso': dict(r),
                           'liquido_us_por_ciclo': {k: round(v / freq * 1e6 / ciclos, 1) for k, v in liq.items()} if ciclos else {},
                           'folhas_top': [[s, d, k] for (s, d), k in folhas.most_common(15)]}
        liquido.update({k: v for k, v in liq.items()})
    R['liquido_us_por_ciclo'] = {k: round(v / freq * 1e6 / ciclos, 1) for k, v in liquido.items()} if ciclos else {}
    json.dump(R, open(f'{pasta}/{base}.perfil.json', 'w'), ensure_ascii=False, indent=1)

    print(f'=== {base}: {meta["imagem"]}, {meta["variante"]}, {meta["n_ues"]} UEs de {meta["periodo"]} em '
          f'{meta["periodo"]} s, {meta["duracao"]} s; {ciclos} ciclos ===\n')
    print(f'{"CPU na carga (ms): perf / cgroup":<40}' + '  '.join(
        f'{f} {R["funcoes"][f]["cpu_perf_ms"]:.0f}/{R["funcoes"][f]["cpu_cgroup_ms"]:.0f}' for f in funcoes))
    if t_rep:
        print(f'{"CPU em repouso (ms por segundo)":<40}' + '  '.join(
            f'{f} {R["funcoes"][f]["repouso_ms_por_s"]:.2f}' for f in funcoes))
    print(f'\nCPU de cada ciclo acordar/adormecer, descontado o repouso (µs por ciclo):\n')
    print(f'{"":<38}' + ''.join(f'{f:>9}' for f in funcoes) + f'{"total":>9}{"%":>8}')
    tot = sum(v for k, v in R['liquido_us_por_ciclo'].items() if not k.startswith('Fundo'))
    for cat in CATEGORIAS:
        linha = f'{cat:<38}' + ''.join(f'{R["funcoes"][f]["liquido_us_por_ciclo"].get(cat, 0):>9.0f}' for f in funcoes)
        v = R['liquido_us_por_ciclo'].get(cat, 0)
        linha += f'{v:>9.0f}' + (f'{100 * v / tot:>7.1f}%' if tot and not cat.startswith('Fundo') else '')
        print(linha)
    print(f'{"Total (sem fundo)":<38}' + ''.join(
        f'{sum(v for k, v in R["funcoes"][f]["liquido_us_por_ciclo"].items() if not k.startswith("Fundo")):>9.0f}'
        for f in funcoes) + f'{tot:>9.0f}')
    for f in funcoes:
        print(f'\n--- {f}: folhas mais frequentes na carga ---')
        for s, d, k in R['funcoes'][f]['folhas_top'][:10]:
            print(f'  {k:>6}  {s[:50]:<50} {d}')


if __name__ == '__main__':
    main(sys.argv[1])
