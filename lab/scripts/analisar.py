#!/usr/bin/env python3
"""Analisa uma corrida gerada por capturar-registo.sh e produz métricas.

Uso: ./scripts/analisar.py <pasta>/<nome>.pcapng

Fases (separadas pelo instante <nome>.t_ue):
  arranque   tudo antes do UE arrancar
  registo    do InitialUEMessage até à Registration Complete (+ Configuration Update)
  sessao     sessão PDU (pedidos SBI depois da Registration Complete + PDUSessionResourceSetup)

Escreve <nome>.ngap.tsv, <nome>.sbi.tsv e <nome>.metricas.json, e imprime um resumo.
Requer a imagem core-simplified/tshark:jammy (lab/images/tshark).
"""
import json, os, re, subprocess, sys
from collections import Counter, defaultdict

NOMES = {
    '10.100.1.5': 'AMF', '10.100.2.5': 'AMF', '10.100.1.4': 'SMF', '10.100.4.4': 'SMF',
    '10.100.4.7': 'UPF', '10.100.3.7': 'UPF', '10.100.1.10': 'NRF', '10.100.1.200': 'SCP',
    '10.100.1.11': 'AUSF', '10.100.1.12': 'UDM', '10.100.1.20': 'UDR', '10.100.1.13': 'PCF',
    '10.100.1.14': 'NSSF', '10.100.1.15': 'BSF', '10.100.1.100': 'MongoDB', '10.100.2.50': 'gNB',
}
INTERFACE = {'10.100.1.': 'SBI', '10.100.2.': 'N2', '10.100.4.': 'N4', '10.100.3.': 'N3'}


def tshark(pasta, ficheiro, filtro, campos, extra=()):
    cmd = ['docker', 'run', '--rm', '-v', f'{pasta}:/cap', '-w', '/cap', 'core-simplified/tshark:jammy',
           'tshark', '-o', 'nas-5gs.null_decipher:TRUE', '-d', 'tcp.port==7777,http2', '-r', ficheiro,
           '-Y', filtro, '-T', 'fields', '-E', 'separator=\t', '-E', 'aggregator=#', *extra]
    for c in campos:
        cmd += ['-e', c]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [l.split('\t') for l in out.splitlines() if l]


def interface(ip):
    for pref, nome in INTERFACE.items():
        if ip.startswith(pref):
            return nome
    return 'outra'


