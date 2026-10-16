# shellcheck shell=bash
# Helpers of platform/install.sh for the profile full: the charts of the local lab (same versions,
# archive SHA256 and image digests) with the values of the cloud. Source after scripts/lib/common.sh.

# load_pins FILE... -> reads KEY=VALUE pin files without executing them.
load_pins() {
  local f line
  for f in "$@"; do
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
  mkdir -p "$dir"
  tgz="$(find "$dir" -maxdepth 1 -name '*.tgz' -print -quit)"
  if [[ -n "$tgz" && -f "$tgz" ]]; then
    got="$(sha256_of "$tgz")"
    [[ "$got" == "$sha" ]] && {
      printf '%s' "$tgz"
      return 0
    }
    rm -rf "${dir:?}"
    mkdir -p "$dir"
  fi
  helm pull "$chart" --repo "$repo" --version "$version" --destination "$dir" >&2
  tgz="$(find "$dir" -maxdepth 1 -name '*.tgz' -print -quit)"
  [[ -n "$tgz" && -f "$tgz" ]] || die "helm pull did not produce the $chart $version archive"
  got="$(sha256_of "$tgz")"
  [[ "$got" == "$sha" ]] || die "refusing $chart $version: SHA256 $got differs from the pinned $sha"
  printf '%s' "$tgz"
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

# chart_table -> the lines of platform/full/charts.txt (comments and blank lines left out), one chart
# per line: <repo key> <version key> <sha256 key> <chart> <release> <namespace> <values files>. The
# values files are paths under platform/, comma separated, applied in that order (the base of the
# local lab first, the overlay of the cloud after it).
chart_table() {
  grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/platform/full/charts.txt"
}

# chart_entry CHART -> the table line of one chart.
chart_entry() {
  local line
  line="$(chart_table | awk -v c="$1" '$4 == c { print; exit }')"
  [[ -n "$line" ]] || die "platform/full/charts.txt has no entry for the chart $1"
  printf '%s' "$line"
}
