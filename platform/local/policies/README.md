# Políticas do lab local (Gatekeeper)

As políticas do lab v1 (tx01 `k8s/policies`, tx03 `k8s/security`) reescritas e testadas. Um arquivo
por objeto, porque o `gator verify` recebe um template e uma constraint por teste.

| Template | Constraint | Regra | Origem no v1 |
|---|---|---|---|
| `templates/laballowedrepos.yaml` | `constraints/allowed-repos.yaml` | imagens só do registry do lab (`registry.tx01v2.local/`) e o Envoy do Istio | tx01 allowed-registries |
| `templates/labimagepinned.yaml` | `constraints/image-pinned.yaml` | tag diferente de `latest` ou digest | tx03 block-latest-image |
| `templates/labcontainerresources.yaml` | `constraints/container-resources.yaml` | requests de cpu e memória e limite de memória | tx01 resource-limits |
| `templates/labrequiredprobes.yaml` | `constraints/required-probes.yaml` | readinessProbe | tx01 require-probes |
| `templates/labrequiredlabels.yaml` | `constraints/required-labels.yaml` | label `app.kubernetes.io/name` | tx01 required-labels |
| `templates/labblocknodeport.yaml` | `constraints/block-nodeport.yaml` | sem Service NodePort | tx01 block-nodeport |

Todas em `deny` (no v1 a maioria ficava em `dryrun` com o audit desligado), nos namespaces com o label
`policy.lab/enforce=true` (o `dx01v2`). Privilegiado, hostPath e hostNetwork ficam com o Pod Security
Admission `restricted`, que não precisa de pod extra.

Como é verificado:

- `tests/suite.yaml`: casos aceitos e recusados de cada política (`gator verify`, check `policy-gator`
  do harness, `verificado no CI`);
- `platform/local/check.sh`: no cluster, um pod fora das regras é recusado pelas cinco constraints de
  pod e um pod conforme é aceito (dry run no servidor); um Service NodePort é recusado.
