#!/usr/bin/env python3
"""Análise da experiência do T3512 dinâmico: população mista (POPULACAO) e vítimas (VITIMAS).

Complementa o analisar-fabrica.py, que dá os totais da janela (NGAP, SBI, PFCP, CPU), com o que só
os logs dão dispositivo a dispositivo:

  - por classe (período de transmissão): registos periódicos e Service Requests por dispositivo e
    por hora na janela de medição, e o T3512 com que os dispositivos acabaram a janela;
  - por vítima: estado e T3512 no momento em que foi desligada, e quanto tempo o AMF levou, desde
    então, a deixar de a procurar ("Mobile Reachable Timer Expired") e a dá-la como desregistada
    ("Implicit De-registered").

As vítimas contam nas classes: estiveram vivas durante toda a janela.

Uso: ./scripts/analisar-t3512.py <pasta>/<nome>.meta   (escreve <nome>.t3512.json ao lado)
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

ANSI = re.compile(r'\x1b\[[0-9;]*m')
# [2026-09-28 16:12:27.801] [999700000000017|nas] [debug] Sending Periodic Registration ...
UE = re.compile(r'^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\] \[(\d+)\|\w+\] \[\w+\] (.*)$')
# 09/28 16:12:27.801: [gmm] INFO: [imsi-999700000000002] Dynamic T3512 [60 -> 120 sec] (../src/...)
AMF = re.compile(r'^(\d\d/\d\d \d\d:\d\d:\d\d\.\d+): \[\w+\] \w+: \[imsi-(\d+)\] (.*?) \(\.\./src')
AJUSTE = re.compile(r'Dynamic T3512 \[(\d+) -> (\d+) sec\]')


def instante(texto, formato):
    # Os contentores registam em UTC
    return datetime.strptime(texto, formato).replace(tzinfo=timezone.utc).timestamp()


def ler_ue(caminho):
    """[(t, imsi, mensagem)] do log de um contentor de UEs."""
    eventos = []
    if not os.path.exists(caminho):
        return eventos
    for linha in open(caminho, errors='replace'):
        m = UE.match(ANSI.sub('', linha.strip()))
        if m:
            eventos.append((instante(m[1], '%Y-%m-%d %H:%M:%S.%f'), m[2], m[3]))
    return eventos


def ler_amf(caminho, ano):
    """[(t, imsi, mensagem)] das linhas do AMF que identificam um UE."""
    eventos = []
    for linha in open(caminho, errors='replace'):
        m = AMF.match(ANSI.sub('', linha.strip()))
        if m:
            eventos.append((instante(f'{ano}/{m[1]}', '%Y/%m/%d %H:%M:%S.%f'), m[2], m[3]))
    return eventos


def periodos(eventos, especificacao):
    """{imsi: período}: a especificação "30:10 900:10" aplicada por ordem de IMSI, como faz o
    mapa_periodos do cenario-fabrica.sh."""
    lista = []
    for grupo in especificacao.split():
        p, n = grupo.split(':')
        lista += [int(p)] * int(n)
    imsis = sorted({imsi for _, imsi, msg in eventos if 'TUN interface[' in msg}, key=int)
    return dict(zip(imsis, lista))


def main(meta_path):
    meta_path = os.path.realpath(meta_path)
    pasta, base = os.path.dirname(meta_path), os.path.basename(meta_path)[:-len('.meta')]
    meta = dict(l.strip().split('=', 1) for l in open(meta_path) if '=' in l)
    logs = f'{pasta}/{base}-logs'
    t0, t1 = float(meta['t_inicio']), float(meta['t_fim'])
    # A mesma janela de tráfego do analisar-fabrica.py
    janela_s = min(t1 - t0, int(meta['duracao']) + int(meta.get('temporizador') or 0))
    ano = meta['data'][:4]

    ue = ler_ue(f'{logs}/ue.log')
    vitimas = ler_ue(f'{logs}/vitimas.log')
    amf = ler_amf(f'{logs}/amf.log', ano)

    periodo = {}
    if meta.get('populacao'):
        periodo.update(periodos(ue, meta['populacao']))
    else:
        periodo.update({i: int(meta['periodo']) for _, i, m in ue if 'TUN interface[' in m})
    periodo_vitima = periodos(vitimas, meta['vitimas']) if meta.get('vitimas') else {}
    periodo.update(periodo_vitima)

    # Contagens na janela, por dispositivo
    periodicos, service_requests = Counter(), Counter()
    for t, imsi, msg in ue + vitimas:
        if t0 <= t < t1:
            if msg.startswith('Sending Periodic Registration'):
                periodicos[imsi] += 1
            elif msg.startswith('Sending Service Request'):
                service_requests[imsi] += 1

    # T3512 de cada dispositivo ao longo da corrida (só existe no log com o modo dinâmico)
    ajustes = defaultdict(list)
    for t, imsi, msg in amf:
        m = AJUSTE.search(msg)
        if m:
            ajustes[imsi].append((t, int(m[2])))

    def t3512_em(imsi, t):
        valores = [v for ta, v in ajustes[imsi] if ta <= t]
        return valores[-1] if valores else None

    classes = {}
    for p in sorted(set(periodo.values())):
        membros = [i for i, pi in periodo.items() if pi == p]
        n = len(membros)
        por_disp_hora = 3600.0 / (janela_s * n)
        classes[p] = {
            'n_dispositivos': n,
            'registos_periodicos_por_disp_hora': round(sum(periodicos[i] for i in membros) * por_disp_hora, 2),
            'service_requests_por_disp_hora': round(sum(service_requests[i] for i in membros) * por_disp_hora, 2),
            'ajustes_na_aprendizagem': sum(1 for i in membros for t, _ in ajustes[i] if t < t0),
            'ajustes_na_janela': sum(1 for i in membros for t, _ in ajustes[i] if t0 <= t < t1),
            # T3512 no fim da janela -> número de dispositivos ('inicial' = nunca ajustado)
            't3512_no_fim': dict(Counter(str(t3512_em(i, t1) or 'inicial') for i in membros)),
        }

    resultado_vitimas = {}
    t_morte = float(meta['t_morte']) if meta.get('t_morte') else None
    if t_morte:
        for imsi, p in sorted(periodo_vitima.items()):
            estados = [(t, msg) for t, i, msg in vitimas
                       if i == imsi and t <= t_morte and msg.startswith('UE switches to state [CM-')]
            ultimo_idle = max((t for t, msg in estados if 'CM-IDLE' in msg), default=None)

            def primeiro(texto):
                return min((t for t, i, msg in amf if i == imsi and t >= t_morte and msg == texto),
                           default=None)
            alcancavel = primeiro('Mobile Reachable Timer Expired')
            desregistado = primeiro('Implicit De-registered')
            resultado_vitimas[imsi] = {
                'periodo_s': p,
                't3512_na_morte': t3512_em(imsi, t_morte),
                'estado_na_morte': estados[-1][1].split('[')[1].rstrip(']') if estados else None,
                'adormeceu_antes_da_morte_s': round(t_morte - ultimo_idle, 1) if ultimo_idle else None,
                'deixa_de_procurar_min': round((alcancavel - t_morte) / 60, 1) if alcancavel else None,
                'desregistada_min': round((desregistado - t_morte) / 60, 1) if desregistado else None,
            }

    R = {'meta': meta, 'janela_trafego_s': round(janela_s, 1), 'classes': classes,
         'vitimas': resultado_vitimas}
    json.dump(R, open(f'{pasta}/{base}.t3512.json', 'w'), indent=1, ensure_ascii=False)

    print(f"=== {base} ({meta['variante']}) ===")
    print(f"janela {janela_s:.0f} s, aprendizagem {meta.get('aprendizagem') or 0} s")
    print('período  disp  reg.periód./h  serv.req./h  ajustes(apr/jan)  T3512 no fim')
    for p, c in classes.items():
        print(f"{p:>6} s {c['n_dispositivos']:>5} {c['registos_periodicos_por_disp_hora']:>14} "
              f"{c['service_requests_por_disp_hora']:>12} "
              f"{c['ajustes_na_aprendizagem']:>9}/{c['ajustes_na_janela']:<7} {c['t3512_no_fim']}")
    if resultado_vitimas:
        print('vítima            período  T3512  estado      adormecida  deixa de procurar  desregistada')
        for imsi, v in resultado_vitimas.items():
            print(f"imsi-{imsi} {v['periodo_s']:>5} s {str(v['t3512_na_morte'] or 'inicial'):>7}  "
                  f"{str(v['estado_na_morte']):<10} {str(v['adormeceu_antes_da_morte_s']):>8} s "
                  f"{str(v['deixa_de_procurar_min']):>12} min {str(v['desregistada_min']):>9} min")


if __name__ == '__main__':
    main(sys.argv[1])
