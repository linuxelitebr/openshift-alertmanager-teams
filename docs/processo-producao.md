# Processo: colocar o despacho pro Teams em producao

Checklist pra executar com pouco tempo. A ideia e' separar **provar que entrega**
de **deixar bonito**, porque misturar as duas coisas e' o jeito classico de nao
saber o que quebrou.

- **Fase 1 (producao):** config de fabrica, sem template. So' prova que o email sai e chega no canal.
- **Fase 2 (lab, em paralelo):** valida o template custom sem risco.
- **Fase 3:** promove o template pra producao, ja' validado.

Todo comando de mutacao passa pelo `scripts/amctl.sh`, que faz backup, valida a
config, mostra o que muda e **pergunta em qual cluster vai aplicar**. Com varios
contextos no kubeconfig, essa pergunta e' a diferenca entre um dia normal e um dia ruim.

---

## Antes de comecar

**1. Pegue o email do canal no Teams.** No canal, menu `...` -> `Obter endereco de email`.
Vai sair algo como `1234abcd.dominio.com@br.teams.ms`. Quem tem esse endereco posta no
canal, entao trate como segredo.

**2. Tenha os dados de SMTP:** host, porta, usuario, senha, remetente e se exige TLS.

**3. Preencha o `values.env`, uma vez.** Ele e' gitignored e nunca vai pro repo.

```bash
cp alertmanager/values.example.env alertmanager/values.env
$EDITOR alertmanager/values.env
```

Senha com `'`, `#`, `$` ou `:` funciona. Esse arquivo nao passa pelo shell e o valor e'
escapado pro YAML antes de entrar na config. Se precisar preservar espaco no fim, ponha
o valor entre quotes simples.

O `smtp_hello` **nao** vai no `values.env`: o script deriva do cluster em que voce esta'
logado. E' justamente o campo que nao pode ser igual em dois clusters.

**4. Confirme em qual cluster voce esta.** Sempre.

```bash
./scripts/amctl.sh status
```

Mostra cluster, contexto, usuario, versao do Alertmanager, os receivers da config
viva, e se ja' existe `html:` custom.

---

## Fase 1: producao, sem customizacao

O objetivo aqui e' um so': **o alerta sai do cluster e aparece no canal.** Nada de template.

```bash
# 1. backup. Sempre primeiro.
./scripts/amctl.sh backup

# 2. renderize a config DESTE cluster e valide
./scripts/amctl.sh render nova.yaml

# 3. aplique (valida, mostra o que muda, confirma o cluster, faz backup)
./scripts/amctl.sh apply nova.yaml

# 4. dispare um alerta sintetico
./scripts/amctl.sh test
```

O `render` deriva o `smtp_hello` do servidor da sua sessao: `api.beta.exemplo.com:6443`
vira `beta.exemplo.com`. Se faltar variavel, ele lista todas as que faltam de uma vez e
nao escreve arquivo nenhum.

A validacao roda `amtool check-config` **dentro do pod do Alertmanager deste cluster**,
pelo binario que vai parsear a config de verdade. Nao havendo pod alcancavel, cai pro
amtool em container e avisa que a versao pode ser outra. Isso importa: o cluster de
teste aqui roda 0.29.0 e a imagem default do script e' a 0.28.1.

O diff antes do `SIM` e' **semantico**, nao de linha. A config que o operador gravou vem
re-serializada, com quote em toda chave (`"global":`), entao um diff de linha contra um
arquivo escrito a mao acusa 70 linhas mudadas quando o que mudou foram 6 campos. Esse
diff some com o ruido e termina em `route: sem mudanca` / `inhibit_rules: sem mudanca`,
que e' a parte que voce precisa confirmar antes de mexer em producao. Senha aparece como
`<oculto sha256:...>`: muda se o valor mudar, sem imprimir o valor no seu terminal.

**5. Olhe o canal.** Se chegou, a Fase 1 acabou. Vai chegar com a cara de fabrica
(cabecalho laranja), e esta certo: e' isso que voce queria provar agora.

Se nao chegou, o problema esta no caminho do email, nao no template. Ordem de
investigacao: log do Alertmanager, relay de SMTP, e se o endereco do canal esta certo.

```bash
oc -n openshift-monitoring logs alertmanager-main-0 -c alertmanager --tail=100 | grep -i -e smtp -e email -e error
```

**6. Dez minutos depois, confira que ficou.** O Secret `alertmanager-main` tem o label
`app.kubernetes.io/managed-by: cluster-monitoring-operator`. Nos clusters em que isso foi
testado o operador nao reescreveu a config depois do apply, e nao ha' `ownerReferences`
no Secret. Mas isso e' do tipo de coisa que se confirma em vez de supor:

