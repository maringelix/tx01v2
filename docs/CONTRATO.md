# Contrato tx01v2 <-> dx01v2 — versão 6 (2026-10-16)

Versão 5 adiciona DNS público e HTTPS opcionais: o tx valida ACM por DNS na hosted zone Route53 já
existente, publica `dns/*` no SSM e instala ExternalDNS com Pod Identity restrito ao hostname e à zona.
O dx seleciona o overlay HTTPS e configura o host por esse contrato, sem ARN manual (R8.1).

Versão 6 publica `alb/source-cidr`, o menor CIDR que cobre somente as subnets públicas do ALB. A
NetworkPolicy do app usa esse intervalo na entrada do web; `vpc-cidr` continua restrito ao egress da
API para o RDS privado (R8.1).

No perfil `full`, o tx instala o waypoint `dx01v2-waypoint`, políticas mTLS/autorização, métricas e
alertas do app, além de Kyverno. Antes do deploy, o dx promove somente os digests GHCR aprovados,
assina a declaração de promoção no ECR e fixa esses digests nos manifests; Kyverno exige a declaração
keyless do workflow `deploy-aws.yml` do fork (R8.2–R8.4).

Versão 4: a camada `full` integra o app ao Istio ambient e ao Gatekeeper e registra no Argo CD a
revisão `gitops/aws` do dx; o grupo `dx01v2-deployers` pode pedir refresh da Application `dx01v2`
(R4.1/R4.4). A versão 3 (2026-10-15) fixou os subjects OIDC do GitHub aos IDs imutáveis do dono e do
repositório e restringiu deploy à `main`; a versão 2 (2026-10-14) adicionou traces via Collector ao
AWS X-Ray. O PR de R4 do dx coordena a versão 4 deste contrato.

Interface entre a infraestrutura (este repositório) e a aplicação (`dx01v2`). Esta é a fonte da
verdade: `dx01v2/docs/CONTRATO.md` repete a parte relevante para o app e aponta para cá. Qualquer
mudança exige PRs coordenados nos dois repositórios e incremento da versão.

## Como o contrato é verificado aqui

| O quê | Onde | Status |
|---|---|---|
| Papéis OIDC, `sub` exatos, permissões do deploy | `terraform/bootstrap/tests/oidc_roles.tftest.hcl` | `verificado localmente` |
| Parâmetros SSM (nomes, tipo, valores fixos), tags padrão | `terraform/envs/lab/tests/lab.tftest.hcl` | `verificado localmente` |
| Política do ESO, Pod Identity (LBC, ESO, OpenTelemetry Collector, Trivy, Kyverno e EBS CSI), access entries | `terraform/envs/lab/tests/eks.tftest.hcl` | `verificado localmente` |
| Namespace `observability`, Collector com exporter do X-Ray, mesmo digest do lab local | checks `contract-platform` e `helm-template` do harness | `verificado localmente` |
| ECR imutável, segredos write-only, RDS | `terraform/envs/lab/tests/*.tftest.hcl` | `verificado localmente` |
| Namespace, Role/RoleBinding, ClusterSecretStore | checks `kubeconform` e `contract-platform` do harness | `verificado localmente` |
| Perfil `full`, Applications do Argo CD, waypoint, telemetria do app, RBAC de refresh e policy Kyverno | `helm-template-full`, `kubeconform` e `contract-platform` | `verificado localmente` |
| DNS/ACM opcionais, IAM ExternalDNS restrito, ALB source CIDR e contrato SSM v6 | `terraform test` (`dns.tftest.hcl`, `network.tftest.hcl`), `helm-template`, `contract-platform` | checks locais passaram; CI obrigatório antes do merge |
| Comportamento real na AWS | `docs/RUNBOOK.md` | `não executado em nuvem (v2)` |

## Identificadores

