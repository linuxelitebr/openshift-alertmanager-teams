#!/usr/bin/env bash
# amctl.sh - operar a config do Alertmanager da plataforma com rede de seguranca.
#
# Existe porque editar o Secret alertmanager-main na mao, em varios clusters, com
# pressa, e' como se perde um fim de semana. Toda mutacao aqui faz backup antes,
# valida, mostra o que muda e pergunta em qual cluster vai aplicar.
#
#   ./amctl.sh status                      cluster alvo, versao, saude, config viva
#   ./amctl.sh backup                      salva a config viva em backups/
#   ./amctl.sh render <saida>              renderiza a config da Fase 1 para ESTE cluster
#   ./amctl.sh diff <arquivo>              o que muda da config viva pra este arquivo
#   ./amctl.sh validate <arquivo>          amtool check-config (exec de leitura no pod)
#   ./amctl.sh apply <arquivo>             backup + validate + diff + confirma + aplica + verifica
#   ./amctl.sh rollout <lista> [--apply]   Fase 1 em varios clusters, um por um
#   ./amctl.sh set-template <tmpl>         injeta o html: em todos os email_configs e aplica
#   ./amctl.sh unset-template              remove o html: (volta ao padrao de fabrica)
#   ./amctl.sh rollback [arquivo]          lista backups, ou restaura um
#   ./amctl.sh test [chave=valor ...]      dispara alerta sintetico
#
# A validacao usa o amtool DO cluster, que e' o binario que vai parsear a config. Sem pod
# alcancavel, cai pro amtool em container e avisa que a versao pode ser outra.
# O diff e' semantico: compara significado, nao linha, e nao imprime senha.
#
# -y em qualquer comando pula a confirmacao. Use quando ja souber o que esta fazendo.
set -euo pipefail

NS=openshift-monitoring
SECRET=alertmanager-main
KEY=alertmanager.yaml
AMIMG="${AMIMG:-quay.io/prometheus/alertmanager:v0.28.1}"
AQUI="$(cd "$(dirname "$0")" && pwd)"
RAIZ="$(dirname "$AQUI")"
BKP="$RAIZ/backups"
ASSUME_YES=0

for a in "$@"; do [ "$a" = "-y" ] && ASSUME_YES=1; done
args=(); for a in "$@"; do [ "$a" = "-y" ] || args+=("$a"); done
set -- "${args[@]:-}"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cya=$'\033[36m'; c_off=$'\033[0m'
die(){ echo "${c_red}ERRO:${c_off} $*" >&2; exit 1; }

alvo() {
  local srv ctx usr
  srv=$(oc whoami --show-server 2>/dev/null) || die "sem sessao oc. Faca login primeiro."
  ctx=$(oc config current-context 2>/dev/null || echo '?')
  usr=$(oc whoami 2>/dev/null || echo '?')
  echo "${c_cya}=====================================================${c_off}"
  echo "${c_cya} CLUSTER :${c_off} $srv"
  echo "${c_cya} CONTEXTO:${c_off} $ctx"
  echo "${c_cya} USUARIO :${c_off} $usr"
  echo "${c_cya}=====================================================${c_off}"
}

confirma() {
  [ "$ASSUME_YES" = "1" ] && return 0
  # Le do TERMINAL, nao do stdin: assim nenhum laco ou pipe consegue "responder" por voce.
  [ -r /dev/tty ] || die "sem terminal pra confirmar. Rode interativo, ou passe -y se tiver certeza."
  local r; read -r -p "${c_yel}$1 [digite SIM para seguir]:${c_off} " r < /dev/tty
  [ "$r" = "SIM" ] || die "cancelado."
}

config_viva() {
  oc -n "$NS" get secret "$SECRET" -o jsonpath="{.data.${KEY//./\\.}}" 2>/dev/null | base64 -d
}

