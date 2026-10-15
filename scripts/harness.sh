#!/usr/bin/env bash
# tx01v2 harness: every check lives here. `make` targets and every CI job only call this script.
# Usage: scripts/harness.sh <stage>...   stages: static, test, e2e, all (= static test e2e), list
#   HARNESS_STRICT=1   (set in CI) turns every SKIP into a FAIL
#   HARNESS_VERBOSE=1  also prints the output of passing checks
#   HARNESS_WORK_DIR   scratch dir for Terraform data, logs and caches (default: $TMPDIR/tx01v2-harness)
# Prints "PASS|FAIL|SKIP <check> (<secs>s)" per check and a summary; exits 1 on any FAIL.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "$REPO_ROOT/scripts/lib/tools.sh"

export PATH="$REPO_ROOT/.tools/bin:$PATH"
export TFLINT_PLUGIN_DIR="$REPO_ROOT/.tools/tflint-plugins"
export TF_IN_AUTOMATION=1 TF_INPUT=0 CHECKPOINT_DISABLE=1
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"

HARNESS_STRICT="${HARNESS_STRICT:-0}"
HARNESS_VERBOSE="${HARNESS_VERBOSE:-0}"
HARNESS_WORK_DIR="${HARNESS_WORK_DIR:-${TMPDIR:-/tmp}/tx01v2-harness}"
# Optional extended regex: run only the checks whose name matches (local debugging; never in CI).
HARNESS_ONLY="${HARNESS_ONLY:-}"

# Pinned schema sources of kubeconform (update procedure: docs/SUSTENTACAO.md).
K8S_SCHEMA_KUBERNETES_VERSION="1.36.0"
K8S_SCHEMA_REF="5f1fa4f7908afc9b6641c62d282a4a22437626e1" # yannh/kubernetes-json-schema
# datreeio/CRDs-catalog at 2026-06-02: its next revision of external-secrets.io/clustersecretstore_v1.json
# (b7e2015, 2026-10-08) cannot be compiled by kubeconform ("could not find schema"); see docs/HARNESS.md.
CRD_SCHEMA_REF="f3e4382095909ac60000da025f323ba44d4c738a"
# Scanner ignores must be reviewed at least every ~7 months.
TRIVYIGNORE_MAX_DAYS=214

REQUIRED_FILES=(
  README.md README.pt-BR.md AGENTS.md CLAUDE.md CONTRIBUTING.md SECURITY.md CHANGELOG.md LICENSE FORK.md
  .editorconfig .gitattributes .gitignore .pre-commit-config.yaml Makefile .tflint.hcl .trivyignore.yaml
  .devcontainer/devcontainer.json
  .github/CODEOWNERS .github/dependabot.yml .github/pull_request_template.md
  .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/cloud_run_report.yml
  .github/workflows/ci.yml .github/rulesets/main.json
  docs/SUSTENTACAO.md docs/GUARDRAILS.md docs/HARNESS.md docs/CONTRATO.md docs/RUNBOOK.md
  docs/ARQUITETURA.md docs/PUBLICACAO.md docs/CUSTOS.md
  tools/versions.env tools/checksums.txt
  scripts/install-tools.sh scripts/update-tool-checksums.sh scripts/harness.sh scripts/repo-guardrails.sh scripts/leftovers.sh
  scripts/destroy.sh scripts/tests/destroy-flow.sh
  platform/install.sh platform/uninstall.sh platform/versions.env
  terraform/bootstrap/.terraform.lock.hcl terraform/envs/lab/.terraform.lock.hcl
  terraform/envs/lab/terraform.tfvars.example terraform/envs/lab/backend.hcl.example
  terraform/envs/local/.terraform.lock.hcl terraform/envs/local/kind-config.yaml
  scripts/local-lab.sh scripts/leftovers-local.sh scripts/local/kind-cluster.sh scripts/lib/local.sh
  platform/local/install.sh platform/local/uninstall.sh platform/local/check.sh platform/local/versions.env
  platform/local/policies/README.md platform/local/policies/tests/suite.yaml
)
# Charts of the local platform (keys of platform/local/versions.env and platform/versions.env):
# <repo key> <version key> <sha256 key> <chart> <values files under platform/local/values, comma separated>
LOCAL_CHARTS=(
  "ISTIO_REPO ISTIO_VERSION ISTIO_BASE_SHA256 base istio-base"
  "ISTIO_REPO ISTIO_VERSION ISTIOD_SHA256 istiod istiod"
  "ISTIO_REPO ISTIO_VERSION ISTIO_CNI_SHA256 cni istio-cni"
  "ISTIO_REPO ISTIO_VERSION ZTUNNEL_SHA256 ztunnel ztunnel"
  "CERT_MANAGER_REPO CERT_MANAGER_VERSION CERT_MANAGER_SHA256 cert-manager cert-manager"
  "ESO_REPO ESO_CHART_VERSION ESO_SHA256 external-secrets ../../values/external-secrets,external-secrets"
  "METRICS_SERVER_REPO METRICS_SERVER_VERSION METRICS_SERVER_SHA256 metrics-server metrics-server"
  "KPS_REPO KPS_VERSION KPS_SHA256 kube-prometheus-stack kube-prometheus-stack"
  "GRAFANA_REPO LOKI_VERSION LOKI_SHA256 loki loki"
  "GRAFANA_REPO ALLOY_VERSION ALLOY_SHA256 alloy alloy"
  "GRAFANA_COMMUNITY_REPO TEMPO_VERSION TEMPO_SHA256 tempo tempo"
  "OTEL_COLLECTOR_REPO OTEL_COLLECTOR_CHART_VERSION OTEL_COLLECTOR_CHART_SHA256 opentelemetry-collector otel-collector"
  "ARGOCD_REPO ARGOCD_VERSION ARGOCD_SHA256 argo-cd argo-cd"
  "GATEKEEPER_REPO GATEKEEPER_VERSION GATEKEEPER_SHA256 gatekeeper gatekeeper"
  "TRIVY_OPERATOR_REPO TRIVY_OPERATOR_VERSION TRIVY_OPERATOR_SHA256 trivy-operator trivy-operator"
  "VELERO_REPO VELERO_VERSION VELERO_SHA256 velero velero"
  "CHAOS_MESH_REPO CHAOS_MESH_VERSION CHAOS_MESH_SHA256 chaos-mesh chaos-mesh"
)

# ---------------------------------------------------------------------------------------------
# Check registry and helpers
# ---------------------------------------------------------------------------------------------

declare -a CHECK_STAGE=() CHECK_NAME=() CHECK_CMD=()
register() {
  CHECK_STAGE+=("$1")
  CHECK_NAME+=("$2")
  CHECK_CMD+=("$3")
}

strict() { [[ "$HARNESS_STRICT" == 1 ]]; }

