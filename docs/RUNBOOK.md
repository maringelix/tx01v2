# Runbook: uma rodada completa na nuvem

Passo a passo para subir o lab na sua conta AWS, usar, destruir e registrar o resultado. Nada disto
foi executado em nuvem na v2 (`não executado em nuvem (v2)`): você será a primeira evidência.

> **Custo**: `core` custa cerca de US$0,26–0,32/h; `full`, com os nós maiores recomendados, cerca de
> US$0,29–0,40/h em `us-east-1` (estimativas, ver `docs/CUSTOS.md`). Uma rodada de 3 horas fica perto
> de US$1. Destrua no mesmo dia; o budget avisa, mas não para recursos.

## 1. Pré-requisitos

- Conta AWS **dedicada** ao lab (o budget é da conta inteira e o papel apply é praticamente admin).
- Um papel/usuário administrador para o bootstrap (por exemplo, IAM Identity Center), com MFA.
- AWS CLI v2, `gh` autenticado e as ferramentas do harness: `make tools` (terraform, kubectl, helm).
- Repositório `tx01v2` no GitHub (seu fork ou o original) e, para o app, o `dx01v2`.
- Tempo: bootstrap ~2 min; apply ~25–35 min (EKS, nós, RDS); plataforma ~5 min; destroy ~20–30 min.

