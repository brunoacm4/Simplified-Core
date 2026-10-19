#!/usr/bin/env python3
"""Conta e conta a história de uma corrida do scripts/historia-fabrica.sh.

As mensagens dos procedimentos (NGAP, SBI lógicos, PFCP de sessão) são agrupadas em rajadas (intervalo
> 0,4 s separa duas). Cada rajada é atribuída a um dispositivo pelo IMSI nos caminhos SBI ou, se não
houver, pelos acontecimentos do log do UE na mesma janela; o rótulo do procedimento vem do log do UE.
O resto é fundo: gestão na NRF (nnrf-nfm), heartbeats e associação PFCP, heartbeats SCTP, NG Setup.
Os pacotes de dados (GTP-U em N3) são contados por dispositivo pelo IP interior.

Uso: ./scripts/analisar-historia.py <pasta>/<nome>.pcapng
Escreve <nome>.historia.json e imprime: totais por fase e dispositivo, a história cronológica e a
sequência completa da primeira ocorrência de cada procedimento em cada dispositivo.
"""
import json, os, re, sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
fab = import_module('analisar-fabrica')
g1 = import_module('analisar-grupo1')

DISPOSITIVOS = {'999700000000001': 'sensor-rapido', '999700000000002': 'atuador',
                '999700000000003': 'sensor-lento'}
# Linha do log do UE -> rótulo do procedimento
ROTULOS = [
    ('Sending Initial Registration', 'registo inicial'),
    ('Sending Periodic Registration', 'registo periódico'),
    ('Responding to received Paging', 'paging + service request'),
    ('Sending Service Request due to [IDLE-UPLINK-DATA', 'service request'),
    ('Sending Service Request due to [IDLE-UPLINK-SIGNAL', 'service request (sinalização)'),
    ('Sending PDU Session Establishment Request', 'sessão PDU'),
    ('Starting de-registration procedure', 'desregisto pelo UE'),
    ('RRC Release received', 'libertação'),
    ('Sending Registration Complete', 'conclusão do registo'),
]
ANTES, DEPOIS = 0.3, 0.05  # s antes / depois de um fragmento onde procurar o acontecimento do UE
FRAGMENTO = 0.1   # s sem mensagens que separa dois fragmentos
INTERVALO = 0.4   # s sem mensagens que separa duas rajadas do mesmo dispositivo


def log_ue(caminho):
    """[(epoch, rótulo)] a partir de um log do UERANSIM (horas em UTC)."""
    out = []
    for linha in open(caminho, errors='replace'):
        m = re.match(r'\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\]', linha)
        if not m:
            continue
        for texto, rotulo in ROTULOS:
            if texto in linha:
                t = datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S.%f').replace(tzinfo=timezone.utc)
                out.append((t.timestamp(), rotulo))
                break
    return out