# skip REASON -> ends the current check as SKIP (FAIL in strict mode). Only for missing preconditions.
# Exit code 77 (the automake SKIP convention) never collides with the tools' own codes.
SKIP_CODE=77
skip() {
  printf 'SKIP_REASON: %s\n' "$*"
  exit "$SKIP_CODE"
}

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || skip "'$c' not found (run: make tools)"
  done
}

# visible_files -> files git would track (tracked + untracked, minus .gitignore), one per line.
visible_files() {
  git ls-files --cached --others --exclude-standard
}

# forbid REGEX MESSAGE GLOB PATH... -> fails when the extended regex matches in the files named
# GLOB ('*' for all) under PATH (recursive).
forbid() {
  local re=$1 msg=$2 glob=$3 out status=0
  shift 3
  out="$(grep -rnIE --include="$glob" -e "$re" -- "$@")" || status=$?
  ((status <= 1)) || {
    echo "grep failed with status $status"
    return 1
  }
  if [[ -n "$out" ]]; then
    printf 'forbidden: %s\n%s\n' "$msg" "$out"
    return 1
  fi
}

date_plus_days() {
  date -u -d "+$1 days" +%F 2>/dev/null || date -u -v+"$1"d +%F
}

tf_init() {
  local dir=$1
  local -a args=(-backend=false -input=false -no-color)
  mkdir -p "$TF_PLUGIN_CACHE_DIR"
  export TF_DATA_DIR="$HARNESS_WORK_DIR/terraform/${dir//\//_}"
  # Root configurations must resolve providers from their committed lock file only.
  [[ -f "$dir/.terraform.lock.hcl" && "$dir" != terraform/modules/* ]] && args+=(-lockfile=readonly)
  terraform -chdir="$dir" init "${args[@]}"
}

installed_version() {
  local out=""
  case "$1" in
    terraform) out="$(terraform version 2>/dev/null)" || out="" ;;
    tflint) out="$(tflint --version 2>/dev/null)" || out="" ;;
    trivy) out="$(trivy --version 2>/dev/null)" || out="" ;;
    actionlint) out="$(actionlint -version 2>/dev/null)" || out="" ;;
    shellcheck) out="$(shellcheck --version 2>/dev/null)" || out="" ;;
    kubeconform) out="$(kubeconform -v 2>/dev/null)" || out="" ;;
    gitleaks) out="$(gitleaks version 2>/dev/null)" || out="" ;;
    kubectl) out="$(kubectl version --client 2>/dev/null)" || out="" ;;
    helm) out="$(helm version --short 2>/dev/null)" || out="" ;;
    kind) out="$(kind version 2>/dev/null)" || out="" ;;
    gator) out="$(gator --version 2>/dev/null)" || out="" ;;
  esac
  [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# ---------------------------------------------------------------------------------------------
# Checks (each runs in its own subshell from the repository root)
# ---------------------------------------------------------------------------------------------

check_tool_versions() {
  local t want got
  local -a missing=() mismatch=()
  load_versions
  for t in "${TOOLS_ALL[@]}"; do
    want="$(tool_version "$t")"
    if [[ "$t" == tflint-ruleset-aws ]]; then
      if [[ -x "$(tool_installed_path "$t" "$want" "$REPO_ROOT/.tools")" ]]; then
        printf '%-20s %s (plugin)\n' "$t" "$want"
      else
        missing+=("$t")
      fi
      continue
    fi
    if ! command -v "$t" >/dev/null 2>&1; then
      missing+=("$t")
      continue
    fi
    got="$(installed_version "$t")"
    printf '%-20s want %-8s got %-8s %s\n' "$t" "$want" "${got:-?}" "$(command -v "$t")"
    [[ "$got" == "$want" ]] || mismatch+=("$t")
  done
  ((${#missing[@]} == 0)) || skip "missing tools: ${missing[*]} (run: make tools)"
  if ((${#mismatch[@]} > 0)); then
    strict && {
      echo "versions differ from tools/versions.env: ${mismatch[*]}"
      return 1
    }
    skip "versions differ from tools/versions.env: ${mismatch[*]} (run: make tools)"
  fi
}

check_repo_structure() {
  local f d rc=0
  for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "$f" ]] || {
      echo "missing required file: $f"
      rc=1
    }
  done
  if [[ -f CLAUDE.md ]]; then
    [[ "$(sed -n 1p CLAUDE.md)" == "@AGENTS.md" ]] || {
      echo "CLAUDE.md: the first line must be @AGENTS.md"
      rc=1
    }
    (($(grep -c . CLAUDE.md) == 2)) || {
      echo "CLAUDE.md: must contain exactly @AGENTS.md and one sentence"
      rc=1
    }
  fi
  if [[ -f README.md ]] && (($(wc -l <README.md) > 250)); then
    echo "README.md: more than 250 lines"
    rc=1
  fi
  if [[ -f .devcontainer/devcontainer.json ]]; then
    grep -qE '"image": "[^"]+@sha256:[0-9a-f]{64}"' .devcontainer/devcontainer.json || {
      echo ".devcontainer/devcontainer.json: the base image must be pinned by digest (@sha256:...)"
      rc=1
    }
    grep -qE '"postCreateCommand":[[:space:]]*"make tools"' .devcontainer/devcontainer.json || {
      echo ".devcontainer/devcontainer.json: postCreateCommand must be \"make tools\""
      rc=1
    }
    if grep -nE '"ghcr.io/devcontainers/features/[^"@]+"' .devcontainer/devcontainer.json | grep -v '@sha256:'; then
      echo ".devcontainer/devcontainer.json: features must be pinned by digest"
      rc=1
    fi
  fi
  forbid 'production-grade|production-ready|enterprise|best-in-class|world-class' "self-ratings in the READMEs" '*' README.md README.pt-BR.md || rc=1
  grep -qF 'not run in the cloud (v2)' README.md || {
    echo "README.md: the status matrix must use the label 'not run in the cloud (v2)'"
    rc=1
  }
  grep -qF 'não executado em nuvem (v2)' README.pt-BR.md || {
    echo "README.pt-BR.md: the status matrix must use the label 'não executado em nuvem (v2)'"
    rc=1
  }
  for d in terraform/modules/*/; do
    grep -q 'required_providers' "${d}versions.tf" 2>/dev/null || {
      echo "${d}versions.tf: missing required_providers"
      rc=1
    }
  done
  need git
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if grep -q $'\r' "$f"; then
      echo "CRLF line endings (LF required): $f"
      rc=1
    fi
  done < <(visible_files)
  # Entry-point scripts must keep the executable bit in git (commits from Windows can drop it).
  while IFS= read -r f; do
    [[ "$(git ls-files -s -- "$f" | awk '{ print $1 }')" == 100755 ]] || {
      echo "not executable in the git index (git update-index --chmod=+x $f): $f"
      rc=1
    }
  done < <(git ls-files -- 'scripts/*.sh' 'platform/*.sh' | grep -v '^scripts/lib/')
  return "$rc"
}

check_version_consistency() {
  local rc=0 v lbc key value policy
  declare -A pv=()
  load_versions
  v="$(awk '/^plugin "aws"/ { a = 1 } a && /^[[:space:]]*version[[:space:]]*=/ { gsub(/[" ]/, ""); sub(/^version=/, ""); print; exit }' .tflint.hcl)"
  [[ "$v" == "$TFLINT_RULESET_AWS_VERSION" ]] || {
    echo ".tflint.hcl uses tflint-ruleset-aws $v but tools/versions.env pins $TFLINT_RULESET_AWS_VERSION"
    rc=1
  }
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] && pv[$key]="$value"
  done < <(grep -E '^[A-Z0-9_]+=' platform/versions.env)
  lbc="${pv[LBC_CHART_VERSION]:-}"
  grep -qF "load_balancer_controller_version = \"$lbc\"" terraform/modules/eks/pod_identity.tf || {
    echo "terraform/modules/eks/pod_identity.tf must pin load_balancer_controller_version = \"$lbc\""
    rc=1
  }
  policy="terraform/modules/eks/policies/aws-load-balancer-controller-v$lbc.json"
  if [[ -f "$policy" ]]; then
    [[ "$(sha256_of "$policy")" == "${pv[LBC_IAM_POLICY_SHA256]:-}" ]] || {
      echo "$policy differs from the upstream copy recorded in platform/versions.env (LBC_IAM_POLICY_SHA256)"
      rc=1
    }
  else
    echo "missing $policy"
    rc=1
  fi
  (($(find terraform/modules/eks/policies -name 'aws-load-balancer-controller-v*.json' | wc -l) == 1)) || {
    echo "keep exactly one LBC policy version in terraform/modules/eks/policies"
    rc=1
  }
  grep -qE "tag: v${lbc//./\\.}@sha256:[0-9a-f]{64}$" platform/values/aws-load-balancer-controller.yaml || {
    echo "platform/values/aws-load-balancer-controller.yaml must pin image v$lbc by digest"
    rc=1
  }
  (($(grep -cE "tag: v${pv[ESO_CHART_VERSION]//./\\.}@sha256:[0-9a-f]{64}$" platform/values/external-secrets.yaml) == 3)) || {
    echo "platform/values/external-secrets.yaml must pin the three images to v${pv[ESO_CHART_VERSION]:-?} by digest"
    rc=1
  }
  (($(grep -h 'required_version' terraform/*/versions.tf terraform/*/*/versions.tf | sort -u | wc -l) == 1)) || {
    echo "every versions.tf must use the same required_version"
    rc=1
  }
  (($(grep -h -A1 'source  = "hashicorp/aws"' terraform/*/versions.tf terraform/*/*/versions.tf | grep version | sort -u | wc -l) == 1)) || {
    echo "every versions.tf must use the same hashicorp/aws constraint"
    rc=1
  }
  [[ "$(grep -A1 'hashicorp/aws"' terraform/bootstrap/.terraform.lock.hcl | grep version)" == "$(grep -A1 'hashicorp/aws"' terraform/envs/lab/.terraform.lock.hcl | grep version)" ]] || {
    echo "bootstrap and envs/lab must lock the same hashicorp/aws version"
    rc=1
  }
  return "$rc"
}