# Valida com o amtool DO CLUSTER quando da', porque e' o binario que vai parsear a config de
# verdade. O amtool de upstream no podman pode ser outra versao (o cluster aqui roda 0.29.0 e a
# imagem default do script e' 0.28.1): config que passa num pode ser recusada no outro.
pod_am() {
  oc -n "$NS" get pods -l alertmanager=main -o name 2>/dev/null | head -1 | sed 's#^pod/##'
}

validar() {
  local f="$1" d b pod
  b="$(basename "$f")"
  pod=$(pod_am)
  if [ -n "$pod" ]; then
    echo "Validando ${b} com o amtool DO cluster (pod $pod)..."
    oc -n "$NS" exec -i "$pod" -c alertmanager -- amtool check-config /dev/stdin < "$f" \
      || die "config invalida segundo o proprio Alertmanager deste cluster. Nada foi aplicado."
  else
    d="$(cd "$(dirname "$f")" && pwd)"
    echo "${c_yel}Sem pod do Alertmanager alcancavel.${c_off} Validando ${b} com ${AMIMG} no podman."
    echo "${c_yel}  atencao: pode ser versao diferente da que roda no cluster.${c_off}"
    podman run --rm -v "$d":/w:ro --entrypoint amtool "$AMIMG" check-config "/w/$b" \
      || die "config invalida. Nada foi aplicado."
  fi
  echo "${c_grn}config valida.${c_off}"
}

fazer_backup() {
  mkdir -p "$BKP"
  local host ts out
  host=$(oc whoami --show-server | sed -E 's#https?://##; s#[:/].*##')
  ts=$(date +%Y%m%d-%H%M%S)
  out="$BKP/${host}-${ts}.yaml"
  config_viva > "$out" || die "nao consegui ler a config viva."
  [ -s "$out" ] || die "config viva veio vazia. Abortando."
  echo "${c_grn}backup:${c_off} $out"
  echo "$out"
}

aplicar() {
  local f="$1"
  validar "$f"
  local tmpd; tmpd=$(mktemp -d)
  config_viva > "$tmpd/viva.yaml" 2>/dev/null || true
  echo; echo "--- o que muda nesta config (viva -> novo) ---"
  python3 "$AQUI/diff-config.py" "$tmpd/viva.yaml" "$f" || true
  echo "----------------------------------------------"; echo
  alvo
  confirma "Aplicar esta config NESTE cluster?"
  fazer_backup >/dev/null
  oc -n "$NS" set data "secret/$SECRET" --from-file="${KEY}=${f}" >/dev/null
  echo "${c_grn}aplicado.${c_off} Aguardando o Alertmanager recarregar..."
  local i
  for i in $(seq 1 30); do
    sleep 2
    config_viva > "$tmpd/agora.yaml" 2>/dev/null || true
    if python3 "$AQUI/diff-config.py" "$tmpd/agora.yaml" "$f" --quiet >/dev/null 2>&1; then
      echo "${c_grn}Secret confirmado com o novo conteudo.${c_off}"; break
    fi
    [ "$i" = "30" ] && echo "${c_yel}aviso: o Secret ainda nao refletiu o novo conteudo.${c_off}"
  done
  echo
  rm -rf "$tmpd"
  echo "Confira a config EM EXECUCAO (nao so' o Secret):"
  echo "  oc -n $NS exec alertmanager-main-0 -- amtool config show --alertmanager.url http://localhost:9093"
}


# Variaveis que mudam POR CLUSTER. O smtp_hello e' o nome do cluster, e muito relay
# valida HELO: mandar o mesmo valor em todo lugar e' pedido de rejeicao silenciosa.
derivar_vars() {
  local srv host
  srv=$(oc whoami --show-server) || die "sem sessao oc."
  host=$(echo "$srv" | sed -E 's#https?://##; s#:[0-9]+$##')
  export CLUSTER_FQDN="${host#api.}"
}

# NAO damos source neste arquivo de proposito: senha de SMTP com ' ou $ derrubaria o shell.
# Quem le e' o render-config.py, literalmente. Aqui so' conferimos que o arquivo existe.
VALUES=""
carregar_values() {
  VALUES="$RAIZ/alertmanager/values.env"
  [ -f "$VALUES" ] || die "crie $VALUES a partir de values.example.env (ele e' gitignored)."
}

