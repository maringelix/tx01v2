# Lessons learned from AWS lab v1 (Nov/2025 – Mar/2026)

> Decisions and lessons preserve each session's initial state. Current HA/backup/PITR/DR
> scope is in [CONTINUITY.md](CONTINUITY.md); capacity, OpenCost/VPA/Spot and estimates
> are in [FINOPS.md](FINOPS.md). Historical exclusions do not revoke R7–R10 construction.

This document distills field notes from lab v1 (`maringelix/tx01`: Terraform with VPC,
EKS, RDS, EC2, ALB, WAF and ECR; GitHub Actions; Prometheus/Grafana; OPA Gatekeeper;
AWS Backup), run using AWS Free Tier credits between November 2025 and March 2026.
Its purpose is to help people spend fewer credits, avoid repeated mistakes and
know what to verify before copying a command.

v2 (`tx01v2`) was redesigned from these lessons: EKS Pod Identity rather than IRSA;
cluster access entries without `aws-auth`; write-only database passwords outside
plan/state; one NAT and SPOT nodes in the initial design; Budgets from bootstrap;
destroy followed by leftover checks; and a cloud-free harness/CI. R10 adds a
separate optional Spot pool while retaining the on-demand base.

## How to read

- Every lesson follows **Symptom → Cause → Correction → Recommendation**.
  Correction records what happened in v1 ("none" when unresolved); Recommendation
  records the October 2026 guidance that informed v2.
- [version: ...] marks version-dependent facts. Check official documentation before
  reuse. Historical prices and calendars are not fresh quotes.
- Real identifiers became placeholders: `<ACCOUNT_ID>`, `<STATE_BUCKET>`, `<IAM_USER>`,
  `<CLUSTER>`, `<INSTANCE_ID>`, `<RDS_SG_ID>`, etc.
- Obsolete material was removed or retained as a warning (December 2025 versions,
  ingress-nginx, Promtail).

## 1. Costs and credits

### 1.1 Free Tier did not cover what the notes assumed

- **Symptom:** notes estimated "6× t3.micro = US$0/month" and "750 hours/month cover
  ~6 instances 24/7", while credits disappeared. On 2026-03-17, US$68.25 remained;
  the Free plan expired on 2026-05-26.
- **Cause:** 750 hours cover one instance for a month (~730 hours), not six.
  Accounts created from 2025-07-15 use credit-based Free Tier (US$100 initially
  plus up to US$100 through activities; Free ends after six months or exhausted
  credits), without the old EC2 750-hour allowance. The lab account used that
  model. EKS control plane, NAT, ALB, WAF and public IPv4 were never free.
- **Correction:** March 2026 audit built an hourly model (1.4); the balance would
  last ~8.7 days with EKS running.
- **Recommendation:** check the account's model in Billing and plan in US$/hour
  multiplied by deployed hours.

### 1.2 Credits hide consumption

- **Symptom:** "net spending since Nov/2025 ≈ US$0". A zero bill concealed the
  burn rate; the credit balance exposed it. v1 had no budget.
- **Cause:** bills/budgets normally subtract credits. Budgets includes credits
  (`include_credit = true`), so an ordinary budget may not alert while they cover usage.
- **Correction:** none; balances were checked manually.
- **Recommendation:** create a budget before the first cluster (v2 bootstrap).
  With credits use `cost_types { include_credit = false }`, actual alerts at
  50/80/100% and forecast at 100%. Cost Explorer `RECORD_TYPE = Usage` shows gross
  consumption. Historical API pricing was US$0.01/request: do not loop
  `aws ce get-cost-and-usage`.

### 1.3 Conflicting estimates and expensive choices

- **Symptom:** documents estimated US$88, 133, 138, 183 and 202/month for variants
  of the same environment.
- **Cause:** manual monthly estimates with different assumptions (Free Tier, NAT
  count, extra ALB), no single price table.
- **Correction:** the 2026-03-17 audit consolidated US$/day per component.
- **Recommendation:** one versioned hourly price table. v1's main cost drivers:
  - Two hardcoded NATs (one/AZ): US$2.16/day, ~28% of total. One suits the lab's
    initial cost tradeoff.
  - Duplicate Terraform/Ingress ALBs (4.2).
  - Zero Pods still incur nodes, control plane, NAT and ALB. End sessions with
    `terraform destroy` for real savings.
  - Stopped EC2 still incurs EBS and associated Elastic IP charges.
  - Extended-support control plane costs 6× more (3.7).

