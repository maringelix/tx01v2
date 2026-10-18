# Local lab policies (Gatekeeper)

The policies from lab v1 (tx01 `k8s/policies` and tx03 `k8s/security`), rewritten and tested.
Use one object per file because each `gator verify` test receives one template and one constraint.

| Template | Constraint | Rule | Origin in v1 |
|---|---|---|---|
| `templates/laballowedrepos.yaml` | `constraints/allowed-repos.yaml` | Images only from the lab registry (`registry.tx01v2.local/`) and Istio Envoy | tx01 allowed-registries |
| `templates/labimagepinned.yaml` | `constraints/image-pinned.yaml` | A tag other than `latest`, or a digest | tx03 block-latest-image |
| `templates/labcontainerresources.yaml` | `constraints/container-resources.yaml` | CPU/memory requests and a memory limit | tx01 resource-limits |
| `templates/labrequiredprobes.yaml` | `constraints/required-probes.yaml` | readinessProbe | tx01 require-probes |
| `templates/labrequiredlabels.yaml` | `constraints/required-labels.yaml` | `app.kubernetes.io/name` label | tx01 required-labels |
| `templates/labblocknodeport.yaml` | `constraints/block-nodeport.yaml` | No NodePort Services | tx01 block-nodeport |

All run in `deny` for namespaces labeled `policy.lab/enforce=true`, including `dx01v2`. In v1 most
used `dryrun` with audit disabled. Pod Security Admission `restricted` handles privileged containers,
hostPath and hostNetwork without an additional policy pod.

Verification:

- `tests/suite.yaml`: allowed and rejected cases for each policy, exercised by `gator verify` through
  the harness's `policy-gator` check; `verified in CI`.
- `platform/local/check.sh`: in the cluster, the five Pod constraints reject a nonconforming Pod,
  accept a conforming Pod through server dry run, and reject a NodePort Service.
