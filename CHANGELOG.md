# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Added

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

- README status matrix: repository settings as code are applied (read back with `gh api`), no
  longer `planned`.

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
