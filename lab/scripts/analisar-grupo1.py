#!/usr/bin/env python3
"""Conta as mensagens de cada acontecimento de uma corrida do scripts/medir-grupo1.sh.

Mesmos critérios do analisar-fabrica.py: NGAP por mensagem (procedureCode) só sobre SCTP; SBI só os
pedidos lógicos (origem diferente da SCP), sem a gestão da NRF (nnrf-nfm); PFCP sem heartbeats.

Uso: ./scripts/analisar-grupo1.py <pasta>/<nome>.pcapng
Imprime, por acontecimento, as contagens e a sequência de mensagens.
"""
import os, re, sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
fab = import_module('analisar-fabrica')

PFCP_TIPOS = {50: 'SessEstReq', 51: 'SessEstResp', 52: 'SessModReq', 53: 'SessModResp',
              54: 'SessDelReq', 55: 'SessDelResp', 56: 'SessReportReq', 57: 'SessReportResp'}


def caminho(q):
    q = re.sub(r'\?.*', '', q)
    q = re.sub(r'imsi-\d+', '{supi}', q)
    q = re.sub(r'suci-[\d-]+', '{suci}', q)
    q = re.sub(r'/(sm-contexts|sm-policies|policies|pcfBindings|ue-contexts)/[^/]+', r'/\1/{id}', q)
    q = re.sub(r'nf-instances/[0-9a-f-]+', 'nf-instances/{id}', q)
    q = re.sub(r'subscriptions/[0-9a-f-]+', 'subscriptions/{id}', q)
    return q


def main(pcap):
    pcap = os.path.realpath(pcap)
    pasta, ficheiro = os.path.dirname(pcap), os.path.basename(pcap)
    base = ficheiro[:-len('.pcapng')]
    eventos = [(float(a), float(b), n) for a, b, n in
               (l.split() for l in open(f'{pasta}/{base}.eventos') if l.strip())]

    msgs = []   # (t, interface, texto)
    for t, s, d, info, codes in fab.tshark(pasta, ficheiro, 'ngap && sctp',
                                           ['frame.time_epoch', 'ip.src', 'ip.dst', '_ws.col.Info',
                                            'ngap.procedureCode']):
        n = len(codes.split('#')) if codes else 1
        info = re.sub(r'SACK \([^)]*\) , ', '', info)
        msgs.append((float(t), 'NGAP', n, f'{fab.NOMES.get(s, s)}->{fab.NOMES.get(d, d)} {info}'))
    for t, s, d, m, p in fab.tshark(pasta, ficheiro, 'http2.headers.path',
                                    ['frame.time_epoch', 'ip.src', 'ip.dst', 'http2.headers.method',
                                     'http2.headers.path']):
        if fab.NOMES.get(s, s) == 'SCP':
            continue
        ms = m.split('#')
        for i, q in enumerate(p.split('#')):
            q = caminho(q)
            if q.startswith('/nnrf-nfm'):
                continue
            met = ms[i] if len(ms) == len(p.split('#')) and ms[i] else '?'
            msgs.append((float(t), 'SBI', 1, f'{fab.NOMES.get(s, s)} {met} {q}'))
    for t, s, d, tipo in fab.tshark(pasta, ficheiro, 'pfcp && !(pfcp.msg_type == 1 || pfcp.msg_type == 2)',
                                    ['frame.time_epoch', 'ip.src', 'ip.dst', 'pfcp.msg_type']):
        msgs.append((float(t), 'PFCP', 1,
                     f'{fab.NOMES.get(s, s)}->{fab.NOMES.get(d, d)} {PFCP_TIPOS.get(int(tipo), tipo)}'))
    msgs.sort()

    print(f'=== {base} ===')
    print(f'{"acontecimento":<18} {"dur(s)":>7} {"NGAP":>5} {"SBI":>4} {"PFCP":>5}')
    vistos = set()
    for a, b, nome in eventos:
        dentro = [m for m in msgs if a <= m[0] <= b]
        c = Counter()
        for _, i, n, _ in dentro:
            c[i] += n
        print(f'{nome:<18} {b - a:>7.1f} {c["NGAP"]:>5} {c["SBI"]:>4} {c["PFCP"]:>5}')
    for a, b, nome in eventos:
        tipo = nome.split('-')[0] if nome[-1].isdigit() else nome
        if tipo in vistos:
            continue
        vistos.add(tipo)
        print(f'\n--- sequência: {nome} ---')
        for t, i, n, txt in (m for m in msgs if a <= m[0] <= b):
            print(f'  +{t - a:7.3f}s {i:<4} {txt}')


if __name__ == '__main__':
    main(sys.argv[1])
