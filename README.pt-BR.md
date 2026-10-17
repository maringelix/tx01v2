# tx01v2

Metade de infraestrutura AWS de um lab de DevOps: Terraform, EKS, RDS, ALB + WAF e GitHub Actions com OIDC.

[![ci](https://github.com/maringelix/tx01v2/actions/workflows/ci.yml/badge.svg)](https://github.com/maringelix/tx01v2/actions/workflows/ci.yml)

[English](README.md)

**Fork do lab:** o [FORK.md](FORK.md) (em inglês) leva você do fork ao lab rodando, primeiro na sua máquina, depois na sua conta de nuvem.

## O que é

Um lab público e educacional para clonar ou fazer fork e aprender como uma plataforma EKS pequena é
construída, testada e destruída com segurança. Tudo é verificado por um harness local que não precisa
de conta na nuvem; o caminho em nuvem é opcional e custa dinheiro. **A v2 nunca foi aplicada na AWS**
— a matriz de status abaixo diz exatamente o que está provado e como.

A família do lab (v2):

| Repositório | Nuvem | Papel | Status |
|---|---|---|---|
| [`tx00v2`](https://github.com/maringelix/tx00v2) | as três | hub da família: roadmap, guardrails da família, checks entre os repositórios | veja a matriz de status dele |
| `tx01v2` (este repositório) | AWS | infraestrutura (Terraform, camada de plataforma) | ver matriz de status |
| [`dx01v2`](https://github.com/maringelix/dx01v2) | AWS | aplicação (construída sobre o `docs/CONTRATO.md`) | veja a matriz de status dele |
| [`tx02v2`](https://github.com/maringelix/tx02v2) | Azure | infraestrutura (Terraform, AKS, PostgreSQL Flexible Server, Application Gateway for Containers) | veja a matriz de status dele |
| [`dx02v2`](https://github.com/maringelix/dx02v2) | Azure | aplicação (o app do dx01v2 no AKS) | veja a matriz de status dele |
| [`tx03v2`](https://github.com/maringelix/tx03v2) | GCP | infraestrutura (Terraform, GKE Autopilot, Cloud SQL, Cloud Armor) | veja a matriz de status dele |
| [`dx03v2`](https://github.com/maringelix/dx03v2) | GCP | aplicação (o app do dx01v2 no GKE Autopilot) | veja a matriz de status dele |

## Matriz de status

| Capacidade | Status | Evidência |
|---|---|---|
| Formatação, validação, lock files de providers (4 plataformas) | `verificado no CI` | `make static` (`terraform-fmt`, `terraform-validate:*`, `terraform-lockfiles`); job `static` do CI |
| Lint e scan de segurança da IaC (tflint, trivy HIGH/CRITICAL) | `verificado no CI` | `make static` (`tflint`, `trivy-config`, `trivy-config-tfvars`) |
| Workflows, scripts, manifests Kubernetes e values do Helm (actionlint, shellcheck, kubeconform, helm template) | `verificado no CI` | `make static` (inclui `destroy-flow`, `local-preflight`) |
| Scan de segredos e políticas do repositório (sem identificadores reais, actions fixadas, scripts que só agem no lab, regressões do v1) | `verificado no CI` | `make static` (`gitleaks`, `policy-*`, `repo-structure`) |
| Testes unitários do Terraform com provider AWS mockado (subjects OIDC imutáveis, permissions boundary do apply, leitura restrita do plan, bucket, budget, EKS, nós, RDS, ECR, WAF, KMS, parâmetros SSM do contrato, validações negativas) | `verificado no CI` | `make test`; job `test` do CI |
| Bootstrap (bucket de state, papéis OIDC do GitHub, budget) | `não executado em nuvem (v2)` | `terraform/bootstrap`, `docs/RUNBOOK.md` |
| Apply do lab (VPC, EKS 1.36, RDS PostgreSQL 17, ECR, WAF, contrato no SSM) | `não executado em nuvem (v2)` | `.github/workflows/terraform-apply.yml` |
| Plan em pull requests | `não executado em nuvem (v2)` | `.github/workflows/terraform-plan.yml` |
| Camada de plataforma (AWS Load Balancer Controller v3.6.0, External Secrets Operator 2.12.0, OpenTelemetry Collector 0.162.0 enviando os traces do app ao AWS X-Ray) | `não executado em nuvem (v2)` | `.github/workflows/platform.yml`, `platform/install.sh`; os charts são renderizados pelo `helm-template` |
| Destroy + checagem de sobras | `não executado em nuvem (v2)` | `.github/workflows/terraform-destroy.yml`, `scripts/leftovers.sh` |
| Configurações do repositório como código (ruleset, environment `lab`) | `verificado localmente` | `scripts/repo-guardrails.sh` aplicado; conferido com `gh api` em 2026-10-14 (`docs/PUBLICACAO.md`) |
| **Lab local** (Terraform no Docker): cluster kind + ECR, RDS (só TLS), S3, load balancer e servidor git emulados; destroy + checagem de sobras | `verificado no CI` | `make e2e` (`terraform/envs/local`, `scripts/local-lab.sh`); `terraform-test:envs/local` |
| Continuidade PostgreSQL: Multi-AZ/PITR/replicação de backup entre regiões opt-in, PITR físico local com rejeição de corrupção | `implementado como código; nuvem não executada (v2)` | `terraform/envs/lab/continuity.tf`, `scripts/local/pitr-drill.sh`, [runbook](docs/CONTINUIDADE.md) |
| Service mesh: Istio 1.31 ambient, mTLS `STRICT`, `AuthorizationPolicy` por identidade | `verificado no CI` | `make e2e` (`platform/local/check.sh`: sondas permitida, de outra identidade e em texto puro) |
| Gateway API no Istio atrás do load balancer emulado, HTTPS com cert-manager (CA do lab), HTTP → HTTPS | `verificado no CI` | `make e2e` |
| External Secrets (ClusterSecretStore `local-secrets`), metrics-server | `verificado no CI` | `make e2e` |
| Observabilidade: Prometheus, Alertmanager (alerta sintético entregue, também como mensagem do Slack), Grafana (ClusterIP), Loki + Alloy | `verificado no CI` | `make e2e`; `helm-template-local` |
| Traces com OpenTelemetry: Collector → Tempo, spans dos Gateways do Istio (W3C trace context), spanmetrics com exemplars, Grafana ligando logs, métricas e traces | `verificado no CI` | `make e2e` (`check_tracing`) |
| GitOps com Argo CD 3.5 (commit → sync → self-heal a partir do servidor git do lab) | `verificado no CI` | `make e2e` |
| Policy as code: Gatekeeper 3.23 em `deny` (registries permitidos, imagens fixadas, recursos, probes, labels, NodePort) | `verificado no CI` | `policy-gator` (`gator verify`); `make e2e` |
| Scan dentro do cluster: Trivy Operator (relatórios de vulnerabilidade e de configuração) | `verificado no CI` | `make e2e` |
| Ensaio de backup e restore: Velero no S3 emulado (namespace apagado e restaurado com os dados) | `verificado no CI` | `make e2e` |
| Chaos engineering com hipóteses: pod kill, 100 ms de latência de rede, stress de CPU e memória (Chaos Mesh); disponibilidade, latência e reinícios medidos | `verificado no CI` | `make e2e` |
| Plataforma completa no EKS (16 charts fixados, waypoint do mesh, observabilidade durável, Gatekeeper, admissão Kyverno de imagens, Trivy Operator, Velero, Chaos Mesh) | `implementado como código; não executado em nuvem (v2)` | `platform/install.sh --profile full`; `helm-template-full`, `platform-sizing`, `kubeconform`, `contract-platform`; `.github/workflows/platform.yml` |

As linhas `verificado no CI` rodam em todo pull request, em todo push para a `main` e toda semana
(jobs `static` e `test` do CI). Uma linha de nuvem só muda com uma issue `cloud_run_report` (data,
região, commit, custo, sobras). As linhas do lab local rodam também no job `e2e` do CI.

## Arquitetura

```mermaid
flowchart LR
  internet((Internet)) --> waf["WAF web ACL"] --> alb["ALB (AWS Load Balancer Controller)"]
  subgraph vpc["VPC, 2 AZs"]
    alb --> eks["EKS tx01v2-lab: nós AL2023 Spot"]
    eks -->|TLS 5432| rds[("RDS PostgreSQL 17")]
    eks --> nat["1 NAT gateway"]
  end
  eks -->|External Secrets, Pod Identity| sm["Secrets Manager"]
  gha["GitHub Actions (OIDC)"] -->|papéis plan / apply / deploy| aws["APIs da AWS"]
  dx["deploy do dx01v2"] -->|contrato SSM, ECR, access entry| eks
```

- `terraform/bootstrap`: bucket S3 de state (lock nativo), provider OIDC do GitHub e os três papéis do
  contrato, budget mensal. Aplicado uma vez, localmente, por um humano.
- `terraform/envs/lab`: módulos `kms`, `network`, `eks`, `rds`, `ecr`, `waf`, o segredo do token de
  admin e os parâmetros SSM que o dx01v2 lê.
- `platform/`: charts Helm e manifests instalados depois do apply, nunca pelo Terraform.
- Decisões de design e a tabela v1 → v2: [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Início rápido (grátis, local)

Você precisa de Docker (devcontainer) ou Linux/WSL 2 com bash >= 4.4, curl, unzip, xz, git e make.

```bash
git clone https://github.com/maringelix/tx01v2.git && cd tx01v2
make tools                     # ferramentas fixadas em .tools/, SHA256 conferido
HARNESS_STRICT=1 make verify   # todos os checks estáticos + terraform test
make help
```

No Windows ou macOS, abra a pasta no devcontainer (`.devcontainer/devcontainer.json`); ele roda
`make tools` sozinho. Nada aqui toca a AWS.

### O lab inteiro na sua máquina (grátis)

O lab v1 rodava a plataforma (mesh, monitoração, GitOps, políticas, scan, backup, chaos) só na nuvem.
O lab local monta a mesma plataforma no Docker, para estudar e quebrar sem conta:

```bash
make e2e            # up + todas as sondas + down: 30 a 40 minutos, 8 GB de memória no Docker para "full"
make local-up       # ou deixe rodando (LOCAL_PROFILE=core|observability|operations|full)
LOCAL_SIZE=small make local-up   # a mesma plataforma com limites menores, para 7 GB de memória no Docker
make local-check    # sondas contra o lab rodando
make local-down     # destroy + checagem de sobras
```

| AWS (caminho em nuvem) | Lab local |
|---|---|
| EKS 1.36 | kind 1.36 (`terraform/envs/local`) |
| ECR | registry (`registry.tx01v2.local`, push em `localhost:5001`) |
| RDS PostgreSQL 17, TLS `verify-full` | PostgreSQL 17, só TLS, CA do lab |
| ALB + AWS Load Balancer Controller | cloud-provider-kind + Gateway do Istio (Gateway API) |
| ACM | cert-manager, ClusterIssuer `lab-ca` |
| Secrets Manager + ESO | Secrets de `lab-secrets` + ESO |
| S3 (backups) | Versity S3 Gateway |
| Contrato no SSM | ConfigMap `lab-system/lab-contract` (`docs/CONTRATO.md`) |
| GitHub (origem do GitOps) | servidor git Soft Serve |

Detalhes, sondas e limites: [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md) e
[docs/ARQUITETURA.md](docs/ARQUITETURA.md). O dx01v2 faz o deploy do app em cima dele
(`make e2e-platform` lá).

## Caminho em nuvem (custa dinheiro)

**Custo primeiro:** cerca de US$0,26–0,32 por hora em us-east-1 com os padrões (preços de tabela de
referência, ver [docs/CUSTOS.md](docs/CUSTOS.md)). Um lab esquecido custa mais de US$40 por semana.
Use uma conta AWS dedicada, mantenha os alertas do budget e destrua no mesmo dia.

Siga o [docs/RUNBOOK.md](docs/RUNBOOK.md): bootstrap → variáveis do GitHub → apply → plataforma →
deploy do dx01v2 → smoke test → destroy → checagem de sobras → issue `cloud_run_report`.

## Harness

| Alvo | O que roda | Quando |
|---|---|---|
| `make help` | lista os alvos | a qualquer momento |
| `make tools` | `scripts/install-tools.sh`: terraform 1.16.5, tflint 0.64.0 + ruleset aws 0.49.0, trivy 0.75.0, actionlint 1.7.12, shellcheck 0.11.0, kubeconform 0.8.0, gitleaks 8.30.1, kubectl 1.37.1, helm 4.3.0, kind 0.33.0, gator 3.23.1 | uma vez, e depois de atualizar uma ferramenta |
| `make static` | `scripts/harness.sh static` | antes de cada push |
| `make test` | `scripts/harness.sh test` (`terraform test`, providers mockados) | antes de cada push |
| `make verify` | static + test (jobs `static` e `test` do CI) | antes de cada PR |
| `make e2e` | `scripts/harness.sh e2e`: o lab local de ponta a ponta (job `e2e` do CI) | mudanças na plataforma ou no lab local |
| `make all` | static + test + e2e | — |
| `make clean` | remove `.tools/`, caches e diretórios de trabalho do Terraform | — |

`scripts/harness.sh list` mostra todos os checks. Detalhes: [docs/HARNESS.md](docs/HARNESS.md).

## Documentação

| Documento | Conteúdo |
|---|---|
| [FORK.md](FORK.md) | fork do lab (em inglês): o que o GitHub não copia, o lab local, a sua conta de nuvem |
| [docs/ARQUITETURA.md](docs/ARQUITETURA.md) | diagrama, ADRs, v1 → v2 |
| [docs/CONTRATO.md](docs/CONTRATO.md) | contrato tx01v2 ⇄ dx01v2 v3 (fonte da verdade) |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | rodada completa na nuvem |
| [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md) | o lab local: o que é emulado, como rodar, sondas, limites |
| [docs/CUSTOS.md](docs/CUSTOS.md) | estimativa de custo por componente |
| [docs/GUARDRAILS.md](docs/GUARDRAILS.md) | regras, aplicação, exceções, limites |
| [docs/HARNESS.md](docs/HARNESS.md) | checks, modo estrito, problemas comuns |
| [docs/SUSTENTACAO.md](docs/SUSTENTACAO.md) | rotinas, calendário de fim de suporte, procedimentos de atualização |
| [docs/PUBLICACAO.md](docs/PUBLICACAO.md) | checklist para tornar o repositório público |
| [docs/LICOES_APRENDIDAS.md](docs/LICOES_APRENDIDAS.md) | lições aprendidas com o v1 |

## Contribuindo

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) e o [AGENTS.md](AGENTS.md) (também para humanos).
Vulnerabilidades: [SECURITY.md](SECURITY.md).

## Licença

[MIT](LICENSE) — Copyright (c) 2025-2026 Bruno Maringeli.

## R10: capacidade e FinOps

Veja [FinOps e escala](docs/FINOPS.md) para kind HA, carga/HPA/PDB, Cluster Autoscaler, OpenCost, VPA Off, Spot opt-in, pre?os regionais, or?amento/expira??o e limpeza. O perfil com pool Spot dedicado preserva on-demand e altera custo; defaults baratos permanecem. Nada executado na nuvem (v2).
