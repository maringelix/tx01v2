# tx01v2 guardrails

A guardrail combines a rule with its enforcement mechanism, automated whenever possible. This
document records repository rules, where they are enforced and what they do not guarantee.
Types: `blocking` (fails the harness/CI/apply), `alert` (notifies) and `process` (human/agent discipline).

## Rules

| ID | Rule | Reason | Enforcement | Type |
|---|---|---|---|---|
| SEC-01 | No secrets in the repository | Public repository; committed history persists | `gitleaks` in harness and pre-commit | blocking |
| SEC-02 | No real identifiers: account IDs only `123456789012`/`<ACCOUNT_ID>`, example-domain emails, private or RFC 5737 addresses | Avoid exposing accounts and people | `policy-identifiers` | blocking |
| SEC-03 | Passwords are ephemeral and sent only through write-only arguments `password_wo`/`secret_string_wo` | Never store their value in Terraform plans/state | `policy-terraform`; `rds_password_never_in_plan_or_state` and `admin_token_is_write_only` tests | blocking |
| SEC-04 | GitHub to AWS uses only OIDC, exact immutable `sub` via StringEquals and `aud=sts.amazonaws.com`, with owner/repository numeric IDs | No static keys, foreign repo/branch access or inheritance after an account name is deleted and re-registered | `terraform/bootstrap/tests/oidc_roles.tftest.hcl`; `scripts/repo-guardrails.sh` checks the repository subject | blocking |
| SEC-05 | `id-token: write` only in a cloud job that needs it, never `ci.yml` | Limit credential issuance | `policy-workflows` | blocking |
| SEC-06 | Restrict the EKS public endpoint to `endpoint_public_access_cidrs`; `0.0.0.0/0` requires explicit `allow_endpoint_from_anywhere=true` | Make endpoint exposure an explicit operator decision | Variable validation and `tests/validations.tftest.hcl` | blocking |
| SEC-07 | Apply avoids PowerUserAccess: reviewed AWS families, IAM names `tx01v2-*`, exact state/Velero bucket ARNs and configured Route53 zone; deny changes to `role/tx01v2-gha-*`. Plan only reads the declared services/zone | A fork cannot change its own CI identities or administer unrelated service families | `role_permissions_follow_the_contract` in `oidc_roles.tftest.hcl` | blocking |
| SEC-08 | Cloud PR plans only for PRs from the same repository, checking `head.repo.full_name==github.repository` | Foreign forks never receive cloud credentials | `terraform-plan.yml` | process |
| SEC-09 | Bootstrap requires a real `github_owner`; rejects `your-github-user` and `you@example.com` for budget alerts | A fork must trust its own repos and send warnings to a monitored address | Variable validations; `placeholder_owner_is_refused` and `placeholder_alert_email_is_refused` | blocking |
| SEC-10 | Scripts act only on lab-owned targets: contract-selected cluster and `Project=tx01v2` tag, temporary kubeconfig/Helm settings, fixed local kind context, ownership-aware leftovers | Operators may already have other clusters, contexts or environment variables | `policy-scripts`, `require_lab_cluster` in `scripts/lib/aws.sh`, `require_lab_context` in `scripts/lib/local.sh` | blocking |
| SEC-11 | Every role created by apply has `tx01v2-lab-boundary`: reviewed service families, EKS Auth only for the two clusters, backup-bucket S3 and optional-zone Route53; IAM writes only to create the exact owned ELB service-linked role; no organization/account administration. Apply cannot edit/remove the boundary | Bound effective privileges even if apply attaches additional policies to `tx01v2-*` roles | `boundary.tftest.hcl`, `cloud_readiness.tftest.hcl`, EKS/network module tests | blocking |
| SEC-12 | Mask every operator CIDR/IP in cloud workflow logs; replace private values in summaries and artifacts | Public Actions logs/artifacts must not reveal operator addresses | `policy-workflows` | blocking |
| SUP-01 | Harness tools pinned by version and SHA256; mismatches are fatal | Supply-chain integrity | `scripts/install-tools.sh` and `tools/checksums.txt` | blocking |
| SUP-02 | Every action uses a 40-character commit SHA and `# vX.Y.Z` comment | Tags can move | `policy-workflows` | blocking |
| SUP-03 | Multi-platform provider locks; roots initialize with `-lockfile=readonly` | Reproducible dependencies | `terraform-lockfiles` and `terraform-validate:*` | blocking |
| SUP-04 | Images pinned by digest; LBC IAM policy byte-identical to the upstream release | Dependency changes require an explicit diff | `version-consistency`, pinned devcontainer revision | blocking |
| SUP-05 | Install Trivy only through `scripts/install-tools.sh`; never trivy-action/setup-trivy, GHSA-69fq-xp46-6x23 | March 2026 supply-chain incident | `policy-workflows` | blocking |
| SUP-06 | Monthly Dependabot; group minor/patch changes and separate majors | Detect dependency drift | `.github/dependabot.yml` | alert |
| IAC-01 | Launch template sets no security groups, AMI or user data; managed node group sets no `disk_size` | v1 nodes failed to join when their template omitted the cluster security group | `policy-terraform` and EKS `nodes` tests | blocking |
| IAC-02 | Require IMDSv2 and hop limit 1 | Ordinary pods cannot read node credentials | EKS tests | blocking |
| IAC-03 | Derive subnets from `vpc_cidr` and available AZs | v1 hard-coded subnets ignored input changes | `policy-terraform` and network tests | blocking |
| IAC-04 | Terraform never talks to Kubernetes; no aws-auth or `system:masters`, only access entries | Separate infrastructure and platform layers | `policy-terraform`, `access_entries` and `control_plane` tests | blocking |
| IAC-05 | EKS `upgrade_policy=STANDARD` and `authentication_mode=API` | No extended-support surcharge or legacy authentication ConfigMap | EKS tests | blocking |
| IAC-06 | No unexcepted HIGH/CRITICAL Trivy IaC findings, including example tfvars rendering | IaC security | `trivy-config` and `trivy-config-tfvars` | blocking |
| IAC-07 | No tflint issues with the recommended preset and AWS ruleset | IaC quality | `tflint` | blocking |
| IAC-08 | Explain every IAM/network/RBAC/CORS expansion in the PR | Conscious scope review | PR template | process |
| K8S-01 | Strict kubeconform validation with commit-pinned schemas | Invalid manifests do not reach a cluster | `kubeconform` | blocking |
| K8S-02 | Namespace, RBAC and ClusterSecretStore follow the contract; deployer only reads Secrets | Least privilege | `contract-platform` | blocking |
| K8S-03 | Disable LBC service mutator; service accounts match Pod Identity associations; chart images use digests | Avoid taking over unrelated Services and silent image changes | `contract-platform` and `helm-template` | blocking |
| K8S-04 | Full charts/images stay pinned; rendered Services cannot be LoadBalancer/NodePort; Gatekeeper exemptions only cover system/platform namespaces | Platform UIs remain private and app admission stays enforced | `helm-template-full`, `kubeconform`, `contract-platform` | blocking |
| APP-01 | Version the tx/dx contract and coordinate changes in both repositories | Both sides evolve together | `docs/CONTRACT.md` and contract tests | process |
| CUSTO-01 | Monthly account budget, default USD 25, alerts at ACTUAL 50/80/100% and FORECASTED 100% | Operator controls spending | `terraform/bootstrap/budget.tf` and budget tests | alert |
| CUSTO-02 | Cheap defaults: Spot, one NAT, single-AZ RDS, one-day backups, seven-day logs | Minimize baseline hourly cost | `defaults_are_lab_friendly` | blocking |
| CUSTO-03 | Destroy fails loudly, continues after failed uninstall through owned AWS API cleanup/Terraform destroy and always checks leftovers | Failed cleanup must not silently leave an ALB billing | `scripts/destroy.sh`, workflow, simulated `destroy-flow` and `policy-workflows` | blocking |
| CUSTO-04 | Finish each cloud run with same-day destroy and a `cloud_run_report` | Avoid forgotten resources | `docs/RUNBOOK.md` | process |
| CUSTO-05 | Size optional full nodes explicitly; retain inexpensive core defaults; publish reproducible requests/costs | Make the optional profile's cost visible before apply | `platform-sizing` and `docs/COSTS.md` | alert |
| CI-01 | Harness is CI: jobs invoke `make <target>` | Same checks locally and in CI | PR review and `ci.yml` | process |
| CI-02 | No `continue-on-error: true`, `\|\| true` or `\|\| echo` in workflows; no sed edits of Terraform files | Honest gates | `policy-workflows` | blocking |
| CI-03 | Top-level `contents: read`, timeouts, concurrency, ubuntu-24.04 and `persist-credentials:false` | Least privilege and predictable execution | `policy-workflows` | blocking |
| CI-04 | CI sets `HARNESS_STRICT=1`; every SKIP becomes FAIL | No silent skipped checks | `ci.yml` and harness | blocking |
| CI-05 | Cloud workflows are manually dispatched, with protected `lab`, variable checks and typed destroy confirmation; plan has its explicit trust guard | Billable changes require intent | Cloud workflow policy | process |
| CI-06 | Scheduled CI every Monday at 06:00 UTC | Detect expired exceptions, moved URLs and new findings | `ci.yml` | alert |
| CI-07 | Local-lab `e2e` runs on every PR and must pass before merge | Prove platform behavior beyond render checks | `ci.yml` and ruleset | blocking |
| LOC-01 | Local Terraform uses no cloud provider/backend; Docker uses a local socket | Keep the local lab free of cloud mutation | `policy-terraform` and `docker_host` validation | blocking |
| LOC-02 | Local containers carry `tx01v2.lab=local`; only registry binds a host port, on 127.0.0.1; Terraform-emulated services are not privileged | No accidental exposure or ownership ambiguity | Local Terraform tests and policy | blocking |
| LOC-03 | Local charts use version/archive SHA256; images use digests; Services are ClusterIP except runtime-created gateways | Supply chain and private platform UIs | `helm-template-local`, `local-versions` and installer | blocking |
| LOC-04 | Gatekeeper constraints deny; app webhook fails closed; every policy has allowed and denied fixtures | v1 mostly used dryrun without audit | `policy-gator` and runtime policy probes | blocking |
| LOC-05 | Every platform component has a traffic/API probe; e2e always destroys and checks leftovers | State only what behavior proves | `platform/local/check.sh` and `scripts/local-lab.sh e2e` | blocking |
| LOC-06 | Preflight checks CLI/provider Docker daemon identity, network/route overlap and registry port; never adopt another state directory; make clean stays under the Makefile directory | Operators may run VPNs, other containers and labs | Simulated `local-preflight`, ownership checks and Makefile | blocking |
| MUD-01 | Main ruleset requires PRs and strict required CI; no force pushes | Every change is reviewed through the harness | Ruleset and `scripts/repo-guardrails.sh` | blocking after publication |
| MUD-02 | Scanner exceptions need `statement` and `expired_at` within approximately seven months | Review and expire accepted risk | `trivyignore-policy` | blocking |
| MUD-03 | Conventional Commits, one subject per PR, update CHANGELOG Unreleased | Readable history | PR template | process |
| DOC-01 | README/docs use exact evidence statuses without self-ratings | Accurate public claims | `repo-structure` and review | blocking |
| DOC-02 | Update documentation with the related code | Prevent stale instructions | PR template | process |
| DOC-03 | Maintain documentation, agent instructions and public templates in English | One complete public onboarding path | English README/status checks and review | process |
| AGT-01 | Agents never mutate cloud without an explicit human request for that action | Money and security | `AGENTS.md` | process |
| AGT-02 | Agents never weaken gates or add unjustified/non-expiring ignores | The harness matters only when respected | Agent instructions and checks above | process |
| AGT-03 | Agents ask a human in the cases listed by AGENTS | Expensive decisions belong to a human | `AGENTS.md` | process |

