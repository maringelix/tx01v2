# Sustentação do tx01v2

Como manter o repositório saudável sem conta na nuvem: rotinas, calendário de fim de suporte e
procedimentos passo a passo. Datas e versões verificadas em 2026-10-10.

## 1. Objetivo e escopo

Cobre o código (Terraform, scripts, workflows), as ferramentas do harness, as versões de plataforma
(EKS, AL2023, PostgreSQL, charts) e as rodadas opcionais em nuvem. Não cobre o app (ver `dx01v2`).

## 2. Estado atual

- Harness completo (`make verify`) `verificado no CI` (jobs `static` e `test`).
- Lab local (`docs/LAB_LOCAL.md`): `make e2e` com o perfil `full` (34 sondas) `verificado no CI`
  (job `e2e`); `verificado localmente` em 2026-10-13 (`full`) e 2026-10-14 (`observability` e
  `operations`, com traces, Slack e os novos experimentos de chaos).
- Bootstrap, apply, plataforma e destroy: `não executado em nuvem (v2)`.
- Contrato com o dx01v2: versão 4 de 2026-10-16; inclui os labels de ambient/policy e a Application
  GitOps, coordenados com o PR R4 do dx. A versão 3 fixou os subjects OIDC imutáveis e a versão 2
  adicionou o endpoint OTLP do Collector (`docs/CONTRATO.md`).

## 3. Rotinas

| Quando | O quê | Como |
|---|---|---|
| Semanal (automático) | CI agendado (segunda 06:00 UTC) roda todo o harness | Falhou? Seção 6. Causas típicas: ignore vencido, URL que mudou, rede |
| Mensal | PRs do Dependabot (actions, providers Terraform, pre-commit) | Playbook "Dependency updater" do `AGENTS.md`; um PR por grupo, harness verde antes do merge |
| Trimestral | Ferramentas do harness, charts e digests, versões de plataforma, schemas do kubeconform, ignores perto de vencer | Seções 4 e 5; registre no CHANGELOG |
| Por rodada em nuvem: antes | Ler `docs/CUSTOS.md`, conferir o budget, CI verde no commit, variáveis do GitHub | `docs/RUNBOOK.md` |
| Por rodada em nuvem: durante | Anotar horários e problemas; não deixar a rodada aberta de um dia para o outro | `docs/RUNBOOK.md` |
| Por rodada em nuvem: depois | destroy, `scripts/leftovers.sh` limpo, issue `cloud_run_report`, matriz de status só com evidência | `docs/RUNBOOK.md`, seção 7 |

## 4. Calendário de fim de suporte

