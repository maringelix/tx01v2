#!/usr/bin/env bash
# Lists what the lab may have left behind after a destroy. Read-only (Describe/List/Get calls).
#   BILLABLE  still costs money        -> exit 1
#   ORPHANED  free, but blocks or confuses the next round (shown, exit code unaffected)
#   INFO      expected (bootstrap resources, KMS keys pending deletion)
# Usage: AWS_REGION=us-east-1 scripts/leftovers.sh [--retry-for SECONDS]
#   --retry-for re-scans every 60 s until nothing billable remains or the time is up
#   (resources in transition right after a destroy). Exit 2 on usage or AWS API errors.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"

PROJECT=tx01v2
CLUSTER="${CLUSTER_NAME:-tx01v2-lab}"
NAME_PREFIX=tx01v2-lab
LOG_GROUP_PREFIXES=("/aws/eks/$NAME_PREFIX" "/aws/vpc/$NAME_PREFIX" "/aws/rds/instance/$NAME_PREFIX" "aws-waf-logs-$NAME_PREFIX")

BILLABLE=0

found() { # LEVEL WHAT ITEMS...
  local level=$1 what=$2 item
  shift 2
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    printf '%-9s %-34s %s\n' "$level" "$what" "$item"
    [[ "$level" == BILLABLE ]] && BILLABLE=$((BILLABLE + 1))
  done
  return 0
}

lines() { # CMD... -> runs an AWS CLI query and prints one item per line; fails on API errors
  local out
  out="$("$@")" || exit 2
  printf '%s\n' "$out" | words_to_lines
}

as_array() { # NAME CMD... -> NAME=(items)
  local -n _arr=$1
  local out
  shift
  out="$(lines "$@")" || exit 2
  _arr=()
  [[ -z "$out" ]] || mapfile -t _arr <<<"$out"
}

