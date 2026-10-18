# Maintaining tx01v2

How to keep the repository healthy without a cloud account: routines, support calendars and
step-by-step update procedures. The support-calendar snapshot below was checked on 2026-10-10.
Recheck the linked official sources before selecting an upgrade; historical dates are not a fresh
provider availability check.

## 1. Purpose and scope

Covers Terraform, scripts and workflows; harness tools; platform versions (EKS, AL2023, PostgreSQL
and charts); and optional cloud runs. The app is maintained in `dx01v2`.

## 2. Current state

- The complete lightweight harness (`make verify`) is `verified in CI` in `static` and `test`.
- The local lab in [LOCAL_LAB.md](LOCAL_LAB.md) is `verified in CI` through `make e2e`.
  Historical local milestones were recorded on 2026-10-13 for `full` and 2026-10-14 for
  `observability` and `operations`, including traces, Slack and the added chaos experiments.
  Current full CI also exercises HA capacity and FinOps; see [FINOPS.md](FINOPS.md).
- Bootstrap, AWS apply, platform installation and destroy remain `not run in the cloud (v2)`.
- The current tx/dx interface is contract v7 dated 2026-10-17. Historical v4, coordinated with
  the dx R4 PR on 2026-10-16, added ambient/policy labels and the GitOps Application. Version 3
  pinned immutable OIDC subjects; version 2 added the Collector OTLP endpoint.
  [CONTRACT.md](CONTRACT.md) is authoritative.

## 3. Routines

| When | What | How |
|---|---|---|
| Weekly, automatic | Scheduled CI runs the complete harness on Monday at 06:00 UTC | On failure, see section 6; common causes are expired exceptions, moved URLs and network failures |
| Monthly | Dependabot PRs for actions, Terraform providers and pre-commit | Follow the dependency-updater playbook in `AGENTS.md`; one PR per group, green harness before merge |
| Quarterly | Harness tools, charts/digests, platform versions, kubeconform schemas and exceptions nearing expiry | Sections 4 and 5; record changes in CHANGELOG |
| Before each cloud run | Review costs, budget/pricing deadline, green CI for the selected commit and GitHub variables | `docs/RUNBOOK.md` |
| During each cloud run | Record times and problems; do not leave a lab running overnight | `docs/RUNBOOK.md` |
| After each cloud run | Destroy, clean `scripts/leftovers.sh` result, `cloud_run_report` issue and evidence-based status updates | `docs/RUNBOOK.md` |

## 4. Support calendar

This table preserves the 2026-10-10 maintenance snapshot. The checked-in pins and current official
release calendars take precedence when planning a new update.

