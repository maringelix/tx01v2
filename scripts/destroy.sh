#!/usr/bin/env bash
# Destroys the lab: the platform layer, terraform/envs/lab and the leftover check. CLOUD-MUTATING.
# Run by .github/workflows/terraform-destroy.yml (after the typed confirmation and the approval of
# the lab environment); by hand it needs the same environment as the workflow.
#   1. platform/uninstall.sh, when the cluster exists (it deletes the load balancers the controller
#      created). When it fails (cluster API unreachable, controller stopped, timeout), what the
#      controller created is deleted through the AWS API instead: only load balancers, target
#      groups and security groups tagged elbv2.k8s.aws/cluster=tx01v2-lab.
#   2. terraform init and destroy, also after a failed step 1: the VPC and the cluster go away
#      even when the controller could not clean up.
#   3. scripts/leftovers.sh --retry-for 900, whatever happened before.
# Exit code 0 only when terraform destroy and the leftover check both passed; a failed uninstall that
# the API cleanup recovered is a warning. Every failure is printed, nothing is ignored.
# usage: scripts/destroy.sh [--force-unlock LOCK_ID]
#   --force-unlock  first removes the Terraform state lock of an interrupted apply or destroy
#                   (the S3 lock file); LOCK_ID is the "ID" of the lock error message.
# Environment: AWS_REGION, TF_STATE_BUCKET and the TF_VAR_* variables of the lab (as in the workflow).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

TF_DIR="$REPO_ROOT/terraform/envs/lab"

usage() {
  echo "usage: $0 [--force-unlock LOCK_ID]" >&2
  exit 2
}

main() {
  local force_unlock="" exists rc=0 uninstalled=1
  while (($# > 0)); do
    case "$1" in
      --force-unlock)
        [[ "${2:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || usage
        force_unlock=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  require_cmd aws terraform
  require_aws_region
  [[ -n "${TF_STATE_BUCKET:-}" ]] || die "set TF_STATE_BUCKET to the state bucket of the bootstrap"

  exists="$(aws eks list-clusters --query "contains(clusters, '$LAB_CLUSTER')" --output text)" || exists=unknown
  if [[ "$exists" == False ]]; then
    log "cluster $LAB_CLUSTER not found: nothing to uninstall"
  else
    bash "$REPO_ROOT/platform/uninstall.sh" || uninstalled=0
  fi
  if ((uninstalled == 0)) || [[ -n "$(controller_leftovers "$LAB_CLUSTER" 2>/dev/null)" ]]; then
    log "warning: platform/uninstall.sh did not finish; deleting what the controller created through the AWS API"
    delete_controller_resources "$LAB_CLUSTER" || rc=1
  fi

  terraform -chdir="$TF_DIR" init -input=false -lockfile=readonly \
    -backend-config="bucket=$TF_STATE_BUCKET" -backend-config="region=$AWS_REGION" || rc=1
  if [[ -n "$force_unlock" ]]; then
    terraform -chdir="$TF_DIR" force-unlock -force "$force_unlock" || rc=1
  fi
  terraform -chdir="$TF_DIR" destroy -auto-approve -input=false -no-color || rc=1

  # The leftover check runs after a failed destroy too: it says what still costs money.
  bash "$REPO_ROOT/scripts/leftovers.sh" --retry-for 900 || rc=1
  return "$rc"
}

main "$@"
