#!/usr/bin/env bash
# Creates the kind cluster of the local lab and points its containerd at the lab registry. Called by
# terraform/envs/local (terraform_data.cluster, local-exec); the destroy-time provisioner runs
# `kind delete cluster` itself. Environment (set by Terraform):
#   CLUSTER, KIND_CONFIG, KIND_EXPERIMENTAL_DOCKER_NETWORK, REGISTRY_ENDPOINT (http://<registry ip>:5000),
#   REGISTRY_HOSTS (space-separated names the node maps to it: the push name localhost:<port> and the
#   in-cluster name registry.tx01v2.local)
# usage: scripts/local/kind-cluster.sh create
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

cluster_exists() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null)" || return 1
  grep -qx "$CLUSTER" <<<"$clusters"
}

create() {
  local work node networks
  require_cmd kind docker
  : "${CLUSTER:?CLUSTER is required}" "${KIND_CONFIG:?KIND_CONFIG is required}"
  : "${KIND_EXPERIMENTAL_DOCKER_NETWORK:?KIND_EXPERIMENTAL_DOCKER_NETWORK is required}"
  : "${REGISTRY_HOSTS:?REGISTRY_HOSTS is required}" "${REGISTRY_ENDPOINT:?REGISTRY_ENDPOINT is required}"
  if cluster_exists; then
    log "kind cluster $CLUSTER already exists: reusing it"
  else
    work="$(mktemp -d)"
    # The kubeconfig of the create step is thrown away: scripts/local-lab.sh writes its own.
    kind create cluster --name "$CLUSTER" --config "$KIND_CONFIG" --kubeconfig "$work/kubeconfig" --wait 180s
    rm -rf "$work"
  fi
  for node in $(kind get nodes --name "$CLUSTER"); do
    networks="$(docker inspect "$node" --format '{{json .NetworkSettings.Networks}}')"
    [[ "$networks" == *"\"$KIND_EXPERIMENTAL_DOCKER_NETWORK\":"* ]] ||
      die "node $node is not on the Docker network $KIND_EXPERIMENTAL_DOCKER_NETWORK (delete it: kind delete cluster --name $CLUSTER)"
    # localhost:<port> inside the node is the node itself, and the in-cluster name has no DNS: send both
    # to the registry container (https://kind.sigs.k8s.io/docs/user/local-registry/).
    for host in $REGISTRY_HOSTS; do
      docker exec "$node" mkdir -p "/etc/containerd/certs.d/$host"
      printf 'server = "%s"\n\n[host."%s"]\n  capabilities = ["pull", "resolve"]\n' "$REGISTRY_ENDPOINT" "$REGISTRY_ENDPOINT" |
        docker exec -i "$node" cp /dev/stdin "/etc/containerd/certs.d/$host/hosts.toml"
      log "node $node: $host -> $REGISTRY_ENDPOINT"
    done
  done
}

case "${1:-}" in
  create) create ;;
  *) die "usage: $0 create" ;;
esac
