#!/usr/bin/env bash
# Offline test of the pre-flight of scripts/local-lab.sh with a simulated docker, kind and ip: no
# Docker daemon is needed and nothing is created. Proves what docs/GUARDRAILS.md (LOC-06) promises:
# the lab is not started when the Docker CLI and the Terraform provider talk to different daemons,
# when its network overlaps a Docker network or a route of the machine (a VPN, the LAN), or when the
# registry port is taken; and it never acts on a lab that its own LOCAL_STATE_DIR did not create.
# Run by the harness (check local-preflight); usage: scripts/tests/local-preflight.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
LISTENER_PID=""
cleanup() {
  [[ -z "$LISTENER_PID" ]] || kill "$LISTENER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
FAILED=0

# The script under test runs from a copy of the tree (it puts .tools/bin in front of PATH).
mkdir -p "$WORK/repo/scripts" "$WORK/bin" "$WORK/state"
cp "$REPO_ROOT/scripts/local-lab.sh" "$WORK/repo/scripts/"
cp -r "$REPO_ROOT/scripts/lib" "$WORK/repo/scripts/lib"

# What this repository's defaults are: the subnet of the lab and the name of its Docker network.
SUBNET="$(sed -n 's/.*TF_VAR_subnet_cidr:-\([0-9./]*\)}.*/\1/p' "$REPO_ROOT/scripts/local-lab.sh" | head -n 1)"
NETWORK="$(sed -n 's/^NETWORK=//p' "$REPO_ROOT/scripts/local-lab.sh" | head -n 1)"
[[ "$SUBNET" =~ ^[0-9.]+/24$ && -n "$NETWORK" ]] || {
  echo "FAIL: cannot read the default subnet and the network name of scripts/local-lab.sh"
  exit 1
}
BIG_NET="${SUBNET%.*.*}.0.0/16"

cat >"$WORK/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_STATE/calls.log"
case "$1" in
  info)
    if [[ "$*" == *"--format"* ]]; then echo "${FAKE_CLI_ID:-daemon-a}"; fi
    ;;
  --host)
    [[ "${FAKE_PROVIDER_DOWN:-0}" != 1 ]] || exit 1
    echo "${FAKE_PROVIDER_ID:-daemon-a}"
    ;;
  context) echo "default" ;;
  network)
    case "$2" in
      ls) echo "net1" ;;
      inspect) printf '%b' "${FAKE_NETWORKS:-bridge 172.17.0.0/16 \n}" ;;
      *) : ;;
    esac
    ;;
  ps)
    if [[ "${FAKE_LAB_CONTAINERS:-0}" == 1 ]]; then echo "abc123"; fi
    ;;
  *) : ;;
esac
exit 0
EOF
cat >"$WORK/bin/kind" <<'EOF'
#!/usr/bin/env bash
echo "kind $*" >>"$FAKE_STATE/calls.log"
if [[ "$1 $2" == "get clusters" ]]; then printf '%b' "${FAKE_KIND_CLUSTERS:-}"; fi
exit 0
EOF
cat >"$WORK/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '%b' "${FAKE_ROUTES:-default via 192.0.2.1 dev eth0\n192.0.2.0/24 dev eth0 scope link\n}"
EOF
for tool in terraform kubectl; do
  cat >"$WORK/bin/$tool" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$FAKE_STATE/calls.log"
