# Arquitetura do tx01v2

Visão da infraestrutura AWS do lab, as decisões por trás dela (ADRs curtos) e o que mudou em relação
ao v1. Nada disto foi aplicado em nuvem na v2 (`não executado em nuvem (v2)`); as decisões estão
cobertas pelos testes e checks citados.

## Diagrama

```mermaid
flowchart LR
  internet((Internet)) --> waf["WAF web ACL (REGIONAL)"]
  subgraph gh["GitHub Actions (OIDC, sem chaves)"]
    planwf["tx01v2: terraform-plan"] --> planrole["tx01v2-gha-plan (read-only)"]
    applywf["tx01v2: apply / platform / destroy (env lab)"] --> applyrole["tx01v2-gha-apply"]
    dxwf["dx01v2: deploy (env lab)"] --> deployrole["dx01v2-gha-deploy"]
  end
  subgraph aws["Conta AWS dedicada"]
    subgraph boot["bootstrap (state local)"]
      s3[("S3: state do lab")]
      budget["Budget mensal + alertas"]
    end
    subgraph vpc["VPC 10.0.0.0/16, 2 AZs"]
      subgraph pub["subnets públicas /24"]
        alb["ALB (criado pelo LBC)"]
        nat["NAT gateway (1)"]
      end
      subgraph priv["subnets privadas /20"]
        eks["EKS tx01v2-lab 1.36: nós AL2023 SPOT, LBC, ESO"]
        rds[("RDS PostgreSQL 17")]
      end
    end
    ssm["SSM /tx01v2/lab/*"]
    sm["Secrets Manager tx01v2-lab/*"]
    ecr["ECR dx01v2/api, dx01v2/web"]
    kms["KMS (chave do lab)"]
  end
  waf --> alb --> eks
  eks -->|5432, TLS| rds
  eks -->|ESO via Pod Identity| sm
  eks --> nat
  deployrole --> ecr
  deployrole --> ssm
  deployrole -->|access entry| eks
  planrole -.-> s3
  applyrole --> s3
  kms -.-> sm
  kms -.-> rds
```

Camadas: `terraform/bootstrap` (uma vez, por um humano) → `terraform/envs/lab` (módulos `kms`,
`network`, `eks`, `rds`, `ecr`, `waf`) → `platform/` (Helm e manifests, nunca pelo Terraform) →
app do `dx01v2`. O contrato entre as camadas está em `docs/CONTRATO.md`.

## Lab local

A mesma arquitetura emulada no Docker (`terraform/envs/local` + `platform/local`), com a plataforma
completa do v1 por cima. Detalhes, sondas e limites: `docs/LAB_LOCAL.md`.

```mermaid
flowchart LR
  dev["sua máquina / runner do CI"] -->|terraform apply| net
  subgraph net["rede Docker tx01v2-local 10.250.0.0/24"]
    reg["registry (ECR)"]
    db[("PostgreSQL 17, só TLS (RDS)")]
    s3["Versity S3 Gateway (S3)"]
    git["Soft Serve (origem do GitOps)"]
    lb["cloud-provider-kind (ALB)"]
    subgraph kind["kind tx01v2-local 1.36 (EKS)"]
      gw["Gateway istio + cert-manager lab-ca"]
      mesh["Istio ambient: ztunnel, mTLS STRICT"]
      obs["Prometheus, Alertmanager, Grafana, Loki, Alloy, Tempo, OpenTelemetry Collector"]
      ops["Argo CD, Gatekeeper, Trivy Operator, Velero, Chaos Mesh"]
      eso["ESO local-secrets"]
      app["namespace dx01v2"]
    end
  end
  lb --> gw --> app
  app -->|TLS verify-full| db
  ops -->|backups| s3
  ops -->|sync| git
  kind -->|pull| reg
```

## Decisões (ADRs curtos)