## Exceptions

A scanner exception is an ignore entry. To add one:

1. Confirm the finding reflects a deliberate lab choice rather than an implementation defect.
2. Add `id`, narrowly scoped `paths`, a `statement` explaining acceptance/compensation, and
   `expired_at` within approximately seven months to `.trivyignore.yaml`.
3. Explain it in the PR. `trivyignore-policy` rejects absent justification/deadlines, expired entries
   and excessive durations. Trivy stops honoring an entry when it expires.

Recorded exceptions, checked on 2026-10-16: AWS-0040/AWS-0041 for the CIDR-controlled public endpoint;
AWS-0132 for SSE-S3 rather than a CMK on the state bucket; KSV-0056 because the deployer must create
Services, Ingresses and NetworkPolicies. Accepted known MEDIUM/LOW findings do not fail the gate:
one-day backups (AWS-0077), disabled deletion protection (AWS-0177), disabled Performance Insights
(AWS-0133), state-bucket access logging (AWS-0089) and deployer Secret reads (KSV-0113).

KSV-0014 is an additional time-bound exception only for the disposable local OWASP CRS WAF probe.
Upstream provides no read-only-root variant. The probe is exposed through the ephemeral kind
Gateway and still uses non-root, no privilege escalation, dropped capabilities, RuntimeDefault
seccomp and read-only ConfigMap mounts. Its exception expires on 2027-04-30.