### 1.4 Reference cost model

March 2026 reference prices in us-east-1; check official prices before reuse.
The STG environment audited on 2026-03-17 used these then-current tfvars:

| Component | Reference price | US$/day |
|---|---|---|
| EKS control plane (standard support) | US$0.10/h | 2.40 |
| 4× t3.small on-demand nodes | US$0.0208/h each | 2.00 |
| 2× NAT Gateway | US$0.045/h each | 2.16 |
| RDS db.t4g.micro, single-AZ, 20 GB | US$0.016/h | 0.38 |
| ALB | ~US$0.023/h (+ LCU) | 0.55 |
| WAF (Web ACL + 2 rules) | ~US$7/month | 0.23 |
| ECR, S3, CloudWatch, Secrets Manager | Variable | ~0.10 |
| Audit total | | ~7.82 |

Relevant costs omitted from that table:

- Public IPv4: reference US$0.005/h, ~US$0.12/day, ~US$3.65/month per IP, including
  NAT EIPs and ALB IPs in each AZ. Above, 2 EIPs + 2 ALB IPs add ~US$0.48/day.
- EKS control plane: US$0.10/h standard, US$0.60/h extended. Extended support
  raises this environment to ~US$19.82/day.
- NAT also charged US$0.045/GB processed; large image pulls contribute.

Scenarios for the remaining US$68.25 (extended-support calculation added here;
other rows are from the audit):

| Scenario | US$/day | Credit days |
|---|---|---|
| STG with EKS (then-current tfvars) | ~7.82 | ~8.7 |
| STG with EKS extended support | ~19.82 | ~3.4 |
| STG without EKS (2× EC2 t3.micro) | ~3.66 | ~18.6 |
| No EKS + 1 NAT | ~2.50 | ~27.3 |
| No EKS or NAT | ~1.34 | ~50.9 |

Complete environment: ~US$0.33/h. A four-hour session was ~US$1.30 with destroy;
left running for 30 days, ~US$235.

## 2. Terraform, state and bootstrap

### 2.1 Missing backend on first execution

- **Symptom:** first init and post-cleanup init failed ("S3 backend not found",
  "Backend initialization required").
- **Cause:** state bucket/lock table must preexist init. Hardcoded globally
  unique `<STATE_BUCKET>` in code/workflows makes forks collide.
- **Correction:** `terraform-bootstrap.yml` ran first with local state; cleanup
  preserved bucket/table.
- **Recommendation:** separate bootstrap root outside lab destruction, partial
  backend (`terraform init -backend-config=backend.hcl`), account/region-derived
  names. Native S3 locking (`use_lockfile = true`) replaces DynamoDB [version:
  GA Terraform 1.11, deprecating `dynamodb_table`].

### 2.2 force_destroy and advice to delete state

- **Symptom:** bootstrap used `force_destroy = true` "to simplify tests";
  troubleshooting advised deleting `.terraform`/`terraform.tfstate*` after state
  corruption, then recreating infrastructure.
- **Cause:** convenience applied to the most critical resource. Deleting state
  forgets resources that still exist and incur charges.
- **Correction:** versioned S3 state; bad advice remained in documentation.
- **Recommendation:** `force_destroy = false`, versioning and old-version
  lifecycle. Restore an earlier S3 state object; use import for forgotten
  resources, never destroy + apply.

### 2.3 Stuck lock

- **Symptom:** "Error acquiring the state lock", often after cancelled apply.
- **Cause:** process died without releasing it.
- **Correction:** `terraform force-unlock <LOCK_ID>`.
- **Recommendation:** unlock only after confirming no apply runs. Environment
  workflow concurrency prevents simultaneous applies.

### 2.4 enable_* flags, count and contradictory comments

- **Symptom:** `module.infrastructure.aws_eks_addon.ebs_csi_driver[0]`,
  `enable_eks`, `instance_count = 0` and partial workflows (`manage-environment`,
  `switch-environment`, `eks-deploy` provision/destroy). A launch-template comment
  claimed IMDS hop limit blocked Pods, but value `2` allowed them.