renderizar() {
  local out="$1"
  carregar_values; derivar_vars
  echo "  CLUSTER_FQDN=$CLUSTER_FQDN  (smtp_hello)"
  python3 "$AQUI/render-config.py" "$RAIZ/alertmanager/fase1.yaml.tmpl" "$out" --values "$VALUES"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  render)
    [ -n "${1:-}" ] || die "uso: amctl.sh render <saida.yaml>"
    alvo; renderizar "$1"; validar "$1"
    ;;
  rollout)
    lista="${1:-}"; [ -f "$lista" ] || die "uso: amctl.sh rollout <lista-de-contextos.txt> [--apply]"
    aplicar_de_verdade=0; for a in "$@"; do [ "$a" = "--apply" ] && aplicar_de_verdade=1; done
    [ "$aplicar_de_verdade" = "1" ] || echo "${c_yel}MODO SIMULACAO. Nada sera aplicado. Use --apply para valer.${c_off}"
    carregar_values
    # Le a lista TODA antes do laco. Se o laco lesse direto do arquivo, o stdin ficaria apontado
    # pra lista e o confirma() engoliria o nome do proximo cluster em vez da tua resposta.
    ctxs=()
    while IFS= read -r linha || [ -n "$linha" ]; do
      linha="${linha%$'\r'}"                      # tolera lista salva no Windows
      case "$linha" in ''|\#*) continue;; esac
      ctxs+=("$linha")
    done < "$lista"
    [ "${#ctxs[@]}" -gt 0 ] || die "a lista $lista nao tem nenhum contexto."
    echo "${#ctxs[@]} cluster(s) na lista."
    original=$(oc config current-context 2>/dev/null || true)
    trap '[ -n "$original" ] && oc config use-context "$original" >/dev/null 2>&1 || true' EXIT
    ok=0; falhou=0; resumo=""
    for ctx in "${ctxs[@]}"; do
      echo; echo "${c_cya}############ $ctx ############${c_off}"
      if ! oc config use-context "$ctx" >/dev/null 2>&1; then
        echo "${c_red}contexto inexistente no kubeconfig.${c_off}"
        falhou=$((falhou+1)); resumo="$resumo\n  FALHOU(contexto)  $ctx"; continue
      fi
      if ! oc whoami >/dev/null 2>&1; then
        echo "${c_red}sessao invalida ou expirada neste cluster. Faca oc login e rode de novo.${c_off}"
        falhou=$((falhou+1)); resumo="$resumo\n  FALHOU(sessao)    $ctx"; continue
      fi
      tmp=$(mktemp -d)
      if ! saida=$(renderizar "$tmp/cfg.yaml" 2>&1); then
        echo "${c_red}falha ao renderizar:${c_off}"; echo "$saida" | tail -6
        falhou=$((falhou+1)); resumo="$resumo\n  FALHOU(render)    $ctx"; rm -rf "$tmp"; continue
      fi
      if ! saida=$(validar "$tmp/cfg.yaml" 2>&1); then
        echo "${c_red}config invalida:${c_off}"; echo "$saida" | tail -8
        falhou=$((falhou+1)); resumo="$resumo\n  FALHOU(validacao) $ctx"; rm -rf "$tmp"; continue
      fi
      hello=$(sed -nE "s/^[[:space:]]*smtp_hello:[[:space:]]*'?([^']*)'?[[:space:]]*$/\1/p" "$tmp/cfg.yaml")
      echo "render e validacao OK   smtp_hello=${c_grn}${hello}${c_off} (derivado deste cluster)"
      echo "--- o que muda neste cluster ---"
      config_viva > "$tmp/viva.yaml" 2>/dev/null || true
      python3 "$AQUI/diff-config.py" "$tmp/viva.yaml" "$tmp/cfg.yaml" || true
      if [ "$aplicar_de_verdade" = "1" ]; then
        alvo; confirma "Aplicar neste cluster?"
        fazer_backup >/dev/null
        oc -n "$NS" set data "secret/$SECRET" --from-file="${KEY}=$tmp/cfg.yaml" >/dev/null
        echo "${c_grn}aplicado.${c_off}"; resumo="$resumo\n  APLICADO          $ctx"
      else
        resumo="$resumo\n  SIMULADO          $ctx"
      fi
      ok=$((ok+1)); rm -rf "$tmp"
    done
    echo; echo "${c_cya}===== RESUMO =====${c_off}"; printf '%b\n' "$resumo"
    echo "ok=$ok falhou=$falhou"
    [ "$falhou" -eq 0 ] || exit 1
    ;;
  status)
    alvo
    echo "--- pods ---"; oc -n "$NS" get pods -l alertmanager=main 2>/dev/null || true
    echo; echo "--- imagem/versao ---"
    pod=$(pod_am)
    [ -n "$pod" ] && oc -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[?(@.name=="alertmanager")].image}{"\n"}' 2>/dev/null || true
    # A versao importa: e' ela que decide que sintaxe de config passa.
    [ -n "$pod" ] && oc -n "$NS" exec "$pod" -c alertmanager -- amtool --version 2>/dev/null | head -1 || true
    echo "--- config viva ---"
    # Resumo via parser, nao via grep: a config do operador vem com quote em toda chave.
    config_viva | python3 "$AQUI/summary-config.py"
    ;;
  backup)   alvo; fazer_backup >/dev/null ;;
  diff)
    [ -n "${1:-}" ] || die "uso: amctl.sh diff <arquivo>"
    alvo
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    config_viva > "$tmp/viva.yaml" 2>/dev/null || true
    python3 "$AQUI/diff-config.py" "$tmp/viva.yaml" "$1"
    ;;
  validate) [ -n "${1:-}" ] || die "uso: amctl.sh validate <arquivo>"; validar "$1" ;;
  apply)    [ -n "${1:-}" ] || die "uso: amctl.sh apply <arquivo>"; aplicar "$1" ;;
  set-template)
    tmpl="${1:-$RAIZ/alertmanager/templates/teams-email.tmpl}"
    [ -f "$tmpl" ] || die "template nao encontrado: $tmpl"
    alvo
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    config_viva > "$tmp/atual.yaml"
    python3 "$AQUI/inject-template.py" set "$tmp/atual.yaml" "$tmpl" "$tmp/novo.yaml"
    aplicar "$tmp/novo.yaml"
    ;;
  unset-template)
    alvo
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    config_viva > "$tmp/atual.yaml"
    python3 "$AQUI/inject-template.py" unset "$tmp/atual.yaml" "$tmp/novo.yaml"
    aplicar "$tmp/novo.yaml"
    ;;
  rollback)
    if [ -z "${1:-}" ]; then
      echo "Backups disponiveis:"; ls -1t "$BKP"/*.yaml 2>/dev/null || echo "(nenhum)"
      echo; echo "uso: amctl.sh rollback <arquivo>"
    else
      [ -f "$1" ] || die "backup nao encontrado: $1"
      echo "${c_yel}Restaurando backup.${c_off}"; aplicar "$1"
    fi
    ;;
  test)
    alvo
    echo "${c_yel}ATENCAO: o alerta sintetico percorre o route real e CHEGA NO CANAL de verdade.${c_off}"
    confirma "Disparar alerta de teste neste cluster?"
    extra=(); for kv in "$@"; do extra+=("$kv"); done
    oc -n "$NS" exec alertmanager-main-0 -- amtool alert add \
      --alertmanager.url http://localhost:9093 \
      alertname="TesteTemplate" severity=critical namespace="$NS" \
      "${extra[@]}" \
      --annotation=summary="Alerta sintetico de validacao do Alertmanager" \
      --annotation=description="Pode ignorar. Validando entrega e template."
    echo "${c_grn}disparado.${c_off} group_wait manda em segundos. Olhe o canal."
    ;;
  *) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0" ;;
esac
