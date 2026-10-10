# shellcheck shell=bash
# Read-only AWS CLI helpers shared by platform/*.sh and scripts/leftovers.sh.
# Every function fails (non-zero) when the AWS call fails: callers must never treat an API error
# as "nothing found". Requires AWS CLI v2 and AWS_REGION.

LAB_SSM_PREFIX="${LAB_SSM_PREFIX:-/tx01v2/lab}"

require_aws_region() {
  [[ -n "${AWS_REGION:-}" ]] || die "set AWS_REGION to the lab region (for example: export AWS_REGION=us-east-1)."
  export AWS_DEFAULT_REGION="$AWS_REGION"
}

# lab_param NAME -> value of the contract SSM parameter $LAB_SSM_PREFIX/NAME.
lab_param() {
  local value
  value="$(aws ssm get-parameter --name "$LAB_SSM_PREFIX/$1" --query 'Parameter.Value' --output text)" ||
    die "cannot read SSM parameter $LAB_SSM_PREFIX/$1 (did terraform apply of terraform/envs/lab run?)"
  [[ -n "$value" && "$value" != None ]] || die "SSM parameter $LAB_SSM_PREFIX/$1 is empty"
  printf '%s' "$value"
}

# words_to_lines -> turns AWS CLI text output (tabs/newlines, "None" for null) into one item per line.
words_to_lines() {
  tr '\t' '\n' | sed -e '/^[[:space:]]*$/d' -e '/^None$/d'
}

# elbv2_arns_with_tag lb|tg KEY VALUE -> ARNs of ELBv2 load balancers (lb) or target groups (tg)
# carrying the tag KEY=VALUE. Uses the ELBv2 API (authoritative), not the Tagging API index.
elbv2_arns_with_tag() {
  local kind=$1 key=$2 value=$3 out i
  local -a arns=() chunk=()
  case "$kind" in
    lb) out="$(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' --output text)" ;;
    tg) out="$(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text)" ;;
    *) die "elbv2_arns_with_tag: kind must be lb or tg" ;;
  esac
  out="$(printf '%s\n' "$out" | words_to_lines)"
  [[ -n "$out" ]] || return 0
  mapfile -t arns <<<"$out"
  for ((i = 0; i < ${#arns[@]}; i += 20)); do
    chunk=("${arns[@]:i:20}")
    out="$(aws elbv2 describe-tags --resource-arns "${chunk[@]}" \
      --query "TagDescriptions[?Tags[?Key=='${key}' && Value=='${value}']].ResourceArn" --output text)"
    printf '%s\n' "$out" | words_to_lines
  done
}