check_terraform_fmt() {
  need terraform
  terraform fmt -check -recursive -diff -no-color terraform
}

check_terraform_validate() {
  need terraform
  tf_init "$1"
  terraform -chdir="$1" validate -no-color
}

check_terraform_lockfiles() {
  local f rc=0
  for f in terraform/bootstrap/.terraform.lock.hcl terraform/envs/lab/.terraform.lock.hcl terraform/envs/local/.terraform.lock.hcl; do
    awk -v file="$f" '
      /^provider "/ { name = $2; h1 = 0; next }
      /"h1:/ { h1++ }
      /^}/ && name != "" { printf "%s %s: %d platform hashes (h1)\n", file, name, h1; if (h1 < 4) bad = 1; name = "" }
      END { exit bad }
    ' "$f" || {
      echo "$f: every provider needs h1 hashes for linux_amd64, linux_arm64, darwin_arm64 and windows_amd64"
      echo "fix: terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64 -platform=windows_amd64"
      rc=1
    }
  done
  return "$rc"
}

check_policy_terraform() {
  local rc=0
  # The local lab (terraform/envs/local) keeps throwaway credentials of this machine in its local state
  # on purpose: the platform scripts read them back. Every cloud root must use ephemeral resources.
  forbid '^[[:space:]]*resource[[:space:]]+"random_(password|string)"' \
    "generated secrets must be ephemeral resources (a random_password resource stores its result in state)" '*.tf' \
    terraform/bootstrap terraform/envs/lab terraform/modules || rc=1
  forbid 'hashicorp/(aws|azurerm|google)|provider[[:space:]]+"(aws|azurerm|google)"|backend[[:space:]]+"(s3|azurerm|gcs)"' \
    "the local lab must not reach a cloud (no cloud provider or remote backend in terraform/envs/local)" '*.tf' terraform/envs/local || rc=1
  forbid '^[[:space:]]*ip[[:space:]]*=[[:space:]]*"0\.0\.0\.0"|^[[:space:]]*privileged[[:space:]]*=[[:space:]]*true' \
    "local lab containers publish ports on 127.0.0.1 only and never run privileged" '*.tf' terraform/envs/local || rc=1
  # Top-level resource arguments only (terraform fmt indents them with exactly two spaces).
  forbid '^  (password|secret_string|secret_binary)[[:space:]]*=' \
    "set secrets only through write-only arguments (password_wo, secret_string_wo)" '*.tf' terraform || rc=1
  forbid 'provider[[:space:]]+"(kubernetes|helm)"|hashicorp/(kubernetes|helm)' \
    "Terraform must not talk to the Kubernetes API (platform/install.sh does)" '*.tf' terraform || rc=1
  forbid '^[^#]*(kubernetes_config_map|"aws-auth"|system:masters)' \
    "cluster access goes through EKS access entries only" '*' terraform platform || rc=1
  forbid 'aws_iam_openid_connect_provider' \
    "no IRSA OIDC provider in the lab (EKS Pod Identity is used)" '*.tf' terraform/envs terraform/modules || rc=1
  forbid '^[[:space:]]*disk_size[[:space:]]*=' \
    "the node root volume comes from the launch template (disk_size + launch template breaks the node group)" '*.tf' terraform/modules/eks || rc=1
  forbid '^[[:space:]]*(vpc_security_group_ids|security_group_names|image_id|user_data)[[:space:]]*=' \
    "the node launch template must not set security groups, AMI or user data" '*.tf' terraform/modules/eks || rc=1
  return "$rc"
}