```bash
./scripts/amctl.sh status
```

Se os `email_configs` sumiram, o operador reverteu e o caminho e' outro: `AlertmanagerConfig`
CR ou a tela do console. Nesse caso para aqui e me chama antes de repetir em 20 clusters.

---

## Fase 1 em massa: varios clusters

O que **nao** fazer: copiar o mesmo `alertmanager.yaml` pra todo mundo. Tem campo que e'
por cluster:

| Campo | Por que muda |
| --- | --- |
| `smtp_hello` | e' o nome do cluster. Muito relay valida HELO e rejeita **calado** quando nao casa. |
| `smtp_from` | costuma derivar do cluster, dependendo da politica do relay. |
| url de webhook | so' existe onde a aplicacao foi implantada. |

Esse e' o motivo do `rollout` **renderizar por cluster** em vez de copiar arquivo.

**1. Monte a lista de contextos**, um por linha. Linha vazia e comentario com `#` passam
batido, e lista salva no Windows (CRLF) funciona.

```bash
oc config get-contexts -o name > clusters.txt
$EDITOR clusters.txt
```

**2. Rode em simulacao.** E' o default: nada e' aplicado.

```bash
./scripts/amctl.sh rollout clusters.txt
```

Por cluster ele troca de contexto, confere a sessao, deriva o `smtp_hello`, renderiza,
valida com o amtool **daquele** cluster e mostra o que mudaria. No fim sai um resumo com
`ok=` e `falhou=`. Leia o resumo antes de seguir: `FALHOU(sessao)` e' token expirado, e
aquele cluster vai ficar de fora.

**3. Agora pra valer.** Pede `SIM` por cluster, faz backup de cada um antes de escrever, e
volta pro seu contexto original no fim (inclusive se voce der Ctrl+C no meio).

```bash
./scripts/amctl.sh rollout clusters.txt --apply
```

**4. Dispare o teste** onde quiser conferir de fato. Nao precisa ser em todos; o alerta
sintetico percorre o route real e **chega no canal**.

```bash
oc config use-context <contexto>
./scripts/amctl.sh test
```

Detalhes do rollout que importam na hora:

- a confirmacao le do **terminal**, nao do stdin. A lista nao consegue responder por voce.
- um cluster que falha nao para os outros. O resumo final diz quem ficou pra tras.
- cluster com sessao invalida nao e' aplicado. Faca `oc login` e rode de novo: quem ja'
  tinha sido aplicado aparece sem mudanca no diff, porque a comparacao e' semantica.
- `-y` existe e pula as confirmacoes. Em producao, com uma lista de clusters, pense duas
  vezes: e' o unico ponto do processo que te obriga a olhar o diff.

---

## Fase 2: template no lab, em paralelo

No cluster de lab, sem pressa e sem risco.

```bash
# preview local, sem cluster nenhum: gera HTML pra abrir no browser
./alertmanager/preview/render.sh

# aplicar no lab (injeta o html: em todos os email_configs e aplica)
./scripts/amctl.sh set-template

# disparar com os labels que voce quer ver
./scripts/amctl.sh test 'cluster_banner="ACM - Lab"' severity=critical
```

Olhe no canal (use um canal de teste se tiver). Nao gostou? Edite
`alertmanager/templates/teams-email.tmpl`, rode `render.sh` pra conferir no browser,
e `set-template` de novo. Quer voltar atras:

```bash
./scripts/amctl.sh unset-template
```

O `unset` devolve o arquivo **identico** ao anterior, sem mexer em recuo nem em
comentario. Isso foi testado, nao e' promessa.

---

## Fase 3: promover o template

Com o template aprovado no lab, em producao e' um comando:

```bash
./scripts/amctl.sh status          # confirme o cluster
./scripts/amctl.sh set-template    # backup + diff + confirma + aplica
./scripts/amctl.sh test
```

O diff vai mostrar **apenas linhas adicionadas** (`+ html: |`). Se aparecer alguma
linha removida, pare: algo saiu do lugar.

---

## Rollback

```bash
./scripts/amctl.sh rollback                      # lista os backups
./scripts/amctl.sh rollback backups/<arquivo>    # restaura
```

Lembre: config invalida **nao e' gravada** e o Alertmanager segue com a ultima boa.
Isso protege o alerta, mas tambem esconde o erro. Se aplicou e nada mudou,
desconfie da validacao antes de desconfiar do template.

---

## O que este processo NAO cobre

- **Como fica no Teams.** O browser nao e' o Teams. So' o canal responde isso.
- **O `group_by: [namespace]`**, que funde alertas de clusters diferentes num email
  so'. E' decisao de comportamento, fora do escopo de aparencia. Veja o
  `preview/mock-mixed.html` pra entender o efeito antes de decidir.