| # | Decisão | Motivo | Alternativa descartada |
|---|---|---|---|
| 1 | EKS Pod Identity para LBC, ESO e o OpenTelemetry Collector | sem provider OIDC por cluster; trust simples (`pods.eks.amazonaws.com`) limitado por `aws:SourceAccount` e `aws:SourceArn` | IRSA (provider OIDC, trust por `sub` do service account) |
| 2 | Nada de provider `kubernetes`/`helm` no Terraform | o state não depende da API do cluster; destroy não trava em recursos Kubernetes; camadas separadas | Helm via Terraform (acoplamento e destroy frágil) |
| 3 | External Secrets Operator lê o Secrets Manager | segredos ficam na AWS; o deployer nunca escreve Secrets | Secrets criados por pipeline ou CSI driver |
| 4 | Segredos `ephemeral` + argumentos write-only | senha do RDS e token do admin nunca no plan ou no state; rotação por `*_version` | `random_password` (fica no state) ou `manage_master_user_password` (formato de segredo fora do contrato) |
| 5 | Nós SPOT (t3.medium/t3a.medium) e 1 NAT gateway | menor custo por hora; duas famílias melhoram a disponibilidade Spot | ON_DEMAND e NAT por AZ (opcionais via variáveis) |
| 6 | ALB pelo AWS Load Balancer Controller v3.6.0 (Ingress, `target-type: ip`) | integração nativa com WAF, target groups por IP, tags para limpeza; o ingress-nginx foi aposentado em março de 2026 | ingress-nginx + NLB |
| 7 | Access entries (`authentication_mode = API`), sem admin implícito do criador | sem ConfigMap aws-auth nem `system:masters`; acesso declarado e auditável | aws-auth (erro do v1) |
| 8 | `upgrade_policy.support_type = STANDARD` | o padrão do EKS é EXTENDED (US$0,60/h contra US$0,10/h); com STANDARD o cluster recebe upgrade automático no fim do suporte | suporte estendido |
| 9 | Endpoint público restrito por CIDR + privado ligado | runners hospedados pelo GitHub (workflows de plataforma e deploy) e laptops precisam alcançar a API; a autenticação IAM continua obrigatória; `0.0.0.0/0` exige opt-in explícito | endpoint só privado (exigiria runner na VPC, VPN ou bastion) |
| 10 | Uma chave KMS gerenciada pelo cliente | secrets do EKS, RDS, Secrets Manager, ECR e logs com rotação anual e política explícita para o CloudWatch Logs (condição de contexto de criptografia) | chaves gerenciadas pela AWS em cada serviço |
| 11 | Bootstrap separado com state local | cria o que o CI não cria para si mesmo (bucket do state, OIDC, papéis); sobrevive aos destroys do lab | bootstrap pelo CI (precisaria de chaves estáticas) |
| 12 | Budget no bootstrap | alerta mesmo quando o lab não existe e cobre a conta inteira; créditos e reembolsos excluídos para refletir o uso real | budget no lab (sumiria no destroy) |
| 13 | SSM Parameter Store como contrato entre repos | o dx01v2 lê valores em tempo de deploy sem acessar o state; parâmetros String padrão não têm custo | remote state compartilhado (vaza o state inteiro) |
| 14 | `AmazonEKS_CNI_Policy` no papel do nó | padrão do EKS; a rede do nó não depende do agente de Pod Identity no bootstrap; com hop limit 1 só pods hostNetwork alcançam essas credenciais | papel de Pod Identity para o aws-node |
| 15 | Volume raiz gp3 com a chave EBS gerenciada pela AWS | uma CMK no launch template exigiria grant para o service-linked role do Auto Scaling, senão as instâncias não sobem | CMK do lab no EBS |
| 16 | Usuário master do RDS usado pelo app | o lab não roda SQL de provisionamento; menos peças | usuário de app separado (precisaria de provider PostgreSQL ou job) |
| 17 | Lab local com Terraform + provider Docker e kind por CLI (`terraform_data` + `local-exec`) | o mesmo fluxo apply/destroy da nuvem, sem conta; o provider `tehcyx/kind` embute uma versão antiga do kind | LocalStack (AWS emulada parcialmente, imagem Pro para EKS); minikube |
| 18 | Istio ambient no lab local | mTLS e autorização por identidade sem sidecar; roda no kind (no v1 o Autopilot recusou sidecar e ambient) | sidecar (mais memória por pod); Linkerd |
| 19 | GitOps com Argo CD lendo um servidor git do lab | um único dono do namespace do app (v1 tinha dois); o push usa a chave do state, a leitura é anônima | Flux; apontar para o GitHub (exigiria credenciais e internet no caminho do deploy) |
| 20 | Gatekeeper com políticas próprias testadas no `gator` | as regras do v1, em `deny`, com casos que provam aceitação e recusa | gatekeeper-library inteira (mais regras do que o lab explica); Kyverno |
| 21 | Alertmanager → `alert-sink` dentro do cluster; receiver do Slack com o webhook num Secret opcional | entrega de alerta provada sem credencial externa (v1 dependia de um webhook do Slack nunca testado); sem webhook, a mensagem no formato do Slack vai para o sink e a sonda confere o conteúdo | webhook do Slack nos values versionados (v1) |
| 22 | Velero no S3 emulado; backup por recursos, sem snapshots | o ensaio de restore roda em minutos e sem nuvem (v1 nunca restaurou nada) | `pg_dump` sozinho; snapshots CSI |
| 23 | Perfis `core`/`observability`/`operations`/`full` | máquinas com pouca memória validam uma camada por vez; o CI roda `full` | um único perfil |
| 24 | Traces: o OpenTelemetry Collector como único destino OTLP; Tempo no lab local, X-Ray na nuvem | o app e os Gateways falam só OTLP; trocar o backend não muda o app; Tempo monolítico (chart grafana-community) cabe no kind; o spanmetrics do Collector liga métricas a traces por exemplars | SDK do X-Ray no app (prende o app à AWS); Jaeger; Tempo distribuído |

