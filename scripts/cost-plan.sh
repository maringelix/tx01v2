#!/usr/bin/env bash
# Offline plan estimate. Raw plan JSON stays private; output contains types/counts/costs only.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd jq
PLAN='' PRICING='' CLOUD='' REGION='' BUDGET='' HOURS='' EXPIRES='' OUT=''
while (($#)); do
  case "$1" in
    --plan) PLAN=$2; shift 2 ;; --pricing) PRICING=$2; shift 2 ;;
    --cloud) CLOUD=$2; shift 2 ;; --region) REGION=$2; shift 2 ;;
    --budget) BUDGET=$2; shift 2 ;; --hours) HOURS=$2; shift 2 ;;
    --expires) EXPIRES=$2; shift 2 ;; --out) OUT=$2; shift 2 ;;
    *) die "unknown cost-plan option: $1" ;;
  esac
done
[[ "$CLOUD" =~ ^(aws|azure|gcp)$ && -n "$REGION" && -f "$PLAN" && -f "$PRICING" && -n "$OUT" ]] ||
  die 'cost-plan requires cloud, region, plan, pricing and output'
[[ "$BUDGET" =~ ^[0-9]+([.][0-9]+)?$ && "$HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'budget/hours must be positive numbers'
jq -en --argjson hours "$HOURS" --argjson budget "$BUDGET" '$hours > 0 and $hours <= 24 and $budget > 0' >/dev/null ||
  die 'a temporary round must last at most 24 hours and have a positive budget'
NOW="$(date -u +%s)"
DEADLINE="$(date -u -d "$EXPIRES" +%s)" || die 'invalid expiration'
((DEADLINE > NOW && DEADLINE <= NOW + 86400)) || die 'expiration must be in the next 24 hours'
jq -en --argjson duration "$((DEADLINE - NOW))" --argjson hours "$HOURS" '$duration <= $hours * 3600 + 60' >/dev/null ||
  die 'estimate duration must cover the whole time until expiration'
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
# No values, addresses, identifiers, secret material or outputs leave the plan.
jq '[.planned_values.root_module | .. | objects | .resources? // empty | .[] |
  select(.mode == "managed") | .type] | sort | group_by(.) |
  map({type:.[0],count:length})' "$PLAN" >"$WORK_DIR/inventory.json"
jq -e 'length > 0' "$WORK_DIR/inventory.json" >/dev/null || die 'plan has no managed resource inventory'
jq -e --arg cloud "$CLOUD" --arg region "$REGION" '
  .cloud == $cloud and .region == $region and .currency == "USD" and
  .mode == "estimate" and (.source | startswith("https://")) and
  (.resources | type == "object") and
  (.externalHourly | keys | sort) == (["backup","dr","egress","loadBalancer","nat","storage","waf"] | sort) and
  (.externalHourly | all(.[]; type == "number" and . >= 0)) and
  (.resources | all(.[]; type == "number" and . >= 0))
' "$PRICING" >/dev/null || die 'invalid reviewed regional estimate or missing external cost categories'
ASOF="$(jq -er '.asOf | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' "$PRICING")"
AGE=$(( (NOW - $(date -u -d "$ASOF" +%s)) / 86400 ))
((AGE >= 0 && AGE <= 31)) || die 'cost rates must be reviewed within 31 days'
jq -e --slurpfile inventory "$WORK_DIR/inventory.json" \
  '$inventory[0] | all(.[]; .type as $t | $ARGS.named.rates | has($t))' \
  --argjson rates "$(jq '.resources' "$PRICING")" "$PRICING" >/dev/null ||
  die 'every managed resource type needs an explicit reviewed hourly estimate (zero only for non-billed/included resources)'
jq --slurpfile inventory "$WORK_DIR/inventory.json" --argjson hours "$HOURS" --argjson budget "$BUDGET" --arg expires "$EXPIRES" '
  . as $p |
  [$inventory[0][] | {type,count,hourly:(.count * $p.resources[.type])}] as $rows |
  (([$rows[].hourly] | add) + ([.externalHourly[]] | add)) as $hourly |
  {cloud,region,currency,source,asOf,mode,hours:$hours,expires:$expires,
   resources:$rows,externalHourly,hourly:$hourly,total:($hourly * $hours),budget:$budget,
   withinBudget:($hourly * $hours <= $budget),
   limitation:"Configured estimate, not invoice or billing cap. Stop and destroy at expiry; verify leftovers."}
' "$PRICING" >"$OUT"
jq -e '.withinBudget' "$OUT" >/dev/null || die 'estimated round exceeds configured budget; reduce scope before apply'
cat "$OUT"
