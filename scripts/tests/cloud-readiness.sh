#!/usr/bin/env bash
# Offline structural checks and negative fixtures. Never connects to a cluster or registry.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_cmd helm jq
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bash "$REPO_ROOT/platform/render-manifests.sh" us-east-1 --full readiness-fixture \
  --only full/image-verification.yaml >"$work/policy.yaml"
bash "$REPO_ROOT/platform/render-manifests.sh" us-east-1 --full readiness-fixture \
  --only full/rbac-dx01v2-deployer-extra.yaml >"$work/rbac.yaml"
# Reuse the already pinned Helm parser; no Python/Node package or live kubectl discovery.
mkdir -p "$work/parser/templates"
printf '%s\n' 'apiVersion: v2' 'name: cloud-readiness-parser' 'version: 0.1.0' >"$work/parser/Chart.yaml"
cat >"$work/parser/templates/bundle.yaml" <<'HELM'
{{- $rbac := list -}}
{{- range splitList "\n---\n" .Values.rbac -}}
{{- $rbac = append $rbac (fromYaml .) -}}
{{- end -}}
{{- dict "rbac" $rbac "policy" (fromYaml .Values.policy) | toJson -}}
HELM
helm template readiness "$work/parser" \
  --set-file "policy=$work/policy.yaml" --set-file "rbac=$work/rbac.yaml" |
  sed '/^---$/d; /^# Source:/d' >"$work/bundle.json"
jq -e -f "$REPO_ROOT/scripts/tests/cloud-readiness.jq" "$work/bundle.json" >/dev/null

reject_mutant() {
  local name=$1 expression=$2
  jq "$expression" "$work/bundle.json" >"$work/$name.json"
  if jq -e -f "$REPO_ROOT/scripts/tests/cloud-readiness.jq" "$work/$name.json" >/dev/null; then
    die "cloud readiness accepted the negative fixture: $name"
  fi
}
reject_mutant json-evaluation '.policy.spec.evaluation.mode = "JSON"'
reject_mutant disabled-admission '.policy.spec.validationActions = ["Audit"]'
reject_mutant missing-namespace-read '.rbac |= map(select(.kind != "ClusterRole"))'
reject_mutant writable-namespace '(.rbac[] | select(.kind == "ClusterRole") | .rules[0].verbs) = ["get","patch"]'
reject_mutant all-namespaces 'del(.rbac[] | select(.kind == "ClusterRole") | .rules[0].resourceNames)'
reject_mutant missing-gateway-read '(.rbac[] | select(.kind == "Role") | .rules) |= map(select(.resources != ["gateways"]))'
reject_mutant all-gateways 'del(.rbac[] | select(.kind == "Role") | .rules[] | select(.resources == ["gateways"]) | .resourceNames)'
reject_mutant wrong-binding '(.rbac[] | select(.kind == "ClusterRoleBinding") | .subjects[0].name) = "other-deployers"'
echo 'PASS cloud readiness: Kubernetes admission, named read-only Namespace/Gateway access, 8 negative fixtures'