- **Cause:** all-in-one environment roots multiplied poorly tested flag paths;
  comments were never checked against code.
- **Correction:** dedicated mode workflows.
- **Recommendation:** few tested variants. Full apply → study → full destroy is
  predictable and cheap. Assert security through Terraform tests (v2 requires
  IMDSv2/hop limit 1), rather than comments.

### 2.5 Kubernetes provider in cluster Terraform

- **Symptom:** `kubernetes_config_map_v1_data` managed aws-auth; provider derived
  from aws_eks_cluster (`host = var.enable_eks ? <endpoint> : ""`), mapping
  `<IAM_USER>` to `system:masters`.
- **Cause:** same-apply provider dependencies break first creation/destroy/
  cluster disable. system:masters bypasses RBAC restrictions.
- **Correction:** none in v1.
- **Recommendation:** no Kubernetes/Helm providers in infrastructure Terraform.
  Use EKS access entries (`authentication_mode = "API"`, `aws_eks_access_entry`
  and access-policy associations); scripts/workflows install in-cluster software
  after apply.

## 3. EKS: nodes, add-ons, storage and upgrades

### 3.1 t3.micro is unsuitable for EKS nodes

- **Symptom:** Pending Pods, "Too many pods"; 7–8 t3.micro nodes (ASG desired 8,
  max 15) needed for system/app/minimal observability.
- **Cause:** VPC CNI ENI/IP limit `ENIs × (IPs per ENI − 1) + 2`: recorded 4 Pods
  on micro, 11 small, 17 medium, 35 large. aws-node/kube-proxy use two of four;
  ebs-csi-node leaves one. Reserves leave ~600 MiB from 1 GiB. One note incorrectly
  claimed ~11 Pods per micro.
- **Correction:** one CoreDNS/LBC/ebs-csi-controller replica
  (`kubectl scale deployment -n kube-system <NAME> --replicas=1`), check
  `READY_NODES × 4` before deploy, finally t3.small.
- **Recommendation:** small is a practical minimum; medium leaves observability
  headroom (v2 t3.medium/t3a.medium). Prefix delegation increases IP capacity but
  memory remains the small-instance bottleneck.

### 3.2 SPOT and vCPU quotas

- **Symptom:** ON_DEMAND group with "or SPOT to save costs"; troubleshooting
  anticipated Quota Exceeded.
- **Cause:** Spot never enabled; new accounts have low, separate quotas.
- **Correction:** none.
- **Recommendation:** Spot with 2–3 equivalent instance types. AWS can reclaim
  with two minutes' notice; two nodes help but guarantee nothing. Check standard
  on-demand quota `L-1216C47A` and Spot `L-34B43A08` with
  `aws service-quotas get-service-quota --service-code ec2 --quota-code <CODE>`.
  Follow current FINOPS for the optional pool and on-demand fallback.

### 3.3 Running node that never joins

- **Symptom:** eight running EC2 with good status checks, seven Kubernetes nodes;
  SSM send-command returned InvalidInstanceId.
- **Cause:** node bootstrap/kubelet registration failed; SSM Agent unreachable.
- **Correction:** compare IPs, terminate orphan, let ASG replace; replacement joined.

```bash
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=<CLUSTER>" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,PrivateIpAddress,LaunchTime]' --output table
kubectl get nodes -o wide
aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
```

- **Recommendation:** managed-node replacement is often cheaper than debugging.
  For debugging attach AmazonSSMManagedInstanceCore and use Session Manager, not
  SSH. Avoid custom launch-template SGs: EKS then omits its cluster SG, possibly
  preventing join (present in final v1). Do not combine launch template and
  node-group disk_size: put disks in the template (also wrong in final v1).

### 3.4 Capacity decided inside workflows

- **Symptom:** observability expanded to 12 nodes and awaited joins; timeouts/
  failed deployments followed.
- **Cause:** provisioning capacity and installing software together, unpredictable joins.
- **Correction:** removed installer autoscaling; required three free slots and
  an actionable sizing message.
- **Recommendation:** Terraform defines capacity; workflows validate/fail early.

### 3.5 Manually created EBS CSI Driver