exit 0
EOF
done
chmod +x "$WORK/bin"/*

# run_case NAME EXPECTED_EXIT COMMAND [VAR=VALUE...]
run_case() {
  local name=$1 expected=$2 cmd=$3 rc=0
  shift 3
  : >"$WORK/state/calls.log"
  env -u DOCKER_HOST PATH="$WORK/bin:$PATH" FAKE_STATE="$WORK/state" LOCAL_STATE_DIR="$WORK/lab-state" \
    TF_VAR_registry_host_port="${PORT:-47999}" "$@" \
    bash "$WORK/repo/scripts/local-lab.sh" "$cmd" >"$WORK/$name.out" 2>&1 || rc=$?
  if [[ "$rc" != "$expected" ]]; then
    echo "FAIL $name: exit code $rc, expected $expected"
    sed 's/^/    /' "$WORK/$name.out" | tail -n 15
    FAILED=1
  fi
}

says() { # NAME TEXT DESCRIPTION
  if grep -qF -- "$2" "$WORK/$1.out"; then echo "PASS $1: $3"; else echo "FAIL $1: $3"; FAILED=1; fi
}

main() {
  # 1. A clean machine passes, and creates nothing.
  run_case clean 0 preflight
  says clean "pre-flight: ok" "a clean machine passes the pre-flight"
  if grep -qE '^(terraform|kubectl) ' "$WORK/state/calls.log"; then
    echo "FAIL clean: the pre-flight must not call terraform or kubectl"
    FAILED=1
  else
    echo "PASS clean: the pre-flight creates nothing"
  fi

  # 2. The CLI and the provider drive different daemons, or the provider's socket does not answer.
  run_case daemons 1 preflight FAKE_PROVIDER_ID=daemon-b
  says daemons "talk to different daemons" "a CLI and a provider on different daemons are refused"
  run_case provider-down 1 preflight FAKE_PROVIDER_DOWN=1
  says provider-down "which does not answer" "a provider socket that does not answer is refused"

  # 3. The lab network overlaps a Docker network or a route (a VPN, the LAN).
  run_case network 1 preflight "FAKE_NETWORKS=their-net $BIG_NET \\n"
  says network "overlaps the Docker network their-net" "a Docker network that contains the lab network is refused"
  run_case earlier 1 preflight "FAKE_NETWORKS=$NETWORK 10.99.0.0/24 \\n"
  says earlier "of an earlier lab is still on the daemon" "the network of an earlier lab, left on the daemon, is refused"
  run_case route 1 preflight "FAKE_ROUTES=$BIG_NET dev tun0 scope link\\n"
  says route "overlaps a route of this machine" "a route (VPN) that contains the lab network is refused"
  run_case defaults 0 preflight "FAKE_ROUTES=default via 192.0.2.1 dev eth0\\n0.0.0.0/0 dev eth1\\n"
  says defaults "pre-flight: ok" "the default routes are not an overlap"

  # 4. The registry port is taken (needs something that can listen: python or node).
  if start_listener 47998; then
    PORT=47998 run_case port 1 preflight
    says port "already in use" "a registry port that is taken is refused"
    kill "$LISTENER_PID" 2>/dev/null || true
    LISTENER_PID=""
  else
    echo "SKIP port: no python or node to listen on a port"
  fi

  # 5. A lab that another state directory created is never touched; one of this directory is.
  run_case other-up 1 preflight FAKE_LAB_CONTAINERS=1
  says other-up "holds no state of it" "up refuses a lab that this state directory did not create"
  run_case other-down 1 down FAKE_LAB_CONTAINERS=1
  says other-down "holds no state of it" "down refuses a lab that this state directory did not create"
  run_case other-e2e 1 e2e FAKE_LAB_CONTAINERS=1
  says other-e2e "is already up" "e2e refuses to build (and then destroy) a lab that is already up"
  mkdir -p "$WORK/lab-state"
  printf '{"resources": [{"type": "docker_network"}]}\n' >"$WORK/lab-state/terraform.tfstate"
  run_case own-up 0 preflight FAKE_LAB_CONTAINERS=1 "FAKE_NETWORKS=their-net $BIG_NET \\n"
  says own-up "pre-flight: ok" "a lab of this state directory is only updated, the machine is not checked again"
  run_case own-e2e 1 e2e FAKE_LAB_CONTAINERS=1
  says own-e2e "is already up" "e2e does not destroy the lab that make local-up keeps either"

  return "$FAILED"
}

# start_listener PORT -> a process that listens on 127.0.0.1:PORT (LISTENER_PID), when python or node exist.
start_listener() {
  local port=$1
  if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
    python3 -c 'import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen()
time.sleep(60)' "$port" &
  elif command -v node >/dev/null 2>&1; then
    node -e 'require("net").createServer().listen(Number(process.argv[1]), "127.0.0.1"); setTimeout(() => {}, 60000)' "$port" &
  else
    return 1
  fi
  LISTENER_PID=$!
  sleep 1
}

main "$@"