| Item | Valor |
|---|---|
| Região AWS | variável Terraform `aws_region`, padrão `us-east-1` |
| Projeto / ambiente / prefixo | `tx01v2` / `lab` / `tx01v2-lab` |
| Tags padrão (`default_tags` do provider) | `Project=tx01v2`, `Environment=lab`, `ManagedBy=terraform`, `Repository=<owner>/tx01v2` |
| Cluster EKS | `tx01v2-lab`, Kubernetes `1.36` (suporte padrão do EKS até 2027-08-02), `upgrade_policy.support_type = "STANDARD"` |
| Namespace do app | `dx01v2` — criado pelo tx com os labels `pod-security.kubernetes.io/enforce=restricted`, `pod-security.kubernetes.io/enforce-version=latest`, `elbv2.k8s.aws/pod-readiness-gate-inject=enabled`; no perfil `full`, também `istio.io/dataplane-mode=ambient` e `policy.lab/enforce=true` |
| Grupo Kubernetes do deployer | `dx01v2-deployers`, ligado no namespace `dx01v2` (RoleBinding `dx01v2-deployers`) à Role `dx01v2-deployer` |
| Traces (OpenTelemetry) | `http://opentelemetry-collector.observability.svc:4318` (OTLP/HTTP), Collector instalado pela camada de plataforma no namespace `observability` (Pod Identity `tx01v2-lab-otel-collector`, só `AWSXRayDaemonWriteAccess`); os spans vão para o AWS X-Ray da região do lab |
| Repositórios ECR | `dx01v2/api`, `dx01v2/web` — tags IMMUTABLE, scan on push; imagens com a tag do SHA git completo (40 caracteres) do dx01v2 |
| Papéis OIDC do GitHub (bootstrap do tx01v2) | `tx01v2-gha-plan`, `tx01v2-gha-apply`, `dx01v2-gha-deploy` |
| Pod Identity EKS (`full`) | `trivy-system/trivy-operator`, `kyverno/kyverno-admission-controller`, `kube-system/ebs-csi-controller-sa`; Trivy e Kyverno leem somente os dois ECR do app |

Regras da Role `dx01v2-deployer` (namespace `dx01v2`), presentes nos perfis `core` e `full`:

- `apps`: deployments → get, list, watch, create, update, patch, delete; replicasets → get, list, watch
- core: services, configmaps, serviceaccounts → get, list, watch, create, update, patch, delete;
  pods, pods/log, events, endpoints → get, list, watch; secrets → get, list, watch (o ESO escreve
  os segredos; o deployer nunca os escreve)
- `networking.k8s.io`: ingresses, networkpolicies → CRUD completo (mesmos verbos de deployments)
- `autoscaling`: horizontalpodautoscalers → CRUD completo; `policy`: poddisruptionbudgets → CRUD completo
- `external-secrets.io`: externalsecrets → CRUD completo

No perfil `full`, uma Role aditiva `dx01v2-deployer-full` permite `HTTPRoute`, `DestinationRule` e
`AuthorizationPolicy` apenas no namespace `dx01v2`. O AppProject do Argo CD libera os mesmos tipos
somente nesse perfil; `platform/uninstall.sh` remove a Role aditiva.

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

O papel `tx01v2-gha-plan` lê só os serviços do lab (Describe/Get/List), não a conta inteira. O apply
não usa `PowerUserAccess`: sua política permite as famílias AWS necessárias ao lab; IAM fica restrito
a nomes `tx01v2-*` e exige o boundary. S3 só cobre o state e o bucket Velero. Route53, quando ativado,
é limitado à hosted zone configurada também no bootstrap. O boundary dos papéis do lab limita as
mesmas famílias de serviço, restringe S3 ao bucket Velero e Route53 à zona configurada, e corta IAM,
organização e APIs da conta.

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
| `vpc-cidr` | CIDR da VPC (NetworkPolicy API -> RDS) |
| `alb/source-cidr` | CIDR que cobre somente as subnets públicas nas quais os nós do ALB são criados (web -> pods) |
| `ecr/api-url` | URL do repositório `dx01v2/api` |
| `ecr/web-url` | URL do repositório `dx01v2/web` |
| `waf/acl-arn` | ARN do web ACL WAFv2 REGIONAL para o ALB do app |
| `db/secret-name` | `tx01v2-lab/db/app` |
| `app/admin-token-secret-name` | `tx01v2-lab/app/admin-token` |
| `eso/cluster-secret-store` | `aws-secrets-manager` |
| `dns/enabled` | `true` quando domínio e zona forem configurados; caso contrário `false` |
| `dns/domain-name` | hostname público do app ou `disabled` |
| `dns/zone-id` | ID da hosted zone pública existente ou `disabled` |
| `dns/acm-certificate-arn` | certificado ACM com DNS validation concluída ou `disabled` |

## Secrets Manager (criados pelo tx01v2; valores via argumentos write-only, nunca em state/plan)

- `tx01v2-lab/db/app`: JSON com valores string `username`, `password`, `host`, `port`, `dbname`.
- `tx01v2-lab/app/admin-token`: string pura, 48 caracteres alfanuméricos aleatórios.
- Criptografados com a chave KMS do lab; o papel do ESO pode `secretsmanager:GetSecretValue` e
  `DescribeSecret` em `arn:aws:secretsmanager:<region>:<account>:secret:tx01v2-lab/*` e `kms:Decrypt`
  na chave do lab (condição `kms:ViaService = secretsmanager.<region>.amazonaws.com`).

