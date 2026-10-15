# Contrato tx01v2 <-> dx01v2 — versão 2 (2026-10-14)

Versão 2: o OpenTelemetry Collector da camada de plataforma (namespace `observability`, traces para o
AWS X-Ray). A versão 1 (2026-10-10) não tinha traces.

Interface entre a infraestrutura (este repositório) e a aplicação (`dx01v2`). Esta é a fonte da
verdade: `dx01v2/docs/CONTRATO.md` repete a parte relevante para o app e aponta para cá. Qualquer
mudança exige PRs coordenados nos dois repositórios e incremento da versão.

## Como o contrato é verificado aqui

| O quê | Onde | Status |
|---|---|---|
| Papéis OIDC, `sub` exatos, permissões do deploy | `terraform/bootstrap/tests/oidc_roles.tftest.hcl` | `verificado localmente` |
| Parâmetros SSM (nomes, tipo, valores fixos), tags padrão | `terraform/envs/lab/tests/lab.tftest.hcl` | `verificado localmente` |
| Política do ESO, Pod Identity (LBC, ESO, OpenTelemetry Collector), access entries | `terraform/envs/lab/tests/eks.tftest.hcl` | `verificado localmente` |
| Namespace `observability`, Collector com exporter do X-Ray, mesmo digest do lab local | checks `contract-platform` e `helm-template` do harness | `verificado localmente` |
| ECR imutável, segredos write-only, RDS | `terraform/envs/lab/tests/*.tftest.hcl` | `verificado localmente` |
| Namespace, Role/RoleBinding, ClusterSecretStore | checks `kubeconform` e `contract-platform` do harness | `verificado localmente` |
| Comportamento real na AWS | `docs/RUNBOOK.md` | `não executado em nuvem (v2)` |

## Identificadores

| Item | Valor |
|---|---|
| Região AWS | variável Terraform `aws_region`, padrão `us-east-1` |
| Projeto / ambiente / prefixo | `tx01v2` / `lab` / `tx01v2-lab` |
| Tags padrão (`default_tags` do provider) | `Project=tx01v2`, `Environment=lab`, `ManagedBy=terraform`, `Repository=<owner>/tx01v2` |
| Cluster EKS | `tx01v2-lab`, Kubernetes `1.36` (suporte padrão do EKS até 2027-08-02), `upgrade_policy.support_type = "STANDARD"` |
| Namespace do app | `dx01v2` — criado pela camada de plataforma do tx01v2 com os labels `pod-security.kubernetes.io/enforce=restricted`, `pod-security.kubernetes.io/enforce-version=latest`, `elbv2.k8s.aws/pod-readiness-gate-inject=enabled` |
| Grupo Kubernetes do deployer | `dx01v2-deployers`, ligado no namespace `dx01v2` (RoleBinding `dx01v2-deployers`) à Role `dx01v2-deployer` |
| Traces (OpenTelemetry) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP), Collector instalado pela camada de plataforma no namespace `observability` (Pod Identity `tx01v2-lab-otel-collector`, só `AWSXRayDaemonWriteAccess`); os spans vão para o AWS X-Ray da região do lab |
| Repositórios ECR | `dx01v2/api`, `dx01v2/web` — tags IMMUTABLE, scan on push; imagens com a tag do SHA git completo (40 caracteres) do dx01v2 |
| Papéis OIDC do GitHub (bootstrap do tx01v2) | `tx01v2-gha-plan`, `tx01v2-gha-apply`, `dx01v2-gha-deploy` |

Regras da Role `dx01v2-deployer` (namespace `dx01v2`):

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch
- core: services, configmaps, serviceaccounts → get, list, watch, create, update, patch, delete;
  pods, pods/log, events, endpoints → get, list, watch; secrets → get, list, watch (o ESO escreve
  os segredos; o deployer nunca os escreve)
- `networking.k8s.io`: ingresses, networkpolicies → CRUD completo (mesmos verbos de deployments)
- `autoscaling`: horizontalpodautoscalers → CRUD completo; `policy`: poddisruptionbudgets → CRUD completo
- `external-secrets.io`: externalsecrets → CRUD completo

## Confiança OIDC do GitHub

`sub` exato (StringEquals, sem curingas), audience `sts.amazonaws.com`, dono configurável
(`github_owner`, sem padrão: o dono do repositório ou do seu fork). O `sub` é o **imutável** do GitHub
(repositórios criados depois de 2026-07-15 ou que aderiram): leva o ID numérico do dono e o do
repositório (`github_owner_id`, `tx01v2_repository_id`, `dx01v2_repository_id`), então um nome de conta
apagado e registrado de novo não herda o lab. O ambiente `lab` só implanta a partir de `main`.

