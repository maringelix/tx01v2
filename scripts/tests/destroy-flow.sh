#!/usr/bin/env bash
# Offline test of scripts/destroy.sh with simulated aws, terraform, kubectl, helm and sleep: no AWS
# account, no cluster, nothing is created. Proves what docs/GUARDRAILS.md (CUSTO-03) promises: a
# destroy that cannot uninstall the platform layer still removes the load balancers through the API,
# still runs terraform destroy and always ends with the leftover check.
# Run by the harness (check destroy-flow); usage: scripts/tests/destroy-flow.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
DESTROY_ARGS=()

LB_ARN="arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/k8s-lab/0123456789abcdef"
TG_ARN="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/k8s-lab/0123456789abcdef"
SG_ID="sg-0123456789abcdef0"

make_fakes() {
  local bin="$WORK/bin"
  mkdir -p "$bin"
  # The simulated AWS CLI keeps its state in files of $FAKE_STATE: the resources of the controller
  # exist until a delete call (or the simulated controller, on `kubectl delete ingress`) removes them.
  cat >"$bin/aws" <<EOF
#!/usr/bin/env bash
S="\$FAKE_STATE"
echo "aws \$*" >>"\$S/calls.log"
case "\$1 \$2" in
  "sts get-caller-identity") echo 123456789012 ;;
  "eks list-clusters") if [[ "\$*" == *"contains(clusters"* ]]; then echo True; fi ;;
  "eks describe-cluster") echo tx01v2 ;;
  "eks update-kubeconfig") exit 0 ;;
  "elbv2 describe-load-balancers") [[ -e "\$S/lb.gone" ]] || echo "$LB_ARN" ;;
  "elbv2 describe-target-groups") [[ -e "\$S/tg.gone" ]] || echo "$TG_ARN" ;;
  "elbv2 describe-tags")
    shift 2
    while (( \$# > 0 )) && [[ "\$1" != --resource-arns ]]; do shift; done
    shift
    while (( \$# > 0 )) && [[ "\$1" != --* ]]; do echo "\$1"; shift; done
    ;;
  "ec2 describe-security-groups") [[ -e "\$S/sg.gone" ]] || echo "$SG_ID" ;;
  "elbv2 delete-load-balancer") touch "\$S/lb.gone" ;;
  "elbv2 delete-target-group") touch "\$S/tg.gone" ;;
  "ec2 delete-security-group") touch "\$S/sg.gone" ;;
  *) : ;;
esac
EOF
  cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$FAKE_STATE/calls.log"
if [[ "$*" == "get --raw /readyz" && "${FAKE_API_DOWN:-0}" == 1 ]]; then
  echo "the connection to the server was refused" >&2
  exit 1
fi
if [[ "$1 $2" == "delete ingress" ]]; then
  touch "$FAKE_STATE/lb.gone" "$FAKE_STATE/tg.gone" "$FAKE_STATE/sg.gone"
fi
exit 0
EOF
  cat >"$bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*" >>"$FAKE_STATE/calls.log"
if [[ " $* " == *" destroy "* && "${FAKE_TF_DESTROY_FAILS:-0}" == 1 ]]; then
  echo "Error: the destroy failed" >&2
  exit 1
fi
exit 0
EOF
  cat >"$bin/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >>"$FAKE_STATE/calls.log"
EOF
  # A retry loop that never ends would hang the harness: the 60th simulated sleep fails.
  cat >"$bin/sleep" <<'EOF'
