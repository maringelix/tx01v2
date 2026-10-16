# Fork this lab

`tx01v2` is the infrastructure half of the AWS pair of this lab; the application half is
[`dx01v2`](https://github.com/maringelix/dx01v2). This page takes you from a fork to a running lab:
first on your own machine (free, no cloud account), then, if you want, in your own AWS account
(that costs money). Each repository has its own FORK.md: start here, the app page only adds what is
specific to the app.

What is proven, and how, is in the [status matrix](README.md#status-matrix). In short: the harness
and the local lab are `verified in CI`; the cloud path of v2 is `not run in the cloud (v2)`. If you
run it in AWS you are one of its first tests: follow [docs/RUNBOOK.md](docs/RUNBOOK.md) step by step
and report what happened (step 8). Most documents under `docs/` are in Brazilian Portuguese; this
page, the README, AGENTS.md and CONTRIBUTING.md are in English.

## What a fork does not bring along

GitHub copies the code and its history, nothing else:

| Not copied | What to do |
|---|---|
| Repository settings: the ruleset (pull requests only, required checks), secret scanning, private vulnerability reporting, the `lab` environment and its reviewer | step 3 applies them with one script |
| Running workflows: a fork keeps its workflows disabled until you enable them, and scheduled workflows stay off in a fork | step 2 |
| Issues: they start disabled in a fork | step 3 turns them on (the bug report and cloud run report forms) |
| Dependabot: security updates start disabled; version updates do not run in a fork by default | step 3 turns security updates on; version bumps arrive when you sync (step 9) |
| Repository variables and secrets | the lab never needs a secret; the cloud path needs variables (step 7) |

A fork of a public repository is public, and so are its workflow logs.

## 1. Fork the pair

Fork both [`maringelix/tx01v2`](https://github.com/maringelix/tx01v2) and
[`maringelix/dx01v2`](https://github.com/maringelix/dx01v2) into your **personal account** and **keep
the names**: the cloud roles that the bootstrap creates trust exactly `<you>/tx01v2` and
`<you>/dx01v2`. Clone both next to each other:

```bash
git clone https://github.com/<you>/tx01v2.git
git clone https://github.com/<you>/dx01v2.git
```

You need Linux or WSL 2 (Ubuntu) with bash >= 4.4, curl, unzip, xz, git, make, Docker and the GitHub
CLI signed in as yourself (`gh auth login`). On Windows or macOS you can open each clone in its
devcontainer instead (VS Code with Docker Desktop): it has Docker-in-Docker and installs the tools,
and `make e2e` runs inside it (verified locally with `LOCAL_PROFILE=core`).

## 2. Enable Actions

In each fork, open the **Actions** tab and click **I understand my workflows, go ahead and enable
them**. Until you do, the required checks never report and no pull request can be merged.

## 3. Apply the repository settings

```bash
cd tx01v2 && scripts/repo-guardrails.sh <you>/tx01v2
cd ../dx01v2 && scripts/repo-guardrails.sh <you>/dx01v2
```

The script is idempotent and applies what the original repository has: vulnerability alerts and
Dependabot security updates, issues, squash-only merges, a read-only default `GITHUB_TOKEN`, the
ruleset of `.github/rulesets/main.json` (pull requests only; here the required checks are `static`,
`test` and `e2e`), secret scanning with push protection, private vulnerability reporting, approval of
workflow runs from forks of external contributors, and the `lab` environment (you as the required
reviewer, deployments from `main` only). It stops with a clear message while Actions are still
disabled, and its notes list what you should change by hand (step 5). Run it again after any change
of the ruleset. On Windows, run it from WSL or Git Bash.

## 4. Run the local lab (free)

```bash
make tools                     # the pinned tools into .tools/, each one SHA256-verified
HARNESS_STRICT=1 make verify   # static checks and terraform test: what the CI jobs static and test run
make e2e                       # the whole local lab: apply, platform, 39 probes, destroy
```

`make e2e` builds the platform of [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md) on Docker: a kind cluster
with emulated ECR, RDS, S3, load balancer and git server, then Istio ambient, cert-manager, External
Secrets, Prometheus/Alertmanager/Grafana, Loki/Alloy, Argo CD, Gatekeeper, Trivy Operator, Velero and
Chaos Mesh. It proves each piece with real traffic and always destroys the lab, also after a failure.
It needs about 8 GB of memory for Docker and takes 20-40 minutes on a laptop (about 10 in CI): run
one lab at a time. With 7 GB, `LOCAL_SIZE=small` installs the same platform with smaller limits and
short retention (proved with the app of dx01v2, [docs/LAB_LOCAL.md](docs/LAB_LOCAL.md)). To keep the
lab up while you study it:

```bash
LOCAL_PROFILE=core make local-up   # core, observability, operations or full (the default)
make local-check                   # the probes of what is installed
make local-down                    # destroy, then the leftover check
```

The app comes next: follow the local integration procedure in your `dx01v2` clone to deploy it on
this platform the GitOps way (see its [FORK.md](https://github.com/maringelix/dx01v2/blob/main/FORK.md)).

## 5. Make the fork yours

`main` takes pull requests only now. Open one that replaces `@maringelix` with your user in
`.github/CODEOWNERS`; its CI (`static`, `test`, `e2e`) takes about 15 minutes and you merge it
yourself. The README badge, the family table and the security contact keep pointing to the original
repositories: change them if you like, nothing depends on them.

## 6. Keep your changes testable

Every pull request of your fork runs the same harness as the original, so
`HARNESS_STRICT=1 make verify` before a push saves a CI round. A change to `platform/local` or
`terraform/envs/local` is proven only by `make e2e`. To test a tx change with the app, follow the
local integration procedure in the matching `dx01v2` runbook or let the dx CI clone this checkout.

## 7. Your own AWS account (costs money)

Before the first apply:

- Read the [cost section of the README](README.md#cloud-path-costs-money) and [docs/CUSTOS.md](docs/CUSTOS.md) (reference
  prices: check the current ones). `core` is estimated at US$0.26–0.32/hour; `full`, with larger
  nodes, at US$0.29–0.40/hour. EKS, its nodes, the NAT gateway, the load balancer, the WAF and RDS
  bill by the hour while the lab is up, and free tiers and trial credits change often: check what
  your account covers. The bootstrap creates a monthly budget with alerts, but a budget only warns,
  it stops nothing. Destroy on the same day.
- Use a **dedicated AWS account** (the apply identity can manage the AWS service families used by the
  lab; most resource creation APIs are scoped to those service families, while IAM roles, the Velero
  bucket and optional Route53 records are further restricted), an
  administrator with MFA for the bootstrap, the AWS CLI v2 and `jq`.

Then, from the root of your `tx01v2` clone:

1. **Bootstrap** (once, from your machine, with the administrator credentials): copy
   `terraform/bootstrap/terraform.tfvars.example` to `terraform.tfvars` (git-ignored) and set
   `github_owner` to your GitHub user and `budget_alert_emails` to an address you read. Neither has a
   usable default: the placeholders are refused, so the roles can only trust your forks. Set the three
   numeric GitHub IDs too (`github_owner_id`, `tx01v2_repository_id`, `dx01v2_repository_id`): GitHub
   writes them into the OIDC subject of every repository created after 2026-07-15 (your fork), and the
   roles trust that exact subject. `scripts/repo-guardrails.sh` prints them, or:
   `gh api users/<you> --jq .id`, `gh api repos/<you>/tx01v2 --jq .id`, `gh api repos/<you>/dx01v2 --jq .id`.
   For optional DNS/HTTPS, set `lab_route53_zone_id` in this bootstrap file to your existing public
   hosted zone; use the same ID in the tx01v2 DNS secret later. Leave it empty for HTTP-only. This
   limits the plan/apply roles' Route53 permissions to that zone.
   A repository that predates 2026-07-15 must opt in to immutable subject claims first (Settings >
   Actions > General > OpenID Connect). If the account already has a GitHub OIDC provider, set
   `create_github_oidc_provider = false`: it is read by its URL and never changed.

   ```bash
   export PATH="$PWD/.tools/bin:$PATH"   # terraform and kubectl from make tools
   cd terraform/bootstrap && terraform init && terraform apply
   terraform output -raw backend_hcl >../envs/lab/backend.hcl
   ```

   The bootstrap state stays local (git-ignored): keep a backup of it.
2. **Repository variables**: the bootstrap prints the ones it knows, ready for `gh`:

   ```bash
   terraform output -json github_variables_tx01v2 | jq -r 'to_entries[] | "\(.key)=\(.value)"' >/tmp/tx01v2.env
   gh variable set -f /tmp/tx01v2.env -R <you>/tx01v2
   terraform output -json github_variables_dx01v2 | jq -r 'to_entries[] | "\(.key)=\(.value)"' >/tmp/dx01v2.env
   gh variable set -f /tmp/dx01v2.env -R <you>/dx01v2
   ```

   Then add the ones you choose (`LAB_ALLOW_ENDPOINT_FROM_ANYWHERE`, and your own admin role in
   `LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS`) and the address you operate from as a **secret**,
   `LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS` (`gh secret set LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS -R <you>/tx01v2`):
   [docs/RUNBOOK.md](docs/RUNBOOK.md), section 3. Variables are not secret: never put a credential or
   your home address in one. The workflows mask every CIDR of the secret in their logs.
   For `full`, set the public repository variables before the first plan and keep them through
   destroy:

   ```bash
   gh variable set LAB_NODE_INSTANCE_TYPES --body '["t3.large","t3a.large"]' -R <you>/tx01v2
   gh variable set LAB_NODE_DESIRED_SIZE --body '2' -R <you>/tx01v2
   ```

   Optionally set the secret `SLACK_WEBHOOK_URL` for warning and critical Alertmanager notifications.
   `core` uses the defaults and does not need the `LAB_NODE_*` variables.
3. **Run**: choose `core` (the default) or `full`. For `full`, first merge the R4 code in both the tx
   and dx repositories, then run `terraform-plan`, review the node types and capacity, and dispatch
   `terraform-apply`. After approval of the `lab` environment, dispatch `platform` with
   `action=install` and the same `profile`. Deploy the app through its dx workflow: it commits the
   image digest to `gitops/aws`; Argo CD syncs it and reports `Synced`/`Healthy`. Then run the smoke
   and Velero restore drill and dispatch `terraform-destroy`, which ends with the leftover check.
   See [docs/RUNBOOK.md](docs/RUNBOOK.md), sections 3 to 9. The workflows take `github_owner` from
   the owner of the repository.

The direct dx push workflow remains available with the `core` profile. With `full`, Argo CD owns the
application and self-heal can revert changes not committed to `gitops/aws`. Switching from `full` to
`core` is unsupported: destroy the lab, remove the `LAB_NODE_*` variables, apply again, and install
`core`.

Your fork is public, and so are its workflow logs: the AWS account ID can show up in them. Never paste
credentials into an issue or a pull request.

## 8. Report the run

Open a **Cloud run report** (date, region, commits, duration, cost, problems and the redacted output
of `scripts/leftovers.sh`) in your fork or, better, in the
[original repository](https://github.com/maringelix/tx01v2/issues/new/choose): every report makes the
lab better for the next person.

## 9. Keep the fork up to date

Use **Sync fork** on the GitHub page of each fork, or pull the original into a branch and open a pull
request. Run `scripts/repo-guardrails.sh` again when `.github/rulesets/main.json` changed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| A pull request waits forever for `static`, `test` or `e2e` | Actions are still disabled in the fork: step 2 |
| `repo-guardrails.sh` fails with "the workflows of this fork are not enabled yet" | step 2, then run it again |
| `full` pods stay Pending | compare requests with the selected node types in `docs/CUSTOS.md`, check Spot capacity, then inspect `kubectl describe pod`; do not run the full chart set on the default `t3.medium` group |
| Argo CD reports `ComparisonError` or the app is OutOfSync | confirm the dx `gitops/aws` branch exists, the repo is public or has an Argo CD credential, and the source path is correct; inspect the dx workflow logs |
| `make e2e` gets killed or Docker freezes | give Docker about 8 GB of memory (Docker Desktop on WSL 2: `memory=8GB` under `[wsl2]` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`) and run one lab at a time; with 7 GB, `LOCAL_SIZE=small make local-up`; with less memory, `LOCAL_PROFILE=core make e2e` proves the base layers |
| Port 5001 is already in use | another local lab or registry is running: `make local-down`, `docker ps` |
| Something of the local lab is left after an interruption | `make local-down` (destroy and leftover check) |
| Bootstrap: `Set github_owner ...` or `Replace the placeholder ...` | put your values in `terraform/bootstrap/terraform.tfvars` |
| Bootstrap: the GitHub OIDC provider already exists | `create_github_oidc_provider = false` with its ARN ([docs/RUNBOOK.md](docs/RUNBOOK.md), section 2) |

## Contributing back

Pull requests to the original repository are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). Their
workflow runs wait for the maintainer's approval, and the same harness decides.