scan() {
  local -a items=() more=()
  local p key state

  as_array items aws eks list-clusters --query "clusters[?@=='$CLUSTER']" --output text
  found BILLABLE "EKS cluster" "${items[@]}"

  as_array items aws ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
  as_array more aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=$PROJECT" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
  found BILLABLE "EC2 instance" "${items[@]}" "${more[@]}"

  as_array items aws ec2 describe-nat-gateways \
    --filter "Name=tag:Project,Values=$PROJECT" "Name=state,Values=pending,available" \
    --query 'NatGateways[].NatGatewayId' --output text
  found BILLABLE "NAT gateway" "${items[@]}"

  # Every unassociated Elastic IP is billed (dedicated lab account assumed).
  as_array items aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text
  found BILLABLE "unattached Elastic IP" "${items[@]}"

  as_array items elbv2_arns_with_tag lb elbv2.k8s.aws/cluster "$CLUSTER"
  as_array more elbv2_arns_with_tag lb Project "$PROJECT"
  found BILLABLE "load balancer (ELBv2)" "${items[@]}" "${more[@]}"

  as_array items elbv2_arns_with_tag tg elbv2.k8s.aws/cluster "$CLUSTER"
  found ORPHANED "target group (ELBv2)" "${items[@]}"

  as_array items aws ec2 describe-security-groups \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" --query 'SecurityGroups[].GroupId' --output text
  as_array more aws ec2 describe-security-groups \
    --filters "Name=tag:Project,Values=$PROJECT" --query 'SecurityGroups[].GroupId' --output text
  found ORPHANED "security group" "${items[@]}" "${more[@]}"

  as_array items aws ec2 describe-volumes \
    --filters "Name=tag:Project,Values=$PROJECT" --query 'Volumes[].VolumeId' --output text
  as_array more aws ec2 describe-volumes \
    --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" --query 'Volumes[].VolumeId' --output text
  found BILLABLE "EBS volume" "${items[@]}" "${more[@]}"

  as_array items aws rds describe-db-instances \
    --query "DBInstances[?starts_with(DBInstanceIdentifier, '$PROJECT-')].DBInstanceIdentifier" --output text
  found BILLABLE "RDS instance" "${items[@]}"

  as_array items aws rds describe-db-snapshots --snapshot-type manual \
    --query "DBSnapshots[?starts_with(DBSnapshotIdentifier, '$PROJECT-')].DBSnapshotIdentifier" --output text
  found BILLABLE "RDS manual snapshot" "${items[@]}"

  as_array items aws rds describe-db-instance-automated-backups \
    --query "DBInstanceAutomatedBackups[?starts_with(DBInstanceIdentifier, '$PROJECT-') && Status=='retained'].DBInstanceAutomatedBackupsArn" --output text
  found BILLABLE "RDS retained automated backup" "${items[@]}"

  for p in "${LOG_GROUP_PREFIXES[@]}"; do
    as_array items aws logs describe-log-groups --log-group-name-prefix "$p" --query 'logGroups[].logGroupName' --output text
    found BILLABLE "CloudWatch log group" "${items[@]}"
  done

  as_array items aws secretsmanager list-secrets --filters "Key=name,Values=$NAME_PREFIX/" \
    --query 'SecretList[?DeletedDate==null].Name' --output text
  found BILLABLE "secret" "${items[@]}"
  as_array items aws secretsmanager list-secrets --include-planned-deletion --filters "Key=name,Values=$NAME_PREFIX/" \
    --query 'SecretList[?DeletedDate!=null].Name' --output text
  found ORPHANED "secret pending deletion" "${items[@]}"

  as_array items aws ecr describe-repositories --query "repositories[?starts_with(repositoryName, 'dx01v2/')].repositoryName" --output text
  found BILLABLE "ECR repository" "${items[@]}"

  as_array items aws wafv2 list-web-acls --scope REGIONAL --query "WebACLs[?Name=='$NAME_PREFIX'].ARN" --output text
  found BILLABLE "WAF web ACL" "${items[@]}"

  as_array items aws ssm get-parameters-by-path --path "$LAB_SSM_PREFIX/" --recursive --query 'Parameters[].Name' --output text
  found ORPHANED "SSM parameter" "${items[@]}"

  as_array items aws resourcegroupstaggingapi get-resources --resource-type-filters kms:key \
    --tag-filters "Key=Project,Values=$PROJECT" --query 'ResourceTagMappingList[].ResourceARN' --output text
  for key in "${items[@]}"; do
    state="$(aws kms describe-key --key-id "$key" --query 'KeyMetadata.KeyState' --output text)" || exit 2
    case "$state" in
      PendingDeletion) found INFO "KMS key pending deletion" "$key" ;;
      *) found BILLABLE "KMS key ($state)" "$key" ;;
    esac
  done

  # Broad sweep: anything else still tagged Project=tx01v2 outside the bootstrap stack. The Tagging API
  # index can lag a few minutes behind deletions, so these lines are for review, not for the exit code.
  as_array items aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=$PROJECT" \
    --query "ResourceTagMappingList[?!(Tags[?Key=='Stack' && Value=='bootstrap'])].ResourceARN" --output text
  for key in "${items[@]}"; do
    case "$key" in
      arn:*:kms:*) ;; # reported above
      *) found ORPHANED "tagged resource (review)" "$key" ;;
    esac
  done

  as_array items aws resourcegroupstaggingapi get-resources \
    --tag-filters "Key=Project,Values=$PROJECT" "Key=Stack,Values=bootstrap" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text
  found INFO "bootstrap resource (kept)" "${items[@]}"
}

main() {
  local retry_for=0 deadline
  while (($# > 0)); do
    case "$1" in
      --retry-for)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || { echo "usage: $0 [--retry-for SECONDS]" >&2; exit 2; }
        retry_for=$2
        shift 2
        ;;
      *) echo "usage: $0 [--retry-for SECONDS]" >&2; exit 2 ;;
    esac
  done
  # Exit 2 (not 1) for setup problems, so they are never mistaken for "billable leftovers found".
  command -v aws >/dev/null 2>&1 || { echo "error: AWS CLI v2 is required" >&2; exit 2; }
  [[ -n "${AWS_REGION:-}" ]] || { echo "error: set AWS_REGION to the lab region (for example: export AWS_REGION=us-east-1)" >&2; exit 2; }
  require_aws_region
  aws sts get-caller-identity --query Account --output text >/dev/null || exit 2

  deadline=$((SECONDS + retry_for))
  while :; do
    BILLABLE=0
    log "scanning $AWS_REGION for leftovers of $CLUSTER ..."
    scan
    if ((BILLABLE == 0)); then
      log "result: nothing billable left by the lab in $AWS_REGION."
      return 0
    fi
    if ((SECONDS + 60 > deadline)); then
      log "result: $BILLABLE billable leftover(s). Delete them (docs/RUNBOOK.md, section sobras) and re-run."
      return 1
    fi
    log "$BILLABLE billable item(s) still present; re-scanning in 60 s"
    sleep 60
  done
}

main "$@"
