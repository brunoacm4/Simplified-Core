#!/usr/bin/env python3
"""Define time.nf_instance.heartbeat em todas as NFs com SBI.

Existe para as experiencias de custo: permite variar o intervalo em bloco e de
forma reproduzivel, em vez de editar dez ficheiros a mao. Passar 'default'
remove a definicao e devolve o Open5GS ao valor por omissao (10 s).
"""
import re, sys, pathlib

NFS = ["nrf","scp","ausf","udm","udr","pcf","nssf","bsf","amf","smf"]
CFG = pathlib.Path(__file__).resolve().parent.parent / "lab/configs/open5gs"

val = sys.argv[1] if len(sys.argv) > 1 else "default"

for nf in NFS:
    p = CFG / f"{nf}.yaml"
    lines = p.read_text().splitlines()
    # remove qualquer definicao anterior, activa ou comentada
    out = [l for l in lines
           if not re.match(r"^\s*#?\s*nf_instance:\s*$", l)
           and not re.match(r"^\s*#?\s*heartbeat:\s*\d+\s*$", l)]
    if val != "default":
        block = ["    nf_instance:", f"      heartbeat: {val}"]
        try:                                    # ja existe uma seccao time:
            i = next(k for k, l in enumerate(out) if re.match(r"^  time:\s*$", l))
            out[i+1:i+1] = block
        except StopIteration:                   # nao existe: cria no fim
            while out and not out[-1].strip():
                out.pop()
            out += ["  time:"] + block
    # remove uma seccao 'time:' que tenha ficado vazia (acontece ao repor o
    # valor por omissao em NFs que nao tinham 'time:' de origem)
    cleaned = []
    for k, l in enumerate(out):
        if re.match(r"^  time:\s*$", l):
            nxt = next((x for x in out[k+1:] if x.strip()), "")
            if not re.match(r"^    \S", nxt):
                continue
        cleaned.append(l)
    p.write_text("\n".join(cleaned) + "\n")

print(f"heartbeat = {val} em {len(NFS)} funcoes de rede")
