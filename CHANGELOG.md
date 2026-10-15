# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Changed

- The family table of both READMEs links the family hub `tx00v2` (roadmap, family guardrails,
  cross-repo checks).
- The edge of the local lab keeps a UUID-shaped external `X-Request-Id` as it came (EnvoyFilter
  `gateway-preserve-request-id`: `pack_trace_reason: false`); with tracing on, Envoy would otherwise
  rewrite one character of it. The probe now sends a UUID too.

### Security

- Scripts act only on what the lab created, so whoever forks it can run them on a machine and an
  account that also hold other work:
  - `platform/uninstall.sh` (it deletes every Ingress and LoadBalancer Service of the cluster) and
    `scripts/leftovers.sh` no longer read `CLUSTER_NAME` from the environment, a variable many EKS
    guides export for another cluster; the target is the contract cluster `tx01v2-lab`, and the
    platform scripts refuse a cluster without the tag `Project=tx01v2` (`require_lab_cluster`).
  - `platform/install.sh` and `platform/uninstall.sh` write the kubeconfig and the Helm repositories
    to a temporary directory: `~/.kube/config`, its current context and the Helm settings of the
    machine stay as they were. The output `update_kubeconfig_command` and `docs/RUNBOOK.md` write the
    kubeconfig of the lab to its own file (`~/.kube/tx01v2-lab.kubeconfig`).
  - The scripts of `platform/local` refuse any kube context but `kind-tx01v2-local`
    (`require_lab_context`), also when one of them runs on its own: `platform/local/uninstall.sh`
    deletes every Gateway and LoadBalancer Service of the cluster it reaches.
  - `scripts/leftovers.sh` counts as billable only the unattached Elastic IPs tagged
    `Project=tx01v2`; any other one is listed as `INFO` (not the lab's), never as something to delete.
  - New static check `policy-scripts` keeps all of this from coming back.
- `github_owner` has no default any more (`terraform/bootstrap` and `terraform/envs/lab`): a fork that
  kept the default would have created CI identities that trust the workflows of another owner. The
  bootstrap refuses the placeholders of `terraform.tfvars.example` (`your-github-user` and the alert
  e-mail `you@example.com`); the workflows pass `github.repository_owner` to the lab root. New tests
  `placeholder_owner_is_refused` and `placeholder_alert_email_is_refused`.

### Added

- Local lab, "Observability 2.0" (the last step of the v1 roadmap, never started there): Tempo 3.1.0
  (grafana-community chart 3.1.0) and the OpenTelemetry Collector contrib 0.162.0 (chart 0.176.0) in the
  observability layer; every Istio Gateway reports its spans (Telemetry `mesh-default`, provider
  `otel-tracing`); the spanmetrics connector feeds Prometheus with RED series and exemplars (exemplar
  storage on); Grafana links logs, metrics and traces (Tempo datasource, Loki derived field, exemplar
  destinations). Probes: an OTLP span reaches Tempo, the Gateway continues an incoming W3C trace and
  reports it, spanmetrics with an exemplar of the trace, Grafana datasource health and links.
- Alertmanager also posts warning and critical alerts to Slack, like the v1 channels, with the webhook
  in the Secret `monitoring/alertmanager-slack` (`LOCAL_SLACK_WEBHOOK_URL`, never in versioned values);
  without it the Slack receiver posts to the sink and a probe checks the Slack message.
- Chaos experiments with hypotheses: 100 ms of network latency (NetworkChaos) and CPU + memory stress
  (StressChaos) on the probe workload, next to the pod kill. The local lab has 34 probes (was 26).
- Local contract version 2: key `tracing.otlp-endpoint` (the OTLP/HTTP endpoint of the Collector).
- Contract version 2 (`not run in the cloud (v2)`): the cloud platform layer installs the same
  OpenTelemetry Collector (same chart and image digest, namespace `observability`), which sends the
  traces of the app to AWS X-Ray. New Pod Identity role `tx01v2-lab-otel-collector` with only the AWS
  managed policy `AWSXRayDaemonWriteAccess` (an IAM addition for the traces, tested in
  `eks.tftest.hcl`); `platform/uninstall.sh` removes the release; the `contract-platform` and
  `helm-template` checks assert the namespace, the service account, the exporter and the digest.
- `FORK.md`: forking the lab step by step (what GitHub does not copy to a fork, the repository
  settings, the local lab, your own cloud account, troubleshooting), linked from both READMEs and
  CONTRIBUTING.md; the harness requires it.
- The devcontainer has Docker-in-Docker, so `make e2e` runs inside it (verified locally with
  `LOCAL_PROFILE=core`), and declares 4 CPUs and 8 GB; the harness checks that devcontainer features
  are pinned by digest.
- `terraform/bootstrap` outputs `github_variables_tx01v2` and `github_variables_dx01v2` (the
  repository variables it knows, as in the other pairs), ready for `gh variable set -f`.
- The local lab (docs/LAB_LOCAL.md): the whole v1 platform on Docker, with no cloud account.
  - `terraform/envs/local` (providers docker 4.6.0, tls 4.4.1, random 3.9.1): network
    `tx01v2-local`, kind 1.36 cluster, emulated ECR (registry 3.1.2), RDS (PostgreSQL 17, TLS only,
    lab CA), S3 (Versity S3 Gateway 1.8.0), load balancer (cloud-provider-kind 0.12.0) and git server
    (Soft Serve 0.12.3); 10 `terraform test` runs (plan only, mocked providers).
  - `platform/local`: Gateway API 1.6.3, Istio 1.31.1 ambient, cert-manager 1.21.2 (`lab-ca`),
    External Secrets 2.12.0 (`local-secrets`), metrics-server, kube-prometheus-stack 92.3.0 with an
    in-cluster alert sink, Loki 7.3.0 + Alloy 1.13.1, Argo CD 10.10.3, Gatekeeper 3.23.1 with six
    policies from v1 in `deny`, Trivy Operator 0.37.0, Velero 12.2.1, Chaos Mesh 2.8.4; charts pinned
    by version and SHA256, images by digest; profiles `core`, `observability`, `operations`, `full`.
  - The edge keeps an external `X-Request-Id` like the ALB (EnvoyFilter
    `gateway-preserve-request-id`); Trivy Operator in ClientServer mode with the built-in Trivy server
    (Standalone scan jobs lost the report of a pod's second container to the Trivy cache lock).
  - The dx01v2 local deploy: AppProject `dx01v2`, Secret `lab-secrets/gitops-push-key`, namespace
    `monitoring` in the ambient mesh (Prometheus scrapes STRICT mTLS pods).
  - `platform/local/check.sh`: 26 probes with real traffic or API calls (mTLS and authorization,
    HTTPS through the emulated load balancer, X-Request-Id pass-through, alert delivery, logs, GitOps sync and self-heal, policy
    denials, vulnerability reports, backup/restore drill, chaos experiment with a hypothesis).
  - `scripts/local-lab.sh` (up, down, check, e2e, kubeconfig, status) and
    `scripts/leftovers-local.sh`; local contract `lab-system/lab-contract` (docs/CONTRATO.md).
  - Harness: checks `local-versions`, `helm-template-local`, `kubeconform-local`, `policy-gator`,
    `terraform-validate:envs/local`, `terraform-test:envs/local`; stage `e2e` (`local-lab-e2e`,
    `make e2e`) and the CI job `e2e`; tools kind 0.33.0 and gator 3.23.1.

### Changed

- `scripts/repo-guardrails.sh` also turns issues on (the issue forms) and requires approval for
  workflow runs from forks of external contributors; the reviewer of the `lab` environment is the gh
  user that runs it. It fails while the workflows of a fork are still disabled and notes a renamed
  repository or a CODEOWNERS that names someone else (tested against a stub gh, then applied to the
  original repository and read back with `gh api` on 2026-10-14).
- The ruleset requires the CI job `e2e` too (`.github/rulesets/main.json`, applied with
  `scripts/repo-guardrails.sh`): the local lab is a merge gate, not only maintainer discipline.
- README status matrix: repository settings as code are applied (read back with `gh api`), no
  longer `planned`.

### Fixed

- `platform/local/uninstall.sh`: the teardown no longer fails when the Service of a Gateway that is
  being deleted disappears between the listing and the delete (`--ignore-not-found`); seen in the
  app repo platform e2e, where the app Gateway still exists at teardown.

### Added (first v2)

- Initial v2 of the AWS infrastructure lab, rebuilt from scratch with the lessons of v1
  (docs/ARQUITETURA.md, "v1 → v2"):
  - `terraform/bootstrap`: S3 state bucket (versioned, TLS-only, native locking), GitHub OIDC
    provider and the contract roles `tx01v2-gha-plan`, `tx01v2-gha-apply`, `dx01v2-gha-deploy`,
    monthly cost budget with ACTUAL 50/80/100 % and FORECASTED 100 % alerts.
  - `terraform/envs/lab` with modules `kms`, `network`, `eks` (Kubernetes 1.36, access entries, Pod
    Identity, managed add-ons, Spot AL2023 nodes), `rds` (PostgreSQL 17, write-only password), `ecr`,
    `waf`; admin-token secret and the contract SSM parameters.
  - Multi-platform provider lock files (linux_amd64, linux_arm64, darwin_arm64, windows_amd64).
  - `terraform test` suites with a mocked AWS provider for both roots and every module.
  - `platform/`: AWS Load Balancer Controller v3.6.0 and External Secrets Operator 2.12.0 install and
    uninstall scripts, Helm values with images pinned by digest, namespace/RBAC/ClusterSecretStore.
  - Harness (`scripts/harness.sh`, `make verify`) with pinned, SHA256-verified tools.
  - GitHub workflows: `ci`, `terraform-plan`, `terraform-apply`, `platform`, `terraform-destroy`;
    ruleset and repository settings as code; Dependabot; issue and PR templates.
  - `scripts/leftovers.sh` to find billable leftovers after a destroy.
  - Brazilian Portuguese docs: architecture, contract v1, runbook, costs, guardrails, harness,
    sustainment, publication checklist, and `docs/LICOES_APRENDIDAS.md` (sanitized lessons learned
    from the v1 AWS lab, Nov 2025 – Mar 2026).

### Changed

- The CI (`static`, `test`) ran green on GitHub: the README status matrix now says `verified in CI`
  for those rows.
- The README family table links the Azure pair (`tx02v2`, `dx02v2`), now public.
- The README family table and AGENTS.md link the Google Cloud pair (`tx03v2`, `dx03v2`), now public.