check_policy_identifiers() {
  local rc=0 out
  local -a files=()
  need git
  grep -qP 'x' <<<"x" 2>/dev/null || skip "grep -P (PCRE) is not available"
  mapfile -t files < <(visible_files | grep -vE '(^|/)(\.terraform\.lock\.hcl|checksums\.txt)$')
  ((${#files[@]} > 0)) || return 0
  out="$(grep -noP '(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])' "${files[@]}" | grep -v ':123456789012$')" || true
  [[ -z "$out" ]] || {
    printf 'AWS account IDs must be placeholders (<ACCOUNT_ID> or 123456789012):\n%s\n' "$out"
    rc=1
  }
  out="$(grep -noP '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' "${files[@]}" |
    grep -vP '@(example\.(com|org|net)|users\.noreply\.github\.com)$')" || true
  [[ -z "$out" ]] || {
    printf 'e-mail addresses must use example.com/example.org placeholders:\n%s\n' "$out"
    rc=1
  }
  out="$(grep -noP '(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9.])' "${files[@]}" |
    grep -vP ':(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|0\.0\.0\.0)')" || true
  [[ -z "$out" ]] || {
    printf 'IP addresses must be private or documentation ranges (RFC 1918 / RFC 5737):\n%s\n' "$out"
    rc=1
  }
  return "$rc"
}

# scripts/destroy.sh with simulated aws, terraform, kubectl and helm: an uninstall that fails still
# ends in the API cleanup, terraform destroy and the leftover check (docs/GUARDRAILS.md, CUSTO-03).
check_destroy_flow() {
  bash scripts/tests/destroy-flow.sh
}

# Scripts act only on what the lab created (docs/GUARDRAILS.md, SEC-10): no variable of the caller's
# shell chooses their target (a forker may have CLUSTER_NAME exported for another cluster), the cloud
# kubeconfig is a temporary file, and every script of platform/local checks the kind context first.
# shellcheck disable=SC2016 # the patterns and messages name shell expansions literally
check_policy_scripts() {
  local rc=0 out f
  forbid '\$\{(CLUSTER_NAME|RESOURCE_GROUP|LAB_[A-Z_]+|CONTRACT_PARAMETER)(:-|-|:=|=)' \
    "an environment variable must never choose the target of a script of the lab" '*.sh' scripts platform || rc=1
  out="$(grep -rn --include='*.sh' --exclude=harness.sh --exclude-dir=tests -e 'eks update-kubeconfig' scripts platform | grep -v -e '--kubeconfig "\$KUBECONFIG"')" || true
  [[ -z "$out" ]] || {
    printf 'aws eks update-kubeconfig must write a temporary file (--kubeconfig "$KUBECONFIG"), never ~/.kube/config:\n%s\n' "$out"
    rc=1
  }
  for f in platform/install.sh platform/uninstall.sh; do
    grep -q '^  require_lab_cluster ' "$f" || {
      echo "$f must call require_lab_cluster (tag Project=tx01v2) before it touches the cluster"
      rc=1
    }
  done
  for f in platform/local/install.sh platform/local/check.sh platform/local/uninstall.sh; do
    grep -q '^  require_lab_context$' "$f" || {
      echo "$f must call require_lab_context (only the kind context of the lab) before any kubectl"
      rc=1
    }
  done
  return "$rc"
}

check_tflint() {
  need tflint
  [[ -d "$TFLINT_PLUGIN_DIR/github.com/terraform-linters/tflint-ruleset-aws" ]] || skip "tflint-ruleset-aws is not installed (run: make tools)"
  (cd terraform && tflint --recursive --config "$REPO_ROOT/.tflint.hcl" --format compact --no-color)
}

trivy_config() {
  trivy config --quiet --skip-check-update --exit-code 1 --severity HIGH,CRITICAL \
    --cache-dir "$HARNESS_WORK_DIR/trivy-cache" --ignorefile .trivyignore.yaml \
    --skip-dirs .tools --skip-dirs .cache --skip-dirs '**/.terraform' \
    --skip-dirs platform/local/policies/tests "$@"
  # platform/local/policies/tests holds the gator fixtures: pods that break the policies on purpose
  # (never applied to a cluster). Everything that is applied is scanned.
}

check_trivy_config() {
  need trivy
  trivy_config .
}

# Same scan with the example inputs: trivy applies them to the terraform/envs/lab root, so
# variable-dependent checks (for example public endpoint CIDRs) see real values.
check_trivy_config_tfvars() {
  need trivy
  trivy_config --tf-vars terraform/envs/lab/terraform.tfvars.example .
}

check_trivyignore_policy() {
  local today max
  today="$(date -u +%F)"
  max="$(date_plus_days "$TRIVYIGNORE_MAX_DAYS")"
  awk -v today="$today" -v max="$max" '
    function flush() {
      if (id != "") {
        n++
        if (!st) { print "entry " id ": missing a non-empty statement"; bad = 1 }
        if (expiry !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { print "entry " id ": expired_at must be YYYY-MM-DD"; bad = 1 }
        else if (expiry < today) { print "entry " id ": expired on " expiry " (review or remove it)"; bad = 1 }
        else if (expiry > max) { print "entry " id ": expired_at " expiry " is after " max " (at most ~7 months ahead)"; bad = 1 }
        else { print "entry " id ": ok until " expiry }
      }
      id = ""; st = 0; expiry = ""
    }
    /^[[:space:]]*-[[:space:]]+id:/ { flush(); id = $NF; next }
    /^[[:space:]]+statement:[[:space:]]*[^[:space:]]/ { st = 1 }
    /^[[:space:]]+expired_at:/ { expiry = $NF; gsub(/["\047]/, "", expiry) }
    END { flush(); printf "%d ignore entries checked\n", n; exit bad }
  ' .trivyignore.yaml
}

check_actionlint() {
  need actionlint shellcheck
  actionlint -shellcheck "$(command -v shellcheck)"
}

check_policy_workflows() {
  local f rc=0 out ctx
  local -a files=()
  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
  ((${#files[@]} > 0)) || {
    echo "no workflows found"
    return 1
  }
  for f in "${files[@]}"; do
    out="$(awk -v file="$f" '
      function err(m) { printf "%s:%d: %s\n", file, NR, m; bad = 1 }
      /^permissions:/ { top_perm = 1; in_top_perm = 1; next }
      in_top_perm && /^  contents: read[[:space:]]*$/ { top_read = 1 }
      in_top_perm && /^[^[:space:]]/ { in_top_perm = 0 }
      /^concurrency:/ { concurrency = 1 }
      /^jobs:/ { in_jobs = 1; next }
      in_jobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job); jobs[job] = 1; next }
      in_jobs && /^    timeout-minutes:/ { timeout[job] = 1 }
      in_jobs && /^    runs-on: ubuntu-24\.04[[:space:]]*$/ { runs[job] = 1 }
      /^[[:space:]-]*uses:/ {
        ref = $0; sub(/^[[:space:]-]*uses:[[:space:]]*/, "", ref)
        if (ref ~ /^\.\//) next
        if (ref !~ /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+@[0-9a-f]+[[:space:]]+#[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$/) {
          err("pin actions to a full commit SHA with a trailing # vX.Y.Z comment: " ref)
        } else {
          sha = ref; sub(/^[^@]*@/, "", sha); sub(/[[:space:]].*$/, "", sha)
          if (length(sha) != 40) err("the commit SHA must have 40 characters: " ref)
        }
        if (ref ~ /^actions\/checkout@/) checkouts++
      }
      /persist-credentials: false/ { persist++ }
      /continue-on-error:[[:space:]]*true/ { err("continue-on-error: true is forbidden") }
      /\|\|[[:space:]]*(true|echo|:)([[:space:]]|$)/ { err("never swallow errors (|| true, || echo, || :)") }
      /aquasecurity\/(trivy-action|setup-trivy)/ { err("trivy-action/setup-trivy are forbidden; trivy comes from scripts/install-tools.sh") }
      /(^|[^A-Za-z])sed[[:space:]].*\.tf([^A-Za-z]|$)/ { err("never edit Terraform files with sed") }
      # The logs, the job summary and the artifacts of a public repository are public: the CIDRs of
      # the operator (his home address) come from a secret, which is masked, and every element is
      # masked on its own because Terraform prints them one by one.
      /TF_VAR_endpoint_public_access_cidrs:/ {
        cidrs_env = 1
        if ($0 !~ /secrets\.LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS/) err("TF_VAR_endpoint_public_access_cidrs must come from secrets.LAB_ENDPOINT_PUBLIC_ACCESS_CIDRS (a variable is printed in clear in the logs)")
      }
      /::add-mask::/ { masks = 1 }
      END {
        if (cidrs_env && !masks) { printf "%s: a workflow that uses the operator CIDRs must mask each of them (::add-mask::) in its first step\n", file; bad = 1 }
        if (!top_perm || !top_read) { printf "%s: top-level permissions must be exactly contents: read\n", file; bad = 1 }
        if (!concurrency) { printf "%s: a top-level concurrency group is required\n", file; bad = 1 }
        for (j in jobs) {
          if (!timeout[j]) { printf "%s: job %s has no timeout-minutes\n", file, j; bad = 1 }
          if (!runs[j]) { printf "%s: job %s must use runs-on: ubuntu-24.04\n", file, j; bad = 1 }
        }
        if (checkouts != persist) { printf "%s: every actions/checkout needs persist-credentials: false\n", file; bad = 1 }
        exit bad
      }' "$f")" || {
      printf '%s\n' "$out"
      rc=1
    }
  done
  if grep -n 'id-token: write' .github/workflows/ci.yml; then
    echo "ci.yml must never request id-token: write (OIDC is for cloud workflows only)"
    rc=1
  fi
  for ctx in static test e2e; do
    grep -qE "^  ${ctx}:[[:space:]]*$" .github/workflows/ci.yml || {
      echo "ci.yml must keep the stable job id '$ctx' (required status check)"
      rc=1
    }
    grep -qF "\"context\": \"$ctx\"" .github/rulesets/main.json || {
      echo ".github/rulesets/main.json must require the status check '$ctx'"
      rc=1
    }
  done
  return "$rc"
}

check_shellcheck() {
  local -a files=()
  need shellcheck
  mapfile -t files < <(find scripts platform -type f -name '*.sh' | sort)
  printf 'shellcheck: %s\n' "${files[@]}"
  shellcheck --external-sources --severity=style "${files[@]}"
}

check_kubeconform() {
  local rendered="$HARNESS_WORK_DIR/platform-manifests.yaml"
  need kubeconform
  mkdir -p "$HARNESS_WORK_DIR/kubeconform-cache"
  bash platform/render-manifests.sh us-east-1 >"$rendered"
  kubeconform -strict -summary -output text \
    -kubernetes-version "$K8S_SCHEMA_KUBERNETES_VERSION" \
    -cache "$HARNESS_WORK_DIR/kubeconform-cache" \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMA_REF/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_SCHEMA_REF/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    "$rendered"
}

check_contract_platform() {
  local rc=0 m e verbs
  m="$(bash platform/render-manifests.sh us-east-1)"
  local -a expect=(
    "kind: Namespace" "name: dx01v2"
    "pod-security.kubernetes.io/enforce: restricted"
    "pod-security.kubernetes.io/enforce-version: latest"
    "elbv2.k8s.aws/pod-readiness-gate-inject: enabled"
    "kind: Role" "name: dx01v2-deployer"
    "kind: RoleBinding" "name: dx01v2-deployers"
    "apiVersion: external-secrets.io/v1" "kind: ClusterSecretStore" "name: aws-secrets-manager"
    "service: SecretsManager" "region: us-east-1"
  )
  for e in "${expect[@]}"; do
    grep -qF -- "$e" <<<"$m" || {
      echo "platform/manifests: missing '$e' (docs/CONTRATO.md)"
      rc=1
    }
  done
  verbs="$(awk '/resources: \["secrets"\]/ { getline; print; exit }' <<<"$m")"
  [[ "$verbs" =~ verbs:\ \[\"get\",\ \"list\",\ \"watch\"\]$ ]] || {
    echo "the dx01v2-deployer Role must only read secrets (get, list, watch); got: $verbs"
    rc=1
  }
  grep -qE '^  name: aws-load-balancer-controller$' platform/values/aws-load-balancer-controller.yaml || {
    echo "LBC service account must be aws-load-balancer-controller (Pod Identity association)"
    rc=1
  }
  grep -qE '^enableServiceMutatorWebhook: false$' platform/values/aws-load-balancer-controller.yaml || {
    echo "the LBC service mutator webhook must stay off"
    rc=1
  }
  grep -qE '^  name: external-secrets$' platform/values/external-secrets.yaml || {
    echo "ESO service account must be external-secrets (Pod Identity association)"
    rc=1
  }
  grep -qE '^  name: observability$' <<<"$m" || {
    echo "platform/manifests: missing the namespace observability of the OpenTelemetry Collector (docs/CONTRATO.md)"
    rc=1
  }
  grep -qE '^  name: opentelemetry-collector$' platform/values/otel-collector.yaml || {
    echo "the OpenTelemetry Collector service account must be opentelemetry-collector (Pod Identity association)"
    rc=1
  }
  return "$rc"
}

# Renders both pinned charts with platform/values/*.yaml (no cluster needed) and asserts that the
# values are consumed as intended: images by digest, Pod Identity service accounts, feature gates,
# default tags, no service mutator webhook.
check_helm_template() {
  local rc=0 lbc eso otel key value want e charts tgz
  declare -A pv=()
  need helm
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z0-9_]+$ ]] && pv[$key]="$value"
  done < <(grep -E '^[A-Z0-9_]+=' platform/versions.env)
  export HELM_CACHE_HOME="$HARNESS_WORK_DIR/helm/cache" HELM_CONFIG_HOME="$HARNESS_WORK_DIR/helm/config" HELM_DATA_HOME="$HARNESS_WORK_DIR/helm/data"
  lbc="$(helm template aws-load-balancer-controller aws-load-balancer-controller \
    --repo https://aws.github.io/eks-charts --version "${pv[LBC_CHART_VERSION]}" --namespace kube-system \
    --values platform/values/aws-load-balancer-controller.yaml \
    --set-string clusterName=tx01v2-lab --set-string region=us-east-1 --set-string vpcId=vpc-0123456789abcdef0)"
  eso="$(helm template external-secrets external-secrets \
    --repo https://charts.external-secrets.io --version "${pv[ESO_CHART_VERSION]}" --namespace external-secrets \
    --values platform/values/external-secrets.yaml)"
  # The Collector archive is pulled and checked against OTEL_COLLECTOR_CHART_SHA256, as
  # platform/install.sh and the local lab do.
  [[ "${pv[OTEL_COLLECTOR_CHART_SHA256]:-}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "platform/versions.env: OTEL_COLLECTOR_CHART_SHA256 must be a SHA256 (64 hex characters)"
    return 1
  }
  charts="$HARNESS_WORK_DIR/charts"
  rm -rf "$charts"
  mkdir -p "$charts"
  helm pull opentelemetry-collector --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
    --version "${pv[OTEL_COLLECTOR_CHART_VERSION]}" --destination "$charts"
  tgz="$charts/opentelemetry-collector-${pv[OTEL_COLLECTOR_CHART_VERSION]}.tgz"
  [[ -f "$tgz" && "$(sha256_of "$tgz")" == "${pv[OTEL_COLLECTOR_CHART_SHA256]}" ]] || {
    echo "the opentelemetry-collector chart ${pv[OTEL_COLLECTOR_CHART_VERSION]} is missing or its SHA256 differs from platform/versions.env"
    return 1
  }
  otel="$(helm template opentelemetry-collector "$tgz" \
    --namespace observability --values platform/values/otel-collector.yaml \
    --set-string config.exporters.awsxray.region=us-east-1)"
  want="$(sed -n 's/^  digest: //p' platform/values/otel-collector.yaml)"
  local -a expect_otel=(
    "image: \"otel/opentelemetry-collector-contrib@$want\""
    "serviceAccountName: opentelemetry-collector"
    "awsxray:"
    "region: us-east-1"
    "- awsxray"
  )
  for e in "${expect_otel[@]}"; do
    grep -qF -- "$e" <<<"$otel" || {
      echo "opentelemetry-collector chart: missing '$e'"
      rc=1
    }
  done
  [[ "$want" == "$(sed -n 's/^  digest: //p' platform/local/values/otel-collector.yaml)" ]] || {
    echo "the cloud and the local OpenTelemetry Collector must run the same image digest"
    rc=1
  }
  want="$(sed -n 's/^  tag: //p' platform/values/aws-load-balancer-controller.yaml)"
  local -a expect=(
    "image: \"public.ecr.aws/eks/aws-load-balancer-controller:$want\""
    "serviceAccountName: aws-load-balancer-controller"
    "- --cluster-name=tx01v2-lab"
    "- --default-tags=Environment=lab,Project=tx01v2"
    "- --feature-gates=ALBGatewayAPI=false,NLBGatewayAPI=false"
    "kind: IngressClass"
  )
  for e in "${expect[@]}"; do
    grep -qF -- "$e" <<<"$lbc" || {
      echo "aws-load-balancer-controller chart: missing '$e'"
      rc=1
    }
  done
  if grep -qF 'mservice.elbv2.k8s.aws' <<<"$lbc"; then
    echo "aws-load-balancer-controller chart: the service mutator webhook is rendered"
    rc=1
  fi
  want="$(sed -n 's/^  tag: //p' platform/values/external-secrets.yaml)"
  (($(grep -cF "image: ghcr.io/external-secrets/external-secrets:$want" <<<"$eso") == 3)) || {
    echo "external-secrets chart: the controller, webhook and cert controller must all use the pinned digest"
    rc=1
  }
  grep -qE '^      serviceAccountName: external-secrets$' <<<"$eso" || {
    echo "external-secrets chart: the controller must run as the service account external-secrets"
    rc=1
  }
  echo "rendered aws-load-balancer-controller ${pv[LBC_CHART_VERSION]} ($(wc -l <<<"$lbc") lines), external-secrets ${pv[ESO_CHART_VERSION]} ($(wc -l <<<"$eso") lines) and opentelemetry-collector ${pv[OTEL_COLLECTOR_CHART_VERSION]} ($(wc -l <<<"$otel") lines)"
  return "$rc"
}

check_gitleaks() {
  need gitleaks git
  if git rev-parse --verify -q HEAD >/dev/null; then
    echo "repository has commits: scanning the full history (gitleaks git)"
    gitleaks git --no-banner --redact --log-level warn .
  else
    echo "no commits yet: scanning the working tree (gitleaks dir)"
    gitleaks dir --no-banner --redact --log-level warn .
  fi
}

check_terraform_test() {
  need terraform
  tf_init "$1"
  terraform -chdir="$1" test -no-color
}

# --- Local lab (terraform/envs/local + platform/local) ---------------------------------------------

# load_local_versions -> LV[KEY]=VALUE from platform/versions.env and platform/local/versions.env.
declare -A LV=()
load_local_versions() {
  local f key value
  for f in platform/versions.env platform/local/versions.env; do
    while IFS='=' read -r key value; do
      [[ "$key" =~ ^[A-Z0-9_]+$ ]] && LV[$key]="$value"
    done < <(grep -E '^[A-Z0-9_]+=' "$f")
  done
}

check_local_versions() {
  local rc=0 key entry prefix version_key sha_key kind_minor
  load_versions
  load_local_versions
  for key in "${!LV[@]}"; do
    if [[ "$key" == *_SHA256 && ! "${LV[$key]}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "platform/local/versions.env: $key must be a SHA256 (64 hex characters)"
      rc=1
    fi
  done
  for entry in "${LOCAL_CHARTS[@]}"; do
    read -r prefix version_key sha_key _ <<<"$entry"
    [[ "${LV[$prefix]:-}" =~ ^https:// ]] || {
      echo "platform/local/versions.env: $prefix must be an https URL"
      rc=1
    }
    [[ -n "${LV[$version_key]:-}" && -n "${LV[$sha_key]:-}" ]] || {
      echo "platform/local/versions.env: $version_key and $sha_key are required"
      rc=1
    }
  done
  [[ "${LV[GATEKEEPER_VERSION]:-}" == "$GATOR_VERSION" ]] || {
    echo "tools/versions.env GATOR_VERSION ($GATOR_VERSION) must equal GATEKEEPER_VERSION (${LV[GATEKEEPER_VERSION]:-?})"
    rc=1
  }
  kind_minor="$(grep -oE 'kindest/node:v[0-9]+\.[0-9]+' terraform/envs/local/kind-config.yaml | sed 's/.*:v//')"
  grep -qE "^  default     = \"$kind_minor\"$" <(awk '/^variable "cluster_version"/ { a = 1 } a' terraform/envs/lab/variables.tf) || {
    echo "the kind node image ($kind_minor) must run the Kubernetes minor of the EKS lab (cluster_version)"
    rc=1
  }
  grep -qE 'kindest/node:v[0-9.]+@sha256:[0-9a-f]{64}$' terraform/envs/local/kind-config.yaml || {
    echo "terraform/envs/local/kind-config.yaml must pin the node image by digest"
    rc=1
  }
  [[ "$(grep -c 'tag: v'"${LV[ESO_CHART_VERSION]}"'@sha256' platform/values/external-secrets.yaml)" == 3 ]] || {
    echo "the local platform reuses platform/values/external-secrets.yaml: it must pin ESO ${LV[ESO_CHART_VERSION]} by digest"
    rc=1
  }
  return "$rc"
}

# local_chart_values NAME -> --values arguments for one chart, with the install-time placeholders of
# platform/local/install.sh replaced by example values.
local_chart_values() {
  local list=$1 v out="$HARNESS_WORK_DIR/local-values" f
  local -a parts=()
  mkdir -p "$out"
  local i=0
  IFS=, read -ra parts <<<"$list"
  for v in "${parts[@]}"; do
    i=$((i + 1))
    f="platform/local/values/$v.yaml"
    sed -e 's|__S3_BUCKET__|tx01v2-local-velero|' -e 's|__S3_ENDPOINT__|http://10.250.0.12:7070|' \
      -e 's|__REGISTRY_ENDPOINT__|10.250.0.10:5000|' "$f" >"$out/$i-$(basename "$v").yaml"
    printf -- '--values\n%s\n' "$out/$i-$(basename "$v").yaml"
  done
}

# Pulls every chart of the local platform (SHA256-verified, like install.sh), renders it with its
# values and asserts: every image pinned by digest, no :latest, no Service of type LoadBalancer or
# NodePort (only the Istio gateways get a LoadBalancer, created at run time), no placeholder left.
# A chart with a size overlay (platform/local/values/small/<chart>.yaml, LOCAL_SIZE=small) is rendered
# twice: the same checks hold for both, and the overlay changes sizes, never images.
check_helm_template_local() {
  local rc=0 entry repo_key version_key sha_key chart values tgz rendered out images bad svc variant label f
  local default_images
  local -a args=() extra=() variants=() charts=()
  need helm
  load_local_versions
  export HELM_CACHE_HOME="$HARNESS_WORK_DIR/helm/cache" HELM_CONFIG_HOME="$HARNESS_WORK_DIR/helm/config" HELM_DATA_HOME="$HARNESS_WORK_DIR/helm/data"
  out="$HARNESS_WORK_DIR/local-charts"
  rm -rf "$out"
  mkdir -p "$out"
  for entry in "${LOCAL_CHARTS[@]}"; do
    read -r _ _ _ chart _ <<<"$entry"
    charts+=("$chart")
  done
  for f in platform/local/values/small/*.yaml; do
    [[ -e "$f" ]] || continue
    printf '%s\n' "${charts[@]}" | grep -qxF "$(basename "$f" .yaml)" || {
      echo "$f: no chart of that name in LOCAL_CHARTS (the size overlays are applied by chart name)"
      rc=1
    }
  done
  for entry in "${LOCAL_CHARTS[@]}"; do
    read -r repo_key version_key sha_key chart values <<<"$entry"
    mkdir -p "$out/$chart"
    helm pull "$chart" --repo "${LV[$repo_key]}" --version "${LV[$version_key]}" --destination "$out/$chart" >/dev/null
    tgz="$(find "$out/$chart" -maxdepth 1 -name '*.tgz' -print -quit)"
    [[ "$(sha256_of "$tgz")" == "${LV[$sha_key]:-}" ]] || {
      echo "$chart ${LV[$version_key]}: SHA256 $(sha256_of "$tgz") differs from $sha_key"
      rc=1
      continue
    }
    mapfile -t args < <(local_chart_values "$values")
    variants=(default)
    [[ -f "platform/local/values/small/$chart.yaml" ]] && variants+=(small)
    default_images=""
    for variant in "${variants[@]}"; do
      rendered="$out/$chart.yaml"
      label="$chart"
      extra=()
      if [[ "$variant" == small ]]; then
        rendered="$out/$chart-small.yaml"
        label="$chart (size small)"
        extra=(--values "platform/local/values/small/$chart.yaml")
      fi
      helm template "$chart" "$tgz" --namespace lab --kube-version "$K8S_SCHEMA_KUBERNETES_VERSION" "${args[@]}" "${extra[@]}" >"$rendered" || {
        echo "$label: helm template failed"
        rc=1
        continue
      }
      # Some charts (istio base) render no workload at all.
      # ConfigMaps are left out: istiod ships its injection templates (with template placeholders) in one.
      images="$(awk '/^---/ { flush(); next } { doc = doc $0 "\n" } /^kind: ConfigMap$/ { skip = 1 }
        function flush() { if (!skip) printf "%s", doc; doc = ""; skip = 0 } END { flush() }' "$rendered" |
        grep -hoE '^[[:space:]-]*image:[[:space:]]*["'\'']?[^"'\''[:space:]]+' | sed -E 's/^[[:space:]-]*image:[[:space:]]*["'\'']?//' | sort -u)" || images=""
      bad=""
      [[ -z "$images" ]] || bad="$(grep -vE '@sha256:[0-9a-f]{64}$' <<<"$images")" || bad=""
      if [[ -n "$bad" ]]; then
        printf '%s: images not pinned by digest:\n%s\n' "$label" "$bad"
        rc=1
      fi
      svc="$(awk '/^kind: Service$/ { s = 1 } s && /^  type: (LoadBalancer|NodePort)/ { print; s = 0 } /^---/ { s = 0 }' "$rendered")"
      if [[ -n "$svc" ]]; then
        printf '%s: Services must stay ClusterIP:\n%s\n' "$label" "$svc"
        rc=1
      fi
      if grep -qE '__[A-Z_]+__' "$rendered"; then
        echo "$label: unresolved placeholder in the rendered chart"
        rc=1
      fi
      if [[ "$variant" == default ]]; then
        default_images="$images"
      elif [[ "$images" != "$default_images" ]]; then
        echo "$label: the size overlay changes the images (it may only change sizes)"
        rc=1
      fi
      echo "$label ${LV[$version_key]}: $(grep -c . <<<"$images" || :) images, $(grep -c '^kind:' "$rendered" || :) objects"
    done
  done
  return "$rc"
}

# kubeconform on the plain manifests of the local platform (the Gatekeeper constraints are custom
# kinds created by their templates: gator verify covers them).
check_kubeconform_local() {
  need kubeconform
  mkdir -p "$HARNESS_WORK_DIR/kubeconform-cache"
  kubeconform -strict -summary -output text \
    -kubernetes-version "$K8S_SCHEMA_KUBERNETES_VERSION" \
    -cache "$HARNESS_WORK_DIR/kubeconform-cache" \
    -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$K8S_SCHEMA_REF/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
    -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/$CRD_SCHEMA_REF/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
    platform/local/manifests platform/local/policies/templates platform/local/policies/tests/namespace-dx01v2.yaml
}

check_policy_gator() {
  need gator
  gator verify -v platform/local/policies/tests/
}

check_local_lab_e2e() {
  need terraform kind kubectl helm docker curl git ssh
  docker info >/dev/null 2>&1 || skip "docker is installed but the daemon is not reachable"
  bash scripts/local-lab.sh e2e
}

register_checks() {
  local d
  register static tool-versions check_tool_versions
  register static repo-structure check_repo_structure
  register static version-consistency check_version_consistency
  register static policy-terraform check_policy_terraform
  register static policy-identifiers check_policy_identifiers
  register static policy-workflows check_policy_workflows
  register static policy-scripts check_policy_scripts
  register static destroy-flow check_destroy_flow
  register static trivyignore-policy check_trivyignore_policy
  register static contract-platform check_contract_platform
  register static terraform-fmt check_terraform_fmt
  register static terraform-lockfiles check_terraform_lockfiles
  for d in terraform/bootstrap terraform/envs/lab terraform/envs/local "$REPO_ROOT"/terraform/modules/*/; do
    d="${d#"$REPO_ROOT"/}"
    d="${d%/}"
    register static "terraform-validate:${d#terraform/}" "check_terraform_validate $d"
  done
  register static tflint check_tflint
  register static trivy-config check_trivy_config
  register static trivy-config-tfvars check_trivy_config_tfvars
  register static actionlint check_actionlint
  register static shellcheck check_shellcheck
  register static kubeconform check_kubeconform
  register static helm-template check_helm_template
  register static local-versions check_local_versions
  register static helm-template-local check_helm_template_local
  register static kubeconform-local check_kubeconform_local
  register static policy-gator check_policy_gator
  register static gitleaks check_gitleaks
  register test tool-versions check_tool_versions
  register test terraform-test:bootstrap "check_terraform_test terraform/bootstrap"
  register test terraform-test:envs/lab "check_terraform_test terraform/envs/lab"
  register test terraform-test:envs/local "check_terraform_test terraform/envs/local"
  register e2e local-lab-e2e check_local_lab_e2e
}

# ---------------------------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------------------------

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a FAILED=()

run_check() {
  local name=$1 cmd=$2 log rc start secs status reason="" lines
  local -a parts=()
  read -ra parts <<<"$cmd"
  log="$HARNESS_WORK_DIR/logs/${name//[^A-Za-z0-9._-]/_}.log"
  start=$SECONDS
  set +e
  (
    set -euo pipefail
    cd "$REPO_ROOT"
    "${parts[@]}"
  ) >"$log" 2>&1
  rc=$?
  set -e
  secs=$((SECONDS - start))
  case "$rc" in
    0) status=PASS ;;
    "$SKIP_CODE")
      reason="$(sed -n 's/^SKIP_REASON: //p' "$log" | tail -n 1)"
      if strict; then
        status=FAIL
        reason="$reason (SKIP is not allowed with HARNESS_STRICT=1)"
      else
        status=SKIP
      fi
      ;;
    *) status=FAIL ;;
  esac
  printf '%s %s (%ss)%s\n' "$status" "$name" "$secs" "${reason:+ - $reason}"
  case "$status" in
    PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    FAIL)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED+=("$name")
      ;;
  esac
  if [[ "$status" == FAIL || "$HARNESS_VERBOSE" == 1 ]]; then
    lines="$(wc -l <"$log")"
    if ((lines > 400)); then
      echo "    ... last 400 of $lines lines (full log: $log)"
    fi
    tail -n 400 "$log" | sed 's/^/    /'
  fi
}

list_checks() {
  local i
  echo "stages:"
  echo "  static  policies, fmt, validate, lock files, tflint, trivy, actionlint, shellcheck, kubeconform, helm template, gitleaks"
  echo "  test    terraform test (mocked providers) for terraform/bootstrap, terraform/envs/lab and terraform/envs/local"
  echo "  e2e     local lab on Docker: terraform apply of envs/local, platform/local, every probe, destroy + leftovers"
  echo "  all     static + test + e2e"
  echo "checks:"
  for i in "${!CHECK_NAME[@]}"; do
    printf '  %-7s %s\n' "${CHECK_STAGE[$i]}" "${CHECK_NAME[$i]}"
  done
}

usage() {
  echo "usage: $0 <stage>...   (stages: static, test, e2e, all, list)" >&2
  exit 2
}

main() {
  local arg stage i start_all=$SECONDS
  local -a stages=()
  declare -A seen=()
  (($# > 0)) || usage
  register_checks
  for arg in "$@"; do
    case "$arg" in
      static | test | e2e) stages+=("$arg") ;;
      all) stages+=(static test e2e) ;;
      list)
        list_checks
        return 0
        ;;
      *) usage ;;
    esac
  done
  mkdir -p "$HARNESS_WORK_DIR/logs"
  echo "harness: stages=${stages[*]} strict=$HARNESS_STRICT work_dir=$HARNESS_WORK_DIR${HARNESS_ONLY:+ only=$HARNESS_ONLY}"
  for stage in "${stages[@]}"; do
    for i in "${!CHECK_NAME[@]}"; do
      [[ "${CHECK_STAGE[$i]}" == "$stage" && -z "${seen[${CHECK_NAME[$i]}]:-}" ]] || continue
      [[ -z "$HARNESS_ONLY" || "${CHECK_NAME[$i]}" =~ $HARNESS_ONLY ]] || continue
      seen[${CHECK_NAME[$i]}]=1
      run_check "${CHECK_NAME[$i]}" "${CHECK_CMD[$i]}"
    done
  done
  echo "summary: $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) checks, $PASS_COUNT PASS, $FAIL_COUNT FAIL, $SKIP_COUNT SKIP ($((SECONDS - start_all))s, strict=$HARNESS_STRICT)"
  if ((PASS_COUNT + FAIL_COUNT + SKIP_COUNT == 0)); then
    echo "no check matched HARNESS_ONLY='$HARNESS_ONLY'"
    return 1
  fi
  if ((FAIL_COUNT > 0)); then
    echo "failed: ${FAILED[*]}"
    return 1
  fi
}

main "$@"
