# Publishing tx01v2

Checklist for publishing a repository with the v2 protections. Follow the order; each item identifies
the command or place to check. Initial repository creation is distinct from ongoing changes, which
use pull requests once the ruleset is active. Fork onboarding starts in the
[central guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md).

## Before publication

- [ ] `HARNESS_STRICT=1 make verify` passes in Linux or the devcontainer.
- [ ] The initial private repository commit has been pushed to `main` and CI is green.
- [ ] `gitleaks git` reports no secrets in the complete history; the harness uses this mode whenever commits exist.
- [ ] No real identifiers: `policy-identifiers` passes and a human has reviewed `docs/`.
- [ ] `docs/LESSONS_LEARNED.md` is present; the README and documentation index link to it.
- [ ] The README status matrix has been reviewed: change `verified locally` to `verified in CI` only
  after successful CI; cloud claims remain `not run in the cloud (v2)` until a `cloud_run_report`.
- [ ] Repository description and topics are set, for example
  `gh repo edit maringelix/tx01v2 --description ... --add-topic terraform`.
- [ ] Documentation, agent instructions and public templates are in English.

## Publication

- [ ] `gh repo edit maringelix/tx01v2 --visibility public --accept-visibility-change-consequences`
- [ ] Run `scripts/repo-guardrails.sh maringelix/tx01v2`: vulnerability alerts, Dependabot security
  updates, squash-only merges, `delete_branch_on_merge`, issues, a read-only default `GITHUB_TOKEN`
  without PR approval, the `main` ruleset, secret scanning and push protection, private vulnerability
  reporting, approval for workflows from external contributors' fork PRs and the `lab` environment
  with the invoking user as required reviewer and `main` as its only deployment branch.
  The script fails if Actions is disabled and identifies fork-specific settings still needed in
  `FORK.md`. It reports applied settings, skips, notes and failures.

For a fork, replace the owner/repository argument with your own. Visibility changes and repository
settings are explicit maintainer operations, not a side effect of documentation or CI verification.

## Main ruleset (`.github/rulesets/main.json`)

- Blocks deletion and force pushes; requires a PR, with zero approvals for a solo maintainer,
  `dismiss_stale_reviews_on_push` and `required_review_thread_resolution`; squash merges only.
- Required strict checks from GitHub Actions: `static`, `test` and the local-lab `e2e`.
- Administrator bypass uses `pull_request` mode and is reserved for emergencies, such as an external
  failure blocking an urgent security fix. Record the reason in the PR. Do not bypass failed or
  pending checks to deliver ordinary changes.

## Stable job IDs

Changing a job ID can break branch protection. Current jobs:

| Workflow | Job | Required by the ruleset |
|---|---|---|
| `ci.yml` | `static` | yes |
| `ci.yml` | `test` | yes |
| `ci.yml` | `e2e` | yes |
| `terraform-plan.yml` | `plan` | no; enabled only when `AWS_PLAN_ROLE_ARN` is configured |
| `terraform-apply.yml` | `apply` | no |
| `platform.yml` | `platform` | no |
| `terraform-destroy.yml` | `destroy` | no |

## After publication

- [ ] Public `main` CI is green and the badge works; update statuses with that evidence.
- [ ] Set cloud repository variables only after bootstrap, following `docs/RUNBOOK.md`.
- [ ] Record the first real cloud run using `cloud_run_report`.