| Component | Version | End of support | Source | Action |
|---|---|---|---|---|
| Kubernetes on EKS | 1.36, lab default | Standard: 2027-08-02; extended: 2028-08-02 | [EKS calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) | Plan 1.37 before standard support ends. `upgrade_policy=STANDARD` permits EKS's end-of-standard-support upgrade instead of extended-support billing, historically US$0.60/h |
| Kubernetes on EKS | 1.37, EKS release recorded as 2026-10-01 | Standard: 2027-12-01; extended: 2028-12-01 | Same EKS calendar | Candidate for the next quarterly review after checking LBC, ESO and add-on compatibility |
| Amazon Linux 2023 nodes | AL2023 | Standard to 2027-06-30; maintenance to 2029-06-30 | [AL2023 cadence](https://docs.aws.amazon.com/linux/al2023/ug/release-cadence.html) | New AMIs arrive through node-group updates; plan a successor before 2029 |
| PostgreSQL on RDS | 17 | Community: 2029-11-08; RDS standard: 2030-02-28, then Extended Support billing | [RDS PostgreSQL calendar](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-release-calendar.html) | Coordinate a major-version/contract update before standard support ends |
| Terraform CLI | 1.16.5, `>=1.11.0,<2.0.0` | No fixed date | [Releases](https://releases.hashicorp.com/terraform/) | Quarterly review, section 5.2 |
| hashicorp/aws provider | 6.68.0, `~>6.68` | No fixed date; major 7 requires migration review | registry.terraform.io | Monthly Dependabot, section 5.3 |
| hashicorp/random provider | 3.9.1, `~>3.9` | No fixed date | registry.terraform.io | Monthly Dependabot |
| AWS Load Balancer Controller | v3.6.0, chart 3.6.0 | No published EOL policy | [Releases](https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases) | Quarterly, section 5.5 |
| External Secrets Operator | v2.12.0, chart 2.12.0; `external-secrets.io/v1` | The project maintains recent versions | [Releases](https://github.com/external-secrets/external-secrets/releases) | Quarterly, section 5.6 |
| kubectl / Helm | 1.37.1 / 4.3.0 | kubectl version skew is one minor from the API, 1.36–1.38 for this client | kubernetes.io, helm.sh | Track the cluster; Helm 4 replaced `--atomic` with `--rollback-on-failure` |
| Runners/devcontainer | Ubuntu 24.04 LTS | Five-year standard support, to 2029-04 | ubuntu.com | Replace before end of support |
| Trivy exceptions | Four entries in the recorded snapshot | 2027-04-30 | `.trivyignore.yaml` | Review the actual current entries and their deadlines, section 5.9 |
| Local Istio | 1.31.1 | Approximately 2027-02, six weeks after 1.33 | [Supported releases](https://istio.io/latest/docs/releases/supported-releases/) | Quarterly, section 5.12; historical 1.29 support ended on 2026-10-12 |
| Other local charts | `platform/local/versions.env`: cert-manager 1.21.2, kube-prometheus-stack 92.3.0, Loki 7.3.0, Alloy 1.13.1, Tempo 3.1.0, OpenTelemetry Collector 0.176.0, Argo CD 10.10.3, Gatekeeper 3.23.1, Trivy Operator 0.37.0, Velero 12.2.1, Chaos Mesh 2.8.4, metrics-server 3.14.0 | Projects maintain recent releases | Each project's releases | Quarterly, section 5.12. Several Grafana charts moved to grafana-community/helm-charts, including Tempo; check each repository before updating |
| Emulated-service images | Registry 3.1.2, Versity S3 Gateway 1.8.0, Soft Serve 0.12.3, cloud-provider-kind 0.12.0, PostgreSQL 17 | No fixed date | `terraform/envs/local/images.tf` | Quarterly, section 5.12 |

## 5. Procedures

### 5.12 Local lab: charts, images and kind

1. For each chart in `platform/local/versions.env`, read release notes, run
   `helm pull <chart> --repo <repo> --version <new-version>` and record the version and archive SHA256.
2. Update digests in `platform/local/values/*.yaml`. `docker buildx imagetools inspect <image>:<tag>`
   returns the multi-architecture index digest. `helm-template-local` rejects images without digests.
3. Update `GATOR_VERSION` with `scripts/update-tool-checksums.sh gator <version>` together with
   `GATEKEEPER_VERSION`; `local-versions` requires them to match.
4. Update emulated-service images in `terraform/envs/local/images.tf`; tests require every image to use a digest.
5. Run `make verify` and `make e2e`, or let the PR's heavy CI e2e prove runtime behavior. Update CHANGELOG.

### 5.1 Harness tools

Applies to Terraform, tflint, its AWS ruleset, Trivy, actionlint, shellcheck, kubeconform, gitleaks,
kubectl and Helm.

```bash
scripts/update-tool-checksums.sh trivy 0.76.0   # downloads the exact release's official checksums
make tools && HARNESS_STRICT=1 make verify
git diff tools/ .tflint.hcl                     # versions.env + checksums.txt; ruleset config when relevant
```

The script reads checksums from the exact release. Shellcheck publishes no checksum file, so the
script downloads all three artifacts and calculates SHA256. Read release notes first. A newer
Trivy can reveal new findings because the harness uses built-in rules with `--skip-check-update`.

### 5.2 Terraform CLI

Use `scripts/update-tool-checksums.sh terraform <version>`. Change `required_version` only when the
minimum must increase. Keep every `versions.tf` consistent; `version-consistency` checks this.

### 5.3 Providers and multi-platform locks

1. Read the provider changelog and migration guide. Version 6 examples include
   `data.aws_region.current.region` replacing `.name`, write-only arguments and per-resource `region`.
2. Keep the same constraint in every `versions.tf`; Dependabot only edits root configurations.
3. In both `terraform/bootstrap` and `terraform/envs/lab`:
   ```bash
   terraform init -backend=false -upgrade
   terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64
   ```
4. Run `HARNESS_STRICT=1 make verify`; `terraform-lockfiles` requires four `h1:` platform hashes per provider.
5. Review the real API read/delete paths used by the pinned provider when changing IAM requirements;
   mocked provider tests validate policy documents, not AWS authorization.

### 5.4 Kubernetes version

Changing `cluster_version` changes the contract and requires coordinated versioned PRs with dx01v2.
Check EKS release notes, LBC/ESO compatibility and default add-on versions first. Update
`K8S_SCHEMA_KUBERNETES_VERSION` in `scripts/harness.sh`. The node group follows the cluster; add-ons
use the EKS default for that version through `data.aws_eks_addon_version` with `most_recent=false`.

### 5.5 AWS Load Balancer Controller

1. Read release notes for incompatible changes and CRDs.
2. Update `LBC_CHART_VERSION` in `platform/versions.env`; since v3 the chart and app share a version.
3. Resolve the digest using
   `docker buildx imagetools inspect public.ecr.aws/eks/aws-load-balancer-controller:v<version>`;
   update `platform/values/aws-load-balancer-controller.yaml`.
4. Fetch the IAM policy from the exact tag:
   `curl -fsSLo terraform/modules/eks/policies/aws-load-balancer-controller-v<version>.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v<version>/docs/install/iam_policy.json`.
   Remove the previous file; update `load_balancer_controller_version` in
   `terraform/modules/eks/pod_identity.tf` and `LBC_IAM_POLICY_SHA256` from the file's SHA256.
5. Helm does not upgrade existing CRDs. Apply the same release's CRDs before upgrading an existing cluster.

### 5.6 External Secrets Operator

Update `ESO_CHART_VERSION`, the image digest shared by controller/webhook/cert-controller and the CRD
API version, currently `external-secrets.io/v1`. An API change is a contract change.

### 5.6.1 OpenTelemetry Collector: cloud and local

Both platforms use `OTEL_COLLECTOR_CHART_VERSION` and `OTEL_COLLECTOR_CHART_SHA256` from
`platform/versions.env` and the same `otel/opentelemetry-collector-contrib` digest.
`helm-template` rejects unequal digests. Installer, harness and local lab reject a different archive
checksum. Read Collector release notes for renamed components such as `otlp_grpc` and
`k8s_attributes`. Update the digest in both `platform/values/otel-collector.yaml` and
`platform/local/values/otel-collector.yaml`, chart version/checksum in `platform/versions.env`,
then `make verify` and `make e2e`. Local e2e proves the pipeline; the X-Ray exporter runs only in AWS.

### 5.6.2 Full cloud-profile charts

`platform/full/charts.txt` lists repository, version key, SHA256 key, chart, release, namespace and
ordered values files. Shared charts retain local version/checksum/image pins; cloud-only
integrations such as Kyverno have pins in `platform/versions.env` and `platform/values/full/`.
AWS-specific values extend or override local configuration.

Read upstream notes, update local pins/values, compare cloud overlays and render through
`helm-template-local` and `helm-template-full`. Checks verify the archive checksum, reject images
without digests, LoadBalancer/NodePort Services and unresolved placeholders, and inspect Collector,
Velero, Gatekeeper, Kyverno and Trivy output. Do not claim AWS installation from render checks:
it stays `not run in the cloud (v2)` until supported by a cloud run report.

`scripts/platform-sizing.sh` takes the node count and rendered manifests and sums requested CPU/RAM,
including pods, init containers, replicas, per-node DaemonSets and Prometheus/Alertmanager resources.
After changing versions, values or replicas, rerun the harness, update the node count and requests
together in `docs/COSTS.md` and check `SUMMARY`/`platform-sizing` output. Requests are not measured
utilization; AWS sizing still requires cloud validation.

### 5.7 Kubeconform schemas

`K8S_SCHEMA_REF` for yannh/kubernetes-json-schema and `CRD_SCHEMA_REF` for datreeio/CRDs-catalog
in `scripts/harness.sh` pin exact commits. Inspect history with
`gh api repos/datreeio/CRDs-catalog/commits?path=external-secrets.io/clustersecretstore_v1.json`.
See the ESO schema note in `docs/HARNESS.md`.

### 5.8 Image digests and actions

Devcontainer digest:
`docker buildx imagetools inspect mcr.microsoft.com/devcontainers/base:ubuntu-24.04`.

For actions outside Dependabot, query `gh api repos/<o>/<r>/git/ref/tags/<tag>`. If
`object.type=="tag"`, follow `gh api repos/<o>/<r>/git/tags/<sha>`. Pin the commit SHA with `# vX.Y.Z`.

### 5.9 Trivy exceptions

For each `.trivyignore.yaml` entry nearing `expired_at`, ask whether its justification still applies.
If so, renew for at most approximately seven months with an updated justification. Otherwise fix
the code and remove the entry.

## 6. Responding to problems

| Situation | First steps |
|---|---|
| Red CI | Read the first FAIL and its immediately following check log. Fix code; never weaken the check. Reproduce with `HARNESS_STRICT=1 make verify` |
| Vulnerability | Update by PR after a Dependabot alert/advisory. Harness tools: section 5.1. Private reports: `SECURITY.md` |
| Budget cost alert | Run `AWS_REGION=<region> scripts/leftovers.sh`; destroy an active lab and inspect Cost Explorer |
| Exposed credential | Revoke/rotate immediately in IAM/GitHub. Inspect CloudTrail. History rewriting requires a maintainer decision |
| Leftovers after destroy | Follow `scripts/leftovers.sh` output and the leftovers section in `docs/RUNBOOK.md`; record in `cloud_run_report` |

## 7. Cloud run records

Every run creates a `cloud_run_report` issue with date, region, commits, steps, duration, observed
cost, problems and leftovers. Change README cloud statuses only with this evidence.

## 8. Ownership

Maintainer: @maringelix, responsible for decisions, merges and cloud runs. AI agents follow
`AGENTS.md`. All maintained documentation and public instructions use English.
