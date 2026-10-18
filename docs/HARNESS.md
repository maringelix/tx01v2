# tx01v2 harness

The harness is the set of checks that supports this repository's claims without a cloud account.
It lives in `scripts/harness.sh`; the `Makefile` and CI call that same script. CI uses
`HARNESS_STRICT=1`, so missing prerequisites and unexpected tool versions fail visibly.

## Layers

| Layer | Command | What it proves | What it does not prove | Where it runs |
|---|---|---|---|---|
| Tools | `make tools` | Binaries match `tools/versions.env` and their SHA256 checksums | — | local, CI |
| Versions | `tool-versions` check | PATH uses the pinned versions in strict mode | — | local, CI |
| Structure and honest claims | `repo-structure`, `version-consistency` | Required files, status labels, LF, consistent versions and the LBC policy matching upstream | Accuracy of every statement in the documentation | local, CI |
| Policies | `policy-terraform`, `policy-identifiers`, `policy-workflows`, `policy-scripts`, `trivyignore-policy`, `contract-platform` | Covered v1 regressions stay fixed; no real IDs; actions are pinned; scripts check lab ownership, use a temporary kubeconfig and fixed kind context; ignores expire; manifests follow the contract | Author intent | local, CI |
| Formatting and syntax | `terraform-fmt`, `terraform-validate:*` | HCL is formatted and valid against the pinned provider schema | AWS accepting all supplied values | local, CI |
| Provider locks | `terraform-lockfiles` | Hashes cover linux_amd64, linux_arm64, darwin_arm64 and windows_amd64 | — | local, CI |
| Lint | `tflint` | Recommended preset and AWS rules report no issues | Rules requiring AWS calls; deep checking is disabled | local, CI |
| IaC security | `trivy-config`, `trivy-config-tfvars` | No HIGH/CRITICAL findings outside documented exceptions | Runtime configuration or effective IAM permissions | local, CI |
| Offline script flows | `destroy-flow`, `local-preflight` | A failed uninstall still reaches API cleanup, Terraform destroy and leftover checks; local preflight refuses mismatched Docker daemons, overlapping networks/routes and occupied ports, and never adopts a different `LOCAL_STATE_DIR` | Actual AWS or Docker behavior; these tests use simulated CLIs | local, CI |
| Workflows and scripts | `actionlint` with shellcheck, `shellcheck` | Valid workflow YAML and bash | Cloud behavior | local, CI |
| Manifests | `kubeconform` | Strict validation of rendered core/full manifests and `platform/gitops` against Kubernetes 1.36 and pinned CRD schemas | Admission decisions or cluster behavior | local, CI (network) |
| Platform charts | `helm-template` | Pinned LBC 3.6.0 and ESO 2.12.0 charts consume the values, render digest-pinned images, Pod Identity service accounts, feature gates and tags | Installation or controller behavior | local, CI (network) |
| Secrets | `gitleaks` | No recognized secrets in the scanned Git history | Secrets outside the scanner's patterns | local, CI |
| Unit tests | `terraform-test:bootstrap`, `terraform-test:envs/lab` | OIDC trust, bucket, budget, EKS, nodes, add-ons, Pod Identity, state-free RDS passwords, ECR, WAF, KMS, contract SSM parameters and negative validations; scoped EKS Auth/ELB boundary allowances, pinned-provider S3 calls and ECR digest resolution | Resources provisioning in AWS; providers are mocked | local, CI |
| Cloud platform readiness | `cloud-readiness` | Real YAML parsed with pinned Helm; Kubernetes evaluation, deny behavior and scope of the Kyverno configuration; `get` only for Namespace `dx01v2` and Gateway `dx01v2-waypoint`; eight negative fixtures rejected | Live webhook signature verification, effective AWS IAM/RBAC or cloud provisioning | local, CI |
| Local lab: Terraform | `terraform-validate:envs/local`, `terraform-test:envs/local` | Private network, ownership labels, only the registry published on 127.0.0.1, TLS-only database, pinned images and negative validations | Docker creating the containers; that is exercised by e2e | local, CI |
| Local lab: platform | `local-versions`, `helm-template-local`, `kubeconform-local`, `policy-gator` | The pinned charts render digest-pinned images and ClusterIP Services, including small overlays that cannot replace images; valid manifests; allowed and denied Gatekeeper fixtures | Cluster behavior | local, CI (network) |
| AWS full platform | `helm-template-full`, `contract-platform`, `platform-sizing`, `kubeconform`, `policy-gator`, `image-admission-policy`, `full-install-order` | Pinned chart archives/images, AWS overlays, gp3 PVCs and signal retention, ambient waypoint, Argo CD project, Velero bucket, Gatekeeper/Kyverno policies, requests for two nodes and Pod Identity for Trivy, Kyverno and EBS CSI; admission is installed before Argo CD sync | AWS installation, private image access, live ECR signature verification or persistence after a real restart | local, CI (network) |
| Observability teardown | `observability-cleanup` | Claims derived from StatefulSets of the lab's three releases; EBS PV selection uses exact PVC namespace/name and excludes other claims/drivers | Actual deletion by EBS CSI | local, CI |
| Fork path | `fork-references`, `fork-profiles` | Referenced scripts, Make targets, workflows and variables exist or are wired; offline core/full render, owner substitution, invalid owner/profile/region rejected before cloud access | Correctness of the operator's account-specific values | local, CI |
| Local lab: end to end | `local-lab-e2e` (`make e2e`) | Local Terraform apply, full installation and probes in `platform/local/check.sh`, including HTTP-01, ACME renewal, OWASP CRS SQLi/rate limiting, continuity and opt-in capacity/FinOps; destroy and leftover checks always run | AWS; Pebble and the local WAF are test counterparts, not homologated cloud services | local Docker, CI |
| Cloud | `terraform-*` and `platform` workflows | — | — | `not run in the cloud (v2)` |

