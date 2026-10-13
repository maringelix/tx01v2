#!/usr/bin/env bash
# The local lab (docs/RUNBOOK.md, "Lab local"): the AWS lab of tx01v2 emulated on the Docker daemon of
# this machine, with the full platform of the v1 lab on top. Nothing here touches AWS.
# usage: scripts/local-lab.sh <command>
#   up [--infra-only]  terraform apply of terraform/envs/local, then platform/local/install.sh
#   down               platform/local/uninstall.sh, terraform destroy, scripts/leftovers-local.sh
#   check              platform/local/check.sh (probes of every platform component)
#   e2e                up + check + down; down always runs, also after a failure (unless KEEP_LAB=1)
#   kubeconfig         writes the kubeconfig of the lab cluster and prints its path
#   status             containers and cluster of the lab
# Environment:
#   LOCAL_STATE_DIR        Terraform state, data dir and kubeconfig
#                          (default: ${XDG_STATE_HOME:-$HOME/.local/state}/tx01v2-local)
#   LOCAL_KIND_INTERNAL=1  this script runs inside a container that drives the host Docker daemon
#                          (docker.sock): join the lab network and use the internal API address
#   KEEP_LAB=1             e2e keeps the lab (remove it later with: scripts/local-lab.sh down)
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

TF_DIR="$REPO_ROOT/terraform/envs/local"
LOCAL_STATE_DIR="${LOCAL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tx01v2-local}"
CLUSTER=tx01v2-local
NETWORK=tx01v2-local
export TF_DATA_DIR="$LOCAL_STATE_DIR/tfdata" TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
export KUBECONFIG="$LOCAL_STATE_DIR/kubeconfig"
export LOCAL_STATE_DIR

tf_init() {
  mkdir -p "$LOCAL_STATE_DIR" "$TF_PLUGIN_CACHE_DIR"
  chmod 700 "$LOCAL_STATE_DIR"
  terraform -chdir="$TF_DIR" init -input=false -no-color -lockfile=readonly \
    -backend-config="path=$LOCAL_STATE_DIR/terraform.tfstate" >"$LOCAL_STATE_DIR/init.log" 2>&1 || {
    cat "$LOCAL_STATE_DIR/init.log" >&2
    die "terraform init failed"
  }
}

cluster_exists() {
  local clusters
  clusters="$(kind get clusters 2>/dev/null)" || return 1
  grep -qx "$CLUSTER" <<<"$clusters"
}

self_container() {
  [[ "${LOCAL_KIND_INTERNAL:-0}" == 1 ]] && hostname
}

write_kubeconfig() {
  local self networks
  cluster_exists || die "the kind cluster $CLUSTER does not exist (run: scripts/local-lab.sh up)"
  if self="$(self_container)"; then
    # Inside a container the published 127.0.0.1 port of the API server belongs to the host: join the
    # lab network and talk to the control plane by its container address instead.
    networks="$(docker inspect "$self" --format '{{json .NetworkSettings.Networks}}')"
    [[ "$networks" == *"\"$NETWORK\":"* ]] || docker network connect "$NETWORK" "$self"
    kind get kubeconfig --internal --name "$CLUSTER" >"$KUBECONFIG"
  else
    kind get kubeconfig --name "$CLUSTER" >"$KUBECONFIG"
  fi
  chmod 600 "$KUBECONFIG"
  kubectl version >/dev/null
}

leave_network() {
  local self networks
  self="$(self_container)" || return 0
  networks="$(docker inspect "$self" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null)" || return 0
  if [[ "$networks" == *"\"$NETWORK\":"* ]]; then
    docker network disconnect "$NETWORK" "$self"
  fi
}

cmd_up() {
  local infra_only=0
  [[ "${1:-}" == --infra-only ]] && infra_only=1
  require_cmd terraform kind docker kubectl
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
  tf_init
  log "terraform apply (terraform/envs/local)"
  terraform -chdir="$TF_DIR" apply -input=false -auto-approve -no-color
  write_kubeconfig
  log "kind cluster $CLUSTER: $(kubectl get nodes --no-headers | awk '{ printf "%s %s %s; ", $1, $2, $5 }')"
  if ((infra_only)); then
    log "--infra-only: the platform was not installed"
    return 0
  fi
  bash "$REPO_ROOT/platform/local/install.sh"
}

cmd_down() {
  require_cmd terraform kind docker kubectl
  if cluster_exists; then
    write_kubeconfig
    bash "$REPO_ROOT/platform/local/uninstall.sh"
  fi
  leave_network
  tf_init
  log "terraform destroy (terraform/envs/local)"
  terraform -chdir="$TF_DIR" destroy -input=false -auto-approve -no-color
  rm -f "$KUBECONFIG"
  bash "$REPO_ROOT/scripts/leftovers-local.sh"
}

cmd_check() {
  write_kubeconfig
  bash "$REPO_ROOT/platform/local/check.sh"
}

cmd_e2e() {
  local rc=0
  # shellcheck disable=SC2329 # invoked through the EXIT trap
  finish() {
    rc=$?
    if [[ "${KEEP_LAB:-0}" == 1 ]]; then
      log "KEEP_LAB=1: keeping the local lab (remove it with: scripts/local-lab.sh down)"
    elif ! cmd_down; then
      log "error: the teardown failed; inspect with scripts/local-lab.sh status and scripts/leftovers-local.sh"
      rc=1
    fi
    exit "$rc"
  }
  trap finish EXIT
  cmd_up
  cmd_check
}

cmd_status() {
  docker ps -a --filter label=tx01v2.lab=local --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  docker ps -a --filter "label=io.x-k8s.cloud-provider-kind.cluster=$CLUSTER" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
  if cluster_exists; then
    write_kubeconfig
    kubectl get nodes -o wide
  else
    log "kind cluster $CLUSTER: absent"
  fi
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    up) cmd_up "$@" ;;
    down) cmd_down ;;
    check) cmd_check ;;
    e2e) cmd_e2e ;;
    kubeconfig)
      write_kubeconfig
      printf '%s\n' "$KUBECONFIG"
      ;;
    status) cmd_status ;;
    *) die "usage: $0 up [--infra-only] | down | check | e2e | kubeconfig | status" ;;
  esac
}

main "$@"