## Limits

- AWS v2 has never run: mocked provider tests prove configuration, not that AWS accepts every call
  or that the managed services work together.
- `tx01v2-gha-apply` has high privileges within the declared service families. Some create APIs
  cannot scope to an ARN before the resource exists. IAM, backup buckets, state and Route53 have
  tighter scope. Use a dedicated account and configure the bootstrap's hosted zone before DNS.
- Account IDs may appear in public workflow logs, including role inputs/bucket names. AWS does not
  treat them as secrets, but use a dedicated account. `mask-aws-account-id` masks after authentication;
  the plan summary substitutes `<ACCOUNT_ID>`.
- Repository variables, including public LAB configuration, may appear in logs; never store private values there.
- Budgets notify; they do not stop resources. Spot interruption can remove nodes.
- The LBC IAM policy is upstream's policy, including wildcard resources constrained by tags.
- `scripts/leftovers.sh` inventories the service families used by the lab, not arbitrary manually created resources.
- Kubeconform's ClusterSecretStore schema is pinned to 2026-06-02; see `docs/HARNESS.md`.
- AWS full has never been installed. Trivy Pod Identity and reads of the two private ECR repositories
  are configured, but actual private scanning awaits cloud homologation.
- Local kind proves local platform behavior, including an optional three-node HA scenario, not AWS.
  cloud-provider-kind controls the Docker socket and creates containers; run only on a disposable
  machine or in CI, as documented in `docs/LOCAL_LAB.md`.
- Istio, monitoring-agent and chaos namespaces need privileged Pod Security for their node-level
  components. The Velero node agent also needs kubelet hostPath/root for filesystem backup, as
  documented in `docs/CONTINUITY.md`. Gatekeeper excludes platform namespaces so platform bootstrap
  does not depend on its own webhook being available.

## Verification

```bash
make tools                 # pinned tools under .tools/
HARNESS_STRICT=1 make verify
scripts/harness.sh list     # all checks and stages
AWS_REGION=us-east-1 scripts/leftovers.sh   # after destroy; requires cloud read credentials
```
