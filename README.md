# Alertas do OpenShift no Microsoft Teams

Como fazer o Alertmanager do OpenShift entregar alerta em canal do Microsoft Teams, por dois
caminhos, e como colocar isso em producao em varios clusters sem passar o fim de semana nisso.

Tem config de referencia, o restyle do template de email padrao, um preview que renderiza com
o motor de verdade do Alertmanager (sem precisar receber email nenhum) e os scripts de
operacao: backup, validacao no proprio cluster, diff semantico, confirmacao por cluster e
rollback. O processo das tres fases esta em
[docs/processo-producao.md](docs/processo-producao.md).

## Como o alerta chega no Teams

Dois caminhos, escolhidos por severidade no `route`:

| Caminho | Receivers | Destino | Observacao |
| --- | --- | --- | --- |
| Email | `Default`, `Watchdog`, `Critical` | endereco do canal (`*.teams.ms`) | o Teams so' exibe o email, quem renderiza e' ele |
| Webhook | `webhook` (severity=warning) | app proprio via Microsoft Graph | existe porque o O365 Connector foi descontinuado |

O caminho de email e' o mais simples que existe: o canal do Teams tem um endereco de email,
voce manda o alerta para la', e o Teams faz o resto. Sem app, sem OAuth, sem token.

O caminho de webhook existe porque a Microsoft aposentou o conector antigo
(`https://outlook.office.com/webhook/...`). Quem precisa de card formatado hoje vai de
Graph API ou Power Automate. O app em `webhook/` faz Graph, com token OAuth persistido num PVC.

## O template: o que voce precisa saber antes de procurar

**Nao existe template customizado na config atual.** Nao ha `templates:`, nem `html:`, nem
`headers.subject:`. Esta rodando o `email.default.html` de fabrica.

O que faz o cluster aparecer no assunto sao **labels injetados no pipeline**:

```
cluster_banner  = ACM - Lab
managed_cluster = a1b2c3d4-...
```

O subject padrao do Alertmanager joga todos os CommonLabels fora do `group_by` dentro de um
parenteses. Como esses dois labels existem, eles aparecem sozinhos. Foi customizacao de label,
nao de template. Pergunta como eu sei: passei um tempo procurando o template que nao existia.

## O restyle: regra de escopo

O objetivo e' deixar o email do Alertmanager com a **mesma cara** do relatorio de DCs/GC que
roda em paralelo, para quem olha o canal nao ter que decodificar dois formatos.

A regra e' estreita de proposito: **so' a aparencia muda**. A estrutura do template de fabrica
fica intacta, campo por campo:

```
N alerts for <group labels>  ->  View in Alertmanager  ->  [N] Firing
  ->  Labels (todos)  ->  Annotations (todas)  ->  Source  ->  Sent by Alertmanager
```

Mesmos textos, mesmos links, mesma ordem. Nenhum campo novo, nenhum removido, e o **subject
nao e' tocado**, porque mexer nele seria mudar comportamento, nao aparencia.

O que muda sao os tokens visuais, herdados do relatorio de DC:

| Token | Valor | Onde |
| --- | --- | --- |
| Azul | `#2C5F8A` | barra de titulo e cabecalho de secao (era laranja `#e6522c`) |
| Vermelho | `#D64545` | titulo do bloco Firing |
| Verde | `#3F8F5F` | titulo do bloco Resolved |
| Texto | `#1a1a1a` / Segoe UI, Arial / 13px | corpo |
| Rodape | `#6b6b6b` / 11px | "Sent by Alertmanager" |

Detalhe que parece bobo e nao e': a tabela usa `border="1"` como **atributo HTML**, nao CSS.
O Teams descarta boa parte do CSS mas honra o atributo. E' o que garante borda visivel la'.

## Inline ou arquivo

Dois jeitos de aplicar, e o recomendado e' o primeiro:

- **Inline** (`html:` direto no `email_configs`): funciona sempre, nao exige montar nada.
  Use `alertmanager/email-receiver-snippet.yaml`, gerado por `render-inline.sh`.
- **Arquivo `.tmpl`** (`templates:` + arquivo montado): mais limpo de manter, mas a montagem
  no Alertmanager da plataforma nao e' documentada para template. Teste antes de depender.

O `.tmpl` em `alertmanager/templates/` e' a fonte de verdade nos dois casos. Editou ele?
Rode `./alertmanager/render-inline.sh` para regerar o snippet inline.

## Estrutura

```
alertmanager/
  alertmanager.yaml              config sanitizada (Secret alertmanager-main)
  fase1.yaml.tmpl                config da Fase 1 (sem template custom), com placeholders
  values.example.env             modelo do values.env (gitignored, nunca commitado)
  templates/teams-email.tmpl     restyle do template padrao (fonte de verdade)
  render-inline.sh               gera o snippet inline a partir do .tmpl
  email-receiver-snippet.yaml    email_configs pronto para colar (gerado)
  preview/                       mocks + render com o amtool de verdade
scripts/
  amctl.sh                       operar a config com backup, validacao e confirmacao
  render-config.py               preenche o fase1.yaml.tmpl por cluster e confere o YAML
  diff-config.py                 compara duas configs por significado, sem vazar senha
  summary-config.py              resume a config viva (parser, porque grep nao serve)
  inject-template.py             injeta/remove o html: preservando comentario e ordem
webhook/
  deployment.yaml                app Graph API
  service.yaml                   o que o Alertmanager chama
  secret.example.yaml            as chaves, sem os valores
docs/
  processo-producao.md           checklist das 3 fases, incluindo rollout em massa
  customizing-the-template.md    onde mexer, e as pegadinhas
  testing-alerts.md              disparar alerta sintetico para iterar
```

## Aplicar

Pelo script, que faz backup, valida com o amtool do proprio cluster, mostra o que muda e
pergunta em qual cluster vai aplicar:

```bash
./scripts/amctl.sh status                     # em que cluster estou, e o que ja' tem la'
./scripts/amctl.sh render novo.yaml           # config da Fase 1 pra ESTE cluster
./scripts/amctl.sh apply novo.yaml            # backup + validate + diff + confirma
./scripts/amctl.sh rollout clusters.txt       # varios clusters, simulacao por default
```

Varios clusters de uma vez estao em [docs/processo-producao.md](docs/processo-producao.md).
Resumo do porque nao e' copiar arquivo: o `smtp_hello` e' o nome do cluster, e relay que
valida HELO rejeita calado quando ele nao casa.

Na mao, se preferir:

```bash
# ver o que esta rodando
oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d > atual.yaml

# aplicar
oc -n openshift-monitoring set data secret/alertmanager-main \
  --from-file=alertmanager.yaml=novo.yaml
```

Guarde o `atual.yaml` antes de mexer. Config invalida nao e' gravada e o Alertmanager segue
com a ultima boa, o que e' otimo para nao derrubar o alerta e pessimo para perceber que voce
errou. Se aplicou e nada mudou, valide antes de culpar o template.

## O que nao entra neste repo

Senha de SMTP, client secret do Entra ID, o endereco real do canal e os IDs de tenant, team e
channel. Quem tem o endereco do canal posta no canal, entao trate como segredo. Valores reais
ficam em `alertmanager/values.env` (gitignored) ou direto no Secret do cluster.

Os UUID e nomes de cluster que aparecem nos mocks e nos exemplos sao inventados. Se algum
parecer real, e' coincidencia ou e' bug, e nesse caso abra uma issue.