def main(pcap):
    pcap = os.path.realpath(pcap)
    pasta, ficheiro = os.path.dirname(pcap), os.path.basename(pcap)
    base = ficheiro[:-len('.pcapng')]
    t_ue = float(open(f'{pasta}/{base}.t_ue').read())
    meta = dict(l.strip().split('=', 1) for l in open(f'{pasta}/{base}.meta') if '=' in l) \
        if os.path.exists(f'{pasta}/{base}.meta') else {}
    janela = float(meta.get('janela', 10))

    # --- NGAP (só SCTP: o SMF também leva blocos NGAP dentro do JSON SBI) ---
    # Um pacote SCTP pode levar várias mensagens NGAP (PDUs), até de UEs diferentes: guardamos a lista
    # (tipo 0=pedido/1=resposta, código do procedimento, RAN-UE-NGAP-ID) de cada pacote.
    ngap, pdus = [], []
    for t, s, d, i, tipo, proc, ue in tshark(pasta, ficheiro, 'ngap && sctp',
                                             ['frame.time_epoch', 'ip.src', 'ip.dst', '_ws.col.Info',
                                              'ngap.NGAP_PDU', 'ngap.procedureCode', 'ngap.RAN_UE_NGAP_ID']):
        t = float(t)
        ngap.append((t, NOMES.get(s, s), NOMES.get(d, d), re.sub(r'SACK \([^)]*\) , ', '', i)))
        tipos, procs, ues = tipo.split('#'), proc.split('#'), ue.split('#') if ue else []
        for k in range(len(procs)):
            pdus.append((t, int(tipos[k]), int(procs[k]), ues[k] if k < len(ues) else None))
    ngap.sort(); pdus.sort()
    npdus = {}  # nº de PDUs por pacote (instante) para contar mensagens e não pacotes
    for x in pdus:
        npdus[x[0]] = npdus.get(x[0], 0) + 1
    t_initial = next(t for t, s, d, i in ngap if t >= t_ue and 'InitialUEMessage' in i)
    t_regcomp = next(t for t, s, d, i in ngap if t >= t_ue and 'Registration complete' in i)
    t_accept = next(t for t, s, d, i in ngap if t >= t_ue and 'Registration accept' in i)
    t_pdu_setup = next((t for t, s, d, i in ngap if t >= t_ue and 'PDUSessionResourceSetupRequest' in i), None)

    def fase_ngap(t, info):
        if t < t_ue:
            return 'arranque'
        return 'sessao' if 'PDUSessionResourceSetup' in info else 'registo'

    def fase_sbi(t):
        if t < t_ue:
            return 'arranque'
        return 'registo' if t < t_regcomp else 'sessao'

    # --- SBI: um pedido HTTP/2 por linha (uma trama pode levar vários) ---
    sbi = []
    for t, s, d, m, p in tshark(pasta, ficheiro, 'http2.headers.path',
                                ['frame.time_epoch', 'ip.src', 'ip.dst', 'http2.headers.method',
                                 'http2.headers.path']):
        paths, mets = p.split('#'), m.split('#') if m else []
        for k, q in enumerate(paths):
            q = re.sub(r'\?.*', '', q)
            q = re.sub(r'imsi-\d+', '{supi}', q)
            q = re.sub(r'suci-[\d-]+', '{suci}', q)
            q = re.sub(r'nf-instances/[0-9a-f-]+', 'nf-instances/{id}', q)
            q = re.sub(r'subscriptions/[0-9a-f-]+', 'subscriptions/{id}', q)
            met = mets[k] if len(mets) == len(paths) and mets[k] else '?'
            sbi.append((float(t), NOMES.get(s, s), NOMES.get(d, d), met, q))
    sbi.sort()

    # --- bytes por interface (todas as tramas IP) ---
    tramas = [(float(t), s, d, int(n)) for t, s, d, n in
              tshark(pasta, ficheiro, 'ip', ['frame.time_epoch', 'ip.src', 'ip.dst', 'frame.len'])]

    # --- ficheiros intermédios ---
    with open(f'{pasta}/{base}.ngap.tsv', 'w') as f:
        for t, s, d, i in ngap:
            f.write(f'{fase_ngap(t, i)}\t{t:.6f}\t{s}\t{d}\t{i}\n')
    with open(f'{pasta}/{base}.sbi.tsv', 'w') as f:
        for t, s, d, m, q in sbi:
            f.write(f'{fase_sbi(t)}\t{t:.6f}\t{s}\t{d}\t{m}\t{q}\n')

    # --- métricas de sinalização por fase ---
    M = {'variante': meta.get('variante', '?'), 'corrida': base, 'meta': meta}
    for fase in ('arranque', 'registo', 'sessao'):
        n = 0
        for tt, s, d, i in ngap:
            k = npdus.get(tt, 1)
            if tt >= t_ue and 'Registration complete' in i and 'PDU session establishment request' in i:
                # pacote com a Registration Complete + o pedido de sessão PDU (2 mensagens NGAP)
                n += 1 if fase == 'registo' else (k - 1 if fase == 'sessao' else 0)
            elif fase_ngap(tt, i) == fase:
                n += k
        pedidos = [x for x in sbi if fase_sbi(x[0]) == fase]
        proc = [x for x in pedidos if not x[4].startswith('/nnrf-nfm')]
        nrf = [x for x in pedidos if x[4].startswith('/nnrf-nfm')]
        M[fase] = {
            'ngap': n,
            # pedido lógico = perna de origem (quem pede não é a SCP)
            'sbi_pedidos': sum(1 for x in proc if x[1] != 'SCP'),
            'http_pedidos': len(proc),                 # todas as pernas (com SCP: 2 por pedido)
            'http_mensagens': 2 * len(proc),           # cada pedido tem uma resposta
            'gestao_nrf_pedidos': len(nrf),
            'gestao_nrf_por_tipo': dict(Counter(
                'notificação' if x[1] == 'NRF' else 'subscrição' if 'subscriptions' in x[4]
                else 'lista' if x[4].endswith('nf-instances') else f'nf-instance {x[3]}'
                for x in nrf if x[1] != 'SCP')),
            'destinos': dict(Counter(x[2] for x in proc if x[2] != 'SCP')),   # destino final de cada pedido
        }
    # bytes: janela com UE = [t_ue, t_ue+janela); fundo = [t_ue-janela, t_ue)
    for nome, a, b in (('bytes_fundo', t_ue - janela, t_ue), ('bytes_ue', t_ue, t_ue + janela)):
        c = defaultdict(int)
        for t, s, d, n in tramas:
            if a <= t < b:
                if '10.100.1.100' in (s, d):
                    c['MongoDB'] += n          # base de dados: está na rede sbi mas não é SBI
                else:
                    c[interface(s) if interface(s) != 'outra' else interface(d)] += n
        M[nome] = dict(c)
    M['bytes_janela_s'] = janela

    # --- janela com UE: totais e métricas por UE (1 ou N UEs) ---
    proc_ue = [x for x in sbi if x[0] >= t_ue and not x[4].startswith('/nnrf-nfm')]
    ini, acc, fim = {}, {}, {}
    for tt, tipo, proc, ue in pdus:
        if tt < t_ue or ue is None:
            continue
        if proc == 15 and tipo == 0:
            ini.setdefault(ue, tt)                      # InitialUEMessage
        elif proc == 14 and tipo == 0:
            acc.setdefault(ue, tt)                      # InitialContextSetupRequest (leva o Registration accept)
        elif proc == 29 and tipo == 1:
            fim.setdefault(ue, tt)                      # PDUSessionResourceSetupResponse (sessão pronta)
    lat_reg = sorted((acc[u] - ini[u]) * 1000 for u in ini if u in acc)
    lat_tot = sorted((fim[u] - ini[u]) * 1000 for u in ini if u in fim)

    def pct(v, p):
        return round(v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))], 3) if v else None
    n_ues = int(meta.get('n_ues', 1))
    M['ue'] = {
        'n_ues_pedidos': n_ues,
        'n_ues_registados': len(lat_reg),
        'n_ues_com_sessao': len(lat_tot),
        'ngap': sum(1 for x in pdus if x[0] >= t_ue),
        'sbi_pedidos': sum(1 for x in proc_ue if x[1] != 'SCP'),
        'http_mensagens': 2 * len(proc_ue),
        'lat_registo_core_ms': {'mediana': pct(lat_reg, 50), 'p95': pct(lat_reg, 95), 'max': pct(lat_reg, 100)},
        'lat_registo_mais_sessao_ms': {'mediana': pct(lat_tot, 50), 'p95': pct(lat_tot, 95), 'max': pct(lat_tot, 100)},
        # do primeiro InitialUEMessage até ao último UE com sessão pronta
        'tempo_todos_ms': round((max(fim.values()) - min(ini.values())) * 1000, 3) if fim and ini else None,
    }

    # --- latência do lado do core (ms) ---
    M['latencia_ms'] = {
        'registo_core': round((t_accept - t_initial) * 1000, 3),        # InitialUEMessage -> Registration accept
        'sessao_core': round((t_pdu_setup - t_regcomp) * 1000, 3) if t_pdu_setup else None,
    }

    # --- recursos: CPU (µs acumulados) e memória por serviço nos instantes A, B, C ---
    rec = defaultdict(dict)
    rp = f'{pasta}/{base}.recursos.tsv'
    if os.path.exists(rp):
        for l in open(rp):
            k, s, cpu, mem = l.split('\t')
            rec[s][k] = (int(cpu), int(mem))
        R = {}
        for s, v in sorted(rec.items()):
            if not all(k in v for k in 'ABC'):
                continue
            fundo = (v['B'][0] - v['A'][0]) / 1000
            ue = (v['C'][0] - v['B'][0]) / 1000
            R[s] = {'cpu_ms_fundo': round(fundo, 3), 'cpu_ms_com_ue': round(ue, 3),
                    'cpu_ms_liquido': round(ue - fundo, 3),
                    'mem_mib_B': round(v['B'][1] / 2**20, 2), 'mem_mib_C': round(v['C'][1] / 2**20, 2)}
        core = [s for s in R if s not in ('ue', 'gnb', 'mongodb')]
        M['recursos'] = R
        M['recursos_core_total'] = {
            'n_servicos': len(core),
            'cpu_ms_fundo': round(sum(R[s]['cpu_ms_fundo'] for s in core), 3),
            'cpu_ms_com_ue': round(sum(R[s]['cpu_ms_com_ue'] for s in core), 3),
            'cpu_ms_liquido': round(sum(R[s]['cpu_ms_liquido'] for s in core), 3),
            'mem_mib_C': round(sum(R[s]['mem_mib_C'] for s in core), 2),
        }
        if M['ue']['n_ues_com_sessao']:
            M['recursos_core_total']['cpu_ms_liquido_por_ue'] = round(
                M['recursos_core_total']['cpu_ms_liquido'] / M['ue']['n_ues_com_sessao'], 3)

    json.dump(M, open(f'{pasta}/{base}.metricas.json', 'w'), indent=1, ensure_ascii=False)

    # --- resumo ---
    print(f"=== {base} ({M['variante']}) ===")
    for fase in ('arranque', 'registo', 'sessao'):
        x = M[fase]
        print(f"[{fase:8s}] NGAP {x['ngap']:3d} | SBI pedidos {x['sbi_pedidos']:3d} | "
              f"HTTP pedidos {x['http_pedidos']:3d} ({x['http_mensagens']} mensagens) | "
              f"gestão NRF {x['gestao_nrf_pedidos']:3d}")
    u = M['ue']
    print(f"UEs: {u['n_ues_registados']}/{u['n_ues_pedidos']} registados, {u['n_ues_com_sessao']} com sessão | "
          f"janela UE: NGAP {u['ngap']}, SBI pedidos {u['sbi_pedidos']}, HTTP {u['http_mensagens']} mensagens")
    print(f"latência registo por UE (ms): {u['lat_registo_core_ms']} | registo+sessão: {u['lat_registo_mais_sessao_ms']} "
          f"| todos prontos em {u['tempo_todos_ms']} ms")
    print(f"bytes em {janela:.0f}s — fundo: {M['bytes_fundo']}  com UE: {M['bytes_ue']}")
    if 'recursos_core_total' in M:
        r = M['recursos_core_total']
        print(f"core ({r['n_servicos']} serviços): CPU fundo {r['cpu_ms_fundo']} ms, com UE {r['cpu_ms_com_ue']} ms, "
              f"líquido {r['cpu_ms_liquido']} ms | memória {r['mem_mib_C']} MiB")


if __name__ == '__main__':
    main(sys.argv[1])
