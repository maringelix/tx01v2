# shellcheck shell=bash
# Read-only AWS CLI helpers shared by platform/*.sh and scripts/leftovers.sh.
# Every function fails (non-zero) when the AWS call fails: callers must never treat an API error
# as "nothing found". Requires AWS CLI v2 and AWS_REGION.

# Fixed by the contract (docs/CONTRACT.md). Never read from the environment: a shell that already
# exports CLUSTER_NAME or similar for another cluster must not retarget a script of the lab.
LAB_PROJECT=tx01v2
# shellcheck disable=SC2034 # used by the scripts that source this file
LAB_CLUSTER=tx01v2-lab
LAB_SSM_PREFIX=/tx01v2/lab
select_lab_target() {
  LAB_TARGET="${1:-primary}"
  case "$LAB_TARGET" in
    primary) LAB_CLUSTER=tx01v2-lab; LAB_SSM_PREFIX=/tx01v2/lab ;;
    secondary) LAB_CLUSTER=tx01v2-lab-dr; LAB_SSM_PREFIX=/tx01v2/lab-dr ;;
    *) die 'target must be primary or secondary' ;;
  esac
  export LAB_TARGET LAB_CLUSTER LAB_SSM_PREFIX
}

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

# require_lab_cluster NAME -> the EKS cluster NAME exists in AWS_REGION and carries the tag
# Project=tx01v2 of the lab: a cluster of whoever runs the script is never touched, even one with
# the same name.
require_lab_cluster() {
  local tag
  tag="$(aws eks describe-cluster --name "$1" --query 'cluster.tags.Project' --output text)" ||
    die "cannot read the EKS cluster $1 in $AWS_REGION"
  [[ "$tag" == "$LAB_PROJECT" ]] ||
    die "refusing to touch the EKS cluster $1: it does not carry the tag Project=$LAB_PROJECT (not created by this lab)"
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

# controller_leftovers CLUSTER -> load balancers, target groups and security groups the AWS Load
# Balancer Controller created for CLUSTER that still exist (one per line). They carry the tag
# elbv2.k8s.aws/cluster=CLUSTER, which the contract fixes to the lab cluster.
controller_leftovers() {
  local cluster=$1 sgs
  elbv2_arns_with_tag lb elbv2.k8s.aws/cluster "$cluster"
  elbv2_arns_with_tag tg elbv2.k8s.aws/cluster "$cluster"
  sgs="$(aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" \
    --query 'SecurityGroups[].GroupId' --output text)"
  printf '%s\n' "$sgs" | words_to_lines
}

# delete_controller_resources CLUSTER -> deletes, through the AWS API, what the controller created
# for CLUSTER: the way out when the controller cannot do it (cluster API unreachable, controller
# stopped). Only what carries the tag of the lab cluster is touched. Load balancers go first; target
# groups and security groups are retried while the load balancer network interfaces detach.
delete_controller_resources() {
  local cluster=$1 arn sg left tries
  while IFS= read -r arn; do
    [[ -n "$arn" ]] || continue
    log "deleting load balancer $arn"
    aws elbv2 delete-load-balancer --load-balancer-arn "$arn"
  done < <(elbv2_arns_with_tag lb elbv2.k8s.aws/cluster "$cluster")
  for ((tries = 0; tries < 20; tries++)); do
    while IFS= read -r arn; do
      [[ -n "$arn" ]] || continue
      aws elbv2 delete-target-group --target-group-arn "$arn" || log "target group $arn is still in use; retrying"
    done < <(elbv2_arns_with_tag tg elbv2.k8s.aws/cluster "$cluster")
    while IFS= read -r sg; do
      [[ -n "$sg" ]] || continue
      aws ec2 delete-security-group --group-id "$sg" || log "security group $sg is still in use; retrying"
    done < <(aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" \
      --query 'SecurityGroups[].GroupId' --output text | words_to_lines)
    left="$(controller_leftovers "$cluster")"
    [[ -n "$left" ]] || return 0
    log "waiting for $(wc -l <<<"$left") resource(s) of the controller to go away"
    sleep "${DESTROY_RETRY_SECONDS:-15}"
  done
  die "resources of the load balancer controller still present after the API cleanup:"$'\n'"$left"
}
