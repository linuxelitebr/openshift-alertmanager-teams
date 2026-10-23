# Testar o template sem esperar alerta real

Esperar um alerta de verdade para ver se o HTML ficou bom e' perda de tempo.
Dispare um na mao, com os labels que o template usa.

## Alerta unico, com os labels do caso

```bash
oc -n openshift-monitoring exec alertmanager-main-0 -- amtool alert add \
  --alertmanager.url http://localhost:9093 \
  alertname="TesteTemplate" \
  severity=critical \
  namespace=openshift-monitoring \
  'cluster_banner="ACM - Lab"' \
  managed_cluster="11111111-1111-1111-1111-111111111111" \
  --annotation=summary="Alerta de teste para validar o template" \
  --annotation=description="Pode ignorar. Estou mexendo no template do email."
```

Repare: passar `cluster_banner` e `managed_cluster` na mao e' o que faz o teste valer.
O `cluster_banner` vai entre quotes **dentro** das quotes do shell. Valor com espaco sem
quote faz o Alertmanager cair no parser antigo de matchers e logar aviso, dizendo que o
formato vai deixar de funcionar. Hoje funciona, mas e' aviso de deprecacao. Valor sem
espaco (`openshift-monitoring`, `openshift-monitoring/k8s`) nao precisa disso.

Sem eles, voce testa um caminho que nao e' o de producao.

## Serie continua, para iterar no template

```bash
#!/bin/bash
while true; do
  NAME=$(shuf -n 1 /usr/share/dict/words)
  oc -n openshift-monitoring exec alertmanager-main-0 -- amtool alert add \
    --alertmanager.url http://localhost:9093 \
    alertname="$NAME" \
    severity=critical \
    'cluster_banner="ACM - Lab"' \
    --annotation=summary="alerta sintetico"
  sleep 60
done
```

Precisa do pacote `words` para o `shuf` ter de onde tirar nome:

```bash
yum -y install words
```

## Lembretes

- `group_wait` esta em 3s e `group_interval` em 6s, entao o alerta sai rapido. Bom para teste,
  agressivo para producao. Se mexer, lembre de voltar.
- `repeat_interval` de 12h quer dizer que o mesmo alerta nao volta antes disso. Para testar
  repeticao, use um alertname novo a cada rodada.
- Dependendo da versao do OpenShift, as aspas do `amtool` precisam de escape.
