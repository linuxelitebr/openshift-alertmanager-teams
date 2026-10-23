#!/usr/bin/env bash
# Gera o trecho de email_configs com o HTML embutido, a partir do .tmpl.
# Existe porque o caminho de arquivo .tmpl exige montagem no pod (nao documentada
# para template no OCP). O inline funciona sempre. Rode depois de editar o .tmpl.
set -euo pipefail
cd "$(dirname "$0")"
OUT=email-receiver-snippet.yaml
{
  echo "# GERADO por render-inline.sh a partir de templates/teams-email.tmpl. Nao edite na mao."
  echo "# Cole o bloco html: dentro de cada email_configs do alertmanager.yaml."
  echo "#"
  echo "# O subject NAO e' alterado de proposito: mexer nele mudaria o comportamento"
  echo "# padrao, e o combinado aqui e' so' aparencia."
  echo "email_configs:"
  echo "  - to: <TEAMS_CHANNEL_ADDRESS>"
  echo "    send_resolved: true"
  echo "    require_tls: true"
  echo "    html: |"
  sed -n '/{{ define "teams.html" -}}/,/{{- end }}/p' templates/teams-email.tmpl \
    | sed '1d;$d' \
    | sed 's/^/      /'
} > "$OUT"
echo "gerado: $OUT"
