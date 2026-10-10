#!/usr/bin/env bash
# Prints every platform/manifests/*.yaml as one multi-document YAML stream with the placeholder
# __AWS_REGION__ replaced. Used by platform/install.sh (| kubectl apply -f -) and by the harness
# (| kubeconform), so what is validated is exactly what gets applied.
# Usage: platform/render-manifests.sh <aws-region>
set -euo pipefail

main() {
  local region=${1:-} dir f content out=""
  [[ "$region" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] || {
    echo "usage: $0 <aws-region>   (for example: $0 us-east-1)" >&2
    exit 2
  }
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifests"
  shopt -s nullglob
  local -a files=("$dir"/*.yaml)
  ((${#files[@]} > 0)) || {
    echo "error: no manifests in $dir" >&2
    exit 1
  }
  for f in "${files[@]}"; do
    content="$(<"$f")"
    out+="---"$'\n'"# Source: platform/manifests/$(basename "$f")"$'\n'"${content//__AWS_REGION__/$region}"$'\n'
  done
  if [[ "$out" =~ __[A-Z][A-Z0-9_]*__ ]]; then
    echo "error: unresolved placeholder ${BASH_REMATCH[0]} in platform/manifests" >&2
    exit 1
  fi
  printf '%s' "$out"
}

main "$@"