| Componente | Versão | Fim do suporte | Fonte | Ação |
|---|---|---|---|---|
| Kubernetes no EKS | 1.36 (padrão do lab) | padrão: 2027-08-02; estendido: 2028-08-02 | [calendário do EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) | Migrar para 1.37 antes de 2027-08-02. Com `upgrade_policy = STANDARD` o EKS faz upgrade automático no fim do suporte padrão (sem cobrança de estendido, US$0,60/h) |
| Kubernetes no EKS | 1.37 (lançado no EKS em 2026-10-01) | padrão: 2027-12-01; estendido: 2028-12-01 | idem | Candidato a padrão na próxima revisão trimestral, depois de conferir LBC, ESO e add-ons |
| Amazon Linux 2023 (nós) | AL2023 | suporte padrão até 2027-06-30; manutenção até 2029-06-30 | [AL2023 release cadence](https://docs.aws.amazon.com/linux/al2023/ug/release-cadence.html) | AMIs novas chegam com o node group; planejar a sucessora antes de 2029 |
| PostgreSQL (RDS) | 17 | comunidade: 2029-11-08; RDS padrão: 2030-02-28 (depois, cobrança de Extended Support) | [calendário do RDS PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html) | Upgrade de major (contrato v2) antes de 2030-02-28 |
| Terraform CLI | 1.16.5 (`>= 1.11.0, < 2.0.0`) | sem data fixa | [releases](https://releases.hashicorp.com/terraform/) | Trimestral (5.2) |
| Provider hashicorp/aws | 6.68.0 (`~> 6.68`) | sem data fixa; a major 7 exigirá migração | registry.terraform.io | Dependabot mensal (5.3) |
| Provider hashicorp/random | 3.9.1 (`~> 3.9`) | sem data fixa | registry.terraform.io | Dependabot mensal |
| AWS Load Balancer Controller | v3.6.0 (chart 3.6.0) | sem política de EOL publicada | [releases](https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases) | Trimestral (5.5) |
| External Secrets Operator | v2.12.0 (chart 2.12.0, CRDs `external-secrets.io/v1`) | o projeto mantém só as versões recentes | [releases](https://github.com/external-secrets/external-secrets/releases) | Trimestral (5.6) |
| kubectl / Helm | 1.37.1 / 4.3.0 | kubectl suporta ±1 minor da API (1.36–1.38) | kubernetes.io, helm.sh | Acompanhar a versão do cluster; Helm 4 removeu `--atomic` (use `--rollback-on-failure`) |
| Runners e devcontainer | Ubuntu 24.04 LTS | suporte padrão de 5 anos (até 2029-04) | ubuntu.com | Trocar antes do fim |
| Exceções do trivy | 4 entradas | 2027-04-30 | `.trivyignore.yaml` | Revisar até 2027-04 (5.9) |
| Istio (lab local) | 1.31.1 | ~2027-02 (6 semanas depois da 1.33) | [releases suportadas](https://istio.io/latest/docs/releases/supported-releases/) | Trimestral (5.12); a 1.29 sai de suporte em 2026-10-12 |
| Demais charts do lab local | `platform/local/versions.env` (cert-manager 1.21.2, kube-prometheus-stack 92.3.0, Loki 7.3.0, Alloy 1.13.1, Tempo 3.1.0, OpenTelemetry Collector 0.176.0, Argo CD 10.10.3, Gatekeeper 3.23.1, Trivy Operator 0.37.0, Velero 12.2.1, Chaos Mesh 2.8.4, metrics-server 3.14.0) | cada projeto mantém as versões recentes | releases de cada projeto | Trimestral (5.12); vários charts da Grafana migraram para `grafana-community/helm-charts` (o do Tempo já vem de lá): confira o repositório de cada um antes do bump |
| Imagens dos serviços emulados | registry 3.1.2, Versity S3 Gateway 1.8.0, Soft Serve 0.12.3, cloud-provider-kind 0.12.0, PostgreSQL 17 | sem data fixa | `terraform/envs/local/images.tf` | Trimestral (5.12) |

## 5. Procedimentos

### 5.12 Lab local (charts, imagens, kind)

1. Para cada chart de `platform/local/versions.env`: leia as notas da release, rode
   `helm pull <chart> --repo <repo> --version <nova>` e grave a versão e o `sha256sum` do `.tgz`.
2. Atualize os digests em `platform/local/values/*.yaml` (`docker buildx imagetools inspect <imagem>:<tag>`
   devolve o digest do índice multi-arquitetura). O check `helm-template-local` recusa imagem sem digest.
3. Gatekeeper: suba `GATOR_VERSION` (`scripts/update-tool-checksums.sh gator <versão>`) junto com
   `GATEKEEPER_VERSION`; o check `local-versions` exige as duas iguais.
4. Imagens dos serviços emulados: `terraform/envs/local/images.tf` (o teste exige digest em todas).
5. Rode `make verify` e `make e2e` (ou deixe o job `e2e` do CI provar no PR) e registre no CHANGELOG.

### 5.1 Ferramenta do harness (terraform, tflint, ruleset AWS, trivy, actionlint, shellcheck, kubeconform, gitleaks, kubectl, helm)

```bash
scripts/update-tool-checksums.sh trivy 0.76.0   # baixa o arquivo de checksums oficial da release
make tools && HARNESS_STRICT=1 make verify
git diff tools/ .tflint.hcl                     # versions.env + checksums.txt (+ .tflint.hcl para o ruleset)
```

O script lê o arquivo de checksums publicado na release exata (shellcheck não publica: o script baixa
os três artefatos e calcula o SHA256). Leia as release notes antes; para o trivy, achados novos
aparecem com a ferramenta nova, porque o harness usa as regras embutidas (`--skip-check-update`).

### 5.2 Terraform CLI

Atualize com `scripts/update-tool-checksums.sh terraform <versão>`. `required_version` só muda se a
versão mínima precisar subir (todos os `versions.tf` iguais — checado por `version-consistency`).

### 5.3 Providers (aws, random) e lock multi-plataforma

1. Revise o CHANGELOG/upgrade guide do provider (na v6: `data.aws_region.current.region` no lugar de
   `.name`, argumentos write-only, atributo `region` por recurso).
2. Mesma restrição em todos os `versions.tf` (o PR do Dependabot só altera os roots).
3. Em `terraform/bootstrap` e `terraform/envs/lab`:
   ```bash
   terraform init -backend=false -upgrade
   terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64
   ```
4. `HARNESS_STRICT=1 make verify` (o check `terraform-lockfiles` exige 4 hashes `h1:` por provider).

### 5.4 Versão do Kubernetes

Mudar `cluster_version` é mudança de contrato (versão + PR no dx01v2). Antes: release notes do EKS,
compatibilidade do LBC e do ESO, versões padrão dos add-ons. Atualize `K8S_SCHEMA_KUBERNETES_VERSION`
em `scripts/harness.sh`. O node group acompanha a versão do cluster; os add-ons usam a versão padrão
do EKS para a versão escolhida (`data.aws_eks_addon_version`, `most_recent = false`).

### 5.5 AWS Load Balancer Controller

1. Leia as release notes (mudanças incompatíveis, CRDs).
2. `platform/versions.env`: `LBC_CHART_VERSION` (desde a v3 o chart tem a mesma versão do app).
3. Digest da imagem: `docker buildx imagetools inspect public.ecr.aws/eks/aws-load-balancer-controller:v<versão>` →
   `platform/values/aws-load-balancer-controller.yaml`.
4. Política IAM da tag exata:
   `curl -fsSLo terraform/modules/eks/policies/aws-load-balancer-controller-v<versão>.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v<versão>/docs/install/iam_policy.json`,
   apague a versão anterior, atualize `load_balancer_controller_version` em
   `terraform/modules/eks/pod_identity.tf` e `LBC_IAM_POLICY_SHA256` (`sha256sum` do arquivo).
5. Em um cluster existente, o Helm não atualiza CRDs: aplique os CRDs da mesma versão antes do upgrade.

### 5.6 External Secrets Operator

`ESO_CHART_VERSION`, digest da imagem (usada também pelo webhook e pelo cert controller) e a versão de
API dos CRDs (`external-secrets.io/v1` hoje). Se a API mudar, é mudança de contrato.

### 5.6.1 OpenTelemetry Collector (nuvem e lab local)

O lab local e a camada de plataforma em nuvem usam o mesmo chart (`OTEL_COLLECTOR_CHART_VERSION` e
`OTEL_COLLECTOR_CHART_SHA256` em `platform/versions.env`) e o mesmo digest de
`otel/opentelemetry-collector-contrib` (o `helm-template` recusa digests diferentes). O
`platform/install.sh`, o harness e o lab local recusam um arquivo do chart com outro SHA256. Na troca:
leia as notas da release do Collector (componentes renomeados, como `otlp_grpc` e `k8s_attributes`),
atualize o digest em `platform/values/otel-collector.yaml` e em
`platform/local/values/otel-collector.yaml`, a versão e o SHA256 do chart em `platform/versions.env` e
rode `make verify` e `make e2e` (o lab local prova o pipeline; o exporter do X-Ray só roda em nuvem).

### 5.6.2 Charts do perfil cloud `full`

`platform/full/charts.txt` é a tabela do perfil `full`: repo, chave de versão, chave SHA256, chart,
release, namespace e lista de arquivos de values. As versões, os SHA256 dos archives e os digests das
imagens devem continuar iguais aos de `platform/local/versions.env`; os arquivos em
`platform/values/full/` só acrescentam ou substituem configurações específicas da AWS. Para atualizar
um chart, leia as notas upstream, atualize o pin e os values locais primeiro, compare os overlays e
re-renderize os 15 charts com `helm-template-local` e `helm-template-full`. O check compara o arquivo
baixado com o SHA256, rejeita imagens sem digest, Services `LoadBalancer`/`NodePort` e placeholders,
e confere as saídas específicas do Collector, Velero, Gatekeeper e Trivy. Não declare instalação AWS:
ela segue `não executado em nuvem (v2)` até um relatório de execução.

O tamanho documentado vem de `scripts/platform-sizing.sh`: recebe a quantidade de nós e os renders
produzidos pelo check e soma CPU/memória solicitados por pods, init containers, réplicas, DaemonSets
por nó e recursos do Prometheus/Alertmanager. Se mudar versão, values ou réplicas, rode o harness,
atualize juntos a quantidade de nós e os requests em `docs/CUSTOS.md`, e confira a linha `SUMMARY`/a
saída do check `platform-sizing`. Requests não são utilização observada; o dimensionamento em AWS
continua sem validação de nuvem.

### 5.7 Schemas do kubeconform

`K8S_SCHEMA_REF` (yannh/kubernetes-json-schema) e `CRD_SCHEMA_REF` (datreeio/CRDs-catalog) em
`scripts/harness.sh` apontam para commits fixos:
`gh api repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/clustersecretstore_v1.json`.
Veja a nota sobre o schema do ESO em `docs/HARNESS.md`.

### 5.8 Digests de imagens e actions

Devcontainer: `docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu-24.04`.
Actions (fora do Dependabot): `gh api repos/<o>/<r>/git/ref/tags/<tag>`; se `object.type == "tag"`,
siga `gh api repos/<o>/<r>/git/tags/<sha>`; use o SHA do commit com `# vX.Y.Z`.

### 5.9 Revisão das exceções do trivy

Para cada entrada de `.trivyignore.yaml` perto do `expired_at`: o motivo ainda vale? Se sim, renove
por até ~7 meses com a justificativa atualizada; se não, corrija o código e remova a entrada.

## 6. Resposta a problemas

| Situação | Primeiros passos |
|---|---|
| CI vermelho | Leia o primeiro `FAIL` (o log do check vem logo abaixo). Corrija no código; nunca enfraqueça o check. Reproduza com `HARNESS_STRICT=1 make verify` |
| Vulnerabilidade | Alerta do Dependabot ou advisory: atualize por PR. Em ferramenta do harness: 5.1. Reporte privado: `SECURITY.md` |
| Alerta de custo (e-mail do budget) | `AWS_REGION=<região> scripts/leftovers.sh`; se houver lab de pé, rode o destroy; confira o Cost Explorer |
| Credencial exposta | Revogue/gire na hora (IAM, GitHub). Verifique o CloudTrail. Reescrever histórico é decisão do mantenedor |
| Sobras após o destroy | Siga a saída de `scripts/leftovers.sh` e a seção de sobras do `docs/RUNBOOK.md`; registre no `cloud_run_report` |

## 7. Registro de execuções em nuvem

Toda rodada gera uma issue com o template `cloud_run_report` (data, região, commits, passos, duração,
custo observado, problemas, sobras). A matriz de status do README só muda com essa evidência.

## 8. Responsáveis

Mantenedor: @maringelix (decisões, merges, rodadas em nuvem). Agentes de IA seguem o `AGENTS.md`.
