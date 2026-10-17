#!/usr/bin/env bash
# Render actual SHA256-verified upstream archives; never starts Docker.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/platform.sh
source "$REPO_ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/finops.sh
source "$REPO_ROOT/scripts/lib/finops.sh"
require_cmd helm kubeconform
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# Avoid changing the learner's Helm repo inventory/cache.
export HELM_REPOSITORY_CONFIG="$WORK_DIR/repositories.yaml" HELM_REPOSITORY_CACHE="$WORK_DIR/repository"
mkdir -p "$HELM_REPOSITORY_CACHE"
finops_load_pins
finops_pricing_values local docker "$WORK_DIR/pricing.json"
ca="$(pull_chart "$WORK_DIR/charts" "$CA_REPO" cluster-autoscaler "$CA_VERSION" "$CA_SHA256")"
helm template cluster-autoscaler "$ca" -n kube-system \
  -f "$REPO_ROOT/platform/finops/values/cluster-autoscaler.yaml" \
  --set-string autoDiscovery.clusterName=tx01v2-lab --set-string awsRegion=us-east-1 >"$WORK_DIR/ca.yaml"
grep -q 'node-group-auto-discovery=asg:tag=' "$WORK_DIR/ca.yaml"
grep -q 'name: cluster-autoscaler' "$WORK_DIR/ca.yaml"
opencost="$(pull_chart "$WORK_DIR/charts" "$OPENCOST_REPO" opencost "$OPENCOST_VERSION" "$OPENCOST_SHA256")"
vpa="$(pull_chart "$WORK_DIR/charts" "$VPA_REPO" vertical-pod-autoscaler "$VPA_VERSION" "$VPA_SHA256")"
helm template opencost "$opencost" -n finops -f "$REPO_ROOT/platform/finops/values/opencost.yaml" \
  -f "$WORK_DIR/pricing.json" >"$WORK_DIR/opencost.yaml"
helm template lab-vpa "$vpa" -n finops -f "$REPO_ROOT/platform/finops/values/vpa.yaml" >"$WORK_DIR/vpa.yaml"
grep -q 'name: lab-vpa-recommender' "$WORK_DIR/vpa.yaml"
if grep -qE 'name: lab-vpa-(updater|admission)|kind: MutatingWebhookConfiguration' "$WORK_DIR/vpa.yaml"; then
  die 'recommendation-only chart unexpectedly installs a mutator'
fi
while IFS= read -r image; do
  [[ "$image" =~ @sha256:[a-f0-9]{64}$ ]] || die "unversioned FinOps runtime image: $image"
done < <(awk '/^[[:space:]]+image:/ {gsub(/"/,"",$2);print $2}' "$WORK_DIR/opencost.yaml" "$WORK_DIR/vpa.yaml" "$WORK_DIR/ca.yaml")
sed 's/__APP__/dx01v2/g' "$REPO_ROOT/platform/finops/manifests/app-policy.yaml" >"$WORK_DIR/app.yaml"
kubeconform -strict -summary \
  -kubernetes-version 1.36.0 \
  -schema-location "platform/finops/schemas/{{.ResourceKind}}.json" \
  -schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/5f1fa4f7908afc9b6641c62d282a4a22437626e1/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json' \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/f3e4382095909ac60000da025f323ba44d4c738a/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$WORK_DIR/opencost.yaml" "$WORK_DIR/vpa.yaml" "$WORK_DIR/app.yaml" "$WORK_DIR/ca.yaml" \
  "$REPO_ROOT/platform/finops/manifests/namespace.yaml" "$REPO_ROOT/platform/finops/manifests/spot-job.yaml" \
  "$REPO_ROOT/platform/finops/manifests/dashboard.yaml"