- **Symptom:** Prometheus/Grafana PVCs needed a manual driver; state diverged;
  prd lacked it.
- **Cause:** add-on, IRSA role, AmazonEBSCSIDriverPolicy attachment and OIDC
  provider outside code; workflow later "created if absent", giving two owners.
- **Correction:** imported aws_iam_openid_connect_provider, aws_iam_role,
  aws_iam_role_policy_attachment, aws_eks_addon; plan reported No changes and
  `terraform state list | grep -E "ebs_csi|oidc"` verified addresses.
- **Recommendation:** declare volumes' add-on from first apply with Pod Identity
  (eks-pod-identity-agent and aws_eks_pod_identity_association for
  kube-system/ebs-csi-controller-sa). No cluster OIDC provider/issuer-bound trust.
  Adopt resources through reviewable import blocks [Terraform ≥1.5]. Set a
  default gp3 StorageClass: new EKS ≥1.30 clusters no longer default gp2, so
  unspecified storageClassName leaves PVCs Pending.

### 3.6 Manually pinned add-on versions

- **Symptom:** tfvars pinned VPC CNI `v1.19.0-eksbuild.1`, kube-proxy
  `v1.32.0-eksbuild.2`, CoreDNS `v1.11.3-eksbuild.2`, EBS CSI `v1.53.0-eksbuild.1`
  [EKS 1.32, Dec/2025]; list aged every upgrade.
- **Cause:** version compatibility matrices (kube-proxy follows cluster minor).
  Managed add-ons do not self-update, contrary to notes.
- **Correction:** versions manually changed for 1.32.
- **Recommendation:** omit addon_version for the EKS minor default or derive it;
  explicitly update add-ons during upgrades. Query
  `aws eks describe-addon-versions --addon-name kube-proxy --kubernetes-version <VERSION>`.

```hcl
data "aws_eks_addon_version" "kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}
```

### 3.7 Upgrades and extended support

- **Symptom:** code referenced 1.28, already extended-support-billed and ending
  extended support in Nov/2025.
- **Cause:** ~14 months standard +12 extended; control plane US$0.60/h rather than
  US$0.10; AWS eventually upgrades automatically.
- **Correction:** 1.32, kubectl 1.32, Kubernetes provider ~>2.35, LBC chart and
  managed add-ons [Dec/2025].
- **Recommendation:** advance one minor at a time (1.28→1.29→…→1.32), control
  plane, add-ons, nodes. Recreating labs is often quicker. October 2026 review
  placed 1.32/1.33 in extended support: use the official calendar and
  `upgrade_policy { support_type = "STANDARD" }`, because API defaults EXTENDED.
  kubectl allows one minor above/below the server; equality is unnecessary.

### 3.8 Conditional metrics-server

- **Symptom:** micro skipped metrics-server/HPA; top failed, scaling was manual
  (`kubectl scale deployment <APP> --replicas=N`).
- **Cause:** slot savings based on
  `grep "eks_node_instance_type" terraform/stg/terraform.tfvars | awk ...`,
  always reading stg regardless of target; downloaded releases/latest/components.
- **Correction:** install on small or larger; apply HPA only if metrics-server exists.
- **Recommendation:** always install on ≥small: one Pod, historical ~100m/200 MiB
  requests, not "2–3 slots". Use the EKS community add-on (v2) or pinned chart,
  never latest. Read correct Terraform outputs, not grep/sed tfvars.
  Without metrics-server HPA targets are `<unknown>`.

## 4. ALB, AWS Load Balancer Controller and WAF

### 4.1 Two owners of one traffic path

- **Symptom:** initial switch-environment deregistered EC2, registered Pods in
  Terraform target groups and edited listener rules; it was rewritten.
- **Cause:** LBC continuously reconciles Ingress-driven ALB/groups/rules;
  manual changes conflict or revert.
- **Correction:** switch-environment-v2 only scaled Deployment/waited for Ingress;
  controller managed ALB, ip target groups and routing.
- **Recommendation:** one owner/LB. Use TargetGroupBinding to connect a Service
  to a Terraform group, not CLI Pod-IP registration.

### 4.2 Two billed ALBs and WAF on the wrong one

- **Symptom:** Terraform EC2 ALB plus k8s-default-... Ingress ALB, documented as
  normal. Web ACL protected the former; EKS traffic used the unprotected latter.
