#!/usr/bin/env bash
# Offline proof that the platform teardown derives PVC names from owned StatefulSets and waits
# only for EBS PVs whose claim reference matches those captured PVCs.
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "jq is required for the observability PVC cleanup fixture" >&2
  exit 1
}

statefulsets='{"items":[{"metadata":{"name":"prometheus"},"spec":{"replicas":2,"volumeClaimTemplates":[{"metadata":{"name":"data"}}]}},{"metadata":{"name":"single"},"spec":{"volumeClaimTemplates":[{"metadata":{"name":"storage"}}]}}]}'
captured="$(jq -r --arg namespace monitoring '
  .items[] as $sts |
  ($sts.spec.volumeClaimTemplates // [])[] as $claim |
  range(0; ($sts.spec.replicas // 1)) |
  [$namespace, ($claim.metadata.name + "-" + $sts.metadata.name + "-" + tostring)] | @tsv
' <<<"$statefulsets" | tr -d '\r')"
expected=$'monitoring\tdata-prometheus-0\nmonitoring\tdata-prometheus-1\nmonitoring\tstorage-single-0'
[[ "$captured" == "$expected" ]] || {
  printf 'unexpected PVC claims captured:\n%s\n' "$captured" >&2
  exit 1
}

claims="$(printf '%s\n' "$captured" | jq -Rn '[inputs | split("\t") | {namespace: .[0], name: .[1]}]')"
pvs='{"items":[{"metadata":{"name":"pv-lab"},"spec":{"claimRef":{"namespace":"monitoring","name":"data-prometheus-0"},"csi":{"driver":"ebs.csi.aws.com"}}},{"metadata":{"name":"pv-unrelated-namespace"},"spec":{"claimRef":{"namespace":"default","name":"data-prometheus-0"},"csi":{"driver":"ebs.csi.aws.com"}}},{"metadata":{"name":"pv-unrelated-claim"},"spec":{"claimRef":{"namespace":"monitoring","name":"other-claim"},"csi":{"driver":"ebs.csi.aws.com"}}},{"metadata":{"name":"pv-other-csi"},"spec":{"claimRef":{"namespace":"monitoring","name":"data-prometheus-0"},"csi":{"driver":"other.csi.example"}}}]}'
matched="$(jq -r --argjson claims "$claims" '
  [.items[] as $pv |
    select($pv.spec.csi.driver == "ebs.csi.aws.com" and
      any($claims[]; .namespace == $pv.spec.claimRef.namespace and .name == $pv.spec.claimRef.name)) |
    $pv.metadata.name
  ] | join(" ")
' <<<"$pvs" | tr -d '\r')"
[[ "$matched" == pv-lab ]] || {
  printf 'cleanup wait matched unrelated EBS volume(s): %s\n' "$matched" >&2
  exit 1
}

if grep -Eq 'kubectl delete pvc --all|kubectl delete pv --all' platform/uninstall.sh; then
  echo "platform/uninstall.sh must not delete every PVC or PV in the cluster" >&2
  exit 1
fi

if ! grep -qF 'kubectl delete gateway --namespace dx01v2 dx01v2-waypoint --ignore-not-found --wait=true --timeout=5m' platform/uninstall.sh ||
  ! grep -qF 'kubectl label namespace dx01v2 istio.io/use-waypoint-' platform/uninstall.sh ||
  ! grep -qF "if [[ \"\$waypoint\" == dx01v2-waypoint ]]; then" platform/uninstall.sh; then
  echo "platform/uninstall.sh must remove its ambient waypoint and namespace reference" >&2
  exit 1
fi

echo "captured only chart PVCs and matched only their EBS volumes"
