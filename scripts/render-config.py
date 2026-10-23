#!/usr/bin/env python3
"""Renderiza o template de config do Alertmanager substituindo os ${PLACEHOLDER}.

  render-config.py <template> <saida> [--values <arquivo>]

Por que isto existe e nao e' um 'envsubst': senha de SMTP tem caractere especial. Se o shell
avaliar o values.env, uma senha com ' ou $ derruba o script; se o YAML receber ela crua, um #
ou um ': ' corrompe a config calado. Aqui o shell nunca toca no valor e o resultado e' conferido.

Regras:
  - So' substitui ${NOME_MAIUSCULO}. Um '$' solto (comentario, senha, regex) passa intacto.
  - Todo ${NOME} do template TEM que estar definido. Erra listando os que faltam, de uma vez.
    Isso tambem pega typo no template: ${SMTP_FRON} nao existe -> falha, nao vai config torta.
  - O valor e' escapado pro contexto de quote em que o placeholder esta' no template.
  - No fim confere que o YAML parseia E que cada valor substituido sobreviveu inteiro.
"""
import os, re, sys

try:
    import yaml
except ImportError:
    sys.exit("ERRO: falta PyYAML. Instale: pip3 install pyyaml")

PLACEHOLDER = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
NOME_VALIDO = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
SEGREDO = ("PASS", "SECRET", "TOKEN", "KEY")


def mascara(nome, valor):
    if any(s in nome for s in SEGREDO):
        return f"<{len(valor)} caracteres, oculto>"
    return valor


def ler_values(caminho):
    """Le KEY=VALUE LITERAL. Nada de shell: sem expansao, sem subshell, sem escape.
    Valor entre quotes vale exatamente o que esta' dentro (inclusive espaco no fim).
    Valor sem quotes e' aparado nas pontas."""
    vals = {}
    with open(caminho, encoding="utf-8") as fh:
        for n, linha in enumerate(fh, 1):
            bruta = linha.rstrip("\r\n")
            if not bruta.strip() or bruta.lstrip().startswith("#"):
                continue
            bruta = bruta.lstrip()
            if bruta.startswith("export "):
                bruta = bruta[len("export "):]
            if "=" not in bruta:
                sys.exit(f"ERRO: {caminho}:{n}: linha sem '=': {bruta!r}")
            chave, valor = bruta.split("=", 1)
            chave = chave.strip()
            if not NOME_VALIDO.match(chave):
                sys.exit(f"ERRO: {caminho}:{n}: nome de variavel invalido: {chave!r}")
            valor = valor.strip()
            if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in ("'", '"'):
                valor = valor[1:-1]
            vals[chave] = valor
    return vals


def escalares(no, saco):
    if isinstance(no, dict):
        for k, v in no.items():
            escalares(k, saco)
            escalares(v, saco)
    elif isinstance(no, list):
        for v in no:
            escalares(v, saco)
    elif isinstance(no, str):
        saco.append(no)


def main():
    arg = sys.argv[1:]
    values = None
    if "--values" in arg:
        i = arg.index("--values")
        if i + 1 >= len(arg):
            sys.exit("ERRO: --values exige um arquivo.")
        values = arg[i + 1]
        del arg[i:i + 2]
    if len(arg) != 2:
        sys.exit("uso: render-config.py <template> <saida> [--values <arquivo>]")
    tmpl, out = arg

    # O arquivo de values manda no que ele declara; o ambiente preenche o resto (CLUSTER_FQDN).
    ambiente = dict(os.environ)
    if values:
        ambiente.update(ler_values(values))

    with open(tmpl, encoding="utf-8") as fh:
        texto = fh.read()

    nomes = sorted(set(PLACEHOLDER.findall(texto)))
    faltando = [n for n in nomes if n not in ambiente]
    if faltando:
        sys.exit(
            "ERRO: variaveis nao definidas: " + ", ".join(faltando)
            + "\n  -> confira o alertmanager/values.env e o contexto do cluster (oc whoami)."
        )

    def troca(m):
        valor = ambiente[m.group(1)]
        antes = texto[m.start() - 1] if m.start() > 0 else ""
        depois = texto[m.end()] if m.end() < len(texto) else ""
        # Respeita o quoting do template: valor com caractere especial sobrevive ao YAML.
        if antes == depois == "'":
            return valor.replace("'", "''")
        if antes == depois == '"':
            return valor.replace("\\", "\\\\").replace('"', '\\"')
        return valor

    render = PLACEHOLDER.sub(troca, texto)

    try:
        doc = yaml.safe_load(render)
    except yaml.YAMLError as e:
        sys.exit(f"ERRO: o render nao e' YAML valido. Algum valor precisa de quote no template.\n{e}")
    if not isinstance(doc, dict):
        sys.exit("ERRO: o render nao virou um mapa YAML. Confira o template.")

    saco = []
    escalares(doc, saco)
    quebrados = [n for n in nomes if not any(ambiente[n] in s for s in saco)]
    if quebrados:
        sys.exit(
            "ERRO: estes valores nao sobreviveram ao parse do YAML: " + ", ".join(quebrados)
            + "\n  -> ponha o placeholder entre quotes simples no template."
        )

    with open(out, "w", encoding="utf-8") as fh:
        fh.write(render)
    print(f"  renderizado -> {out}")
    for n in nomes:
        print(f"    {n}={mascara(n, ambiente[n])}")


if __name__ == "__main__":
    main()