- **Cause:** parallel EC2/EKS modes kept separate ALBs; aws_wafv2_web_acl_association
  stayed on the old one and Ingress lacked WAF annotation.
- **Correction:** none; switching only chose the traffic destination.
- **Recommendation:** ALBs charge hours/LCU/public IP per AZ. Use one; share with
  alb.ingress.kubernetes.io/group.name. Annotate the actual traffic ALB with
  alb.ingress.kubernetes.io/wafv2-acl-arn and verify
  `aws wafv2 get-web-acl-for-resource --resource-arn <ALB_ARN>`.

### 4.3 Log commands pointing nowhere

- **Symptom:** "enable" logs used `access_logs.s3.enabled,Value=false`, then
  `aws logs tail /aws/alb/<ENV>` and `aws logs tail /aws/waf/<ENV>`.
- **Cause:** ALB logs go to S3 with ELB bucket policy, not CloudWatch Logs; WAF
  destinations need names starting aws-waf-logs-.
- **Correction:** none recorded.
- **Recommendation:** lab metrics HTTPCode_Target_5XX_Count, TargetResponseTime,
  BlockedRequests plus Ingress describe/controller logs often suffice. v2 sends
  WAF logs to aws-waf-logs-<NAME>, redacting authorization.

### 4.4 Slow Ingress, controller versions and HTTP without TLS

- **Symptom:** address took 2–3 minutes, then health checks; errors only in
  events. Docs claimed HSTS with only HTTP port 80.
- **Cause:** asynchronous provisioning; browsers ignore HTTP-delivered HSTS.
- **Correction:** `kubectl get ingress -w`, `kubectl describe ingress <NAME>`,
  `kubectl logs -n kube-system deployment/aws-load-balancer-controller`.
- **Recommendation:** v1's "1.10.1" was chart version, not app (then v2.x,
  Dec/2025). October review used v3.x: pin chart/app, read major-upgrade notes,
  update IAM from same-tag iam_policy.json. With IMDS hop limit 1 supply region/
  vpcId in values. ingress-nginx retired March 2026. Without domain/ACM, do not
  advertise HTTPS/HSTS.

## 5. RDS and database credentials

### 5.1 Pod connection timeouts

- **Symptom:** initialization failed "Connection terminated due to connection timeout".
- **Cause:** RDS 5432 allowed EC2 SG only, while Pods used the omitted EKS cluster SG.
- **Correction:** temporary
  `aws ec2 authorize-security-group-ingress --group-id <RDS_SG_ID> --protocol tcp --port 5432 --source-group <EKS_CLUSTER_SG_ID>`,
  then Terraform below and rollout restart.
- **Recommendation:** timeouts mean network/SG; password authentication failed
  means credentials. Put CLI emergency fixes in code that day. Cluster-SG sources
  work only when nodes carry it; custom launch-template/per-Pod SGs change the source.

```hcl
resource "aws_security_group_rule" "rds_from_eks" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}
```

### 5.2 Plaintext database password

- **Symptom:** committed config contained actual password, RDS endpoint and ALB
  DNS from get-secret-value; CI used kubectl --from-literal; Terraform state held password.
- **Cause:** pasted command output; classic aws_db_instance password stores it in state.
- **Correction:** documents removed later, database destroyed.
- **Recommendation:** deletion does not remove history: treat as leaked and
  rotate. Use placeholders. v2 ephemeral random_password feeds password_wo/
  password_wo_version; Secrets Manager uses secret_string_wo/
  secret_string_wo_version, outside plan/state [Terraform ≥1.11]. ESO delivers
  to Pods rather than CI literals. Enable secret scanning/push protection.

### 5.3 Blocked secret name after destroy

- **Symptom:** database secret gained -v2, typical post-destroy collision.
- **Likely cause:** DeleteSecret schedules deletion (default 30 days); same-name
  creation fails while pending.
- **Correction:** renamed secret.
- **Recommendation:** disposable-lab recovery_window_in_days=0 (v2 default), or
  `aws secretsmanager delete-secret --secret-id <NAME> --force-delete-without-recovery`.

### 5.4 RDS leftovers

