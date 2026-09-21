#!/usr/bin/env python3
"""Compara as métricas de duas pastas de corridas (baseline vs variante).

Uso: ./scripts/comparar.py <pasta-baseline> <pasta-variante> [--md ficheiro.md]

Para cada métrica mostra a mediana de cada lado, [mín–máx], a diferença e a variação em %.
"""
import glob, json, statistics, sys

METRICAS = [
    # (secção, rótulo, função que extrai o valor de um metricas.json)
    ('Sinalização — registo', 'Mensagens NGAP (N2)', lambda m: m['registo']['ngap']),
    ('Sinalização — registo', 'Pedidos SBI', lambda m: m['registo']['sbi_pedidos']),
    ('Sinalização — registo', 'Mensagens HTTP (pedidos + respostas, todas as pernas)', lambda m: m['registo']['http_mensagens']),
    ('Sinalização — sessão PDU', 'Mensagens NGAP (N2)', lambda m: m['sessao']['ngap']),
    ('Sinalização — sessão PDU', 'Pedidos SBI', lambda m: m['sessao']['sbi_pedidos']),
    ('Sinalização — sessão PDU', 'Mensagens HTTP (pedidos + respostas, todas as pernas)', lambda m: m['sessao']['http_mensagens']),
    ('Arranque do core', 'Pedidos de gestão na NRF (todas as pernas)', lambda m: m['arranque']['gestao_nrf_pedidos']),
    ('Latência (lado do core)', 'Registo: InitialUEMessage → Registration Accept (ms)', lambda m: m['latencia_ms']['registo_core']),
    ('Latência (lado do core)', 'Sessão PDU: pedido → PDUSessionResourceSetup (ms)', lambda m: m['latencia_ms']['sessao_core']),
    ('Tráfego', 'Bytes SBI em repouso (10 s, só heartbeats)', lambda m: m['bytes_fundo'].get('SBI', 0)),
    ('Tráfego', 'Bytes SBI com UE (10 s: registo + sessão)', lambda m: m['bytes_ue'].get('SBI', 0)),
    ('Tráfego', 'Bytes N2 com UE (10 s)', lambda m: m['bytes_ue'].get('N2', 0)),
    ('Recursos do core', 'Nº de serviços do core (contentores)', lambda m: m['recursos_core_total']['n_servicos']),
    ('Recursos do core', 'CPU em repouso (ms em 10 s)', lambda m: m['recursos_core_total']['cpu_ms_fundo']),
    ('Recursos do core', 'CPU com UE (ms em 10 s)', lambda m: m['recursos_core_total']['cpu_ms_com_ue']),
    ('Recursos do core', 'CPU atribuível ao UE (com UE − repouso, ms)', lambda m: m['recursos_core_total']['cpu_ms_liquido']),
    ('Recursos do core', 'Memória total (MiB)', lambda m: m['recursos_core_total']['mem_mib_C']),
]


# Com vários UEs as fases registo/sessão sobrepõem-se no tempo: usam-se os totais da janela com UE
# e as latências por UE.
METRICAS_CARGA = [
    ('Resultado', 'UEs registados', lambda m: m['ue']['n_ues_registados']),
    ('Resultado', 'UEs com sessão PDU', lambda m: m['ue']['n_ues_com_sessao']),
    ('Sinalização (todos os UEs)', 'Mensagens NGAP (N2)', lambda m: m['ue']['ngap']),
    ('Sinalização (todos os UEs)', 'Pedidos SBI', lambda m: m['ue']['sbi_pedidos']),
    ('Sinalização (todos os UEs)', 'Mensagens HTTP (pedidos + respostas, todas as pernas)', lambda m: m['ue']['http_mensagens']),
    ('Latência por UE (lado do core)', 'Registo — mediana (ms)', lambda m: m['ue']['lat_registo_core_ms']['mediana']),
    ('Latência por UE (lado do core)', 'Registo — p95 (ms)', lambda m: m['ue']['lat_registo_core_ms']['p95']),
    ('Latência por UE (lado do core)', 'Registo — máximo (ms)', lambda m: m['ue']['lat_registo_core_ms']['max']),
    ('Latência por UE (inclui UE simulado)', 'Registo + sessão — mediana (ms)', lambda m: m['ue']['lat_registo_mais_sessao_ms']['mediana']),
    ('Latência por UE (inclui UE simulado)', 'Todos os UEs com sessão (ms)', lambda m: m['ue']['tempo_todos_ms']),
    ('Tráfego', 'Bytes SBI com UE (janela)', lambda m: m['bytes_ue'].get('SBI', 0)),
    ('Recursos do core', 'Nº de serviços do core (contentores)', lambda m: m['recursos_core_total']['n_servicos']),
    ('Recursos do core', 'CPU atribuível aos UEs (com UE − repouso, ms)', lambda m: m['recursos_core_total']['cpu_ms_liquido']),
    ('Recursos do core', 'CPU por UE (ms)', lambda m: m['recursos_core_total'].get('cpu_ms_liquido_por_ue')),
    ('Recursos do core', 'Memória total (MiB)', lambda m: m['recursos_core_total']['mem_mib_C']),
]


def carregar(pasta):
    ms = [json.load(open(f)) for f in sorted(glob.glob(f'{pasta}/*.metricas.json'))]
    if not ms:
        sys.exit(f'Sem métricas em {pasta}')
    return ms


def fmt(x):
    return f'{x:.0f}' if abs(x) >= 100 or float(x).is_integer() else f'{x:.2f}'


def main():
    a, b = carregar(sys.argv[1]), carregar(sys.argv[2])
    na, nb = a[0]['variante'], b[0]['variante']
    n_ues = int(a[0].get('meta', {}).get('n_ues', 1))
    lista = METRICAS_CARGA if n_ues > 1 else METRICAS
    linhas = [f'Comparação: **{na}** ({len(a)} corridas) vs **{nb}** ({len(b)} corridas), '
              f'{n_ues} UE(s) por corrida. Valores: mediana [mín–máx].', '']
    secao = None
    for sec, rot, f in lista:
        if sec != secao:
            linhas += ['', f'**{sec}**', '', f'| Métrica | {na} | {nb} | Diferença | Variação |', '|---|---|---|---|---|']
            secao = sec
        va = [f(m) for m in a if f(m) is not None]
        vb = [f(m) for m in b if f(m) is not None]
        ma, mb = statistics.median(va), statistics.median(vb)
        pct = f'{(mb - ma) / ma * 100:+.0f}%' if ma else '—'
        linhas.append(f'| {rot} | {fmt(ma)} [{fmt(min(va))}–{fmt(max(va))}] | '
                      f'{fmt(mb)} [{fmt(min(vb))}–{fmt(max(vb))}] | {fmt(mb - ma)} | {pct} |')
    txt = '\n'.join(linhas)
    print(txt)
    if '--md' in sys.argv:
        open(sys.argv[sys.argv.index('--md') + 1], 'w').write(txt + '\n')


if __name__ == '__main__':
    main()
