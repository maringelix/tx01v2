#!/usr/bin/env bash
# The local lab (docs/RUNBOOK.md, "Lab local"): the AWS lab of tx01v2 emulated on the Docker daemon of
# this machine, with the full platform of the v1 lab on top. Nothing here touches AWS.
# usage: scripts/local-lab.sh <command>
#   preflight          checks the machine (what up checks first); creates nothing
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
# Before it creates anything, `up` checks the machine (pre-flight): the Docker CLI and the Terraform
# provider talk to the same daemon, the lab network does not overlap a network or a route of the
# machine, the registry port is free, and no lab of another state directory lives on the daemon.
# `down` and `e2e` never touch a lab that this state directory did not create (the dx repositories
# keep their own state directory, so they cannot destroy the lab you keep with `make local-up`).
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
LOCAL_TOPOLOGY="${LOCAL_TOPOLOGY:-single}"
[[ "$LOCAL_TOPOLOGY" == single || "$LOCAL_TOPOLOGY" == ha ]] || die 'LOCAL_TOPOLOGY must be single or ha'
[[ "$LOCAL_TOPOLOGY" != ha || "${LOCAL_SIZE:-default}" != small ]] || die 'HA topology requires the default size (12 GiB Docker recommended)'
export TF_VAR_local_topology="$LOCAL_TOPOLOGY"

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

# --- pre-flight --------------------------------------------------------------------------------

# lab_state_exists -> the Terraform state of THIS state directory holds resources of the lab.
lab_state_exists() {
  [[ -s "$LOCAL_STATE_DIR/terraform.tfstate" ]] && grep -q '"type":' "$LOCAL_STATE_DIR/terraform.tfstate"
}

# lab_present -> a lab already lives on the Docker daemon: the kind cluster or a labeled container.
lab_present() {
  local ids
  if cluster_exists; then
    return 0
  fi
  ids="$(docker ps -aq --filter label=tx01v2.lab=local)" || return 1
  [[ -n "$ids" ]]
}

# require_own_lab ACTION -> refuses to go on when a lab lives on the daemon but this state directory
# holds no state of it: it was created with another LOCAL_STATE_DIR (the other repository of the
# pair, another checkout), and acting on it would destroy something this run did not create.
require_own_lab() {
  if lab_present && ! lab_state_exists; then
    die "a tx01v2 lab already lives on this Docker daemon, but $LOCAL_STATE_DIR holds no state of it (another LOCAL_STATE_DIR or checkout created it): $1 refused. Run the command with the LOCAL_STATE_DIR that created it, or remove it by hand: kind delete cluster --name $CLUSTER; docker rm -f \$(docker ps -aq --filter label=tx01v2.lab=local)"
  fi
}

# cidr_range A.B.C.D/N -> "first last" of the block as integers.
cidr_range() {
  local a b c d start size
  IFS=. read -r a b c d <<<"${1%/*}"
  size=$((1 << (32 - ${1#*/})))
  start=$((((a << 24) | (b << 16) | (c << 8) | d) & ~(size - 1) & 0xFFFFFFFF))
  printf '%s %s' "$start" "$((start + size - 1))"
}

# cidrs_overlap CIDR CIDR -> success when the two IPv4 blocks share an address.
cidrs_overlap() {
  local s1 e1 s2 e2
  read -r s1 e1 <<<"$(cidr_range "$1")"
  read -r s2 e2 <<<"$(cidr_range "$2")"
  ((s1 <= e2 && s2 <= e1))
}

# preflight -> checks of the machine, before anything is created.
preflight() {
  local subnet="${TF_VAR_subnet_cidr:-10.250.0.0/24}" port="${TF_VAR_registry_host_port:-5001}"
  local socket="${TF_VAR_docker_host:-unix:///var/run/docker.sock}" cli_id provider_id name nets net route
  local -a network_ids=()

  # The Terraform provider and the kind CLI must drive the daemon you are looking at.
  cli_id="$(docker info --format '{{.ID}}' 2>/dev/null)" || die "the Docker daemon is not reachable"
  provider_id="$(docker --host "$socket" info --format '{{.ID}}' 2>/dev/null)" ||
    die "the Terraform provider talks to $socket, which does not answer (DOCKER_HOST=${DOCKER_HOST:-unset}, context $(docker context show 2>/dev/null)): set TF_VAR_docker_host to the socket of your daemon"
  [[ "$cli_id" == "$provider_id" ]] ||
    die "the Docker CLI (DOCKER_HOST=${DOCKER_HOST:-unset}, context $(docker context show 2>/dev/null)) and the Terraform provider ($socket) talk to different daemons: set TF_VAR_docker_host to the socket the CLI uses"

  # The lab network (subnet_cidr of terraform/envs/local) must not overlap another Docker network or a
  # route of the machine (a VPN or the LAN): the containers would be unreachable or would shadow it.
  mapfile -t network_ids < <(docker network ls -q)
  while read -r name nets; do
    if [[ "$name" == "$NETWORK" ]]; then
      die "the network $NETWORK of an earlier lab is still on the daemon: run scripts/local-lab.sh down, or docker network rm $NETWORK"
    fi
    for net in $nets; do
      [[ "$net" =~ ^[0-9.]+/[0-9]+$ ]] || continue
      if cidrs_overlap "$subnet" "$net"; then
        die "the lab network $subnet overlaps the Docker network $name ($net): set TF_VAR_subnet_cidr to another private /24"
      fi
    done
  done < <(docker network inspect --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' "${network_ids[@]}" 2>/dev/null)
  if command -v ip >/dev/null 2>&1; then
    while read -r route _; do
      [[ "$route" =~ ^[0-9.]+/([0-9]+)$ && "${BASH_REMATCH[1]}" != 0 ]] || continue
      if cidrs_overlap "$subnet" "$route"; then
        die "the lab network $subnet overlaps a route of this machine ($route: a VPN or your LAN): set TF_VAR_subnet_cidr to another private /24"
      fi
    done < <(ip -4 route show 2>/dev/null)
  fi

  # The registry publishes this port on 127.0.0.1.
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    die "port $port of 127.0.0.1 is already in use: stop what uses it or set TF_VAR_registry_host_port"
  fi
}

# cmd_preflight -> the checks that `up` makes before it creates anything, on their own.
cmd_preflight() {
  require_cmd kind docker
  docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"
  require_own_lab up
  # A lab of this state directory is only updated; the machine is checked before a new one.
  lab_present || preflight
  log "pre-flight: ok"
}

cmd_up() {
  local infra_only=0
  [[ "${1:-}" == --infra-only ]] && infra_only=1
  require_cmd terraform kind docker kubectl
  cmd_preflight
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
  require_own_lab down
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
  # e2e builds a lab and always destroys it: one that is already up is yours, and is left alone.
  require_cmd docker kind
  if lab_present; then
    die "a tx01v2 lab is already up: e2e would destroy it. Use scripts/local-lab.sh check on it, or scripts/local-lab.sh down first"
  fi
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
    preflight) cmd_preflight ;;
    up) cmd_up "$@" ;;
    down) cmd_down ;;
    check) cmd_check ;;
    e2e) cmd_e2e ;;
    kubeconfig)
      write_kubeconfig
      printf '%s\n' "$KUBECONFIG"
      ;;
    status) cmd_status ;;
    *) die "usage: $0 preflight | up [--infra-only] | down | check | e2e | kubeconfig | status" ;;
  esac
}

main "$@"
