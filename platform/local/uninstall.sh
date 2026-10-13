#!/usr/bin/env bash
# Removes what the local platform created outside the cluster, before terraform destroy deletes the
# cluster (the local twin of platform/uninstall.sh deleting the ALBs first):
#   1. stops Argo CD self-heal, then deletes every Gateway and every Service of type LoadBalancer
#      (cloud-provider-kind then removes its Envoy containers)
#   2. waits until no Envoy container of the cluster is left (fails loudly after 180 s)
# Everything else lives inside the kind cluster and goes away with it. Needs kubectl, docker and the
# KUBECONFIG written by scripts/local-lab.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../../scripts/lib/common.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

CLUSTER=tx01v2-local
WAIT_SECONDS=180

envoy_containers() {
  docker ps -a --filter "label=io.x-k8s.cloud-provider-kind.cluster=$CLUSTER" --format '{{.Names}}'
}

main() {
  local services i left
  require_cmd kubectl docker
  kubectl version >/dev/null 2>&1 || die "the lab cluster is not reachable (KUBECONFIG=${KUBECONFIG:-unset})"
  # Argo CD self-heals: with an app synced (dx01v2), it would recreate the Gateway deleted below and
  # cloud-provider-kind would start a new Envoy container after the wait. Stop the reconciler first.
  if kubectl -n argocd get statefulset argocd-application-controller >/dev/null 2>&1; then
    log "stopping the Argo CD application controller (no self-heal during the teardown)"
    kubectl -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
    kubectl -n argocd wait --for=delete pod -l app.kubernetes.io/name=argocd-application-controller --timeout=120s >/dev/null
  fi
  # Gateways first: Istio owns the Service of each Gateway and would recreate a deleted one.
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    kubectl delete gateways.gateway.networking.k8s.io --all --all-namespaces --wait=true --timeout=120s
  fi
  services="$(kubectl get services --all-namespaces --no-headers \
    -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type' | awk '$3 == "LoadBalancer" { print $1 "/" $2 }')"
  if [[ -n "$services" ]]; then
    while IFS=/ read -r ns name; do
      log "deleting Service $ns/$name (type LoadBalancer)"
      kubectl -n "$ns" delete service "$name" --wait=true --timeout=120s
    done <<<"$services"
  fi
  for i in $(seq 1 "$WAIT_SECONDS"); do
    left="$(envoy_containers)"
    [[ -z "$left" ]] && {
      log "no load balancer container left for $CLUSTER"
      return 0
    }
    ((i % 15 == 0)) && log "waiting for cloud-provider-kind to remove: $(tr '\n' ' ' <<<"$left")"
    sleep 1
  done
  die "load balancer containers still running after ${WAIT_SECONDS}s: $(tr '\n' ' ' <<<"$left")"
}

main "$@"
