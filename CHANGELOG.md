# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Conventional Commits](https://www.conventionalcommits.org/).

## [Unreleased]

### Added

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
    sustainment, publication checklist.