The single-node default and the HA capacity/FinOps scenario have different resource requirements.
The HA scenario recommends 12 GiB available to Docker; `LOCAL_SIZE=small` uses one node and 7 GiB.
See [LOCAL_LAB.md](LOCAL_LAB.md) and [FINOPS.md](FINOPS.md).

## CI jobs

| Job in `ci.yml` | Target | Harness stage |
|---|---|---|
| `static` | `make tools && make static` | `static` |
| `test` | `make tools && make test` | `test` |
| `e2e` | `make tools && make e2e` | `e2e`; the local lab, with diagnostic artifacts on failure |

The job IDs `static`, `test` and `e2e` are stable required checks in
`.github/rulesets/main.json`. The local-lab `e2e` gate was added on 2026-10-13.
The complete current CI enables `LOCAL_TOPOLOGY=ha` and `LOCAL_FINOPS=1` for e2e.

## Strict mode

`HARNESS_STRICT=1`, set in CI, converts every SKIP into FAIL and requires the PATH versions in
`tools/versions.env`. Without it, a check may skip only a missing local prerequisite, such as a
tool that is not installed, and must print the reason.

`HARNESS_VERBOSE=1` prints output from passing checks. `HARNESS_ONLY=<regex>` runs only checks
whose names match, for local debugging, for example
`HARNESS_ONLY='^tflint$' scripts/harness.sh static`. CI never uses that filter.

## Adding a check

1. Write `check_<name>` in `scripts/harness.sh`, returning zero for PASS and nonzero for FAIL.
   Use `need <tool>` or `skip "<reason>"` only for missing prerequisites.
2. Register it in `register_checks` under the appropriate stage, `static` or `test`.
3. Run `scripts/harness.sh list` and `HARNESS_STRICT=1 make verify`.
4. Update this table, `docs/GUARDRAILS.md` if it is a guardrail, and the changelog.

For a new tool, add its official URLs to `scripts/lib/tools.sh` and its version to
`tools/versions.env`; run `scripts/update-tool-checksums.sh <tool> <version>`.

## Windows and macOS

- Windows: use the digest-pinned devcontainer in `.devcontainer/devcontainer.json` or Ubuntu on
  WSL 2. Git Bash is not the supported full harness environment; installer binaries target Linux/macOS.
- Apple Silicon macOS: use `brew install bash`; the system bash 3.2 is too old for the harness's
  bash >=4.4 requirement. The devcontainer is another option. The installer supports linux_amd64,
  linux_arm64 and darwin_arm64.
- A standalone container can reproduce the lightweight verification environment:
  `docker run --rm -e HARNESS_STRICT=1 -v "$PWD:/work" -w /work ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl unzip git xz-utils make >/dev/null && make tools && make verify"`.
  If files are owned by another user, add
  `-e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=*`.

## Data outside the repository

The harness stores Terraform data (`TF_DATA_DIR`), logs and caches in `HARNESS_WORK_DIR`,
defaulting to `$TMPDIR/tx01v2-harness`. Provider plugins use `TF_PLUGIN_CACHE_DIR`, defaulting to
`~/.terraform.d/plugin-cache` and cached in CI. Only ignored `.tools/` and module lock files remain
inside the working tree. `make clean` removes these generated files.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `SKIP tool-versions - missing tools` | `make tools` was not run | Run `make tools` |
| `FAIL terraform-validate:terraform/envs/lab` with a lock error | Provider changed without refreshed lock hashes | Run `terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64` in the affected root |
| `FAIL trivyignore-policy ... expired` | Exception expired | Review it; fix the code or renew with a current justification |
| `FAIL kubeconform ... could not find schema` | Network failure or a catalog schema kubeconform cannot compile | Check connectivity and the note below |
| `FAIL gitleaks` | Secret or false positive | Remove the secret and rotate it. A justified false-positive exception requires review; never silently weaken the gate. Before the first commit, `gitleaks dir .` also reads ignored tfvars/env files, so keep local credentials outside the repository |
| `FAIL policy-identifiers` | Real account ID, email or IP | Use `123456789012`, `you@example.com` or `203.0.113.10/32` |

Kubeconform note, checked on 2026-10-10: the 2026-10-08 revision of
`external-secrets.io/clustersecretstore_v1.json` in datreeio/CRDs-catalog, generated from ESO 2.12,
places `"additionalProperties": false` inside a `properties` map for the `crd` provider. Kubeconform
cannot compile it and reports "could not find schema". The harness pins the previous revision,
commit `f3e4382` dated 2026-06-02, which strictly validates this repository's ClusterSecretStore and
rejects misspelled fields. Reassess this choice during the quarterly harness review in
[MAINTENANCE.md](MAINTENANCE.md).

## R10: capacity and FinOps

See [FinOps and scaling](FINOPS.md) for kind HA, load/HPA/PDB, OpenCost, recommendation-only VPA,
opt-in Spot, regional pricing, budget/expiration and cleanup. This is construction for forks;
nothing has run in AWS v2.