## 2. Bootstrap (uma vez, local, credenciais de admin)

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edite: budget_alert_emails, github_owner e os três IDs
terraform init
terraform apply
terraform output                               # guarde os valores para a seção 3
terraform output -raw backend_hcl > ../envs/lab/backend.hcl
```

- `github_owner` não tem padrão: use o seu usuário do GitHub, o dono dos repositórios `tx01v2` e
  `dx01v2` (ou dos seus forks). O placeholder do exemplo (`your-github-user`) e o e-mail
  `you@example.com` são recusados.
- Os papéis confiam no `sub` **imutável** do GitHub, que leva os IDs numéricos do dono e do
  repositório: `repo:<dono>@<id do dono>/tx01v2@<id do repositório>:environment:lab`. Todo repositório
  criado depois de 2026-07-15 (um fork novo também) já emite esse formato; o formato antigo, só com os
  nomes, não casa e seria herdado por quem registrasse de novo um nome apagado. Os IDs vêm de
  `gh api users/<dono> --jq .id`, `gh api repos/<dono>/tx01v2 --jq .id` e
  `gh api repos/<dono>/dx01v2 --jq .id` (`github_owner_id`, `tx01v2_repository_id` e
  `dx01v2_repository_id` do `terraform.tfvars`); o `scripts/repo-guardrails.sh` também os imprime.
- Um repositório criado **antes** de 2026-07-15 precisa aderir às claims de sujeito imutáveis
  (Settings > Actions > General > OpenID Connect) antes do primeiro apply. Confira com
  `gh api repos/<dono>/tx01v2/actions/oidc/customization/sub`: o `sub_claim_prefix` deve ter os `@<id>`.
  Um repositório renomeado ou transferido muda o `sub`: aplique o bootstrap de novo.
- O state do bootstrap fica **local** (`terraform.tfstate`, ignorado pelo git). Faça backup dele.
- Já existe um provider OIDC do GitHub na conta? Use `create_github_oidc_provider = false`: o
  bootstrap o lê pela URL e nunca o altera.
- Confirme o e-mail de inscrição que o AWS Budgets envia.
- Opcional, migrar o state para o bucket: crie `backend_override.tf` (ignorado pelo git) com
  `terraform { backend "s3" {} }` e rode
  `terraform init -migrate-state -backend-config=../envs/lab/backend.hcl -backend-config="key=bootstrap/terraform.tfstate"`.
  Antes do teardown (seção 10), volte para local: apague o arquivo e `terraform init -migrate-state`.

## 3. Variáveis do GitHub

Settings > Secrets and variables > Actions > **Variables** (variáveis de repositório; elas aparecem
nos logs, então não coloque nada privado). Os outputs `github_variables_tx01v2` e
`github_variables_dx01v2` do bootstrap trazem as que ele já conhece; o `FORK.md` (passo 7) as grava
com `gh variable set -f`. O endereço de onde você opera (`LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS`) é um
**secret**, na aba Secrets: os logs, o resumo e os artefatos de um repositório público são públicos,
e um secret é mascarado (os workflows mascaram cada CIDR e o IP dele). Depois,
`scripts/repo-guardrails.sh <owner>/tx01v2` cria o environment `lab` (revisor obrigatório, deploy só
de `main`); ele falha, em vez de pular, se o repositório não puder protegê-lo.

| Variável | Exemplo | Usada por | Vem de |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | todos os workflows de nuvem | `aws_region` do bootstrap |
| `TF_STATE_BUCKET` | `tx01v2-tfstate-<ACCOUNT_ID>-us-east-1` | plan, apply, destroy | output `state_bucket_name` |
| `AWS_PLAN_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-plan` | plan (também liga a guarda do workflow) | output `plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-apply` | apply, platform, destroy | output `apply_role_arn` |
| `LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS` (**secret**) | `["0.0.0.0/0"]` | `TF_VAR_endpoint_public_access_cidrs` (lista JSON) | runners do GitHub têm IPs variáveis: precisam de `0.0.0.0/0` |
| `LAB_ALLOW_ENDPOINT_FROM_ANYWHERE` | `true` | `TF_VAR_allow_endpoint_from_anywhere` | obrigatório com `0.0.0.0/0`; padrão `false` |
| `LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS` | `["arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-apply","arn:aws:iam::<ACCOUNT_ID>:role/<YOUR_ADMIN_ROLE>"]` | `TF_VAR_cluster_admin_principal_arns` (lista JSON) | o papel apply (plataforma e destroy) e o seu papel admin |
| `LAB_APP_DEPLOYER_PRINCIPAL_ARNS` | `["arn:aws:iam::<ACCOUNT_ID>:role/dx01v2-gha-deploy"]` | `TF_VAR_app_deployer_principal_arns` (lista JSON) | output `deploy_role_arn`; padrão `[]` |
| `LAB_NODE_INSTANCE_TYPES` (só `full`) | `["t3.large","t3a.large"]` | `TF_VAR_node_instance_types` (lista JSON) | dimensionamento do R4.7 |
| `LAB_NODE_DESIRED_SIZE` (só `full`) | `2` | `TF_VAR_node_desired_size` | dimensionamento do R4.7 |

`TF_VAR_github_owner` vem de `github.repository_owner` e `TF_VAR_aws_region` de `AWS_REGION`. Os
demais inputs usam os padrões do `variables.tf`; para mudar um (por exemplo `node_capacity_type`),
adicione o `TF_VAR_<nome>` ao bloco `env` dos workflows em um PR. ARNs de admin: use o ARN do papel
IAM (`arn:aws:iam::<ACCOUNT_ID>:role/<nome>`), não o ARN `sts::...:assumed-role/...` que o
`aws sts get-caller-identity` mostra. No dx01v2, configure o ARN do `dx01v2-gha-deploy` conforme a
documentação daquele repositório.

O perfil `core` usa os defaults e não precisa das duas variáveis `LAB_NODE_*`. Para `full`, grave os
valores da tabela antes do plan e mantenha-os nos workflows de plan, apply e destroy. No GitHub, o
webhook opcional do Slack deve ser um **secret** `SLACK_WEBHOOK_URL`, nunca uma variável. O instalador
manda o valor ao Secret do Alertmanager por stdin; sem ele, os alertas usam o receiver `null`.

## 4. Apply

1. Dispare `terraform-plan` a partir de `main` (ou abra um PR que mexa em `terraform/**`) e leia o
   plano no resumo do job. Para `full`, confirme que o plan mostra o node group `t3.large`/`t3a.large`
   com duas instâncias antes de aprovar o apply.
2. Dispare `terraform-apply` e aprove o environment `lab`. O job planeja e aplica no mesmo run.

Alternativa local (suas credenciais; o seu papel precisa estar nos admins para a seção 5):

```bash
cd terraform/envs/lab
cp terraform.tfvars.example terraform.tfvars   # seus valores reais (arquivo ignorado pelo git)
terraform init -backend-config=backend.hcl
terraform plan -out tfplan && terraform apply tfplan
terraform output update_kubeconfig_command   # o comando que grava o kubeconfig do lab num arquivo próprio
```

O kubeconfig do lab fica num arquivo só dele: o `~/.kube/config` e o contexto atual da sua máquina
não mudam (nenhum script do lab mexe neles).

```bash
aws eks update-kubeconfig --region us-east-1 --name tx01v2-lab --kubeconfig ~/.kube/tx01v2-lab.kubeconfig
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig   # só neste terminal
```

## 5. Plataforma

Dispare `platform` com `action=install` e escolha `profile=core` (padrão) ou `profile=full`, com a
aprovação do environment `lab`. Use `full` apenas depois que os PRs de tx01v2 e dx01v2 do R4 estiverem
mesclados. Localmente (o script usa kubeconfig e cache Helm temporários e só instala no cluster
`tx01v2-lab` com a tag `Project=tx01v2`):

```bash
export AWS_REGION=us-east-1
platform/install.sh --profile core
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig   # o arquivo da seção 4
kubectl get ingressclass alb && kubectl get clustersecretstore aws-secrets-manager
kubectl -n observability rollout status deployment/opentelemetry-collector
```

Para instalar `full` localmente, exporte `GITHUB_OWNER=<seu-usuario-ou-org>` e rode
`platform/install.sh --profile full --github-owner "$GITHUB_OWNER"`. O modo `full` cria o AppProject e
a Application `platform` no Argo CD; a Application do app segue a branch `gitops/aws` do dx. Se o fork
do app for privado, configure a credencial do repositório no Argo CD antes de instalar. Para enviar
alertas ao Slack, configure o secret `SLACK_WEBHOOK_URL` no GitHub (ou exporte-o apenas no terminal
local da rodada).

Os traces do app (contrato v2) passam pelo Collector e chegam ao AWS X-Ray da mesma região. Depois do
deploy do app e de algumas requisições, confira no console do CloudWatch (X-Ray traces) ou com
`aws xray get-trace-summaries --start-time <INÍCIO> --end-time <FIM>`; nenhum trace em alguns minutos:
`kubectl -n observability logs deployment/opentelemetry-collector` (erros do exporter `awsxray` ou do
Pod Identity).

## 6. Deploy do app (dx01v2)

Siga o runbook do dx01v2. O workflow lê os parâmetros `/tx01v2/lab/*`, publica as imagens nos
repositórios `dx01v2/api` e `dx01v2/web` e usa `dx01v2-gha-deploy` (grupo `dx01v2-deployers`). Com
`core`, selecione `mode=push`, pois esse perfil não instala Argo CD. Com `full`, use `mode=gitops`
(padrão): o workflow publica as imagens, registra a tag SHA do commit na branch `gitops/aws`, configura
na Application viva o overlay e os parâmetros de nuvem e espera o Argo CD sincronizar e deixar `dx01v2`
saudável. A branch pública recebe apenas parâmetros de exemplo; IDs e CIDRs reais ficam no cluster.
O modo `push` também serve a clusters sem Argo CD; no perfil `full`, o self-heal pode reverter mudanças
feitas fora da branch GitOps.

## 7. Smoke test

```bash
kubectl -n dx01v2 get ingress                       # ADDRESS = hostname do ALB (alguns minutos)
curl -fsS "http://<ALB_HOSTNAME>/healthz"           # web
aws wafv2 get-web-acl-for-resource --resource-arn "<ALB_ARN>"   # o ACL do lab está associado
kubectl -n dx01v2 get externalsecrets               # SecretSynced
kubectl -n argocd get application dx01v2             # só no perfil full: Synced / Healthy
kubectl -n velero get backupstoragelocation default  # só no perfil full: Available
```

No perfil `full`, o Grafana é ClusterIP; acesse-o com `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`
e a UI do Argo CD com `kubectl -n argocd port-forward svc/argocd-server 8080:443`. A senha do Grafana
é gerada durante a instalação; não a registre no Git. Sem autenticação do ECR para o Trivy Operator,
os relatórios de imagens privadas podem faltar.

### Drill de restore do Velero (perfil `full`)

O drill usa um namespace descartável, só objetos Kubernetes e nenhum volume. Ele não altera o app nem
prova snapshots de EBS. Rode com um contexto do cluster do lab:

```bash
DRILL=velero-restore-drill
BACKUP="tx01v2-restore-$(date -u +%Y%m%d%H%M%S)"
kubectl create namespace "$DRILL"
kubectl label namespace "$DRILL" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$DRILL" create configmap restore-proof --from-literal=payload=restore-me
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $BACKUP
  namespace: velero
spec:
  includedNamespaces: [$DRILL]
  snapshotVolumes: false
  ttl: 24h0m0s
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}=Completed' "backup/$BACKUP" --timeout=10m
kubectl delete namespace "$DRILL" --wait=true
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $BACKUP
  namespace: velero
spec:
  backupName: $BACKUP
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}=Completed' "restore/$BACKUP" --timeout=10m
kubectl -n "$DRILL" get configmap restore-proof -o jsonpath='{.data.payload}'  # restore-me
kubectl -n velero delete restore "$BACKUP"
kubectl delete namespace "$DRILL" --wait=true
```

O backup expira após 24 horas e o ciclo do bucket remove os objetos após 35 dias. Se qualquer espera
falhar, leia `kubectl -n velero describe backup "$BACKUP"` ou `restore "$BACKUP"`, corrija a causa e
repita com um nome novo.

## 8. Destroy

Dispare `terraform-destroy` com a confirmação `destroy tx01v2-lab`. O job roda `scripts/destroy.sh`:

1. `platform/uninstall.sh`, se o cluster existir. Ele apaga todo Ingress e todo Service
   `LoadBalancer` do cluster, por isso só age no cluster `tx01v2-lab` com a tag `Project=tx01v2`;
   nenhuma variável de ambiente (`CLUSTER_NAME`, por exemplo) muda o alvo.
2. Se o passo 1 falhar (API do cluster fora do ar, controlador parado, tempo esgotado), o script apaga
   pela API da AWS o que o controlador criou: load balancers, target groups e security groups com a
   tag `elbv2.k8s.aws/cluster=tx01v2-lab`, e segue. Um aviso `warning: platform/uninstall.sh did not
   finish` no log marca esse caminho.
3. `terraform destroy`, também depois de um passo 1 que falhou: a VPC e o cluster saem de qualquer
   jeito.
4. `scripts/leftovers.sh --retry-for 900`, sempre, também depois de um destroy que falhou. O job só
   passa quando o destroy e a checagem de sobras passam.

No `full`, o uninstall apaga primeiro as Applications do Argo CD para impedir que o self-heal recrie
o Ingress enquanto o controlador do ALB é removido. O Terraform destrói o bucket do Velero junto com
o lab, inclusive os objetos de backup restantes (o módulo usa `force_destroy`). Guarde fora do lab
qualquer dado que precise preservar.

Não há transição suportada de `full` para `core`: destrua o lab e aplique-o de novo com as variáveis
`LAB_NODE_*` removidas ou nos valores de `core`; instale então `profile=core`. Não desinstale apenas
os charts e reduza o node group.

### Se uma etapa falhar

| Etapa | Diagnóstico e próxima ação |
|---|---|
| Bootstrap | Leia o primeiro erro do Terraform; se o provider OIDC já existe, use `create_github_oidc_provider = false` com o ARN existente. Não repita o apply sem corrigir a variável ou a permissão. |
| Plan/apply | Leia o plano e o erro do provider; confira `LAB_NODE_*`, região, quotas e estado remoto. Corrija a entrada e rode um novo plan antes do apply. |
| Instalação `core`/`full` | Confira `kubectl get pods -A` e `helm list -A` no cluster do lab, corrija o primeiro chart sem Ready e repita a mesma opção `profile`; o instalador é idempotente. |
| Application do Argo CD | `kubectl -n argocd describe application dx01v2`; confirme que a branch `gitops/aws` existe, que o repositório público é acessível e que `deploy/k8s/overlays/aws` renderiza. Corrija no dx e faça novo deploy. |
| Velero | `kubectl -n velero describe backupstoragelocation default`; confira a associação Pod Identity `velero/velero`, o nome/região do bucket e o status. Não crie credenciais AWS estáticas no cluster. |
| Destroy/sobras | Deixe o workflow terminar; se o check falhar, leia `scripts/leftovers.sh`, confirme as tags `Project=tx01v2` e rode o destroy de novo. Não remova recursos sem conferir a tag. |

Qualquer erro aparece no log: leia, corrija e rode de novo. O fluxo é testado sem AWS (check
`destroy-flow` do harness, com `aws`, `terraform`, `kubectl` e `helm` simulados).

**Rodada interrompida** (um apply ou destroy cancelado, ou que estourou o tempo) deixa um *lock* do
state: o próximo `terraform` falha com `Error acquiring the state lock` e um `ID`. Rode
`terraform-destroy` com o input `force_unlock_id` preenchido com esse ID (o arquivo de lock fica no
bucket do state, `lab/terraform.tfstate.tflock`). Se o apply parou no meio e criou algo que não
entrou no state, o próximo apply falha com `already exists`: importe o recurso
(`terraform import <endereço> <id>`) ou apague-o pelo console, e rode de novo. Localmente:

```bash
export AWS_REGION=us-east-1 TF_STATE_BUCKET=<bucket>
# mais as TF_VAR_* do lab (as mesmas do workflow)
scripts/destroy.sh                         # ou: scripts/destroy.sh --force-unlock <ID>
```

## 9. Sobras

`scripts/leftovers.sh` lista `BILLABLE` (sai com 1), `ORPHANED` e `INFO`. Chaves KMS em
`PendingDeletion` são esperadas (janela de 7 dias). Elastic IPs sem a tag `Project=tx01v2` aparecem
só como `INFO` ("not the lab's"): não são do lab, não apague. Antes de apagar qualquer item, confira
que ele é do lab (tag `Project=tx01v2` ou o prefixo `tx01v2-`). Remoção manual dos casos mais comuns:

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <ARN>
aws elbv2 delete-target-group --target-group-arn <ARN>
aws ec2 delete-nat-gateway --nat-gateway-id <ID>
aws ec2 release-address --allocation-id <ID>
aws ec2 delete-security-group --group-id <ID>
aws logs delete-log-group --log-group-name <NOME>
aws rds delete-db-snapshot --db-snapshot-identifier <ID>
aws secretsmanager delete-secret --secret-id <NOME> --force-delete-without-recovery
```

Rode o script de novo até não sobrar nada `BILLABLE`.

## 10. Teardown do bootstrap (fim da série de rodadas)

1. Lab destruído e `scripts/leftovers.sh` limpo.
2. State do bootstrap de volta para local, se tiver sido migrado (seção 2).
3. O provider OIDC do GitHub é da **conta**, não do lab: outro projeto pode ter passado a usá-lo.
   Se o bootstrap o criou (`create_github_oidc_provider = true`), tire-o do state antes do destroy:
   `terraform state rm 'aws_iam_openid_connect_provider.github[0]'`. Só apague-o depois, pelo console,
   se tiver certeza de que nada mais depende dele.
4. Em `terraform/bootstrap`: `state_bucket_force_destroy = true` no `terraform.tfvars`,
   `terraform apply` (só muda essa flag) e `terraform destroy`. Isso apaga o bucket com todas as
   versões do state, os papéis do GitHub, a política de boundary `tx01v2-lab-boundary` e o budget.
5. Confira a fatura no dia seguinte.

## 11. Registro

Abra uma issue com o template **Cloud run report**: data, região, commits do tx01v2/dx01v2, passos,
duração, custo observado, problemas e a saída (redigida) do `scripts/leftovers.sh`.
