#!/usr/bin/env bash
# Read-only check after `scripts/local-lab.sh down`: fails when anything of the local lab survived on
# this machine (the local twin of scripts/leftovers.sh). Looks for:
#   - containers, networks and volumes labelled tx01v2.lab=local (everything Terraform created)
#   - the kind cluster tx01v2-local
#   - Envoy containers that cloud-provider-kind started for Services of type LoadBalancer
#     (created outside the Terraform state, like the ALBs of the AWS Load Balancer Controller)
# The pinned images stay in the local Docker cache on purpose (keep_locally): they are not lab resources.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

CLUSTER=tx01v2-local
found=0

report() { # WHAT LINES
  if [[ -n "$2" ]]; then
    printf 'LEFTOVER %s:\n  %s\n' "$1" "${2//$'\n'/$'\n  '}"
    found=1
  else
    printf 'ok: no %s\n' "$1"
  fi
}

main() {
  local out clusters
  require_cmd docker
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
  out="$(docker ps -a --filter label=tx01v2.lab=local --format '{{.Names}} ({{.Status}})')"
  report "containers labelled tx01v2.lab=local" "$out"
  out="$(docker ps -a --filter "label=io.x-k8s.cloud-provider-kind.cluster=$CLUSTER" --format '{{.Names}} ({{.Status}})')"
  report "cloud-provider-kind load balancer containers of $CLUSTER" "$out"
  out="$(docker ps -a --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --format '{{.Names}} ({{.Status}})')"
  report "kind node containers of $CLUSTER" "$out"
  out="$(docker network ls --filter label=tx01v2.lab=local --format '{{.Name}}')"
  report "networks labelled tx01v2.lab=local" "$out"
  out="$(docker volume ls --filter label=tx01v2.lab=local --format '{{.Name}}')"
  report "volumes labelled tx01v2.lab=local" "$out"
  if command -v kind >/dev/null 2>&1; then
    clusters="$(kind get clusters 2>/dev/null || true)"
    report "kind cluster $CLUSTER" "$(grep -x "$CLUSTER" <<<"$clusters" || true)"
  fi
  if ((found)); then
    die "the local lab left resources behind (see above); remove them, then run this check again"
  fi
  log "no leftovers of the local lab"
}

main "$@"
