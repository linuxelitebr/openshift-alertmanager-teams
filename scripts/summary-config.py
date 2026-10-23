#!/usr/bin/env python3
"""Resume uma config do Alertmanager lida na entrada padrao.

  config_viva | summary-config.py

Existe porque grep nao serve aqui: a config que o operador grava vem com quote em toda
chave ("receivers":, - "name": "Default"), entao um grep por '- name:' acha nada e voce
conclui que o cluster nao tem receiver nenhum.
"""
import sys

try:
    import yaml
except ImportError:
    sys.exit("ERRO: falta PyYAML. Instale: pip3 install pyyaml")

bruto = sys.stdin.read()
if not bruto.strip():
    print("  (config viva vazia ou ilegivel)")
    sys.exit(0)
try:
    d = yaml.safe_load(bruto) or {}
except yaml.YAMLError as e:
    print(f"  (config viva nao parseia: {e})")
    sys.exit(0)

g = d.get("global") or {}
smtp = sorted(k for k in g if k.startswith("smtp_"))
print("  global: " + (", ".join(smtp) if smtp else "sem nada de smtp"))

print("  receivers:")
for r in d.get("receivers") or []:
    if not isinstance(r, dict):
        continue
    emails = r.get("email_configs") or []
    hooks = r.get("webhook_configs") or []
    html = sum(1 for e in emails if isinstance(e, dict) and e.get("html"))
    destinos = [e.get("to") for e in emails if isinstance(e, dict) and e.get("to")]
    partes = []
    if emails:
        partes.append(f"{len(emails)} email_configs" + (f" -> {', '.join(destinos)}" if destinos else ""))
    if hooks:
        partes.append(f"{len(hooks)} webhook_configs")
    if not partes:
        partes.append("nenhum destino")
    if html:
        partes.append(f"template html em {html}")
    print(f"    {r.get('name','?')}: " + "; ".join(partes))

rt = d.get("route") or {}
print(f"  route: receiver={rt.get('receiver','?')} group_by={rt.get('group_by')} "
      f"group_wait={rt.get('group_wait')} repeat_interval={rt.get('repeat_interval')} "
      f"subrotas={len(rt.get('routes') or [])}")
print(f"  inhibit_rules: {len(d.get('inhibit_rules') or [])}   templates: {d.get('templates') or 'nenhum'}")
