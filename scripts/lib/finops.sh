# shellcheck shell=bash
# Shared local/cloud installer. Call with a verified lab context, WORK_DIR and pull_chart helper.
install_cluster_autoscaler() {
  local cluster=$1 region=$2 chart
  finops_load_pins
  chart="$(pull_chart "$WORK_DIR/finops-charts" "$CA_REPO" cluster-autoscaler "$CA_VERSION" "$CA_SHA256")"
  helm upgrade --install cluster-autoscaler "$chart" --namespace kube-system \
    --values "$REPO_ROOT/platform/finops/values/cluster-autoscaler.yaml" \
    --set-string "autoDiscovery.clusterName=$cluster" --set-string "awsRegion=$region" \
    --wait=watcher --rollback-on-failure --timeout 5m >/dev/null
}
finops_load_pins() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^([A-Z0-9_]+)=([A-Za-z0-9._:/@-]+)$ ]] || die 'invalid FinOps pin'
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done <"$REPO_ROOT/platform/finops/versions.env"
}
finops_pricing_values() {
  local cloud=$1 region=$2 out=$3 file="${FINOPS_PRICING_FILE:-}" asof age
  if [[ "$cloud" == local ]]; then file="$REPO_ROOT/platform/finops/pricing/local.json"; fi
  [[ -f "$file" ]] || die 'FinOps cloud requires FINOPS_PRICING_FILE with current regional rates (docs/FINOPS.md)'
  jq -e --arg cloud "$cloud" --arg region "$region" '
    .cloud == $cloud and .region == $region and .currency == "USD" and
    (.source | type == "string" and startswith("https://")) and
    ([.cpuPerCoreHour,.ramPerGiBHour,.storagePerGiBHour] | all(.[]; type == "string" and test("^[0-9]+(\\.[0-9]+)?$") and tonumber > 0)) and
    (.cpuPerCoreHour | tonumber) <= 1 and (.ramPerGiBHour | tonumber) <= 0.1
  ' "$file" >/dev/null || die 'FinOps pricing has invalid units, region, currency, source or bounds'
  if [[ "$cloud" != local ]]; then
    asof="$(jq -er '.asOf | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' "$file")"
    age=$(( ($(date -u +%s) - $(date -u -d "$asof" +%s)) / 86400 ))
    ((age >= 0 && age <= 31)) || die 'FinOps regional rates must be reviewed within 31 days'
  fi
  jq '{opencost:{customPricing:{costModel:{
    CustomPricesEnabled:"true",description:.description,CPU:.cpuPerCoreHour,RAM:.ramPerGiBHour,storage:.storagePerGiBHour,
    spotCPU:.cpuPerCoreHour,spotRAM:.ramPerGiBHour
  }}}}' "$file" >"$out"
  # Conservative Spot accounting: no unmeasured discount is assumed.
}
install_finops_stack() {
  local cloud=$1 cluster=$2 region=$3 app=$4 chart pricing="$WORK_DIR/finops-pricing.json"
  require_cmd jq helm kubectl
  [[ "$app" =~ ^dx0[123]v2$ ]] || die 'invalid FinOps lab namespace'
  finops_load_pins
  finops_pricing_values "$cloud" "$region" "$pricing"
  kubectl apply -f "$REPO_ROOT/platform/finops/manifests/namespace.yaml" >/dev/null
  if [[ "$cloud" == gcp ]]; then
    kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null ||
      die 'Autopilot VPA API is not available; do not install a competing controller'
  else
    chart="$(pull_chart "$WORK_DIR/finops-charts" "$VPA_REPO" vertical-pod-autoscaler "$VPA_VERSION" "$VPA_SHA256")"
    helm upgrade --install lab-vpa "$chart" --namespace finops \
      --values "$REPO_ROOT/platform/finops/values/vpa.yaml" --wait=watcher --rollback-on-failure --timeout 5m >/dev/null
  fi
  chart="$(pull_chart "$WORK_DIR/finops-charts" "$OPENCOST_REPO" opencost "$OPENCOST_VERSION" "$OPENCOST_SHA256")"
  helm upgrade --install opencost "$chart" --namespace finops \
    --values "$REPO_ROOT/platform/finops/values/opencost.yaml" --values "$pricing" \
    --set-string "opencost.exporter.defaultClusterId=$cluster" \
    --wait=watcher --rollback-on-failure --timeout 5m >/dev/null
  sed "s/__APP__/$app/g" "$REPO_ROOT/platform/finops/manifests/app-policy.yaml" | kubectl apply -f - >/dev/null
  kubectl apply -f "$REPO_ROOT/platform/finops/manifests/dashboard.yaml" >/dev/null
}