Detalhes do LBC v3: desde a v3.0.0 o chart tem a mesma versão do app (chart 3.6.0); o Gateway API
vem habilitado por padrão e é desligado explicitamente (o lab usa Ingress); o service mutator webhook
também fica desligado. A política IAM é a do upstream da tag `v3.6.0`, sem edição.

## v1 → v2

| Problema no v1 | Decisão no v2 | Evidência |
|---|---|---|
| Launch template e `disk_size` juntos | volume raiz só no block device mapping do launch template | `policy-terraform`; teste `nodes` (sentinela do mock) |
| Security group próprio no launch template: o EKS deixava de anexar o SG do cluster e os nós não entravam | launch template sem SGs, AMI ou user data | `policy-terraform`; teste `nodes` |
| IMDS com hop limit 2 | IMDSv2 obrigatório, hop limit 1 | teste `nodes` |
| Subnets fixas ignorando variáveis | CIDRs derivados de `vpc_cidr` e AZs de `aws_availability_zones` | testes `network` |
| WAF ligado a um ALB que não recebia tráfego | ACL publicado no SSM e associado pelo Ingress do app (anotação do LBC) | contrato; teste `contract_ssm_parameters_and_wiring` |
| "Testes" que só faziam `echo` | `terraform test` com provider mockado e testes negativos; checks reais no harness | `make test` |
| Terraform 1.6.0 fixado (init falhava: chave da HashiCorp expirada) | `required_version >= 1.11.0, < 2.0.0`; harness com 1.16.5 por SHA256 | `tool-versions`, `version-consistency` |
| Argumentos de CLI do tflint removidos na v0.47 | `tflint --recursive --config` (v0.64.0) | check `tflint` |
| `sed` em arquivos Terraform nos workflows | inputs por `TF_VAR_*`; `sed` em `.tf` proibido | `policy-workflows` |
| Destroy que engolia erros (`\|\| echo`) | destroy falha alto e termina com `scripts/leftovers.sh` | `terraform-destroy.yml`, `policy-workflows` |
| ConfigMap aws-auth + `system:masters` | access entries, modo API | `policy-terraform`; teste `access_entries` |
| Account IDs fixos no código | data sources; placeholders `123456789012`/`<ACCOUNT_ID>` | `policy-identifiers` |
| Só HTTP, mas com claims de HSTS | HTTP 80 declarado; HTTPS apenas com certificado ACM (contrato); nenhuma afirmação além disso | `docs/CONTRATO.md` |
| Senha do RDS em texto no state | `ephemeral "random_password"` + `password_wo`/`secret_string_wo` | teste `rds_password_never_in_plan_or_state` |
| Sem budgets | budget mensal com 4 alertas no bootstrap | teste `budget` |
| Dois NAT gateways fixos | 1 NAT por padrão, um por AZ opcional | testes `network` e `lab` |
| README afirmando coisas que não existiam | matriz de status com rótulos exatos e evidência | `repo-structure`; `README.md` |
