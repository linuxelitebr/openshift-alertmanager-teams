#!/usr/bin/env python3
"""Compara duas configs do Alertmanager por SIGNIFICADO, nao por linha.

  diff-config.py <viva.yaml> <nova.yaml>

Por que: a config que o operador grava no Secret vem re-serializada, com quote em toda chave
("global":) e indentacao propria. Um diff de linha contra um arquivo escrito a mao acusa 70
linhas mudadas quando o que mudou de fato foram 6 campos. Isso treina voce a dar SIM sem ler.
Aqui sai primeiro o resumo do que muda de verdade, e depois o diff das duas formas normalizadas.
"""
import copy, difflib, hashlib, sys

try:
    import yaml
except ImportError:
    sys.exit("ERRO: falta PyYAML. Instale: pip3 install pyyaml")

SEGREDO = ("pass", "secret", "token", "key", "credential")


def e_segredo(chave):
    return any(s in str(chave).lower() for s in SEGREDO)


def marca(valor):
    """Marcador estavel: nao revela o valor, mas muda se o valor mudar."""
    d = hashlib.sha256(str(valor).encode("utf-8")).hexdigest()[:8]
    return f"<oculto sha256:{d}>"


def esconde(chave, valor):
    return marca(valor) if e_segredo(chave) else valor


def censura(no):
    """Copia a arvore trocando todo valor de chave sensivel pelo marcador. O diff normalizado
    sai pro terminal e pra qualquer log do rollout; senha nao pode passar por ali."""
    if isinstance(no, dict):
        return {k: (marca(v) if e_segredo(k) and not isinstance(v, (dict, list))
                    else censura(v)) for k, v in no.items()}
    if isinstance(no, list):
        return [censura(v) for v in no]
    return no


def normaliza(doc):
    return yaml.safe_dump(doc, sort_keys=True, default_flow_style=False,
                          allow_unicode=True, width=10**6)


def por_nome(receivers):
    return {r.get("name", "?"): r for r in (receivers or []) if isinstance(r, dict)}


def conta(rcv, campo):
    return len(rcv.get(campo) or []) if isinstance(rcv, dict) else 0


def tem_html(rcv):
    return any(isinstance(e, dict) and e.get("html") for e in (rcv.get("email_configs") or []))


def resumo(a, b):
    linhas = []

    ga, gb = a.get("global") or {}, b.get("global") or {}
    add = [k for k in gb if k not in ga]
    rem = [k for k in ga if k not in gb]
    mud = [k for k in gb if k in ga and ga[k] != gb[k]]
    if add or rem or mud:
        linhas.append("global:")
        for k in sorted(add):
            linhas.append(f"    + {k}: {esconde(k, gb[k])}")
        for k in sorted(rem):
            linhas.append(f"    - {k}  (sai)")
        for k in sorted(mud):
            linhas.append(f"    ~ {k}: {esconde(k, ga[k])}  ->  {esconde(k, gb[k])}")
    else:
        linhas.append("global: sem mudanca")

    ra, rb = por_nome(a.get("receivers")), por_nome(b.get("receivers"))
    for nome in sorted(set(ra) | set(rb)):
        if nome not in ra:
            linhas.append(f"receiver {nome}: NOVO")
            continue
        if nome not in rb:
            linhas.append(f"receiver {nome}: REMOVIDO  <-- confira se e' intencional")
            continue
        ea, eb = conta(ra[nome], "email_configs"), conta(rb[nome], "email_configs")
        wa, wb = conta(ra[nome], "webhook_configs"), conta(rb[nome], "webhook_configs")
        partes = []
        if ea != eb:
            partes.append(f"email_configs {ea} -> {eb}")
        if wa != wb:
            partes.append(f"webhook_configs {wa} -> {wb}  <-- confira se e' intencional")
        if tem_html(ra[nome]) != tem_html(rb[nome]):
            partes.append(f"template html {'SAI' if tem_html(ra[nome]) else 'ENTRA'}")
        destinos = [e.get("to") for e in (rb[nome].get("email_configs") or [])
                    if isinstance(e, dict) and e.get("to")]
        if destinos:
            partes.append("to: " + ", ".join(destinos))
        if partes:
            linhas.append(f"receiver {nome}: " + "; ".join(partes))
        elif normaliza(ra[nome]) != normaliza(rb[nome]):
            linhas.append(f"receiver {nome}: mudou (veja o diff abaixo)")

    for secao in ("route", "inhibit_rules", "templates"):
        va, vb = a.get(secao), b.get(secao)
        if normaliza(va) != normaliza(vb):
            linhas.append(f"{secao}: MUDOU  <-- isto altera o roteamento/supressao, leia o diff")
        elif va is not None:
            linhas.append(f"{secao}: sem mudanca")
    return linhas


def main():
    arg = sys.argv[1:]
    quieto = "--quiet" in arg
    arg = [a for a in arg if a != "--quiet"]
    if len(arg) != 2:
        sys.exit("uso: diff-config.py <viva.yaml> <nova.yaml> [--quiet]")
    docs = []
    for caminho in arg[:2]:
        with open(caminho, encoding="utf-8") as fh:
            bruto = fh.read()
        if not bruto.strip():
            docs.append({})
            continue
        try:
            d = yaml.safe_load(bruto)
        except yaml.YAMLError as e:
            sys.exit(f"ERRO: {caminho} nao e' YAML valido.\n{e}")
        docs.append(d if isinstance(d, dict) else {})
    a, b = docs

    if quieto:
        # Para o laco de espera do apply: igual por SIGNIFICADO, nao por byte.
        sys.exit(0 if normaliza(a) == normaliza(b) else 1)

    if not a:
        print("  (nao havia config viva legivel: tudo e' novo)")

    print("  MUDANCAS SEMANTICAS")
    for l in resumo(a, b):
        print("   ", l)

    na = normaliza(censura(copy.deepcopy(a))).splitlines(True)
    nb = normaliza(censura(copy.deepcopy(b))).splitlines(True)
    d = list(difflib.unified_diff(na, nb, fromfile="viva (normalizada)",
                                  tofile="nova (normalizada)", n=2))
    print("\n  DIFF NORMALIZADO" + ("" if d else "  (nenhuma diferenca)"))
    for l in d:
        print("   " + l.rstrip("\n"))


if __name__ == "__main__":
    main()
