#!/usr/bin/env python3
"""
Injeta ou remove o bloco html: em TODOS os email_configs de um alertmanager.yaml.

Usa ruamel para preservar comentarios, ordem das chaves e formatacao do arquivo
original. O objetivo e' mexer so' no que precisa e devolver o resto intacto.

  inject-template.py set   <config.yaml> <template.tmpl> <saida.yaml>
  inject-template.py unset <config.yaml> <saida.yaml>
"""
import sys, re
from ruamel.yaml import YAML
from ruamel.yaml.scalarstring import LiteralScalarString


def corpo_do_template(caminho):
    """Extrai o corpo de {{ define "teams.html" }} ... {{- end }}."""
    txt = open(caminho, encoding="utf-8").read()
    m = re.search(r'\{\{ define "teams\.html" -?\}\}(.*?)\{\{-? end \}\}', txt, re.S)
    if not m:
        sys.exit("ERRO: nao achei o bloco 'teams.html' no template.")
    return m.group(1).strip("\n") + "\n"


def cada_email_config(cfg):
    for receiver in cfg.get("receivers", []) or []:
        for ec in receiver.get("email_configs", []) or []:
            yield receiver.get("name", "?"), ec


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    acao = sys.argv[1]
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 10**6          # nao quebrar linha longa
    # Recuo no estilo que o OpenShift emite: item de lista indentado sob a chave.
    # Sem isto o ruamel re-emite a lista colada na margem e o diff acusa o arquivo
    # inteiro como alterado, escondendo a mudanca real.
    yaml.indent(mapping=2, sequence=4, offset=2)

    if acao == "set":
        _, _, cfg_path, tmpl_path, out_path = sys.argv
        html = LiteralScalarString(corpo_do_template(tmpl_path))
        cfg = yaml.load(open(cfg_path, encoding="utf-8"))
        n = 0
        for nome, ec in cada_email_config(cfg):
            ec["html"] = html
            n += 1
            print(f"  html: injetado em receiver '{nome}'")
        if n == 0:
            sys.exit("ERRO: nenhum email_configs encontrado na config.")
        yaml.dump(cfg, open(out_path, "w", encoding="utf-8"))
        print(f"{n} email_configs atualizados -> {out_path}")

    elif acao == "unset":
        _, _, cfg_path, out_path = sys.argv
        cfg = yaml.load(open(cfg_path, encoding="utf-8"))
        n = 0
        for nome, ec in cada_email_config(cfg):
            if "html" in ec:
                del ec["html"]
                n += 1
                print(f"  html: removido do receiver '{nome}'")
        yaml.dump(cfg, open(out_path, "w", encoding="utf-8"))
        print(f"{n} email_configs voltaram ao template padrao -> {out_path}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
