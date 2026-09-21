#!/usr/bin/env python3
"""Analisa uma corrida do cenário 'fábrica' (scripts/cenario-fabrica.sh).

Ao contrário do analisar.py, que separa o registo da sessão PDU no tempo, aqui os procedimentos
de todos os dispositivos misturam-se: a análise é feita à janela de regime e as métricas são
normalizadas por dispositivo e por hora.

Uso: ./scripts/analisar-fabrica.py <pasta>/<nome>.pcapng
Escreve <nome>.fabrica.json e imprime um resumo.
"""
import json, os, re, subprocess, sys
from collections import Counter

NOMES = {
    '10.100.1.5': 'AMF', '10.100.2.5': 'AMF', '10.100.1.4': 'SMF', '10.100.4.4': 'SMF',
    '10.100.4.7': 'UPF', '10.100.3.7': 'UPF', '10.100.1.10': 'NRF', '10.100.1.200': 'SCP',
    '10.100.1.11': 'AUSF', '10.100.1.12': 'UDM', '10.100.1.20': 'UDR', '10.100.1.13': 'PCF',
    '10.100.1.14': 'NSSF', '10.100.1.15': 'BSF', '10.100.1.100': 'MongoDB', '10.100.2.50': 'gNB',
}
INTERFACE = {'10.100.1.': 'SBI', '10.100.2.': 'N2', '10.100.4.': 'N4', '10.100.3.': 'N3'}

# Procedimento -> texto que o identifica na coluna Info da mensagem que o inicia
PROCEDIMENTOS = {
    'service_request': 'Service request',
    'registo_periodico': 'Registration request',
    'libertacao': 'UEContextReleaseRequest',
}