- **Symptom:** cleanup removed snapshots after destroy.
- **Cause:** final snapshots (skip_final_snapshot=false), manual/AWS Backup
  snapshots outlive instance and bill storage.
- **Correction:** cleanup scripts.
- **Recommendation:** consciously document skip_final_snapshot=true and
  deletion_protection=false for disposable runs. Inventory snapshots/recovery
  points. v1 reference [Dec/2025]: PostgreSQL 17.6, db.t4g.micro Graviton, 20 GB
  gp3, single-AZ, one-day retention, managed aws/rds encryption.

## 6. GitHub Actions and secrets

### 6.1 Long-lived keys and administrator access

- **Symptom:** both repos used AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY from
  <IAM_USER> with AdministratorAccess/two keys. Troubleshooting attached admin
  for AccessDenied; EC2 used secret SSH key. Setup claimed OIDC was default.
- **Cause:** convenient implementation remained; OIDC existed only in docs.
- **Correction:** audit recommended deleting one key.
- **Recommendation:** GitHub OIDC, per-purpose plan/apply/deploy roles, no cloud
  keys, id-token:write and exact sub. Environment jobs' legacy subject is
  repo:<OWNER>/<REPO>:environment:<ENV>; ref:refs/heads/main trust fails
  AssumeRoleWithWebIdentity. Current v2 uses immutable-ID subjects (CONTRACT).
  Session Manager for nodes, access entries for Kubernetes (2.5).

### 6.2 Missing or duplicated environments

- **Symptom:** tf-deploy accepted nonexistent prd; duplicate stg/staging; app had none.
- **Cause:** manual naming. Referencing a nonexistent environment creates it
  unprotected, without secrets, allowing an unapproved "prd" deployment.
- **Correction:** audit blocker.
- **Recommendation:** create one canonical environment before first run via
  gh api/IaC, required reviewers and proper secret/variable scope. OIDC sub
  depends on the name (6.1).

### 6.3 Red CI for weeks

- **Symptom:** fmt failed on 12 files; tflint reported "Invalid value 'ormat'
  for option -f, --format". App had seven copied terraform-tests failures against
  nonexistent ./terraform. Some "tests" merely echoed.
- **Cause:** no pre-commit formatting; -format compact means -f ormat; copied
  jobs, no real tests.
- **Correction:** terraform fmt -recursive terraform/, tflint --format compact,
  removed copied job.
- **Recommendation:** pinned fmt/validate/tflint locally and in CI. tflint ≥0.47
  requires --chdir/--recursive instead of positional directories. Long-lived red
  CI loses signal. Repositories test their responsibilities.

### 6.4 Many workflows, few exercised

- **Symptom:** 20 infrastructure workflows, 14 never run; app deploy failed since
  Dec/2025; destroy used `terraform destroy ... || echo "Some resources may have failed..."`.
- **Cause:** manual workflow per switch/scale/manage/import/configure/restore,
  no cloud-free exercise; swallowed errors made green meaningless.
- **Correction:** none; local cleanup scripts did the work (10.1).
- **Recommendation:** few workflows covered by harness: fmt, init-backend=false/
  validate, tflint, trivy config, terraform test/mock_provider (≥1.7), actionlint,
  shellcheck, kubeconform, secret scan. v2 CI does this without AWS credentials.
  Never swallow required failures with ||echo.

### 6.5 latest in immutable ECR

- **Symptom:** rollback retagged old images latest, deployment used image_tag:latest.
- **Cause:** existing immutable tags reject overwrite; latest hides running code.
- **Correction:** none recorded.
- **Recommendation:** commit-SHA tags/digests; rollback redeploys previous SHA;
  lifecycle old images (v1 retained ten).

## 7. Observability with limited resources

### 7.1 Full kube-prometheus-stack does not fit

- **Symptom:** full Prometheus/Grafana/Alertmanager/node-exporter/Loki/Promtail
  estimated ~14 Pods/~1.7–2.2 GB; micro lacked slots/memory.
- **Cause:** 3.1 limits and defaults for larger clusters.
- **Correction:** four-Pod micro stack, ~288 MiB/105m requests: Prometheus
  128–256 MiB, 1 Gi disk, 2-day retention, 60s scrape; Grafana 64–128 MiB,
  no persistence; kube-state-metrics 32–64 MiB; operator 64–128 MiB, admission
  webhooks off; Alertmanager/node-exporter/default rules off.