| Papel | `sub` permitido |
|---|---|
| `tx01v2-gha-plan` | `repo:<owner>@<owner id>/tx01v2@<repo id>:pull_request`, `repo:<owner>@<owner id>/tx01v2@<repo id>:ref:refs/heads/main` |
| `tx01v2-gha-apply` | `repo:<owner>@<owner id>/tx01v2@<repo id>:environment:lab` |
| `dx01v2-gha-deploy` | `repo:<owner>@<owner id>/dx01v2@<repo id>:environment:lab` |

O papel `tx01v2-gha-plan` lê só os serviços do lab (Describe/Get/List), não a conta inteira. Todo
papel IAM que o apply cria (`tx01v2-*`) leva o *permissions boundary* `tx01v2-lab-boundary`, criado
pelo bootstrap: o apply só cria um papel com ele e não pode editá-lo nem tirá-lo, e o boundary corta
qualquer alteração de IAM, da organização e da conta, seja qual for a política anexada ao papel.

Permissões de `dx01v2-gha-deploy`: `ecr:GetAuthorizationToken` em `*`; ações de push/pull apenas nos
ARNs dos dois repositórios ECR; `eks:DescribeCluster` no ARN do cluster; `ssm:GetParameter`,
`ssm:GetParameters`, `ssm:GetParametersByPath` em `parameter/tx01v2/lab/*`. Acesso Kubernetes: access
entry do EKS (tipo `STANDARD`, `kubernetes_groups = ["dx01v2-deployers"]`) criada pelo root do lab
para cada ARN em `app_deployer_principal_arns`.

Nota de uso (não altera o contrato): com `GetParametersByPath`, use `Path=/tx01v2/lab/` (com a barra
final), que casa com o recurso `parameter/tx01v2/lab/*`; ou leia os nomes com `GetParameter(s)`.

## Parâmetros SSM (tipo String, escritos pelo root do lab), prefixo `/tx01v2/lab/`

| Nome | Valor |
|---|---|
| `region` | região AWS |
| `cluster-name` | `tx01v2-lab` |
| `vpc-id` | ID da VPC |
| `vpc-cidr` | CIDR da VPC (as NetworkPolicies do app o usam para o tráfego ALB -> pod e pod -> RDS) |
| `ecr/api-url` | URL do repositório `dx01v2/api` |
| `ecr/web-url` | URL do repositório `dx01v2/web` |
| `waf/acl-arn` | ARN do web ACL WAFv2 REGIONAL para o ALB do app |
| `db/secret-name` | `tx01v2-lab/db/app` |
| `app/admin-token-secret-name` | `tx01v2-lab/app/admin-token` |
| `eso/cluster-secret-store` | `aws-secrets-manager` |

## Secrets Manager (criados pelo tx01v2; valores via argumentos write-only, nunca em state/plan)

- `tx01v2-lab/db/app`: JSON com valores string `username`, `password`, `host`, `port`, `dbname`.
- `tx01v2-lab/app/admin-token`: string pura, 48 caracteres alfanuméricos aleatórios.
- Criptografados com a chave KMS do lab; o papel do ESO pode `secretsmanager:GetSecretValue` e
  `DescribeSecret` em `arn:aws:secretsmanager:<region>:<account>:secret:tx01v2-lab/*` e `kms:Decrypt`
  na chave do lab (condição `kms:ViaService = secretsmanager.<region>.amazonaws.com`).

## Camada de plataforma (instalada pelo tx01v2, não pelo Terraform)

- AWS Load Balancer Controller em `kube-system`, ServiceAccount `aws-load-balancer-controller`
  (EKS Pod Identity), IngressClass `alb`.
- External Secrets Operator no namespace `external-secrets`, ServiceAccount `external-secrets`
  (EKS Pod Identity); ClusterSecretStore `aws-secrets-manager` (provider aws, service SecretsManager,
  região vinda do SSM, sem auth explícita → credenciais do controller). Detalhe do tx01v2: o store só
  aceita ExternalSecrets do namespace `dx01v2` (`spec.conditions`).
- Add-ons do EKS gerenciados pelo Terraform: vpc-cni (com enforcement de network policy), kube-proxy,
  coredns, eks-pod-identity-agent, metrics-server.

## Runtime do app (dx01v2)

