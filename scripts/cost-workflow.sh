#!/usr/bin/env bash
# Called after a saved plan and before apply. Never uploads the sensitive plan JSON.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[[ $# == 2 ]] || die 'usage: cost-workflow.sh CLOUD REGION'
require_cmd terraform jq
[[ -n "${FINOPS_PRICING_JSON:-}" && -n "${COST_BUDGET_USD:-}" && -n "${COST_EXPIRES_AT:-}" && -n "${COST_HOURS:-}" ]] ||
  die 'configure FINOPS_PRICING_JSON, COST_BUDGET_USD, COST_HOURS and COST_EXPIRES_AT before a cloud plan/apply'
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"
umask 077
printf '%s\n' "$FINOPS_PRICING_JSON" >"$WORK_DIR/pricing.json"
terraform -chdir=terraform/envs/lab show -json tfplan >"$WORK_DIR/plan.json"
bash "$REPO_ROOT/scripts/cost-plan.sh" --cloud "$1" --region "$2" --plan "$WORK_DIR/plan.json" \
  --pricing "$WORK_DIR/pricing.json" --budget "$COST_BUDGET_USD" --hours "$COST_HOURS" \
  --expires "$COST_EXPIRES_AT" --out "$WORK_DIR/cost.json"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '\n## Configured round estimate (USD; not a billing cap)\n' >>"$GITHUB_STEP_SUMMARY"
  jq -r '"Estimated total: \(.total) / budget \(.budget). Destroy deadline: \(.expires). Source: \(.source), reviewed \(.asOf)."' \
    "$WORK_DIR/cost.json" >>"$GITHUB_STEP_SUMMARY"
fi