#!/usr/bin/env bash
n="$(cat "$FAKE_STATE/sleeps" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$FAKE_STATE/sleeps"
((n < 60)) || { echo "the simulated sleep ran 60 times: a retry loop does not end" >&2; exit 1; }
EOF
  chmod +x "$bin"/*
}

# run_case NAME EXPECTED_EXIT [VAR=VALUE...] -> runs scripts/destroy.sh and leaves the result in
# $WORK/<NAME>.out and the calls in $WORK/<NAME>.calls
run_case() {
  local name=$1 expected=$2 rc=0
  shift 2
  mkdir -p "$WORK/state"
  rm -f "$WORK/state"/*
  env "$@" PATH="$WORK/bin:$PATH" FAKE_STATE="$WORK/state" AWS_REGION=us-east-1 TF_STATE_BUCKET=fake-bucket \
    DESTROY_RETRY_SECONDS=0 LB_WAIT_SECONDS=0 \
    bash "$REPO_ROOT/scripts/destroy.sh" "${DESTROY_ARGS[@]}" >"$WORK/$name.out" 2>&1 || rc=$?
  cp "$WORK/state/calls.log" "$WORK/$name.calls"
  if [[ "$rc" != "$expected" ]]; then
    echo "FAIL $name: exit code $rc, expected $expected"
    sed 's/^/    /' "$WORK/$name.out" | tail -n 25
    FAILED=1
  fi
}

# line_of NAME REGEX -> first line number of the calls of the case that matches REGEX (empty: none)
line_of() {
  grep -nE -- "$2" "$WORK/$1.calls" | head -n 1 | cut -d: -f1
}

expect() { # NAME DESCRIPTION CONDITION(0 = true)
  if [[ "$3" == 0 ]]; then
    echo "PASS $1: $2"
  else
    echo "FAIL $1: $2"
    FAILED=1
  fi
}

absent() { # NAME REGEX -> 0 when no call of the case matches
  if [[ -z "$(line_of "$1" "$2")" ]]; then echo 0; else echo 1; fi
}

both() { # NAME REGEX_A REGEX_B -> 0 when both kinds of call happened
  if [[ -n "$(line_of "$1" "$2")" && -n "$(line_of "$1" "$3")" ]]; then echo 0; else echo 1; fi
}

output_has() { # NAME TEXT -> 0 when the output of the case contains TEXT
  if grep -qF -- "$2" "$WORK/$1.out"; then echo 0; else echo 1; fi
}

ordered() { # NAME REGEX_A REGEX_B -> 0 when A exists and comes before B
  local a b
  a="$(line_of "$1" "$2")"
  b="$(line_of "$1" "$3")"
  if [[ -n "$a" && -n "$b" ]] && ((a < b)); then echo 0; else echo 1; fi
}

main() {
  make_fakes

  # 1. The controller works: the uninstall deletes the ingress, the API cleanup is not needed.
  run_case healthy 0
  expect healthy "platform uninstalled, then terraform destroy, then the leftover check" \
    "$(ordered healthy 'kubectl delete ingress' 'terraform .*destroy')"
  expect healthy "the leftover check runs after terraform destroy" \
    "$(ordered healthy 'terraform .*destroy' 'describe-nat-gateways')"
  expect healthy "no load balancer is deleted through the API" \
    "$(absent healthy 'elbv2 delete-load-balancer')"

  # 2. The cluster API is unreachable: the uninstall fails, the API cleanup removes the load
  #    balancer, the destroy and the leftover check still run, and the run passes.
  run_case api-down 0 FAKE_API_DOWN=1
  expect api-down "the uninstall failure is reported as a warning" \
    "$(output_has api-down 'warning: platform/uninstall.sh did not finish')"
  expect api-down "the load balancer of the controller is deleted through the AWS API" \
    "$(ordered api-down 'elbv2 delete-load-balancer' 'terraform .*destroy')"
  expect api-down "the target group and the security group are deleted too" \
    "$(both api-down 'elbv2 delete-target-group' 'ec2 delete-security-group')"
  expect api-down "terraform destroy still runs and the leftover check follows" \
    "$(ordered api-down 'terraform .*destroy' 'describe-nat-gateways')"

  # 3. terraform destroy fails: the run fails, and the leftover check still runs.
  run_case destroy-fails 1 FAKE_API_DOWN=1 FAKE_TF_DESTROY_FAILS=1
  expect destroy-fails "the leftover check runs after a failed terraform destroy" \
    "$(ordered destroy-fails 'terraform .*destroy' 'describe-nat-gateways')"

  # 4. An interrupted apply left a lock: --force-unlock removes it before the destroy.
  DESTROY_ARGS=(--force-unlock 0b5d3a9e-1c2f-4a60-9d7e-3f1b2c4d5e6f)
  run_case lock 0
  DESTROY_ARGS=()
  expect lock "the lock is released before terraform destroy" \
    "$(ordered lock 'terraform .*force-unlock -force 0b5d3a9e' 'terraform .*destroy')"
  if bash "$REPO_ROOT/scripts/destroy.sh" --force-unlock "not-a-lock-id" >/dev/null 2>&1; then
    echo "FAIL lock: a lock ID that is not a UUID must be refused"
    FAILED=1
  else
    echo "PASS lock: a lock ID that is not a UUID is refused"
  fi

  exit "$FAILED"
}

main "$@"