- **Recommendation:** starting point for small/medium. Without operator webhooks,
  invalid PrometheusRule is accepted: promtool CI. Provision Grafana dashboards
  as sidecar-read ConfigMaps to survive restarts without persistence. PVC volumes
  may survive cluster destroy unless claims are deleted first (10.1).

### 7.2 Loki and Promtail logs

- **Symptom:** installed grafana/loki-stack with Promtail.
- **Cause:** common 2024–2025 approach.
- **Correction:** micro disabled them; logs stayed CloudWatch.
- **Recommendation:** Promtail EOL 2026-03-02; use Alloy and grafana/loki [2026].
  Small labs may use kubectl logs/short-retention CloudWatch.

### 7.3 Public Grafana with default credentials

- **Symptom:** LoadBalancer, adminPassword=admin, admin/admin documented. Password
  later moved to repository secret but LB remained public.
- **Cause:** manual shortcut.
- **Correction:** GRAFANA_PASSWORD secret.
- **Recommendation:** internal-tool port-forward
  `kubectl port-forward -n monitoring svc/<GRAFANA_SVC> 3000:80`; avoids another
  LB (~US$18/month v1 estimate) and public IPs. admin.existingSecret, never --set password.

### 7.4 Alerts on nonexistent metrics

- **Symptom:** examples used http_requests_total, up{job="rds"},
  pg_stat_database_numbackends and kube_pod_status_phase{phase!="Running"}>0.
- **Cause:** absent app instrumentation/postgres_exporter means no series/no
  alerts; phase rule also catches Succeeded Job Pods.
- **Correction:** micro disabled rules/Alertmanager; later workflow connected
  Slack through SLACK_WEBHOOK_URL.
- **Recommendation:** start with stack rules; write against actual series;
  promtool test rules. Slack webhook is credential: referenced Kubernetes Secret,
  never committed values.

## 8. OPA Gatekeeper

### 8.1 Gatekeeper did not fit t3.micro

- **Symptom:** controller/audit (~256 MiB each) did not fit.
- **Cause:** limits in 3.1.
- **Correction:** micro controller only (80–150 MiB), audit off, seven policies
  (privileged/hostPath/etc.) dryrun.
- **Recommendation:** native PSA handles privileged/hostPath/hostNetwork with
  namespace baseline/restricted and no extra Pods. Use Gatekeeper for custom
  registries/labels once controller and audit fit.

### 8.2 dryrun without audit shows nothing

- **Symptom:** micro dryrun with audit disabled expected violations in logs.
- **Cause:** dryrun neither blocks nor warns; audit populates constraint status;
  admission logging needs logDenies.
- **Correction:** none recorded.
- **Recommendation:** without audit use enforcementAction:warn for kubectl
  warnings, then deny after fixing violations. One-replica Gatekeeper defaults
  fail-open (failurePolicy:Ignore); an outage lets admission through.

## 9. Backup and restore

### 9.1 Tag selection selecting nothing

- **Symptom:** daily 03:00 UTC AWS Backup selected RDS/EBS tags; troubleshooting
  cited missing tags/short windows for missing backups.
- **Cause:** untagged resources silently excluded.
- **Correction:** configure-backup added tags, vault, plan and role.
- **Recommendation:** verify actual recovery points after first cycle:
  `aws backup list-recovery-points-by-backup-vault --backup-vault-name <VAULT>`.
  AWS cron has six fields (`cron(0 3 * * ? *)`), not five.

### 9.2 Restore creates another resource

- **Symptom:** new RDS ...-restored-<TIMESTAMP>; runbook edited Secret DB_HOST,
  but its key was host (DB_HOST is Deployment env). EBS suggested direct
  aws ec2 attach-volume to node.
- **Cause:** new restore endpoint; inconsistencies surface in end-to-end rehearsal.
- **Correction:** none recorded.
- **Recommendation:** rehearse/time once per cycle; supply RDS subnet group,
  SGs and parameter group, avoiding default-SG timeout (5.1). Kubernetes restore
  uses static PV csi.volumeHandle:<VOLUME_ID> with AZ affinity or CSI VolumeSnapshot,
  never manual node attachment.

