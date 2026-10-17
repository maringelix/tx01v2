#!/usr/bin/env bash
# Generate a deliberately incomplete, identifier-free rate review worksheet from a saved plan.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
[[ $# == 4 ]] || die 'usage: cost-pricing-template.sh CLOUD REGION PLAN_JSON OUT_JSON'
case "$1" in
  aws) source_url=https://aws.amazon.com/pricing/ ;;
  azure) source_url=https://azure.microsoft.com/pricing/ ;;
  gcp) source_url=https://cloud.google.com/pricing ;;
  *) die 'unknown cloud' ;;
esac
jq --arg cloud "$1" --arg region "$2" --arg source "$source_url" --arg date "$(date -u +%F)" '
  [.planned_values.root_module | .. | objects | .resources? // empty | .[] |
    select(.mode == "managed") | .type] | unique |
  {cloud:$cloud,region:$region,currency:"USD",mode:"estimate",source:$source,asOf:$date,
   description:"Fill current regional rates. Each resource type rate must cover its peak planned size; zero requires an included/non-billed justification.",
   cpuPerCoreHour:null,ramPerGiBHour:null,storagePerGiBHour:null,
   resources:map({key:.,value:null})|from_entries,
   externalHourly:{backup:null,dr:null,egress:null,loadBalancer:null,nat:null,storage:null,waf:null}}
' "$3" >"$4"