def main(pcap):
    pcap = os.path.realpath(pcap)
    pasta, ficheiro = os.path.dirname(pcap), os.path.basename(pcap)
    base = ficheiro[:-len('.pcapng')]
    eventos = [(float(a), float(b), n) for a, b, n in
               (l.split() for l in open(f'{pasta}/{base}.eventos') if l.strip())]
    fases = [(a, b, n.split(':', 1)[1]) for a, b, n in eventos if n.startswith('fase:')]
    t0 = min(a for a, _, _ in fases)
    meta = dict(l.strip().split('=', 1) for l in open(f'{pasta}/{base}.meta') if '=' in l)
    ip_disp = {meta['ip_atuador']: 'atuador'}
    for d in ('sensor-rapido', 'sensor-lento'):
        for ip in meta.get(f'ips_{d}', '').split():
            ip_disp[ip] = d

    logs = {d: log_ue(f'{pasta}/{base}-logs/{d}.log') for d in DISPOSITIVOS.values()}

    proc, fundo = [], []   # (t, interface, n, texto, imsi|None)
    for t, s, d, info, codes in fab.tshark(pasta, ficheiro, 'ngap && sctp',
                                           ['frame.time_epoch', 'ip.src', 'ip.dst', '_ws.col.Info',
                                            'ngap.procedureCode']):
        n = len(codes.split('#')) if codes else 1
        info = re.sub(r'SACK \([^)]*\) , ', '', info)
        txt = f'{fab.NOMES.get(s, s)}->{fab.NOMES.get(d, d)} {info}'
        (fundo if 'NGSetup' in info else proc).append((float(t), 'NGAP', n, txt, None))
    for (t,) in fab.tshark(pasta, ficheiro, 'sctp.chunk_type == 4 || sctp.chunk_type == 5',
                           ['frame.time_epoch']):
        fundo.append((float(t), 'SCTP-HB', 1, 'heartbeat SCTP', None))
    for t, s, d, m, p in fab.tshark(pasta, ficheiro, 'http2.headers.path',
                                    ['frame.time_epoch', 'ip.src', 'ip.dst', 'http2.headers.method',
                                     'http2.headers.path']):
        if fab.NOMES.get(s, s) == 'SCP':
            continue
        ps, ms = p.split('#'), m.split('#')
        for i, q in enumerate(ps):
            imsi = re.search(r'imsi-(\d+)', q)
            met = ms[i] if len(ms) == len(ps) and ms[i] else '?'
            q = g1.caminho(q)
            txt = f'{fab.NOMES.get(s, s)} {met} {q}'
            alvo = fundo if q.startswith('/nnrf-nfm') else proc
            alvo.append((float(t), 'SBI', 1, txt, imsi.group(1) if imsi else None))
    for t, s, d, tipo in fab.tshark(pasta, ficheiro, 'pfcp', ['frame.time_epoch', 'ip.src', 'ip.dst',
                                                              'pfcp.msg_type']):
        tipo = int(tipo)
        nome = g1.PFCP_TIPOS.get(tipo, {1: 'HeartbeatReq', 2: 'HeartbeatResp', 5: 'AssocSetupReq',
                                       6: 'AssocSetupResp'}.get(tipo, str(tipo)))
        txt = f'{fab.NOMES.get(s, s)}->{fab.NOMES.get(d, d)} {nome}'
        (fundo if tipo < 50 else proc).append((float(t), 'PFCP', 1, txt, None))
    dados = []   # (t, dispositivo)
    for t, ips in fab.tshark(pasta, ficheiro, 'gtp && ip', ['frame.time_epoch', 'ip.addr']):
        disp = next((ip_disp[ip] for ip in re.split('[#,]', ips) if ip in ip_disp), None)
        if disp:
            dados.append((float(t), disp))
    proc.sort(); fundo.sort()

    # --- rajadas ---
    # Primeiro fragmentos curtos (separados por > FRAGMENTO s), cada um atribuído a um dispositivo;
    # depois os fragmentos do mesmo dispositivo (ou sem dispositivo) a menos de INTERVALO s da rajada
    # anterior desse dispositivo juntam-se a ela. Assim dois procedimentos de dispositivos diferentes
    # a 0,2 s um do outro ficam separados, e a conclusão de um registo (que o UE envia ~0,2 s depois)
    # fica com o registo.
    # Casar com o log do UE: cada acontecimento do log serve um só fragmento, o primeiro que o tenha
    # na janela [início - ANTES, fim + DEPOIS]. O gNB do UERANSIM às vezes entrega ao AMF ~0,2 s depois
    # de o UE enviar (fila ocupada com outro UE), por isso a janela olha mais para trás.
    usados = set()

    def quem(f):
        a, b = f[0][0], f[-1][0]
        disp_imsi = {DISPOSITIVOS.get(m[4], m[4]) for m in f if m[4]}
        rot = defaultdict(list)
        for d, ev in logs.items():
            for i, (t, nome) in enumerate(ev):
                if (d, i) not in usados and a - ANTES <= t <= b + DEPOIS:
                    rot[d].append((i, nome))
        if len(disp_imsi) == 1:
            disp = next(iter(disp_imsi))
        elif not disp_imsi and len(rot) == 1:
            disp = next(iter(rot))
        else:
            disp = '+'.join(sorted(disp_imsi or rot)) or None
        nomes = []
        for d in (disp or '').split('+'):
            for i, nome in rot.get(d, []):
                usados.add((d, i)); nomes.append(nome)
        return disp, nomes

    fragmentos, atual = [], []
    for m in proc:
        if atual and m[0] - atual[-1][0] > FRAGMENTO:
            fragmentos.append(atual); atual = []
        atual.append(m)
    if atual:
        fragmentos.append(atual)
    rajadas = []   # [mensagens, dispositivo, rótulos]
    for f in fragmentos:
        d, nomes = quem(f)
        alvo = None
        for r in reversed(rajadas):              # a rajada recente do mesmo dispositivo
            if f[0][0] - r[0][-1][0] > INTERVALO:
                break
            if d is None or r[1] == d:
                alvo = r
                break
        if alvo:
            alvo[0].extend(f); alvo[2].extend(nomes)
        else:
            rajadas.append([f, d, nomes])

    historia = []
    for r, disp, nomes in rajadas:
        r.sort()
        a, b = r[0][0], r[-1][0]
        disp = disp or '?'
        rotulos = list(dict.fromkeys(nomes))
        if len(rotulos) > 1 and 'conclusão do registo' in rotulos:
            rotulos.remove('conclusão do registo')
        textos = ' '.join(m[3] for m in r)
        if 'registo periódico' in rotulos and 'Identity request' in textos:
            # O AMF já não conhece o GUTI (desregisto implícito): identificação + autenticação
            rotulos[rotulos.index('registo periódico')] = 'registo periódico depois do desregisto'
        if not rotulos:
            if 'sm-contexts/{id}/release' in textos and 'amf-3gpp-access' in textos:
                rotulos = ['desregisto implícito']
            elif 'UEContextReleaseRequest' in textos:
                rotulos = ['libertação']
            else:
                rotulos = [r[0][3][:60]]
        c = Counter()
        for m in r:
            c[m[1]] += m[2]
        fase = next((n for fa, fb, n in fases if fa <= a <= fb), '?')
        historia.append({'t': round(a - t0, 3), 'fase': fase, 'dispositivo': disp,
                         'procedimento': ' + '.join(rotulos), 'NGAP': c['NGAP'], 'SBI': c['SBI'],
                         'PFCP': c['PFCP'],
                         'mensagens': [{'t': round(m[0] - a, 4), 'if': m[1], 'n': m[2], 'texto': m[3]}
                                       for m in r]})

    # --- totais por fase ---
    totais = {}
    for fa, fb, nome in fases:
        por = defaultdict(Counter)
        for h in historia:
            if h['fase'] == nome:
                for k in ('NGAP', 'SBI', 'PFCP'):
                    por[h['dispositivo']][k] += h[k]
                por[h['dispositivo']]['procedimentos'] += 1
        for t, d in dados:
            if fa <= t <= fb:
                por[d]['dados'] += 1
        for m in fundo:
            if fa <= m[0] <= fb:
                chave = {'SBI': 'NRF', 'PFCP': 'PFCP', 'SCTP-HB': 'SCTP', 'NGAP': 'NGAP'}[m[1]]
                por['fundo'][chave] += m[2]
        totais[nome] = {'inicio': round(fa - t0, 1), 'duracao': round(fb - fa, 1),
                        'por': {k: dict(v) for k, v in por.items()}}

    # --- custo médio por procedimento e dispositivo ---
    custos = defaultdict(lambda: Counter())
    for h in historia:
        k = (h['dispositivo'], h['procedimento'])
        custos[k]['vezes'] += 1
        for x in ('NGAP', 'SBI', 'PFCP'):
            custos[k][x] += h[x]

    json.dump({'fases': totais, 'historia': historia,
               'custos': [{'dispositivo': d, 'procedimento': p, **dict(c)} for (d, p), c in custos.items()]},
              open(f'{pasta}/{base}.historia.json', 'w'), ensure_ascii=False, indent=1)

    print(f'=== {base} ===\n')
    print('--- totais por fase (procedimentos: NGAP/SBI/PFCP; dados: pacotes GTP-U em N3) ---')
    for nome, f in totais.items():
        print(f'\n[{nome}] início +{f["inicio"]:.0f}s, {f["duracao"]:.0f}s')
        for d, c in sorted(f['por'].items()):
            if d == 'fundo':
                print(f'  {"fundo":<14} NRF {c.get("NRF", 0):>4}  PFCP-HB {c.get("PFCP", 0):>3}  '
                      f'SCTP-HB {c.get("SCTP", 0):>3}  NGSetup {c.get("NGAP", 0)}')
            else:
                print(f'  {d:<14} proc {c.get("procedimentos", 0):>3}  NGAP {c.get("NGAP", 0):>4}  '
                      f'SBI {c.get("SBI", 0):>4}  PFCP {c.get("PFCP", 0):>4}  dados {c.get("dados", 0):>4}')
    print('\n--- custo por procedimento (média por ocorrência) ---')
    for (d, p), c in sorted(custos.items()):
        v = c['vezes']
        print(f'  {d:<14} {p:<45} {v:>3}x  NGAP {c["NGAP"]/v:5.1f}  SBI {c["SBI"]/v:5.1f}  PFCP {c["PFCP"]/v:4.1f}')
    print('\n--- história ---')
    for h in historia:
        mm, ss = divmod(h['t'], 60)
        print(f'  +{int(mm):02d}:{ss:06.3f}  {h["fase"]:<13} {h["dispositivo"]:<14} {h["procedimento"]:<45} '
              f'{h["NGAP"]}/{h["SBI"]}/{h["PFCP"]}')
    print('\n--- sequências (primeira ocorrência de cada procedimento em cada dispositivo) ---')
    vistos = set()
    for h in historia:
        k = (h['dispositivo'], h['procedimento'])
        if k in vistos:
            continue
        vistos.add(k)
        print(f'\n{h["dispositivo"]}: {h["procedimento"]} (+{h["t"]:.1f}s)')
        for m in h['mensagens']:
            print(f'   +{m["t"]:.3f}s {m["if"]:<4} {m["texto"]}')


if __name__ == '__main__':
    main(sys.argv[1])