### 9.3 Immutability, another region and destroy

- **Symptom:** proposed us-west-2 prd copies called "immutable"; destroy removed
  recovery points before vault.
- **Cause:** enforced immutability needs Vault Lock; vault deletion needs emptiness;
  another region adds forgotten billable resources.
- **Correction:** cross-region off in stg; destroy deleted points.
- **Recommendation at that stage:** short seven-day retention, no cross-region/
  compliance Vault Lock for disposable runs. Compliance prevents even root
  deleting before retention, blocking cleanup. Surviving recovery points cost
  storage. This historical exclusion does not supersede R9 DR construction.

## 10. Cleanup, destroy and orphaned resources

### 10.1 Terraform destroy did not clean everything

- **Symptom:** cleanup-aws-manual.ps1 and cleanup-aws-deep.ps1 (~386 lines each)
  removed LBs/groups/ENIs/SGs/NAT/EIPs/logs/secrets/snapshots/ECR; orphan node role remained.
- **Cause:** controllers create outside-state ALBs/groups/SGs, CNI ENIs, PVC
  volumes, service log groups, manual/workflow add-ons. They block subnet/VPC
  deletion (DependencyViolation). Empty state is not an empty account.
- **Correction:** fixed Kubernetes→LBC→add-ons→nodes→cluster order, cleanup scripts.
- **Recommendation:** three phases (v2): delete Ingress/LB Services/PVCs and await
  AWS LBs/volumes; terraform destroy without swallowing errors; fail leftovers
  on billable resources. Terraform should own retained service log groups,
  e.g. /aws/eks/<CLUSTER>/cluster, so destroy removes them.

### 10.2 Resource Explorer shows nonexistent resources

- **Symptom:** after cleanup index showed 111 (50 Fleets, 15 SG rules, 6 subnets,
  4 ENIs…), but opening returned networkInterface ID does not exist.
- **Cause:** eventual indexing (notes:24–48h). Auto Scaling instant Fleets remain
  deleted_* records, unbilled, and expire.
- **Correction:** direct APIs; index delete/recreate
  (aws resource-explorer-2 delete-index/create-index) cleaned the view.
- **Recommendation:** query every service API in every region, including backup
  destinations (v1 cleanup touched two):

```bash
aws ec2 describe-instances --filters "Name=instance-state-name,Values=pending,running,stopping,stopped"
aws ec2 describe-nat-gateways --filter "Name=state,Values=pending,available"
aws ec2 describe-addresses
aws ec2 describe-network-interfaces --filters "Name=status,Values=available"
aws ec2 describe-volumes --filters "Name=status,Values=available"
aws elbv2 describe-load-balancers
aws eks list-clusters
aws rds describe-db-instances
aws rds describe-db-snapshots --snapshot-type manual
aws logs describe-log-groups --log-group-name-prefix /aws/eks/
aws secretsmanager list-secrets --include-planned-deletion
```

### 10.3 What may remain

- **Symptom:** ~61 remaining items, unclear if billed.
- **Cause:** account defaults/AWS-managed items.
- **Correction:** item-by-item inventory; residual state-backend cost
  ~US$0.01–0.10/month.
- **Recommendation:** default VPC/children, AWSServiceRoleFor... roles, managed
  KMS keys aws/rds and aws/secretsmanager, default.* parameter/option groups,
  state backend may remain. Corrections: default VPC can be deleted/recreated
  (aws ec2 create-default-vpc), but unnecessary; unused service-linked roles
  use aws iam delete-service-linked-role, not delete-role. Leftover customer
  node roles indicate outside-Terraform creation/interrupted destroy.

## 11. Next-cycle checklist

- Bootstrap budget excluding credits on credit-funded accounts.
- On-demand/Spot vCPU quotas checked.
- Standard-support EKS and upgrade_policy STANDARD.
- Nodes ≥t3.small, preferably medium; deliberate Spot choice, one NAT/ALB,
  WAF on the traffic destination.
- No manual resources; if needed import {} that day.
- OIDC without long-lived keys; environments created before first run.
- Write-only/Secrets Manager passwords, no real values in docs.
- Restore rehearsed at least once.
- Three-phase destroy, leftovers in every used region at session end.
