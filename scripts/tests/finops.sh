#!/usr/bin/env bash
# Lightweight negative and allocation arithmetic checks, no Docker or cloud.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/finops.sh
source "$REPO_ROOT/scripts/lib/finops.sh"
require_cmd jq helm
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
finops_load_pins
finops_pricing_values local docker "$WORK_DIR/values.json"
finops_external_rules local docker "$WORK_DIR/external.json"
jq -e '.spec.groups[0].rules | length == 9' "$WORK_DIR/external.json" >/dev/null
jq -e '.opencost.customPricing.costModel.CPU == "0.01"' "$WORK_DIR/values.json" >/dev/null
if (FINOPS_PRICING_FILE="$REPO_ROOT/platform/finops/pricing/local.json" finops_pricing_values gcp us-central1 "$WORK_DIR/bad.json") 2>/dev/null; then
  die 'wrong cloud/region rates were accepted'
fi
jq -n '{planned_values:{root_module:{resources:[{mode:"managed",type:"fixture_compute"},{mode:"managed",type:"fixture_database"}]}}}' >"$WORK_DIR/plan.json"
bash "$REPO_ROOT/scripts/cost-pricing-template.sh" gcp us-central1 "$WORK_DIR/plan.json" "$WORK_DIR/template.json"
jq -e '(.resources | keys | length) == 2 and .resources.fixture_compute == null' "$WORK_DIR/template.json" >/dev/null
jq -n --arg date "$(date -u +%F)" \
  '{cloud:"gcp",region:"us-central1",currency:"USD",source:"https://opencost.io/docs/",asOf:$date,mode:"estimate",
    resources:{fixture_compute:0.1,fixture_database:0.2},
    externalHourly:{backup:0.01,controlPlane:0,database:0,dr:0.02,egress:0.03,loadBalancer:0.04,nat:0.05,storage:0.06,waf:0.07}}' >"$WORK_DIR/pricing.json"
args=(--cloud gcp --region us-central1 --plan "$WORK_DIR/plan.json" --pricing "$WORK_DIR/pricing.json"
  --hours 2 --expires "$(date -u -d '+2 hours' +%FT%TZ)" --out "$WORK_DIR/report.json")
bash "$REPO_ROOT/scripts/cost-plan.sh" "${args[@]}" --budget 2 >/dev/null
jq -e '.total > 1.15 and .total < 1.17 and .withinBudget' "$WORK_DIR/report.json" >/dev/null
if bash "$REPO_ROOT/scripts/cost-plan.sh" "${args[@]}" --budget 1 >/dev/null 2>&1; then die 'expensive plan accepted'; fi
jq '.asOf="2000-01-01"' "$WORK_DIR/pricing.json" >"$WORK_DIR/stale.json"
if bash "$REPO_ROOT/scripts/cost-plan.sh" "${args[@]}" --pricing "$WORK_DIR/stale.json" --budget 2 >/dev/null 2>&1; then die 'stale rates accepted'; fi
jq 'del(.resources.fixture_database)' "$WORK_DIR/pricing.json" >"$WORK_DIR/missing.json"
if bash "$REPO_ROOT/scripts/cost-plan.sh" "${args[@]}" --pricing "$WORK_DIR/missing.json" --budget 2 >/dev/null 2>&1; then die 'unpriced resources accepted'; fi
grep -q 'updateMode: "Off"' "$REPO_ROOT/platform/finops/manifests/app-policy.yaml"
grep -q 'enabled: false' "$REPO_ROOT/platform/finops/values/vpa.yaml"
grep -q 'serviceName: kube-prometheus-stack-prometheus' "$REPO_ROOT/platform/finops/values/opencost.yaml"
echo 'PASS FinOps: deterministic costs, regional prices, budget rejection, expiry and stale/missing rates'
