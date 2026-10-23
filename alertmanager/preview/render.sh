#!/usr/bin/env bash
# Renderiza o template com o motor REAL do Alertmanager (amtool), via podman.
# Nao precisa de cluster, de SMTP nem de caixa de email: gera HTML pra abrir no browser.
# Rode depois de editar templates/teams-email.tmpl.
set -euo pipefail
cd "$(dirname "$0")"
IMG=quay.io/prometheus/alertmanager:latest
for m in mock-*.json; do
  out="${m%.json}.html"
  podman run --rm -v "$PWD/..":/t --entrypoint amtool "$IMG" \
    template render \
    --template.glob='/t/templates/*.tmpl' \
    --template.text='{{ template "teams.html" . }}' \
    --template.type=html \
    --template.data="/t/preview/$m" > "$out"
  echo "$m -> $out  ($(wc -c < "$out") bytes)"
done