## Camada de plataforma (instalada pelo tx01v2, não pelo Terraform)

- AWS Load Balancer Controller em `kube-system`, ServiceAccount `aws-load-balancer-controller`
  (EKS Pod Identity), IngressClass `alb`.
- Com `dns/enabled=true`, ExternalDNS roda em `kube-system` como `external-dns` via Pod Identity. O
  papel pode ler a zona selecionada e alterar só o A do app e o TXT `a-_external-dns-<hostname>` nessa
  mesma zona. Sem domínio, ExternalDNS não é instalado.
- External Secrets Operator no namespace `external-secrets`, ServiceAccount `external-secrets`
  (EKS Pod Identity); ClusterSecretStore `aws-secrets-manager` (provider aws, service SecretsManager,
  região vinda do SSM, sem auth explícita → credenciais do controller). Detalhe do tx01v2: o store só
  aceita ExternalSecrets do namespace `dx01v2` (`spec.conditions`).
- Add-ons do EKS gerenciados pelo Terraform: vpc-cni (com enforcement de network policy), kube-proxy,
  coredns, eks-pod-identity-agent, metrics-server e EBS CSI.
- `platform/install.sh --profile full` instala Istio ambient, o waypoint L7, Gatekeeper, Kyverno,
  Trivy Operator, Argo CD, observabilidade persistente, Velero e Chaos Mesh; `core` continua sendo o
  padrão.
- No `full`, a Application `platform` lê `platform/gitops` do tx e passa por `valuesObject` a URL
  pública do dx e a revisão `gitops/aws`. O chart registra a Application `dx01v2`, que observa
  `deploy/k8s/overlays/aws` com sync automático, prune e self-heal. Repositórios privados precisam
  de credencial configurada no Argo CD por quem fez o fork.
- O workflow de deploy atualiza na Application viva o overlay, as imagens e os parâmetros de nuvem.
  A Application `platform` ignora apenas `spec.source.path`, `spec.source.kustomize.images` e
  `spec.source.kustomize.patches` da Application `dx01v2`, para o self-heal do pai preservar esses
  valores. A branch pública `gitops/aws` recebe a revisão e parâmetros de exemplo; IDs e CIDRs reais
  permanecem no cluster.
- O grupo Kubernetes `dx01v2-deployers` tem RoleBinding `dx01v2-gitops-sync` em `argocd`: pode
  `get`, `list`, `watch` e `patch` a Application `dx01v2` (a listagem é necessária ao cliente
  Kubernetes; `get/watch/patch` ficam restritos a `resourceNames: [dx01v2]`). Essa permissão permite
  ao deploy pedir refresh; não pode criar ou modificar outras Applications. A Role `dx01v2-deployer`
  no namespace `dx01v2` continua limitada aos recursos do app.
- No `full`, a malha ambient usa mTLS `STRICT` entre workloads, autorização por identidade e waypoint
  para rotas L7. A exceção HTTP do ALB limita-se ao web e ao CIDR das subnets públicas. A constraint
  `allowed-repos` e a policy Kyverno protegem os Pods do namespace `dx01v2`.
- Trivy Operator e Kyverno recebem credenciais ECR temporárias por Pod Identity e podem ler apenas
  `dx01v2/api` e `dx01v2/web`. Kyverno falha fechado quando o digest não tem attestation de promoção
  assinada pelo workflow exato do fork; a política é validada offline, enquanto o runtime AWS segue
  `não executado em nuvem (v2)`.

## Runtime do app (dx01v2)

- Secret `db-credentials`: chaves `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`
  (AWS: ExternalSecret de `tx01v2-lab/db/app`; local/kind/compose: gerado em tempo de execução).
- Secret `app-secrets`: chave `ADMIN_TOKEN` (AWS: ExternalSecret de `tx01v2-lab/app/admin-token`).
- TLS do banco: AWS `DB_SSL_MODE=verify-full`, `DB_SSL_CA_FILE=/etc/rds-ca/ca.pem` a partir do
  ConfigMap `rds-ca` (criado no deploy a partir de
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`); local `DB_SSL_MODE=disable`.
- Services: `api` (porta 3000 http, 9464 métricas), `web` (porta 8080).
- Ingress AWS: classe `alb`, `internet-facing`, `target-type: ip`, WAF do SSM e rotas `/api` →
  `api:3000`, `/` → `web:8080`. Sem DNS configurado, o caminho permanece HTTP-only. Com DNS, o dx
  usa `aws-https`, hostname e certificado ACM do contrato; HTTP redireciona para HTTPS e ExternalDNS
  mantém o A record. Health checks: web `/healthz`, API `/readyz`.
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
