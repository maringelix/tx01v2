# shellcheck shell=bash
# Helpers of the local lab scripts (platform/local/*.sh). Source after scripts/lib/common.sh.

LOCAL_TF_DIR="$REPO_ROOT/terraform/envs/local"

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
  local release=$1 ns=$2 tgz=$3
  shift 3
  log "helm upgrade --install $release ($(basename "$tgz"), namespace $ns)"
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
