#!/usr/bin/env python3
"""Analisa as corridas do scripts/medir-fase1.sh.

frota: tabela da memória do core em cada amostra (S0 só o core, S1 registados, S2 inalcançáveis,
S3 desregistados, S4 de volta) e o custo por dispositivo:
  guardado   = (S2 - S3) / N   o que o core liberta ao desregistar, com os processos vivos
  registo    = (S1 - S0) / N   o que custa registar (inclui crescimento do heap por pedido)
  regresso   = (S4 - S3) / N   o que custa voltar depois de apagado
para o heap talloc, a memória do cgroup (current, anon) e os lugares ocupados nos pools.
dl, ausencia: pacotes de dados (G-PDU no N3) para o IP do UE em cada acontecimento e, na ausencia,
as linhas de log que marcam o que o core fez (paging falhado, "UE not reachable", DROBU, desregisto).

As mensagens por acontecimento contam-se com scripts/analisar-grupo1.py <pasta>/<nome>.pcapng.

Uso: ./scripts/analisar-fase1.py <pasta>/<nome>.meta
"""
import os, re, sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib import import_module
fab = import_module('analisar-fabrica')

CAMPOS = ['talloc_bytes', 'talloc_blocks', 'memory_current', 'anon', 'malloc_uordblks']
RAJADA = 30  # s: janela da rajada de regresso (manutencao), abaixo do T3512 de 60 s das variantes
AMOSTRAS = ['S0', 'S1', 'S2', 'S3', 'S4']


def ler_memoria(caminho):
    """{amostra: {serviço: {campo: valor}}}"""
    m = defaultdict(lambda: defaultdict(dict))
    for linha in open(caminho):
        p = linha.split()
        if len(p) == 5:
            rot, _, s, campo, v = p
            m[rot][s][campo] = int(v)
    return m


def frota(pasta, base, meta):
    n = int(meta.get('n_ues', 0))
    m = ler_memoria(f'{pasta}/{base}.memoria.tsv')
    rots = list(m)                            # amostras pela ordem do ficheiro (S0.., C0/D1.., R1..)
    servicos = sorted({s for a in m.values() for s in a})
    print(f'=== {base}: N = {n}' + (f', braço {meta["braco"]}' if meta.get('braco') else '') + ' ===\n')
    for campo in CAMPOS:
        print(f'--- {campo} (KiB) ---')
        print(f'{"":<6}' + ''.join(f'{a:>10}' for a in rots))
        for s in servicos:
            print(f'{s:<6}' + ''.join(f'{m[a][s].get(campo, 0) / 1024:>10.0f}' for a in rots))
        tot = {a: sum(m[a][s].get(campo, 0) for s in servicos) for a in rots}
        print(f'{"total":<6}' + ''.join(f'{tot[a] / 1024:>10.0f}' for a in rots))
        if n:
            def d(x, y):
                return (tot.get(x, 0) - tot.get(y, 0)) / n / 1024 if x in tot and y in tot else float('nan')
            if base.startswith('frota'):
                print(f'  por dispositivo: guardado (S2-S3) {d("S2", "S3"):.1f} KiB | registo (S1-S0) '
                      f'{d("S1", "S0"):.1f} KiB | regresso (S4-S3) {d("S4", "S3"):.1f} KiB')
            else:
                print(f'  por dispositivo, em relação a {rots[0]}: ' +
                      ' | '.join(f'{a} {d(a, rots[0]):+.1f} KiB' for a in rots[1:]))
        print()
    # CPU de cada função entre amostras seguidas (inclui o fundo: heartbeats da NRF, etc.)
    if all('cpu_usec' in m[a].get(s, {}) for a in rots for s in servicos):
        print('--- CPU entre amostras (ms) ---')
        pares = list(zip(rots, rots[1:]))
        print(f'{"":<6}' + ''.join(f'{x + "-" + y:>10}' for x, y in pares))
        for s in servicos:
            print(f'{s:<6}' + ''.join(f'{(m[y][s]["cpu_usec"] - m[x][s]["cpu_usec"]) / 1000:>10.0f}' for x, y in pares))
        print(f'{"total":<6}' + ''.join(
            f'{sum(m[y][s]["cpu_usec"] - m[x][s]["cpu_usec"] for s in servicos) / 1000:>10.0f}' for x, y in pares))
        print()
    print('--- lugares ocupados nos pools ---')
    pools = sorted({(s, c) for a in m.values() for s, cs in a.items() for c in cs if c.startswith('pool_')})
    print(f'{"":<34}' + ''.join(f'{a:>8}' for a in rots))
    for s, c in pools:
        print(f'{s + " " + c[5:]:<34}' + ''.join(f'{m[a][s].get(c, 0):>8}' for a in rots))
    # Relatório talloc deixado por cada função ao terminar (o que ainda estava vivo)
    print('\n--- heap talloc vivo no fim (relatório ao terminar) ---')
    for s in servicos:
        log = f'{pasta}/{base}-logs/{s}.log'
        if not os.path.exists(log):
            continue
        tot = re.search(r"full talloc report on 'core' \(total\s+(\d+) bytes in\s+(\d+) blocks\)", open(log, errors='replace').read())
        print(f'  {s:<6} ' + (f'{int(tot.group(1)) / 1024:.0f} KiB em {tot.group(2)} blocos' if tot else 'sem relatório: todo o heap talloc libertado ao sair'))


