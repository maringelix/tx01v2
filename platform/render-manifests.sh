#!/usr/bin/env bash
# Prints every platform/manifests/*.yaml as one multi-document YAML stream with the placeholder
# __AWS_REGION__ replaced. Used by platform/install.sh (| kubectl apply -f -) and by the harness
# (| kubeconform), so what is validated is exactly what gets applied.
# Usage: platform/render-manifests.sh <aws-region> [--full <github-owner>] [--alb-source-cidr CIDR] [--only <file>]
#   --full  also prints platform/manifests/full/*.yaml (the profile full of platform/install.sh), with
#           __TX_REPO_URL__ and __DX_REPO_URL__ replaced by the repositories of the GitHub owner (the
#           fork) and __DX_REVISION__ by the branch that the deploy workflow of dx01v2 updates
#   --only  prints just that file (a path under platform/manifests, for example full/tracing.yaml): the
#           installer applies the manifests that need a CRD after the chart that brings it
set -euo pipefail

DX_REVISION=gitops/aws
OWNER_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$'

usage() {
  echo "usage: $0 <aws-region> [--full <github-owner>] [--only <file>]   (for example: $0 us-east-1 --full maringelix)" >&2
  exit 2
}

main() {
  local region=${1:-} owner="" only="" alb_source_cidr=192.0.2.0/24 dir f content out="" full=0
  [[ "$region" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || usage
  shift
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifests"
  while (($# > 0)); do
    case "$1" in
      --full)
        [[ "${2:-}" =~ $OWNER_RE ]] || usage
        full=1
        owner=$2
        shift 2
        ;;
      --only)
        [[ "${2:-}" =~ ^[a-z0-9-]+(/[a-z0-9-]+)*\.yaml$ && -f "$dir/$2" ]] || usage
        only=$2
        shift 2
        ;;
      --alb-source-cidr)
        [[ "${2:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || usage
        alb_source_cidr=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  shopt -s nullglob
  local -a files=("$dir"/*.yaml)
  ((${#files[@]} > 0)) || {
    echo "error: no manifests in $dir" >&2
    exit 1
  }
  ((full == 0)) || files+=("$dir"/full/*.yaml)
  [[ -z "$only" ]] || files=("$dir/$only")
  for f in "${files[@]}"; do
    content="$(<"$f")"
    content="${content//__AWS_REGION__/$region}"
    if ((full == 1)); then
      content="${content//__TX_REPO_URL__/https://github.com/$owner/tx01v2.git}"
      content="${content//__DX_REPO_URL__/https://github.com/$owner/dx01v2.git}"
      content="${content//__GITHUB_OWNER__/$owner}"
      content="${content//__DX_REVISION__/$DX_REVISION}"
      content="${content//__ALB_SOURCE_CIDR__/$alb_source_cidr}"
    fi
    out+="---"$'\n'"# Source: platform/manifests/${f#"$dir"/}"$'\n'"$content"$'\n'
  done
  if [[ "$out" =~ __[A-Z][A-Z0-9_]*__ ]]; then
    echo "error: unresolved placeholder ${BASH_REMATCH[0]} in platform/manifests" >&2
    exit 1
  fi
  printf '%s' "$out"
}

main "$@"