def tshark(pasta, ficheiro, filtro, campos):
    cmd = ['docker', 'run', '--rm', '-v', f'{pasta}:/cap', '-w', '/cap', 'core-simplified/tshark:jammy',
           'tshark', '-o', 'nas-5gs.null_decipher:TRUE', '-d', 'tcp.port==7777,http2', '-r', ficheiro,
           '-Y', filtro, '-T', 'fields', '-E', 'separator=\t', '-E', 'aggregator=#']
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
    meta = dict(l.strip().split('=', 1) for l in open(f'{pasta}/{base}.meta') if '=' in l)
    t0, t1 = float(meta['t_inicio']), float(meta['t_fim'])
    n_ues = int(meta['ues_prontos'] or meta['n_ues'])
    janela_s = t1 - t0
    # fator de normalização: de "na janela" para "por dispositivo e por hora"
    por_disp_hora = 3600.0 / (janela_s * n_ues) if n_ues and janela_s > 0 else 0

    M = {'meta': meta, 'janela_s': round(janela_s, 1), 'n_dispositivos': n_ues,
         'periodo_s': int(meta['periodo'])}

    # --- NGAP: mensagens e procedimentos ---
    ngap_msgs = 0
    procs = Counter()
    for t, info, codes in tshark(pasta, ficheiro, 'ngap && sctp',
                                 ['frame.time_epoch', '_ws.col.Info', 'ngap.procedureCode']):
        t = float(t)
        if not (t0 <= t <= t1):
            continue
        ngap_msgs += len(codes.split('#')) if codes else 1
        # A coluna Info repete o nome da mensagem NAS (exterior e interior), por isso contar
        # ocorrências do texto duplicaria: conta-se a mensagem NGAP que INICIA o procedimento.
        n_inicial = info.count('InitialUEMessage')
        if n_inicial:
            if PROCEDIMENTOS['service_request'] in info:
                procs['service_request'] += n_inicial
            elif PROCEDIMENTOS['registo_periodico'] in info:
                procs['registo_periodico'] += n_inicial
        procs['libertacao'] += info.count(PROCEDIMENTOS['libertacao'])

    # --- SBI: pedidos lógicos (a origem não é a SCP) e por caminho ---
    sbi, caminhos = 0, Counter()
    for t, s, d, p in tshark(pasta, ficheiro, 'http2.headers.path',
                             ['frame.time_epoch', 'ip.src', 'ip.dst', 'http2.headers.path']):
        t = float(t)
        if not (t0 <= t <= t1):
            continue
        for q in p.split('#'):
            q = re.sub(r'\?.*', '', q)
            q = re.sub(r'imsi-\d+', '{supi}', q)
            q = re.sub(r'suci-[\d-]+', '{suci}', q)
            q = re.sub(r'/(sm-contexts|sm-policies|pcfBindings)/[^/]+', r'/\1/{id}', q)
            q = re.sub(r'nf-instances/[0-9a-f-]+', 'nf-instances/{id}', q)
            q = re.sub(r'subscriptions/[0-9a-f-]+', 'subscriptions/{id}', q)
            if q.startswith('/nnrf-nfm'):
                continue                       # gestão de NFs: heartbeats, não é tráfego de UEs
            caminhos[q] += 1
            if NOMES.get(s, s) != 'SCP':
                sbi += 1

    # --- PFCP e bytes por interface ---
    pfcp = 0
    for t, in tshark(pasta, ficheiro, 'pfcp && !(pfcp.msg_type == 1 || pfcp.msg_type == 2)',
                     ['frame.time_epoch']):
        if t0 <= float(t) <= t1:
            pfcp += 1
    bytes_if = Counter()
    for t, s, d, n in tshark(pasta, ficheiro, 'ip', ['frame.time_epoch', 'ip.src', 'ip.dst', 'frame.len']):
        if t0 <= float(t) <= t1:
            nome = 'MongoDB' if '10.100.1.100' in (s, d) else (
                interface(s) if interface(s) != 'outra' else interface(d))
            bytes_if[nome] += int(n)

    M['procedimentos'] = {k: procs.get(k, 0) for k in PROCEDIMENTOS}
    M['procedimentos']['total'] = sum(M['procedimentos'].values())
    M['mensagens'] = {'ngap': ngap_msgs, 'sbi_pedidos': sbi, 'pfcp': pfcp}
    M['sbi_por_caminho'] = dict(caminhos.most_common())
    M['bytes'] = dict(bytes_if)

    # --- recursos: CPU consumida na janela e memória no fim ---
    rec = {}
    rp = f'{pasta}/{base}.recursos.tsv'
    if os.path.exists(rp):
        for l in open(rp):
            k, s, cpu, mem = l.split('\t')
            rec.setdefault(s, {})[k] = (int(cpu), int(mem))
        core = [s for s in rec if s not in ('ue', 'gnb', 'mongodb') and 'I' in rec[s] and 'F' in rec[s]]
        M['recursos_core'] = {
            'n_servicos': len(core),
            'cpu_ms_janela': round(sum(rec[s]['F'][0] - rec[s]['I'][0] for s in core) / 1000, 1),
            'mem_mib_fim': round(sum(rec[s]['F'][1] for s in core) / 2**20, 1),
            'cpu_ms_por_servico': {s: round((rec[s]['F'][0] - rec[s]['I'][0]) / 1000, 1)
                                   for s in sorted(core)},
        }

    # --- normalizado por dispositivo e por hora ---
    M['por_dispositivo_hora'] = {
        'procedimentos': round(M['procedimentos']['total'] * por_disp_hora, 1),
        'ngap': round(ngap_msgs * por_disp_hora, 1),
        'sbi_pedidos': round(sbi * por_disp_hora, 1),
        'pfcp': round(pfcp * por_disp_hora, 1),
    }
    if 'recursos_core' in M:
        M['por_dispositivo_hora']['cpu_ms'] = round(
            M['recursos_core']['cpu_ms_janela'] * por_disp_hora, 1)

    json.dump(M, open(f'{pasta}/{base}.fabrica.json', 'w'), indent=1, ensure_ascii=False)

    p = M['procedimentos']
    print(f"=== {base} (fabrica/{meta['variante']}) ===")
    print(f"{n_ues} dispositivos, periodo {meta['periodo']}s, janela {janela_s:.0f}s")
    print(f"procedimentos: {p['total']} "
          f"(service request {p['service_request']}, registo periódico {p['registo_periodico']}, "
          f"libertação {p['libertacao']})")
    print(f"mensagens na janela: NGAP {ngap_msgs} | SBI pedidos {sbi} | PFCP {pfcp}")
    h = M['por_dispositivo_hora']
    print(f"por dispositivo/hora: {h['procedimentos']} procedimentos | {h['ngap']} NGAP | "
          f"{h['sbi_pedidos']} SBI | {h.get('cpu_ms', '-')} ms CPU")
    if 'recursos_core' in M:
        r = M['recursos_core']
        print(f"core ({r['n_servicos']} serviços): {r['cpu_ms_janela']} ms de CPU na janela, "
              f"{r['mem_mib_fim']} MiB de memória")
    print(f"bytes na janela: {dict(bytes_if)}")


if __name__ == '__main__':
    main(sys.argv[1])
