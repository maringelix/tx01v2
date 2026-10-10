# Runbook: uma rodada completa na nuvem

Passo a passo para subir o lab na sua conta AWS, usar, destruir e registrar o resultado. Nada disto
foi executado em nuvem na v2 (`não executado em nuvem (v2)`): você será a primeira evidência.

> **Custo**: com os padrões, cerca de US$0,26–0,32 por hora em us-east-1 (preços de tabela de
> referência, ver `docs/CUSTOS.md`). Uma rodada de 3 horas fica perto de US$1, mas um lab esquecido
> ligado passa de US$40 por semana. Destrua no mesmo dia.

## 1. Pré-requisitos

- Conta AWS **dedicada** ao lab (o budget é da conta inteira e o papel apply é praticamente admin).
- Um papel/usuário administrador para o bootstrap (por exemplo, IAM Identity Center), com MFA.
- AWS CLI v2, `gh` autenticado e as ferramentas do harness: `make tools` (terraform, kubectl, helm).
- Repositório `tx01v2` no GitHub (seu fork ou o original) e, para o app, o `dx01v2`.
- Tempo: bootstrap ~2 min; apply ~25–35 min (EKS, nós, RDS); plataforma ~5 min; destroy ~20–30 min.

## 2. Bootstrap (uma vez, local, credenciais de admin)

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edite: budget_alert_emails, github_owner
terraform init
terraform apply
terraform output                               # guarde os valores para a seção 3
terraform output -raw backend_hcl > ../envs/lab/backend.hcl
```

- O state do bootstrap fica **local** (`terraform.tfstate`, ignorado pelo git). Faça backup dele.
- Já existe um provider OIDC do GitHub na conta? Use `create_github_oidc_provider = false` e
  `existing_github_oidc_provider_arn`.
- Confirme o e-mail de inscrição que o AWS Budgets envia.
- Opcional, migrar o state para o bucket: crie `backend_override.tf` (ignorado pelo git) com
  `terraform { backend "s3" {} }` e rode
  `terraform init -migrate-state -backend-config=../envs/lab/backend.hcl -backend-config="key=bootstrap/terraform.tfstate"`.
  Antes do teardown (seção 10), volte para local: apague o arquivo e `terraform init -migrate-state`.

## 3. Variáveis do GitHub

Settings > Secrets and variables > Actions > **Variables** (variáveis de repositório; elas aparecem
nos logs, então não coloque nada privado). Depois, `scripts/repo-guardrails.sh <owner>/tx01v2` cria
o environment `lab` (revisor obrigatório, deploy só de `main`) — exige repositório público.

| Variável | Exemplo | Usada por | Vem de |
|---|---|---|---|
| `AWS_REGION` | `us-east-1` | todos os workflows de nuvem | `aws_region` do bootstrap |
| `TF_STATE_BUCKET` | `tx01v2-tfstate-<ACCOUNT_ID>-us-east-1` | plan, apply, destroy | output `state_bucket_name` |
| `AWS_PLAN_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-plan` | plan (também liga a guarda do workflow) | output `plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-apply` | apply, platform, destroy | output `apply_role_arn` |
| `LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS` | `["0.0.0.0/0"]` | `TF_VAR_endpoint_public_access_cidrs` (lista JSON) | runners do GitHub têm IPs variáveis: precisam de `0.0.0.0/0` |
| `LAB_ALLOW_ENDPOINT_FROM_ANYWHERE` | `true` | `TF_VAR_allow_endpoint_from_anywhere` | obrigatório com `0.0.0.0/0`; padrão `false` |
| `LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS` | `["arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-apply","arn:aws:iam::<ACCOUNT_ID>:role/<YOUR_ADMIN_ROLE>"]` | `TF_VAR_cluster_admin_principal_arns` (lista JSON) | o papel apply (plataforma e destroy) e o seu papel admin |
| `LAB_APP_DEPLOYER_PRINCIPAL_ARNS` | `["arn:aws:iam::<ACCOUNT_ID>:role/dx01v2-gha-deploy"]` | `TF_VAR_app_deployer_principal_arns` (lista JSON) | output `deploy_role_arn`; padrão `[]` |

`TF_VAR_github_owner` vem de `github.repository_owner` e `TF_VAR_aws_region` de `AWS_REGION`. Os
demais inputs usam os padrões do `variables.tf`; para mudar um (por exemplo `node_capacity_type`),
adicione o `TF_VAR_<nome>` ao bloco `env` dos workflows em um PR. ARNs de admin: use o ARN do papel
IAM (`arn:aws:iam::<ACCOUNT_ID>:role/<nome>`), não o ARN `sts::...:assumed-role/...` que o
`aws sts get-caller-identity` mostra. No dx01v2, configure o ARN do `dx01v2-gha-deploy` conforme a
documentação daquele repositório.

## 4. Apply

1. Dispare `terraform-plan` a partir de `main` (ou abra um PR que mexa em `terraform/**`) e leia o
   plano no resumo do job.
2. Dispare `terraform-apply` e aprove o environment `lab`. O job planeja e aplica no mesmo run.

Alternativa local (suas credenciais; o seu papel precisa estar nos admins para a seção 5):

```bash
cd terraform/envs/lab
cp terraform.tfvars.example terraform.tfvars   # seus valores reais (arquivo ignorado pelo git)
terraform init -backend-config=backend.hcl
terraform plan -out tfplan && terraform apply tfplan
terraform output update_kubeconfig_command
```

## 5. Plataforma

Dispare `platform` com `action=install` (aprovação do environment `lab`). Localmente:

```bash
export AWS_REGION=us-east-1
platform/install.sh        # LBC, ESO e platform/manifests; termina com ClusterSecretStore Ready
kubectl get ingressclass alb && kubectl get clustersecretstore aws-secrets-manager
```

## 6. Deploy do app (dx01v2)

Siga o runbook do dx01v2: ele lê os parâmetros `/tx01v2/lab/*` do SSM, publica as imagens nos
repositórios `dx01v2/api` e `dx01v2/web` e aplica os manifests no namespace `dx01v2` com o papel
`dx01v2-gha-deploy` (grupo `dx01v2-deployers`).

## 7. Smoke test

```bash
kubectl -n dx01v2 get ingress                       # ADDRESS = hostname do ALB (alguns minutos)
curl -fsS "http://<ALB_HOSTNAME>/healthz"           # web
aws wafv2 get-web-acl-for-resource --resource-arn "<ALB_ARN>"   # o ACL do lab está associado
kubectl -n dx01v2 get externalsecrets               # SecretSynced
```

## 8. Destroy

Dispare `terraform-destroy` com a confirmação `destroy tx01v2-lab`. O job roda
`platform/uninstall.sh` (se o cluster existir), `terraform destroy` e `scripts/leftovers.sh`.
Qualquer erro para o job: leia o log, corrija e rode de novo. Localmente:

```bash
export AWS_REGION=us-east-1
platform/uninstall.sh
terraform -chdir=terraform/envs/lab destroy
scripts/leftovers.sh --retry-for 900
```

## 9. Sobras

`scripts/leftovers.sh` lista `BILLABLE` (sai com 1), `ORPHANED` e `INFO`. Chaves KMS em
`PendingDeletion` são esperadas (janela de 7 dias). Remoção manual dos casos mais comuns:

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
3. Em `terraform/bootstrap`: `state_bucket_force_destroy = true` no `terraform.tfvars`,
   `terraform apply` (só muda essa flag) e `terraform destroy`. Isso apaga o bucket com todas as
   versões do state, os papéis do GitHub, o provider OIDC (se criado aqui) e o budget.
4. Confira a fatura no dia seguinte.

## 11. Registro

Abra uma issue com o template **Cloud run report**: data, região, commits do tx01v2/dx01v2, passos,
duração, custo observado, problemas e a saída (redigida) do `scripts/leftovers.sh`.
