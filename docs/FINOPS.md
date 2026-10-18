# R10 — scaling, capacity and FinOps

## Status and prerequisites

Construction for forks; no AWS operation has run in v2. CI runs Docker. Cloud commands below require
the fork owner's explicitly authorized run, account/domain and budget. FinOps installation is opt-in
and requires the full profile. The local default remains one node; the capacity exercise uses three
kind nodes and recommends 12 GiB available to Docker. Do not combine HA with `LOCAL_SIZE=small`.

## Local exercise: HPA, PDB and interruption

On Linux or in the devcontainer:

```bash
make tools
LOCAL_TOPOLOGY=ha LOCAL_FINOPS=1 make e2e
```

`scripts/local/capacity-drill.sh` creates a dedicated namespace and refuses to adopt one that already
exists. A digest-pinned Node fixture generates CPU load on a worker thread while HTTP remains
responsive. The probe requires HPA 1 → 3 → 1 under bounded load, refusal to evict the last Pod under
its PDB, drain of a worker owned by the kind cluster and redistribution of all three Pods across
remaining nodes. Drain selects only fixture Pods, leaving persistent platform workloads in place.

The client accesses the Service throughout drain, requiring errors <=1% and p99 <=1 s; it does not
port-forward to a Pod. Cleanup always uncordons the node and deletes the owned namespace.
Failure diagnostics show Pods/HPA/PDB/VPA/events without Secrets. A JSON report records measured
values and criteria. Earlier mesh, backup, PITR, observability, policy and chaos probes remain mandatory.

VPA must produce a recommendation while `updateMode` stays `Off` and original requests remain
unchanged. OpenCost must report positive measured cost for the fixture namespace through
`/allocation`. The probe retries for up to five minutes while asynchronous samples arrive, keeping
the positive-cost requirement. Local prices are an explicit deterministic simulation in
`platform/finops/pricing/local.json`.

## EKS Cluster Autoscaler and Spot

The installer deploys official Cluster Autoscaler chart 9.59.0 with image 1.36.1, matching the EKS
minor, service account `kube-system/cluster-autoscaler` and cluster Pod Identity. Writes
`SetDesiredCapacity`/`TerminateInstanceInAutoScalingGroup` require both owned-cluster discovery
tags, and the role keeps its permissions boundary. Spot pool node-template tags support discovery
from zero. The controller adds requests of 50m CPU and 128Mi RAM beyond the full-chart sizing table.

Cheap core retains the interruptible single SPOT pool option. For the exercise that preserves
critical capacity, `enable_spot_pool=true`, exposed as `LAB_ENABLE_SPOT_POOL`, changes the default
pool to ON_DEMAND and creates a separate tainted Spot pool with 0–2 nodes. The change can replace the
default pool and increase cost: review the plan before applying. Critical workloads do not tolerate
that taint. The same module configures the DR cluster.

During an authorized cloud run, apply `platform/finops/manifests/spot-job.yaml` and inspect events,
scaling and placement. If Spot is unavailable, cancel the Job, create a differently named copy without
the Spot toleration and set `nodeSelector` to `eks.amazonaws.com/capacityType=ON_DEMAND`. Preserve the
deadline/budget. kind cannot prove ASG scaling or AWS cost savings.

## Rates and installation

OpenCost chart/app 2.5.33/1.121.3 and VPA 0.14.0/1.8.0 have archive SHA256 and image pins in
`platform/finops/versions.env` and values files. The API is ClusterIP; UI, MCP and cloud billing
ingestion are disabled. The exporter uses configured rates and existing Prometheus, without
billing credentials.

For cloud installation, provide `FINOPS_PRICING_FILE`: JSON with `cloud=aws`, the selected `region`,
`currency=USD`, `mode=estimate`, an HTTPS `source`, `asOf` reviewed within 31 days, a `description` and
positive decimal strings for `cpuPerCoreHour`, `ramPerGiBHour` and `storagePerGiBHour`.
Consult current provider prices; never use the local simulation as a quote. Spot uses on-demand rates
as a conservative bound.

