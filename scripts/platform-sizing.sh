#!/usr/bin/env bash
# Reproduce the profile full resource-request total from the rendered chart manifests.
# Usage: scripts/platform-sizing.sh <node-count> <directory-with-rendered-yaml>
# The result includes Deployment/StatefulSet replicas, DaemonSets times node-count, all pod
# containers (including init containers), and Prometheus/Alertmanager spec.resources.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage() {
  echo "usage: $0 <node-count> <render-directory>" >&2
  exit 2
}

main() {
  local nodes=${1:-} render_dir=${2:-}
  local file output cpu memory
  local -a files=()
  [[ "$nodes" =~ ^[1-9][0-9]*$ && -d "$render_dir" ]] || usage
  mapfile -t files < <(find "$render_dir" -maxdepth 1 -type f -name '*.yaml' -print | sort)
  ((${#files[@]} > 0)) || die "no Helm renders found in $render_dir"
  cpu=0
  memory=0
  for file in "${files[@]}"; do
    output="$(awk -v nodes="$nodes" -f "$REPO_ROOT/scripts/platform-sizing.awk" "$file")"
    cpu=$((cpu + $(awk -F= '$1 == "cpu_millicores" { print $2 }' <<<"$output")))
    memory=$((memory + $(awk -F= '$1 == "memory_mib" { print $2 }' <<<"$output")))
  done
  printf 'cpu_millicores=%s\nmemory_mib=%s\nnodes=%s\n' "$cpu" "$memory" "$nodes"
}

main "$@"