def dl(pasta, base):
    ue_ip = open(f'{pasta}/{base}.ue_ip').read().strip().split('=')[1]
    eventos = [(float(a), float(b), n) for a, b, n in
               (l.split() for l in open(f'{pasta}/{base}.eventos') if l.strip())]
    pdus = [float(t) for t, in fab.tshark(pasta, f'{base}.pcapng', f'gtp && ip.dst == {ue_ip}',
                                         ['frame.time_epoch'])]
    print(f'=== {base}: pacotes de dados para o UE ({ue_ip}) no N3 ===')
    for a, b, n in eventos:
        print(f'  {n:<16} {sum(1 for t in pdus if a <= t <= b):>4}')


# Linhas de log dos patches 0007–0009 e do comportamento original: (função, texto)
MARCAS = [('amf', 'Mobile Reachable Timer Expired'), ('amf', 'Paging failed'),
          ('amf', 'UE not reachable: N1N2 rejected'), ('amf', 'kept registered'),
          ('amf', 'Implicit De-registered'), ('smf', 'drop buffered packets'),
          ('upf', '[DROBU]')]


def marcas(pasta, base):
    print(f'--- linhas de log ---')
    for s, texto in MARCAS:
        log = f'{pasta}/{base}-logs/{s}.log'
        linhas = [l for l in open(log, errors='replace')] if os.path.exists(log) else []
        n = sum(1 for l in linhas if texto in l)
        extra = ''
        if texto == '[DROBU]':
            fora = sum(int(m) for m in re.findall(r'(\d+) buffered packets dropped', ''.join(linhas)))
            extra = f'  ({fora} pacotes deitados fora)'
        print(f'  {s:<4} {texto:<34} {n:>3}{extra}')


def latencias(pasta, base):
    """Regresso em massa (manutencao): latência do core por UE, emparelhada pelo RAN-UE-NGAP-ID, do
    InitialUEMessage ao InitialContextSetupRequest (no regresso leva o Registration accept; no envio,
    o Service accept), e duração da rajada (primeiro InitialUEMessage ao último
    InitialContextSetupRequest da janela)."""
    eventos = {n: (float(a), float(b)) for a, b, n in
               (l.split() for l in open(f'{pasta}/{base}.eventos') if l.strip())}
    tramas = [(float(t), info, codes.split('#'), pdus.split('#'), rids.split('#'))
              for t, info, codes, pdus, rids in fab.tshark(
                  pasta, f'{base}.pcapng', 'ngap && sctp',
                  ['frame.time_epoch', '_ws.col.Info', 'ngap.procedureCode', 'ngap.NGAP_PDU',
                   'ngap.RAN_UE_NGAP_ID'])]
    print('--- latência do core no N2 (ms) ---')
    for nome in ('regresso', 'uplink'):
        if nome not in eventos:
            continue
        a, b = eventos[nome]
        # A rajada do regresso são os registos dos primeiros RAJADA s: se a espera se arrastar (UEs
        # presos no UERANSIM), a janela apanharia os registos periódicos seguintes (T3512 = 60 s)
        if nome == 'regresso':
            b = min(b, a + RAJADA)
        inicio, lat, fins = {}, [], []
        for t, info, cl, pl, rl in tramas:
            if not (a <= t <= b) or not (len(cl) == len(pl) == len(rl)) or not cl[0]:
                continue
            for c, pdu, rid in zip(cl, pl, rl):
                if int(c) == 15:
                    inicio.setdefault(rid, t)
                elif int(c) == 14 and int(pdu) == 0 and rid in inicio:
                    lat.append(t - inicio.pop(rid))
                    fins.append(t)
        if not lat:
            print(f'  {nome:<9} sem pares')
            continue
        v = sorted(lat)
        primeiro = min(t for t, info, cl, *_ in tramas if a <= t <= b and '15' in cl)
        print(f'  {nome:<9} n={len(v):>3}  mediana {1000 * v[len(v) // 2]:7.1f}  p95 '
              f'{1000 * v[min(len(v) - 1, int(0.95 * len(v)))]:7.1f}  máx {1000 * v[-1]:7.1f}  '
              f'rajada {max(fins) - primeiro:5.2f} s')


def main(meta_path):
    pasta = os.path.dirname(os.path.realpath(meta_path))
    base = os.path.basename(meta_path)[:-len('.meta')]
    meta = dict(l.strip().split('=', 1) for l in open(meta_path) if '=' in l)
    if base.startswith('dl'):
        dl(pasta, base)
    elif base.startswith('ausencia'):
        print(f'braço: {meta.get("braco") or "-"}')
        dl(pasta, base)
        marcas(pasta, base)
    else:
        frota(pasta, base, meta)
        if base.startswith('manutencao'):
            print()
            latencias(pasta, base)
        if not base.startswith('frota'):
            print()
            marcas(pasta, base)


if __name__ == '__main__':
    main(sys.argv[1])
