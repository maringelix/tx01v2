# AGENTS.md

Instructions for AI coding agents and humans working in `tx01v2`. `CLAUDE.md` points here; this file
is the source of truth. The full rule list (pt-BR) is [docs/GUARDRAILS.md](docs/GUARDRAILS.md).

## 1. Mission and context

- `tx01v2` is the AWS infrastructure half of a public, educational DevOps lab (v2 family: `tx01v2` +
  `dx01v2` on AWS now; `tx02v2`/`dx02v2` on Azure and `tx03v2`/`dx03v2` on GCP are planned).
- It must stay healthy without any cloud account: every claim is backed by the local harness or
  carries a status label (`verified in CI`, `verified locally`, `not run in the cloud (v2)`, `planned`).
- Current status: the harness (`make verify`) passes locally in a Linux container. **Nothing of v2
  has run in AWS** (bootstrap, apply, platform, destroy are `not run in the cloud (v2)`).
- The interface with `dx01v2` is [docs/CONTRATO.md](docs/CONTRATO.md) (contract v1, owned here).

## 2. Non-negotiable rules

1. Never commit secrets or real identifiers (AWS account IDs, hostnames, public IPs, e-mails). Use
   `123456789012`/`<ACCOUNT_ID>`, `203.0.113.10/32`/`<YOUR_IP>/32`, `you@example.com`.
2. Never run cloud-mutating actions — `terraform apply`/`destroy` against AWS, `kubectl`/`helm` against
   a cloud cluster, AWS write API calls, dispatching cloud workflows — unless a human explicitly asks
   for that action in the current task. Read-only `gh api` lookups are fine.
3. Never weaken a gate: no `continue-on-error`, no `|| true` on checks, no `--no-verify`, no disabled
   or skipped checks, no new scanner ignores without `statement` + `expired_at`.
4. Never widen IAM, network, RBAC or CORS without stating why in the PR.
5. Keep the contract: changes need coordinated PRs in `tx01v2` and `dx01v2` and a version bump.
6. Pin every new dependency, action and image (version + SHA256, 40-char SHA + `# vX.Y.Z`, digest)
   and update the docs in the same change.
7. Once the ruleset is on, never push to `main`: pull requests only.

## 3. Repo map

```text
.github/workflows/      ci.yml (harness), terraform-plan/apply/destroy.yml, platform.yml (cloud, dispatch only)
.github/rulesets/       main.json: branch ruleset applied by scripts/repo-guardrails.sh
.devcontainer/          Linux environment pinned by digest (runs make tools)
docs/                   pt-BR docs: architecture, contract, runbook, costs, guardrails, harness, sustainment
platform/               install.sh / uninstall.sh, versions.env, Helm values, manifests (never Terraform)
scripts/harness.sh      every check of the harness (stages static, test, all, list)
scripts/install-tools.sh            pinned tools into .tools/ (SHA256-verified)
scripts/update-tool-checksums.sh    bump a tool: versions.env + checksums.txt from upstream checksums
scripts/leftovers.sh    read-only scan for billable/orphaned lab resources after a destroy
scripts/repo-guardrails.sh          repository settings via gh api (run by the maintainer)
scripts/lib/            shared bash helpers (common, tools, aws)
terraform/bootstrap/    state bucket, GitHub OIDC + 3 roles, budget (local state, applied by a human)
terraform/envs/lab/     lab root: modules + admin-token secret + contract SSM parameters
terraform/modules/      kms, network, eks, rds, ecr, waf
terraform/tests/mocks/  shared mock data for terraform test
tools/                  versions.env and checksums.txt of the harness tools
```

## 4. Setup

- Linux or WSL 2 (Ubuntu) with bash >= 4.4, curl, unzip, xz, git, make: `make tools`.
- Windows/macOS: open the repo in the devcontainer (it runs `make tools`). macOS without the
  devcontainer: `brew install bash`.
- No cloud credentials are needed for anything except the cloud workflows and `scripts/leftovers.sh`.

## 5. Harness commands

| Command | Runs | When |
|---|---|---|
| `make tools` | `scripts/install-tools.sh` (all pinned tools) | first time, after a tool bump |
| `make static` | `scripts/harness.sh static`: policies, fmt, validate, lock files, tflint, trivy (x2), actionlint, shellcheck, kubeconform, helm template, gitleaks | every change |
| `make test` | `scripts/harness.sh test`: `terraform test` for bootstrap and envs/lab (mocked AWS) | every Terraform change |
| `HARNESS_STRICT=1 make verify` | static + test with SKIP = FAIL (what CI runs) | before every PR |
| `scripts/harness.sh list` | lists all checks | any time |

## 6. Definition of Done

- [ ] `HARNESS_STRICT=1 make verify` green locally; CI green (`static`, `test`).
- [ ] Docs, README status matrix and `CHANGELOG.md` (`[Unreleased]`) updated in the same PR.
- [ ] No new unexplained scanner ignores; no weakened checks.
- [ ] Contract respected (or bumped with a linked `dx01v2` PR).
- [ ] New dependencies pinned; no secrets or real identifiers.

## 7. Playbooks

**Maintainer / sustentação.** Follow [docs/SUSTENTACAO.md](docs/SUSTENTACAO.md): react to a red
scheduled CI, merge monthly Dependabot PRs, run the quarterly review (tools, charts, image digests,
Kubernetes/PostgreSQL calendar, kubeconform schema commits, ignores close to `expired_at`).

**Reviewer.** Check the PR template boxes; confirm the harness is green; look for widened IAM/RBAC/
network, unpinned references, ignores without justification, docs claiming more than the harness
proves, and contract changes without a version bump.

**Dependency updater.** One Dependabot group per PR. Read the release notes. Terraform providers:
keep the same constraint in every `versions.tf` and regenerate both lock files for the four
platforms (docs/SUSTENTACAO.md 5.3). Actions: confirm the new SHA matches the tag comment. Harness
tools are bumped only with `scripts/update-tool-checksums.sh`.

**Cloud operator** (only with explicit human approval for that action): follow
[docs/RUNBOOK.md](docs/RUNBOOK.md), always finish with destroy + `scripts/leftovers.sh`, and file a
`cloud_run_report` issue. Never leave a lab running unattended.

## 8. Common tasks

- Add a Terraform input: variable in `terraform/envs/lab/variables.tf` with a validation, pass it to
  the module, add a test (positive and `expect_failures`), document it in `docs/RUNBOOK.md` if CI must
  pass it as `TF_VAR_*`.
- Add a resource that needs computed values in tests: add a `mock_resource` default (valid ARN/ID
  format) to `terraform/tests/mocks/aws.tfmock.hcl`; assert inside the module with a run block
  `module { source = "../../modules/<name>" }`.
- Bump a harness tool: `scripts/update-tool-checksums.sh <tool> <version>`, then `make tools verify`.
- Bump the AWS Load Balancer Controller or External Secrets: docs/SUSTENTACAO.md 5.5 / 5.6 (chart,
  image digest, IAM policy file + SHA256, CRDs).
- Add a check: docs/HARNESS.md ("Como adicionar um check").

## 9. When to stop and ask a human

- Any action that changes or costs money in a cloud account, or needs credentials.
- A check fails for a reason outside the repository (upstream outage, broken catalog) — report it;
  do not weaken or skip the check.
- A contract change, an IAM/RBAC/network widening, or a new scanner ignore.
- Rewriting git history, force-pushing, changing repository settings or rulesets.
- Anything that would make a README/doc claim stronger than the evidence.
