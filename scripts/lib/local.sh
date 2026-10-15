# shellcheck shell=bash
# Helpers of the local lab scripts (platform/local/*.sh). Source after scripts/lib/common.sh.

LOCAL_TF_DIR="$REPO_ROOT/terraform/envs/local"
LOCAL_CLUSTER=tx01v2-local

# require_lab_context -> refuses to run kubectl against anything but the kind cluster of the local lab.
# KUBECONFIG must be one file (scripts/local-lab.sh writes $LOCAL_STATE_DIR/kubeconfig) whose current
# context is kind-tx01v2-local: the kube contexts of the machine (the clusters of whoever forked the
# lab) are never used, also when a script of platform/local runs on its own.
require_lab_context() {
  local want="kind-$LOCAL_CLUSTER" got
  [[ -n "${KUBECONFIG:-}" && "$KUBECONFIG" != *:* && -f "$KUBECONFIG" ]] ||
    die "KUBECONFIG must be the kubeconfig file of the local lab: run this through scripts/local-lab.sh"
  got="$(kubectl config current-context 2>/dev/null)" || got=""
  [[ "$got" == "$want" ]] ||
    die "refusing to touch the kube context '${got:-none}': only $want (the local lab) is allowed; run this through scripts/local-lab.sh"
}

# tf_out NAME -> value of a terraform/envs/local output (needs the TF_DATA_DIR of scripts/local-lab.sh).
tf_out() {
  terraform -chdir="$LOCAL_TF_DIR" output -raw "$1"
}

# local_load_versions -> reads platform/versions.env and platform/local/versions.env (KEY=VALUE lines)
# without executing them.
local_load_versions() {
  local f line
  for f in "$REPO_ROOT/platform/versions.env" "$REPO_ROOT/platform/local/versions.env"; do
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
      [[ "$line" =~ ^([A-Z0-9_]+)=([A-Za-z0-9._:/-]+)$ ]] || die "invalid line in $f: $line"
      printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    done <"$f"
  done
}

# pull_chart DEST_DIR REPO CHART VERSION SHA256 -> prints the path of the verified chart archive.
pull_chart() {
  local dest=$1 repo=$2 chart=$3 version=$4 sha=$5 dir tgz got
  dir="$dest/$chart-$version"
  rm -rf "$dir"
  mkdir -p "$dir"
  helm pull "$chart" --repo "$repo" --version "$version" --destination "$dir" >&2
  tgz="$(find "$dir" -maxdepth 1 -name '*.tgz' -print -quit)"
  [[ -n "$tgz" && -f "$tgz" ]] || die "helm pull did not produce the $chart $version archive"
  got="$(sha256_of "$tgz")"
  [[ "$got" == "$sha" ]] || die "refusing $chart $version: SHA256 $got differs from the pinned $sha"
  printf '%s' "$tgz"
}

# helm_install RELEASE NAMESPACE CHART_ARCHIVE [helm args...] -> upgrade --install and wait.
helm_install() {
  local release=$1 ns=$2 tgz=$3 chart small=""
  shift 3
  # LOCAL_SIZE=small: platform/local/values/small/<chart>.yaml (chart = the archive name without its
  # version) goes last, so its sizes win over every other values file (docs/LAB_LOCAL.md).
  chart="$(basename "$tgz" .tgz)"
  chart="${chart%-*}"
  if [[ "${LOCAL_SIZE:-default}" == small && -f "$REPO_ROOT/platform/local/values/small/$chart.yaml" ]]; then
    small="$REPO_ROOT/platform/local/values/small/$chart.yaml"
    set -- "$@" --values "$small"
  fi
  log "helm upgrade --install $release ($(basename "$tgz"), namespace $ns${small:+, size small})"
  helm upgrade --install "$release" "$tgz" --namespace "$ns" "$@" \
    --wait=watcher --rollback-on-failure --timeout 10m >/dev/null
}

# retry ATTEMPTS SECONDS CMD... -> runs CMD until it succeeds (admission webhooks need a few seconds
# after their Deployment is ready).
retry() {
  local attempts=$1 pause=$2 i
  shift 2
  for i in $(seq 1 "$attempts"); do
    "$@" && return 0
    ((i < attempts)) && sleep "$pause"
  done
  return 1
}