- Secret `db-credentials`: chaves `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  (AWS: ExternalSecret de `tx01v2-lab/db/app`; local/kind/compose: gerado em tempo de execução).
- Secret `app-secrets`: chave `ADMIN_TOKEN` (AWS: ExternalSecret de `tx01v2-lab/app/admin-token`).
- TLS do banco: AWS `DB_SSL_MODE=verify-full`, `DB_SSL_CA_FILE=/etc/rds-ca/ca.pem` a partir do
  ConfigMap `rds-ca` (criado no deploy a partir de
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`); local `DB_SSL_MODE=disable`.
- Services: `api` (porta 3000 http, 9464 métricas), `web` (porta 8080).
- Ingress (só AWS): classe `alb`, `internet-facing`, `target-type: ip`, HTTP 80 (HTTPS só se um ARN de
  certificado ACM for informado), anotação `alb.ingress.kubernetes.io/wafv2-acl-arn` vinda do SSM;
  `/api` → `api:3000`, `/` → `web:8080`; health checks web `/healthz`, api `/readyz`.
- RDS PostgreSQL 17, porta 5432, acessível só a partir do security group do cluster EKS,
  `rds.force_ssl = 1`.

## Lab local (contrato local, versão 2)

O lab local (`docs/LAB_LOCAL.md`) é um contrato à parte, com versão própria (chave `version`), lido
pelo deploy local do dx01v2. Ele espelha o contrato da nuvem com nomes do lab local; não muda nada
acima. Publicado por `platform/local/install.sh` no ConfigMap `lab-system/lab-contract`:

| Chave | Valor | Equivale na nuvem |
|---|---|---|
| `version` | `2` (2026-10-14: `tracing.otlp-endpoint`; a versão 1 não tinha traces) | versão deste arquivo |
| `cluster-name` | `tx01v2-local` | `cluster-name` |
| `network-cidr` | `10.250.0.0/24` (ou `subnet_cidr`) | `vpc-cidr` |
| `registry` | `registry.tx01v2.local` (nome das imagens no cluster) | `ecr/api-url`, `ecr/web-url` (prefixo) |
| `registry-push` | `localhost:5001` (push desta máquina) | — |
| `db.endpoint-ip`, `db.hostname`, `db.port` | `10.250.0.11`, `db.tx01v2.local`, `5432` | endpoint do RDS |
| `db.secret-name` | `tx01v2-lab-db-app` (chaves `host`, `port`, `dbname`, `username`, `password`) | `db/secret-name` |
| `db.ca-configmap` | `lab-system/lab-ca` (chave `ca.crt`) | bundle de CA do RDS |
| `app.admin-token-secret-name` | `tx01v2-lab-app-admin-token` (chave `token`) | `app/admin-token-secret-name` |
| `eso.cluster-secret-store` | `local-secrets` (só o namespace `dx01v2`) | `eso/cluster-secret-store` |
| `gateway.class` | `istio` (Gateway API) | IngressClass `alb` |
| `tls.cluster-issuer` | `lab-ca` (cert-manager) | certificado ACM |
| `gitops.push-url`, `gitops.read-url` | `ssh://10.250.0.13:23231/dx01v2-gitops`, `http://10.250.0.13:23232/dx01v2-gitops.git` | — |
| `gitops.push-key-secret` | `lab-secrets/gitops-push-key` (chave SSH do push, `kubernetes.io/ssh-auth`) | papel `dx01v2-gha-deploy` |
| `argocd.project` | `dx01v2` (AppProject: só o repositório GitOps, só o namespace `dx01v2`, só os kinds do deploy, nada de Secret ou recurso de cluster) | Role `dx01v2-deployer` |
| `monitoring.prometheus-service-account` | `monitoring/kube-prometheus-stack-prometheus` (identidade do Prometheus no mesh) | — |
| `tracing.otlp-endpoint` | `http://opentelemetry-collector.monitoring.svc:4318` (OTLP/HTTP do OpenTelemetry Collector; o app manda os spans por ele, pelo mesh, e os Gateways mandam os deles em OTLP/gRPC na porta 4317) | — |

Regras do namespace `dx01v2` no lab local: Pod Security `restricted`, mesh ambient (`istio.io/dataplane-mode:
ambient`), constraints do Gatekeeper em `deny` (`policy.lab/enforce: "true"`; imagens só de
`registry.tx01v2.local/`), métricas do app coletadas pelo Prometheus do namespace `monitoring`. O deploy
local escreve no repositório GitOps; quem aplica no cluster é o Argo CD.

## Mudando o contrato

1. Abra PRs nos dois repositórios, com links cruzados, e incremente a versão no título deste arquivo.
2. Atualize testes e checks que cobrem o item (tabela "Como o contrato é verificado aqui").
3. Faça o merge do lado que publica (tx01v2) antes do lado que consome, salvo remoções (ao contrário).
