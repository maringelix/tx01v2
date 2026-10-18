# Runbook: a complete cloud session

Create the lab in your own AWS account, use it, destroy it and record the result.
None of these procedures has been executed in the v2 cloud
(`not run in the cloud (v2)`): your run supplies the first real-account evidence.
Start with the family [getting started guide](https://github.com/maringelix/tx00v2/blob/main/docs/GETTING_STARTED.md);
this runbook defines the AWS-specific details.

> **Cost:** the historical `core` estimate was about US$0.26–0.32/hour and `full`
> with the recommended larger nodes US$0.29–0.40/hour in `us-east-1`
> (`docs/COSTS.md`). Those are reference estimates, not current quotes. Prepare
> the mandatory current-price worksheet in [FINOPS.md](FINOPS.md), including
> HA/DR and external resources. Destroy on the same day; budgets notify but do
> not stop resources.

## AWS readiness fixes

The post-construction audit found permissions that mocked providers and kind do
not exercise. The code fixes these paths, still `not run in the cloud (v2)`:

- The node boundary allows `eks-auth:AssumeRoleForPodIdentity` only on the primary
  and DR cluster ARNs. `eks:*` does not include `eks-auth`; attaching
  `AmazonEKSWorkerNodePolicy` alone cannot override a boundary that omits it.
- Load Balancer Controller can create only this account's standard ELB
  service-linked role, conditioned on
  `iam:AWSServiceName=elasticloadbalancing.amazonaws.com`. The existing `Deny`
  exception did not supply the `Allow` required for a new account's first ALB.
  Other services, roles and accounts are excluded.
- Apply reads ACL, CORS, website, acceleration, request payment, logging and
  Object Lock settings on the same lab backup buckets. AWS provider 6.68.0
  `aws_s3_bucket` reads these configurations even when absent.
  `s3:ListBucketVersions` permits enumeration when emptying the primary bucket;
  DR destination retention remains explicit in [CONTINUITY.md](CONTINUITY.md).
- The app role has `ecr:DescribeImages` on the same API/web repositories in both
  regions to resolve the promoted digest without rebuilding.
- `full` preflight can only `get` Namespace `dx01v2` and Gateway
  `dx01v2-waypoint`. The former uses a ClusterRole with `resourceNames`; the
  latter uses the app Role. Kyverno evaluates Pods in `Kubernetes` mode with
  `failurePolicy: Fail` and action `Deny`.

If bootstrap already exists from older code, review the plan and apply these IAM
changes through the human workflow in section 2 before running the lab.
Reinstall `full` to update RBAC and policy. Do not grant the app role administrator
access to work around `Forbidden`.

Regressions in `cloud_readiness.tftest.hcl` inspect IAM documents and scope;
`cloud-readiness` parses the actual YAML and rejects eight negative
configurations. They do not emulate complete AWS authorization or verify a
real signature at admission. Before accepting `full` in a real account, record
both successful admission of promoted images and rejection of an image lacking
attestation, using the intended ECR repository and namespace.

References: [Pod Identity Agent](https://docs.aws.amazon.com/eks/latest/userguide/pod-id-agent-setup.html),
[IAM boundaries](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html),
[ELB service-linked role](https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/elb-service-linked-roles.html),
[S3 permissions](https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html),
[pinned provider: bucket reads](https://github.com/hashicorp/terraform-provider-aws/blob/v6.68.0/internal/service/s3/bucket.go),
[pinned provider: version deletion](https://github.com/hashicorp/terraform-provider-aws/blob/v6.68.0/internal/service/s3/delete.go),
[ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/).

## 1. Prerequisites

- An AWS account **dedicated** to the lab: the budget covers the account, and the
  apply role has broad infrastructure permissions within its service boundaries.
- A bootstrap administrator identity (for example IAM Identity Center), with MFA.
- AWS CLI v2, authenticated `gh` and harness tools: `make tools` (Terraform,
  kubectl, Helm). Use Linux, WSL 2 or the devcontainer for Bash workflows.
- GitHub `tx01v2` and `dx01v2` repositories (your forks, or the originals).
- Historical timing: bootstrap ~2 minutes, apply ~25–35 minutes (EKS, nodes,
  RDS), base platform ~5 minutes, destroy ~20–30 minutes. Full, DNS and DR add time.

## 2. Bootstrap (once, locally, with administrator credentials)

From your tx01v2 clone:

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars   # edit budget_alert_emails, github_owner and all three IDs
terraform init
terraform plan
terraform apply
terraform output                               # keep outputs private for section 3
terraform output -raw backend_hcl > ../envs/lab/backend.hcl
cd ../..
```

- `github_owner` has no default: use the owner of both repositories/forks.
  Example placeholders `your-github-user` and `you@example.com` are rejected.
- Roles trust GitHub's **immutable** subject with numeric owner/repository IDs:
  `repo:<owner>@<owner id>/tx01v2@<repository id>:environment:lab`. New repositories
  created after 2026-07-15, including new forks, use this format. The older
  name-only subject does not match and could be inherited by a re-registered
  account name. Obtain the IDs with `gh api users/<owner> --jq .id`,
  `gh api repos/<owner>/tx01v2 --jq .id` and
  `gh api repos/<owner>/dx01v2 --jq .id`; set `github_owner_id`,
  `tx01v2_repository_id` and `dx01v2_repository_id` in `terraform.tfvars`.
  `scripts/repo-guardrails.sh` also prints them.
- Repositories created **before** 2026-07-15 must opt into immutable subject
  claims in Settings → Actions → General → OpenID Connect before first apply.
  Check `gh api repos/<owner>/tx01v2/actions/oidc/customization/sub`:
  `sub_claim_prefix` must contain `@<id>`. Renaming/transferring a repository
  changes `sub`; reapply bootstrap.
- Bootstrap state is **local** (`terraform.tfstate`, ignored by Git). Back it up.
- If the account already has GitHub's OIDC provider, set
  `create_github_oidc_provider = false`. Bootstrap reads it by URL and never changes it.
- Confirm the AWS Budgets subscription email.
- For DNS/HTTPS, set bootstrap `lab_route53_zone_id` to the same existing public
  zone ID as lab `route53_public_zone_id`. Plan/apply roles receive Route53 access
  only to that zone. Update bootstrap before the first infrastructure plan/apply
  when enabling/changing the zone.
- State DR is explicit: review `enable_state_dr` and `dr_region` before enabling
  recovery storage. Preserve recovery copies/keys independently of the primary.
- Optional state migration: in `terraform/bootstrap` create ignored
  `backend_override.tf` containing `terraform { backend "s3" {} }`, then run
  `terraform init -migrate-state -backend-config=../envs/lab/backend.hcl -backend-config="key=bootstrap/terraform.tfstate"`.
  Before final bootstrap teardown (section 10), remove that override and run
  `terraform init -migrate-state` to return to local state.

## 3. GitHub variables and secrets

Use Settings → Secrets and variables → Actions → **Variables** for repository
variables. They can appear in public logs: never put private values there.
From the **TX clone root**, import the bootstrap maps:

```bash
OWNER=your-github-user
terraform -chdir=terraform/bootstrap output -json github_variables_tx01v2 |
  jq -r 'to_entries[] | "\(.key)=\(.value)"' |
  gh variable set --repo "$OWNER/tx01v2" --env-file -
terraform -chdir=terraform/bootstrap output -json github_variables_dx01v2 |
  jq -r 'to_entries[] | "\(.key)=\(.value)"' |
  gh variable set --repo "$OWNER/dx01v2" --env-file -
scripts/repo-guardrails.sh "$OWNER/tx01v2"
```

Run the equivalent guardrails script from the dx clone as well. It creates
environment `lab` with a required reviewer and `main`-only deployment; inability
to protect it is a failure, not a skipped safeguard. Plan reads repository
variables because it does not use environment `lab`.

| Name | Type | Example / use | Source |
|---|---|---|---|
| `AWS_REGION` | Variable | `us-east-1`; all cloud workflows | Bootstrap `aws_region` |
| `TF_STATE_BUCKET` | Variable | `tx01v2-tfstate-<ACCOUNT_ID>-us-east-1`; plan/apply/destroy | `state_bucket_name` |
| `AWS_PLAN_ROLE_ARN` | Variable | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-plan`; also enables workflow guard | `plan_role_arn` |
| `AWS_APPLY_ROLE_ARN` | Variable | `arn:aws:iam::<ACCOUNT_ID>:role/tx01v2-gha-apply`; apply/platform/destroy | `apply_role_arn` |
| `LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS` | **Required Secret** | JSON list of EKS API source CIDRs | Reachable runner/operator egress |
| `LAB_ALLOW_ENDPOINT_FROM_ANYWHERE` | Variable | `true` required with `["0.0.0.0/0"]`; default `false` | Explicit operator choice |
| `LAB_CLUSTER_ADMIN_PRINCIPAL_ARNS` | Variable | JSON IAM role ARN list retaining apply plus optional human admin | Bootstrap map + operator |
| `LAB_APP_DEPLOYER_PRINCIPAL_ARNS` | Variable | `["arn:aws:iam::<ACCOUNT_ID>:role/dx01v2-gha-deploy"]` | Bootstrap `deploy_role_arn`; default `[]` without map |
| `LAB_NODE_INSTANCE_TYPES` | Variable, full sizing | `["t3.large","t3a.large"]` | R4.7 sizing |
| `LAB_NODE_DESIRED_SIZE` | Variable, full sizing | `2` | R4.7 sizing |
| `LAB_DB_PROFILE` | Optional Variable | `core`, `ha` or `dr`; HA Multi-AZ/PITR, DR second region | R9 |
| `LAB_DR_REGION` | Variable for `dr` | `us-west-2`, different from `AWS_REGION` | Operator |
| `LAB_DR_VPC_CIDR` | Optional Variable | Nonoverlapping secondary network | `variables.tf` |
| `LAB_DB_BACKUP_RETENTION_DAYS` | Optional Variable | `7`; `ha`/`dr` require at least 7 days | Operator |
| `LAB_DB_DELETION_PROTECTION` | Optional Variable | `true` requires reviewed apply to disable before destroy | Default `false` |
| `LAB_DB_SKIP_FINAL_SNAPSHOT` | Optional Variable | `false` leaves a billable final snapshot | Default `true` |
| `LAB_DB_DELETE_AUTOMATED_BACKUPS` | Optional Variable | `false` retains billable backups after instance deletion | Default `true` |
| `LAB_ENABLE_SPOT_POOL` | Optional Variable | Dedicated Spot pool; on-demand base remains | R10, see FINOPS |
| `LAB_APP_DOMAIN_NAME` | Optional **Secret**, paired | `app.example.org` | Owned app hostname |
| `LAB_ROUTE53_PUBLIC_ZONE_ID` | Optional **Secret**, paired | `Z0123456789ABC` | Existing public hosted zone containing hostname |
| `LAB_VELERO_REPOSITORY_PASSWORD` | **Required Secret for first full install** | 64 random hexadecimal characters, same key both regions | Escrow outside both regions |
| `SLACK_WEBHOOK_URL` | Optional **Secret** | Full Alertmanager Slack destination | Your incoming webhook |
| `LAB_FINOPS_PRICING_JSON` | **Required Variable for plan/apply** | Reviewed USD pricing JSON for selected provider/region and complete scope | FINOPS worksheet |
| `LAB_COST_BUDGET_USD` | **Required Variable for plan/apply** | Positive estimated-session bound | Operator |
| `LAB_COST_HOURS` | **Required Variable for plan/apply** | Priced duration, at most 24 hours | Operator |
| `LAB_COST_EXPIRES_AT` | **Required Variable for plan/apply** | Future UTC deadline within 24 hours and within the priced duration | Operator |

Use `gh secret set NAME --repo OWNER/REPO` interactively or protected stdin.
Public logs, summaries and artifacts are public. Workflows mask each endpoint
CIDR and its IP; do not place CIDRs in repository variables. Hosted runners have
changing egress IPs: the documented learning path explicitly uses
`["0.0.0.0/0"]` plus `LAB_ALLOW_ENDPOINT_FROM_ANYWHERE=true`. Restricting CIDRs
requires a reachable runner with matching egress; federation and RBAC still apply.

`TF_VAR_github_owner` comes from `github.repository_owner` and
`TF_VAR_aws_region` from `AWS_REGION`. Other inputs use `variables.tf` defaults.
To expose a different input (for example `node_capacity_type`), add its
`TF_VAR_<name>` to workflow `env` through a reviewed PR. Admin identities must be
IAM role ARNs (`arn:aws:iam::<ACCOUNT_ID>:role/<name>`), not the
`sts::...:assumed-role/...` session ARN printed by `aws sts get-caller-identity`.
DX uses its own `AWS_REGION` and `AWS_DEPLOY_ROLE_ARN` from the second output map;
secondary deployment also needs matching `LAB_DR_REGION` there.

`core` needs no `LAB_NODE_*` overrides. DNS/HTTPS are optional in code: set both
DNS secrets before plan to create DNS validation, the ACM certificate with AWS
managed renewal, and the ExternalDNS role. Domain and zone must already exist;
the lab neither registers domains nor creates hosted zones. Keep these secrets
consistent across plan/apply/destroy. Without them, contract values are
`disabled`, ExternalDNS is absent and HTTP remains available. Configure DNS to
exercise the complete public TLS scope.

For `full` set capacity before plan and escrow the Velero key before installation.
Existing backup credentials are preserved; a different supplied key is refused
rather than silently rotated. Without a supplied key, a fresh full installation
fails. Slack is optional: the installer sends its secret to Alertmanager over
stdin; otherwise alerts use receiver `null`.

### Prepare the first price worksheet

Follow [FINOPS.md](FINOPS.md). First use authenticated **read-only local plan**
with the backend/tfvars in section 4 to derive the resource inventory; keep the
plan and JSON private. Generate a deliberately incomplete worksheet with
`scripts/cost-pricing-template.sh aws us-east-1 <private-plan.json> <private-rates.json>`.
Fill all resource and external categories at current reviewed prices, including
HA/DR, managed services and positive OpenCost CPU/RAM/storage rates. The pricing
document requires an HTTPS source and `asOf` within 31 days. Do not use
`platform/finops/pricing/local.json` as an AWS quote. Upload the completed JSON
and refresh budget/deadline settings each session. Secondary FinOps installation
requires secondary-region rates.

## 4. Apply

1. Dispatch `terraform-plan.yml` from `main` (or open a PR changing
   `terraform/**`). Read the plan and cost report. For `full`, confirm the plan
   contains the intended `t3.large`/`t3a.large` node group with two instances.
2. Dispatch `terraform-apply.yml` and approve environment `lab` only after review.
   The job creates a fresh saved plan, repeats the cost gate and applies it in
   the same run; it does not consume an old plan artifact.

Local alternative for planning/apply uses your credentials; your role must be a
cluster admin for section 5:

```bash
cd terraform/envs/lab
cp terraform.tfvars.example terraform.tfvars   # real values, ignored by Git
terraform init -backend-config=backend.hcl
terraform plan -out tfplan
# For the first worksheet: terraform show -json tfplan > /private/path/plan.json
# Review prices and run the cost gate documented in FINOPS before any local apply.
terraform apply tfplan
terraform output update_kubeconfig_command
```

The lab writes its own kubeconfig. No lab script changes `~/.kube/config` or your
machine's current context:

```bash
aws eks update-kubeconfig --region us-east-1 --name tx01v2-lab --kubeconfig ~/.kube/tx01v2-lab.kubeconfig
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig   # this terminal only
```

## 5. Platform

Dispatch `platform.yml` with `action=install`, `profile=core` (default) or `full`,
`target=primary` and initially `finops=false`. Approve environment `lab`.
Enable FinOps only with the reviewed regional rates. Leave `activate_dns=false`
on a secondary installation until the fenced cutover procedure allows DNS changes.

For a local operator installation, the script uses temporary kubeconfig and Helm
cache and checks the selected lab cluster and `Project=tx01v2` tag:

```bash
export AWS_REGION=us-east-1
platform/install.sh --profile core
export KUBECONFIG=~/.kube/tx01v2-lab.kubeconfig
kubectl get ingressclass alb
kubectl get clustersecretstore aws-secrets-manager
kubectl -n observability rollout status deployment/opentelemetry-collector
```

For local `full` installation, export `GITHUB_OWNER=<your-user-or-org>`, securely
supply `LAB_VELERO_REPOSITORY_PASSWORD` and run
`platform/install.sh --profile full --github-owner "$GITHUB_OWNER"`. Full creates
the AppProject and root Application `platform`; the app Application follows dx
branch `gitops/aws`. It also installs the waypoint, traffic rules and Kyverno
validation of ECR promotion statements. Private app forks need Argo CD repository
credentials configured by the operator. Slack uses the GitHub secret
`SLACK_WEBHOOK_URL`, or that variable exported only in the operator's terminal.

App traces pass through the Collector to same-region AWS X-Ray. After app
deployment and some requests, inspect CloudWatch X-Ray traces or
`aws xray get-trace-summaries --start-time <START> --end-time <END>`. If no traces
arrive after a few minutes, inspect
`kubectl -n observability logs deployment/opentelemetry-collector` for `awsxray`
exporter or Pod Identity errors.

In `full`, Prometheus, Alertmanager, Grafana, Loki and Tempo store data on gp3 PVCs:

```bash
kubectl -n monitoring get pvc
kubectl get storageclass tx01v2-gp3
```

`platform/uninstall.sh` captures PVCs belonging to lab release StatefulSets,
deletes only those claims after uninstalling charts, and waits for EBS CSI to
delete volumes. `terraform-destroy` runs uninstall before removing the cluster
and EBS CSI add-on.

dx01v2 uses the waypoint for 80/20 canary traffic, bounded retries and circuit
breaking. Its `e2e-platform` CI job also checks authorized SPIFFE identity,
intruder rejection and app metrics/SLOs. In AWS inspect
`kubectl -n monitoring get servicemonitor,prometheusrule` and
`kubectl get imagevalidatingpolicy dx01v2-release-signatures`. For rejected Pods,
inspect Kyverno admission-controller logs and `dx01v2` events. ECR must contain the
attestation from the fork's exact workflow before deployment. CI checks rendering
and contracts; actual AWS runtime remains `not run in the cloud (v2)`.

## 6. App deployment (dx01v2)

Follow the dx01v2 runbook's complete publication chain:
**successful current-main push CI → `publish-images.yml` with `ci_run_id` →
`deploy-aws.yml` with the publication's `release_run_id`**. A PR CI run alone
does not qualify. Publisher verifies the source checks and publishes the tested
archives to GHCR without rebuilding.

The deploy workflow verifies that release, promotes approved images to ECR
repositories `dx01v2/api` and `dx01v2/web` without rebuilding, checks image
configuration IDs, resolves final ECR digests, and signs promotion statements
with the workflow identity. It reads `/tx01v2/lab/*` under `dx01v2-gha-deploy`
(Kubernetes group `dx01v2-deployers`).

Inputs are `platform_profile=core|full`, `deploy_mode=auto|gitops|push` and
`target=primary|secondary`. `auto` is the default: it uses Argo CD if the
Application exists, otherwise direct push. `core` can use `push` because it does
not install Argo CD; `full` should use `gitops` or `auto`. GitOps updates the
`gitops/aws` revision and the live Application's overlay/images/cloud patches,
then waits for Synced/Healthy. Only example parameters go into public Git;
real IDs/CIDRs remain in the cluster. Direct changes under full self-heal can be
reverted. A laptop script call does not issue the workflow promotion attestations
and is not an equivalent full deployment path.

## 7. Smoke test

```bash
kubectl -n dx01v2 get ingress                       # ADDRESS = ALB hostname after provisioning
curl -fsS "http://<ALB_HOSTNAME>/healthz"            # HTTP path without DNS; use HTTPS hostname with DNS
aws wafv2 get-web-acl-for-resource --resource-arn "<ALB_ARN>"
kubectl -n dx01v2 get externalsecrets               # SecretSynced
kubectl -n argocd get application dx01v2            # full only: Synced / Healthy
kubectl -n velero get backupstoragelocation default # full only: Available
```

Full Grafana is ClusterIP:
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`.
Argo CD UI:
`kubectl -n argocd port-forward svc/argocd-server 8080:443`. Grafana's password
is generated during installation; never record it in Git. Trivy scan jobs obtain
short-lived EKS Pod Identity credentials limited to the two app ECR repositories;
inspect reports in `trivy-system` after installing full.

### Velero restore drill (full profile)

This disposable namespace drill restores Kubernetes objects without volumes.
It does not change the app or establish EBS snapshot recovery. Use the lab context:

```bash
DRILL=velero-restore-drill
BACKUP="tx01v2-restore-$(date -u +%Y%m%d%H%M%S)"
kubectl create namespace "$DRILL"
kubectl label namespace "$DRILL" pod-security.kubernetes.io/enforce=restricted
kubectl -n "$DRILL" create configmap restore-proof --from-literal=payload=restore-me
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $BACKUP
  namespace: velero
spec:
  includedNamespaces: [$DRILL]
  snapshotVolumes: false
  ttl: 24h0m0s
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}=Completed' "backup/$BACKUP" --timeout=10m
kubectl delete namespace "$DRILL" --wait=true
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $BACKUP
  namespace: velero
spec:
  backupName: $BACKUP
EOF
kubectl -n velero wait --for=jsonpath='{.status.phase}=Completed' "restore/$BACKUP" --timeout=10m
kubectl -n "$DRILL" get configmap restore-proof -o jsonpath='{.data.payload}' # restore-me
kubectl -n velero delete restore "$BACKUP"
kubectl delete namespace "$DRILL" --wait=true
```

The backup expires after 24 hours; bucket lifecycle removes objects after
35 days. For a failed wait, describe the Backup/Restore, fix the cause and
repeat with a fresh name. The data-volume drill and isolated database PITR/DR
procedures are in [CONTINUITY.md](CONTINUITY.md); object restore alone does not
establish application-data recovery.

## 8. Destroy

Dispatch `terraform-destroy.yml` with `confirm=destroy tx01v2-lab`. The job runs
`scripts/destroy.sh`:

1. `platform/uninstall.sh` if the cluster exists. It deletes all Ingresses and
   `LoadBalancer` Services in the selected owned lab cluster; the exact cluster
   and `Project=tx01v2` checks prevent unrelated targets.
2. If uninstall fails (API unavailable, stopped controller, timeout), AWS API
   cleanup removes controller-created load balancers, target groups and security
   groups tagged `elbv2.k8s.aws/cluster=tx01v2-lab` and continues. The log includes
   `warning: platform/uninstall.sh did not finish`.
3. `terraform destroy`, even after uninstall failure, removes the Terraform lab.
4. `scripts/leftovers.sh --retry-for 900` always runs, including after failed
   destruction. Both destruction and leftover checks must pass.

Full uninstall deletes Argo CD Applications first so self-heal cannot recreate
Ingresses while ALB Controller is being removed. The primary Velero bucket uses
`force_destroy` and is deleted with remaining backup objects; preserve required
data outside the lab before teardown. Recovery/DR buckets intentionally use
`force_destroy=false`: inventory, archive or deliberately empty them under the
reviewed continuity procedure, and retain needed encryption keys.

For `LAB_DB_DELETION_PROTECTION=true`, plan/apply `false` before destroy. Retained
final snapshots and automated backups need explicit inventory and cleanup.
`dr` adds a second-region cluster, private database replica, registry/network,
regional KMS and recovery storage; inspect both regions and bootstrap state
replication. See [CONTINUITY.md](CONTINUITY.md).

There is no supported in-place `full` → `core` transition: destroy and recreate
with `LAB_NODE_*` removed or set for core, then install `profile=core`. Do not
merely uninstall charts and shrink the node group.

### If a step fails

| Step | Diagnosis and next action |
|---|---|
| Bootstrap | Read the first Terraform error; for an existing OIDC provider use `create_github_oidc_provider = false`. Correct input/permission before retrying. |
| Plan/apply | Inspect plan/provider error; check `LAB_NODE_*`, region, quotas, remote state and current cost inputs. Correct them and create a new plan before apply. |
| Core/full installation | Inspect `kubectl get pods -A` and `helm list -A` in the lab, fix the first unready chart, repeat the same profile. Installation is idempotent. |
| Argo CD Application | Describe `argocd/application/dx01v2`; check `gitops/aws` exists, repository access and overlay rendering. Fix dx, then redeploy. |
| Velero | Describe `velero/backupstoragelocation/default`; check `velero/velero` Pod Identity, regional bucket, escrowed repository key and status. Do not add static AWS credentials. |
| Destroy/leftovers | Let the workflow finish; inspect `scripts/leftovers.sh` and ownership tags, then retry. Never remove resources without verifying ownership. |

Read, correct and rerun errors. Harness `destroy-flow` tests orchestration without
AWS using mocked `aws`, `terraform`, `kubectl` and `helm` commands.

An **interrupted run** (cancelled/timed-out apply or destroy) may leave a state
lock: the next Terraform reports `Error acquiring the state lock` and an ID.
Only after verifying no apply is active, dispatch destroy with that exact
`force_unlock_id`. The lock object is `lab/terraform.tfstate.tflock` in the state
bucket. A resource created before interruption but not recorded in state can
produce `already exists`: import the exact owned resource
(`terraform import <address> <id>`) or deliberately delete it, then retry.

```bash
export AWS_REGION=us-east-1 TF_STATE_BUCKET=<bucket>
# Supply the same lab TF_VAR_* values used by the workflow.
scripts/destroy.sh                         # or scripts/destroy.sh --force-unlock <ID>
```

## 9. Leftovers

`scripts/leftovers.sh` classifies `BILLABLE` (exit 1), `ORPHANED` and `INFO`.
KMS keys in `PendingDeletion` are expected during the 7-day window. Elastic IPs
without `Project=tx01v2` appear only as `INFO` ("not the lab's"): do not delete
them. Before deleting anything verify `Project=tx01v2` or the exact owned
`tx01v2-` resource prefix. Common manual operations, after ownership checks:

```bash
aws elbv2 delete-load-balancer --load-balancer-arn <ARN>
aws elbv2 delete-target-group --target-group-arn <ARN>
aws ec2 delete-nat-gateway --nat-gateway-id <ID>
aws ec2 release-address --allocation-id <ID>
aws ec2 delete-security-group --group-id <ID>
aws logs delete-log-group --log-group-name <NAME>
aws rds delete-db-snapshot --db-snapshot-identifier <ID>
aws secretsmanager delete-secret --secret-id <NAME> --force-delete-without-recovery
```

Repeat the script until no `BILLABLE` items remain, then inventory both regions,
retained recovery objects and keys as the human administrator. A clean Terraform
destroy does not establish a zero bill.

## 10. Bootstrap teardown (after the final session)

1. Destroy the dependent lab and complete leftover/recovery inventories.
2. Return bootstrap state to local storage if migrated (section 2).
3. GitHub's OIDC provider belongs to the **account**: another project may depend
   on it. If bootstrap created it (`create_github_oidc_provider = true`), remove
   it from state before destroy:
   `terraform state rm 'aws_iam_openid_connect_provider.github[0]'`.
   Delete it later only if nothing else depends on it.
4. In `terraform/bootstrap` set `state_bucket_force_destroy = true` in
   `terraform.tfvars`, review `terraform apply` changing this flag, then
   `terraform destroy`. This deletes state bucket versions, GitHub roles,
   `tx01v2-lab-boundary` and the budget. First preserve required state/DR copies;
   recovery resources may require their separate explicit procedure.
5. Inspect billing the following day, accounting for reporting delay and
   intentionally retained resources.

## 11. Record the session

Open an issue using **Cloud run report**: date, region, tx01v2/dx01v2 revisions,
steps, run IDs, duration, observed cost, failures and sanitized leftover output.
Record which core/full/HA/DR/FinOps exercises actually ran and their limitations.
Keep real identifiers, addresses, plans/state, credentials and webhook URLs private.