During an authorized run, the installer accepts `--profile full --finops`. Workflow `platform` has
a `finops` input and reads `LAB_FINOPS_PRICING_JSON`. Secondary installation requires rates for
the secondary region; wrong or stale rates fail. Grafana's "Lab FinOps" dashboard shows CPU/RAM by
namespace and explains idle/shared allocation. Compare
`/allocation?window=1h&aggregate=namespace&includeIdle=true` and
`aggregate=label:cost_lab_owner` for showback. Owner/environment labels are mandatory in exercises;
the DX repositories check their manifests and perform rightsizing under an SLO.

## Pre-apply estimate and expiration

`terraform-plan` and `terraform-apply` call `scripts/cost-workflow.sh` after saving `tfplan`.
Apply proceeds only after that gate passes. Configure `LAB_FINOPS_PRICING_JSON`,
`LAB_COST_BUDGET_USD`, `LAB_COST_HOURS` (<=24) and `LAB_COST_EXPIRES_AT`, a UTC deadline in the next
24 hours. Refresh the deadline for every run. It must fit within the priced duration.
These are public inputs without private identifiers.

To prepare the review worksheet outside CI:

```bash
umask 077
terraform -chdir=terraform/envs/lab show -json tfplan > /tmp/plan-private.json
bash scripts/cost-pricing-template.sh aws us-east-1 /tmp/plan-private.json /tmp/rates.json
```

The worksheet is deliberately incomplete. Fill every resource type with its per-resource hourly cost
at the largest planned configuration, including HA/DR, maximum nodes and database sizes. Use zero
only for free or already-included types, with a documented justification. The gate rejects unpriced
types. It also requires external categories `backup`, `controlPlane`, `database`, `dr`, `egress`,
`loadBalancer`, `nat`, `storage` and `waf`, including justified zeros to prevent double counting.
This includes controller-created resources outside Terraform.

OpenCost CPU/RAM/storage rates and the Terraform plan inventory complement each other. Do not add
their totals as though they were independent invoices.

Plan JSON may contain secrets and must never become a public artifact. The report exposes only
resource types/counts, rates, source/date, total, budget and expiry. CI fixtures prove arithmetic and
rejection of excessive cost, stale prices and unpriced resources; they are not current AWS quotes.

A budget alert and this estimate gate do not cap actual billing. Expiry refuses new plans/applies
after their deadline and requires teardown at the end of the exercise; it does not deploy an
automatic account-destruction service. Use existing teardown, inspect leftovers and record retained
backup/state costs. Stop load at the deadline even when an exercise fails.

## Diagnosis and limits

For missing HPA scaling, inspect metrics-server, requests and ScalingActive. For failed rescheduling,
inspect cordon, PDB, affinity, quota and events. VPA Off never updates requests itself.
For missing allocation, inspect ServiceMonitor, Prometheus targets, a populated time window,
exporter read permissions and prices. Missing reviewed regional rates fail the gate.
Compare load/SLO before and after; lower requests alone do not establish savings.

References: [OpenCost Helm](https://opencost.io/docs/installation/helm/),
[allocation API](https://opencost.io/docs/integrations/api-examples/),
[EKS Cluster Autoscaler](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html) and
[EKS Spot](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html).

### External cost, idle and owner dashboard

The pricing document also requires `externalHourly` with `backup`, `controlPlane`, `database`,
`dr`, `egress`, `loadBalancer`, `nat`, `storage` and `waf` in USD/hour. A zero needs an
included/not-applicable justification. Do not count the same expense in a Terraform type and an
external category. The installer creates `lab_external_hourly_estimate` recording rules; the
dashboard shows categories, owner/environment, shared infrastructure and estimated idle.
Kube-state-metrics exposes only the two extra showback labels. Local simulation uses zero external
costs; the fork owner fills reviewed cloud rates.

LimitRange fills absent limits before quota enforcement: CPU 1, RAM 512Mi per container, default
requests 10m/64Mi. Explicit requests/limits, including proxies, are preserved. Quota remains blocking.

For a DR plan, use the largest SKU and highest applicable rate across both regions and explain the
choice in the source description. EKS node idle is a capacity/cost-allocation estimate; managed
capacity and final AWS charges must be measured during the authorized cloud exercise.
