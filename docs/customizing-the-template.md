# Onde customizar o template do email

## Primeiro, o que NAO existe hoje

A config que esta rodando **nao tem template custom**. Nao ha `templates:` e nenhum
`email_configs` define `html`, `text` ou `headers.subject`. O que chega no Teams e' o
`email.default.html` de fabrica do Alertmanager.

O que faz o cluster aparecer no assunto nao e' template, sao **labels**:

```
cluster_banner  = ACM - Lab
managed_cluster = a1b2c3d4-...
```

O subject padrao do Alertmanager e':

```
[{{ .Status | toUpper }}{{ if eq .Status "firing" }}:{{ .Alerts.Firing | len }}{{ end }}] {{ .GroupLabels.SortedPairs.Values | join " " }} ({{ .CommonLabels.Remove .GroupLabels.Names }})
```

Ou seja, ele despeja **todos os CommonLabels que nao estao no group_by** dentro do parenteses.
Como alguem injetou `cluster_banner` e `managed_cluster` no pipeline, o template de fabrica
os mostra sozinho. Por isso o assunto fica comprido e meio baguncado.

Conclusao: se voce sair procurando "o template customizado", nao vai achar. Ele nunca existiu.

## Caminho 1: inline (recomendado, funciona hoje)

Nao depende de montar arquivo nenhum. Dentro de cada `email_configs`:

```yaml
    email_configs:
      - to: <TEAMS_CHANNEL_ADDRESS>
        headers:
          subject: '{{ template "teams.subject" . }}'
        html: '{{ template "teams.html" . }}'
```

Se preferir nem usar arquivo `.tmpl`, da' para escrever o HTML direto no `html:`. Fica feio
de manter, mas funciona e nao exige nada do operador.

### Pegadinha de sintaxe que ja' nos mordeu

O formato de `headers` muda conforme ONDE voce escreve:

| Onde | Formato de `headers` |
| --- | --- |
| `alertmanager.yaml` cru (Secret `alertmanager-main`) | **mapa**: `subject: '...'` |
| CRD `AlertmanagerConfig` (v1beta1) | **array**: `- key: subject` / `  value: '...'` |

No CRD, mapa e' rejeitado com `headers in body must be of type array: "object"`.
Aqui estamos no YAML cru, entao e' mapa.

## Caminho 2: arquivo .tmpl (plausivel, precisa testar)

Alertmanager suporta carregar arquivos:

```yaml
templates:
  - /etc/alertmanager/secrets/alertmanager-templates/*.tmpl
```

O problema e' colocar o arquivo dentro do pod. No OpenShift o mecanismo documentado de montagem
e' via `cluster-monitoring-config`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    alertmanagerMain:
      secrets:
        - alertmanager-templates
```

O Secret vai montado em `/etc/alertmanager/secrets/alertmanager-templates`.

**Ressalva honesta:** a documentacao da Red Hat descreve esse mecanismo para **credencial de
receiver**, nao para template. Nao encontrei doc oficial cobrindo `templates:` com arquivo no
Alertmanager da plataforma. O caminho e' plausivel e segue a mecanica do operador, mas
**teste antes de depender dele**. Se falhar, o Caminho 1 resolve o mesmo problema.

## Limite do Teams

O Teams renderiza o email, ele nao e' um cliente de email completo. Na pratica:

- tabela com `style` inline: funciona
- CSS moderno (flex, grid, media query, classes): descartado
- imagem externa: frequentemente bloqueada

Por isso o template em `alertmanager/templates/teams-email.tmpl` e' tabela com style inline.
Nao e' falta de capricho, e' o que sobrevive.

## Validar antes de aplicar

```bash
oc -n openshift-monitoring exec alertmanager-main-0 -- amtool check-config /etc/alertmanager/config_out/alertmanager.env.yaml
```

Config invalida nao e' gravada, o Alertmanager mantem a ultima boa. Isso salva, mas tambem
esconde o erro: se voce aplicar e "nada mudou", desconfie da validacao antes de desconfiar do template.
