# Lab costs

Hourly/daily reference costs for the lab defaults in us-east-1, to review before creating anything.
The base table preserves list-price references checked on 2026-10-10; later sections record
2026-10-14/16 additions. They are historical examples, not current quotes. Check official AWS pricing
before every run. Taxes and data transfer are excluded unless explicitly stated.

Current plan/apply additionally require the reviewed regional pricing document, budget, bounded
duration and expiry described in [FINOPS.md](FINOPS.md). The historical Spot-discount assumption below
must not replace that gate's conservative on-demand rates.

## Component estimate: defaults in us-east-1

| Component | Quantity | Reference price | USD/hour | USD/day |
|---|---|---|---|---|
| EKS control plane, standard support | 1 cluster | USD 0.10/h | 0.100 | 2.40 |
| EKS extended support, avoided with `upgrade_policy=STANDARD` | — | USD 0.60/h | (0.600) | (14.40) |
| t3.medium/t3a.medium SPOT nodes | 2 | On-demand USD 0.0416/h and 0.0376/h; Spot varies by AZ/time, historical estimate 35% of on-demand | ~0.030 | ~0.72 |
| Same nodes ON_DEMAND, optional | 2 | USD 0.0416/h | (0.083) | (2.00) |
| Node EBS gp3 | 2 × 20 GB | USD 0.08/GB-month | 0.004 | 0.11 |
| NAT gateway | 1 | USD 0.045/h + 0.045/GB processed | 0.045 | 1.08 + data |
| Public IPv4 | 3: NAT EIP and 2 ALB addresses | USD 0.005/h per IP | 0.015 | 0.36 |
| Application Load Balancer | 1 | USD 0.0225/h + USD 0.008/LCU-hour | ~0.030 | ~0.73 |
| RDS PostgreSQL db.t4g.micro, single-AZ | 1 | USD 0.016/h | 0.016 | 0.38 |
| RDS gp3 storage | 20 GB | USD 0.115/GB-month | 0.003 | 0.08 |
| WAF | 1 ACL + 5 rules | USD 5/month + 1/rule-month + 0.60/million requests | 0.014 | 0.33 |
| KMS | 1 key | USD 1/month + requests | 0.001 | 0.03 |
| Secrets Manager | 2 secrets | USD 0.40/secret-month + calls | 0.001 | 0.03 |
| CloudWatch Logs: EKS control plane, flow logs, RDS, WAF | Low volume | USD 0.50/GB ingested + 0.03/GB-month | ~0.005 | ~0.05–0.25 |
| X-Ray, app traces through Collector | Lab volume | 100,000 recorded traces/month without charge, then USD 5/million; [pricing](https://aws.amazon.com/xray/pricing/), checked 2026-10-14 | ~0 | ~0 |
| ECR, Standard SSM, state S3, budget without actions | — | Cents/month or no charge | ~0 | ~0 |
| **Core total with default SPOT** | | | **~0.26** | **~6.3–6.5** |
| **Core total with ON_DEMAND** | | | **~0.32** | **~7.6–7.8** |

## Database continuity: HA and DR profiles, R9

Core retains one RDS instance in one AZ and one-day backups. HA adds a Multi-AZ standby and at least
seven days of automated backups for PITR. An initial three-hour us-east-1 estimate adds an equivalent
database instance, approximately USD 0.048 at the historical USD 0.016/h rate, plus copy storage and
backups above the applicable allowance. Actual charges depend on class, region, storage type, writes
and retention. Review [AWS Pricing Calculator](https://calculator.aws/) and
[RDS PostgreSQL rates](https://aws.amazon.com/rds/postgresql/pricing/) before apply.

DR adds automatic snapshot/log copies to `dr_region` and a regional KMS key. Price snapshot/log bytes
transferred at inter-region transfer rates, retained destination snapshots at destination storage
rates and KMS key/requests. AWS charges transfer and destination snapshots; logs have no additional
storage charge in the documented model ([RDS pricing](https://aws.amazon.com/rds/pricing/)).
Actual WAL volume depends on writes.

The first backup-only R9 slice was described as a data pilot light without a running secondary DB,
EKS, ALB, NAT or app. That is historical scope, superseded by the completed R9 independent regional
runtime described below. Budget the current second VPC/EKS/node groups, running RDS read replica,
registry, network, edge and telemetry; backup-copy cost alone is insufficient.

`db_deletion_protection`, final snapshots and post-deletion backup retention are separate choices.
Defaults remain destroyable so a fork does not accidentally retain billable resources. If enabled,
plan disabling protection and explicitly clean retained snapshots/backups. A USD 25 budget only
notifies; it does not block billing.

## Full profile, R4.7

`scripts/platform-sizing.sh 2 <render-directory>` sums full-chart requests, including replicas, init
containers, DaemonSets multiplied by two nodes, and Prometheus/Alertmanager `spec.resources`.
Kyverno contributes 520m CPU/576MiB RAM. The reproducible updated total is **1335m CPU/3808MiB RAM**.
Requests are not measured use; managed EKS Pods are excluded.

| Profile | Profile requests | Recommended node group | Estimated Spot total | Estimated on-demand total |
|---|---:|---|---:|---:|
| core | — | 2 × `t3.medium`/`t3a.medium` | ~USD 0.26/h | ~USD 0.32/h |
| full | 1335m CPU / 3808MiB RAM | 2 × `t3.large`/`t3a.large` | **~USD 0.29/h** | **~USD 0.40/h** |

Full additionally provisions **36 GiB of gp3 EBS**: Prometheus 12 GiB, Alertmanager 2 GiB, Grafana
2 GiB, Loki 10 GiB and Tempo 10 GiB. At the recorded us-east-1 USD 0.08/GiB-month rate, this adds
approximately **USD 2.88/month**, or **USD 0.004/h**, while the volumes exist. Charges use provisioned
capacity; reducing retention does not shrink a PVC or its storage bill. `platform/uninstall.sh`
removes chart PVCs and waits for EBS CSI volume deletion before Terraform destroy.
[EBS gp3 pricing](https://aws.amazon.com/ebs/pricing/), checked 2026-10-16.

For full, set repository variables `LAB_NODE_INSTANCE_TYPES='["t3.large","t3a.large"]'` and
`LAB_NODE_DESIRED_SIZE=2` before planning; keep them unchanged through destroy. All three Terraform
workflows pass them as `TF_VAR_*`; otherwise inexpensive core defaults remain. The historical
estimate uses USD 0.0832/h per t3.large and a 35% on-demand Spot assumption, as in core.
Real Spot/t3a rates vary by AZ/time. Two t3.medium nodes are not the documented full sizing.

The recorded three-hour estimate is **USD 0.88 Spot** or **USD 1.22 on-demand**, including full
storage. At 730 hours it becomes approximately USD 215/month or USD 295/month, respectively, before
extra traffic, ingestion and storage. The intentionally low monthly USD 25 budget alerts at ACTUAL
50%, 80%, 100% and FORECASTED 100%; it never stops resources.

EKS/t3.large references checked on 2026-10-16:
[Amazon EKS](https://aws.amazon.com/eks/pricing/) and
[t3.large in us-east-1](https://docs.aws.amazon.com/prescriptive-guidance/latest/optimize-costs-microsoft-workloads/right-size-selection.html).

Quick interpretation of the historical baseline:

- A three-hour apply → exercise → destroy run was approximately USD 0.80–1.00.
- Forgotten running, the baseline exceeds USD 40/week; the monthly budget is much lower.
- EKS control plane plus NAT account for approximately 55% of that baseline; Spot nodes about 10%.

## V1 scenarios, March 2026

From v1 `ENVIRONMENT_AUDIT_2026-03-17` for comparison; v1 excluded public IPv4:

| V1 scenario | USD/day | Days covered by USD 68.25 credit |
|---|---|---|
| STG with EKS: 4 × t3.small, 2 NAT, RDS, ALB, WAF | ~7.82 | ~8.7 |
| STG without EKS: 2 × EC2 t3.micro | ~3.66 | ~18.6 |
| STG without EKS + 1 NAT | ~2.50 | ~27.3 |
| STG without EKS or NAT | ~1.34 | ~50.9 |

Daily v1 EKS scenario detail: EKS USD 2.40; four t3.small USD 2.00; two NAT USD 2.16; RDS USD 0.38;
ALB USD 0.55; WAF USD 0.23; ECR/S3/CloudWatch/Secrets Manager approximately USD 0.10. V2 replaces
two fixed NATs with one by default and on-demand nodes with Spot; it also includes KMS, five WAF
rules and public IPv4.

## Tips

- Destroy the same day; run `scripts/leftovers.sh` until no BILLABLE resource remains.
- For the inexpensive baseline, retain `node_capacity_type="SPOT"`, `nat_gateway_per_az=false` and single-AZ RDS.
- Do not opt into EXTENDED without reviewing the historical USD 0.60/h control-plane charge.
- Controller-created load balancers bill while present. Uninstall waits for their deletion before destroy.
- The KMS key remains PendingDeletion for seven days after destroy; consult KMS pricing.
- Promotional credits hide resource consumption. The budget intentionally excludes credits/refunds.
- Logs retain seven days; EKS audit logs are the largest volume. End the run promptly.

## R9: second region and recovery copies

The completed DR profile maintains runtime in two regions: two EKS control planes, node groups in
both, primary Multi-AZ RDS plus a read replica, networks/NAT, ALB/WAF, ECR, KMS-encrypted secrets and
three Velero buckets: source, recovery and the secondary's own backup. Add compute, storage/IOPS,
WAL/PITR, S3 requests, object versions, inter-region transfer and retention. Cost is not merely an
RDS backup copy. `enable_state_dr=true` can add another versioned state bucket.

Before the run, calculate:
`hours × (2 × EKS + both regions' nodes + RDS HA + replica + NAT/LB/WAF) +
GB-months of data/backups/registry + requests + egress`,
using official rates for the chosen regions, date and account discounts. Do not multiply the core
total by an arbitrary factor and call it a quote. Set duration, owner and teardown. Recovery buckets
retained after cluster removal still hold billable objects/versions until deliberate cleanup.

## R10: capacity and FinOps

See [FinOps and scaling](FINOPS.md) for kind HA, load/HPA/PDB, OpenCost, VPA Off, opt-in Spot,
regional rates, budget/expiration and cleanup. Construction for forks; nothing has run in AWS v2.
