# shellcheck shell=bash
# Download metadata for every harness tool (official release URLs only).
# Used by scripts/install-tools.sh and scripts/update-tool-checksums.sh.

# Install order; also the list accepted by both scripts.
# shellcheck disable=SC2034 # used by the scripts that source this file
TOOLS_ALL=(terraform tflint tflint-ruleset-aws trivy actionlint shellcheck kubeconform gitleaks kubectl helm kind gator)
# shellcheck disable=SC2034
TOOLS_PLATFORMS=(linux_amd64 linux_arm64 darwin_arm64)

# tools_platform -> linux_amd64 | linux_arm64 | darwin_arm64 for the current machine.
tools_platform() {
  local os arch
  case "$(uname -s)" in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported OS '$(uname -s)'; use the devcontainer or WSL (see docs/HARNESS.md)." ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported CPU architecture '$(uname -m)'." ;;
  esac
  case "${os}_${arch}" in
    linux_amd64 | linux_arm64 | darwin_arm64) printf '%s_%s' "$os" "$arch" ;;
    *) die "unsupported platform ${os}_${arch} (supported: ${TOOLS_PLATFORMS[*]})." ;;
  esac
}

# tool_known TOOL -> success when TOOL is managed by these scripts.
tool_known() {
  local t
  for t in "${TOOLS_ALL[@]}"; do
    [[ "$t" == "$1" ]] && return 0
  done
  return 1
}

# tool_artifact TOOL VERSION PLATFORM -> release artifact file name.
tool_artifact() {
  local tool=$1 v=$2 p=$3 os=${3%_*} arch=${3#*_} x
  case "$tool" in
    terraform) printf 'terraform_%s_%s.zip' "$v" "$p" ;;
    tflint) printf 'tflint_%s.zip' "$p" ;;
    tflint-ruleset-aws) printf 'tflint-ruleset-aws_%s.zip' "$p" ;;
    trivy)
      case "$p" in
        linux_amd64) x=Linux-64bit ;;
        linux_arm64) x=Linux-ARM64 ;;
        darwin_arm64) x=macOS-ARM64 ;;
      esac
      printf 'trivy_%s_%s.tar.gz' "$v" "$x"
      ;;
    actionlint) printf 'actionlint_%s_%s.tar.gz' "$v" "$p" ;;
    shellcheck)
      case "$p" in
        linux_amd64) x=linux.x86_64 ;;
        linux_arm64) x=linux.aarch64 ;;
        darwin_arm64) x=darwin.aarch64 ;;
      esac
      printf 'shellcheck-v%s.%s.tar.xz' "$v" "$x"
      ;;
    kubeconform) printf 'kubeconform-%s-%s.tar.gz' "$os" "$arch" ;;
    gitleaks)
      x=$p
      [[ "$p" == linux_amd64 ]] && x=linux_x64
      printf 'gitleaks_%s_%s.tar.gz' "$v" "$x"
      ;;
    kubectl) printf 'kubectl' ;;
    helm) printf 'helm-v%s-%s-%s.tar.gz' "$v" "$os" "$arch" ;;
    kind) printf 'kind-%s-%s' "$os" "$arch" ;;
    gator) printf 'gator-v%s-%s-%s.tar.gz' "$v" "$os" "$arch" ;;
    *) die "unknown tool: $tool" ;;
  esac
}

# tool_url TOOL VERSION PLATFORM -> official download URL of the artifact.
tool_url() {
  local tool=$1 v=$2 p=$3 os=${3%_*} arch=${3#*_} a gh=https://github.com
  a="$(tool_artifact "$tool" "$v" "$p")"
  case "$tool" in
    terraform) printf 'https://releases.hashicorp.com/terraform/%s/%s' "$v" "$a" ;;
    tflint) printf '%s/terraform-linters/tflint/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    tflint-ruleset-aws) printf '%s/terraform-linters/tflint-ruleset-aws/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    trivy) printf '%s/aquasecurity/trivy/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    actionlint) printf '%s/rhysd/actionlint/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    shellcheck) printf '%s/koalaman/shellcheck/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    kubeconform) printf '%s/yannh/kubeconform/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    gitleaks) printf '%s/gitleaks/gitleaks/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    kubectl) printf 'https://dl.k8s.io/release/v%s/bin/%s/%s/kubectl' "$v" "$os" "$arch" ;;
    helm) printf 'https://get.helm.sh/%s' "$a" ;;
    kind) printf '%s/kubernetes-sigs/kind/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    gator) printf '%s/open-policy-agent/gatekeeper/releases/download/v%s/%s' "$gh" "$v" "$a" ;;
    *) die "unknown tool: $tool" ;;
  esac
}

# tool_checksum_url TOOL VERSION PLATFORM -> URL of the upstream checksum file of that
# exact release, or nothing when upstream publishes none (shellcheck).
tool_checksum_url() {
  local tool=$1 v=$2 p=$3 gh=https://github.com
  case "$tool" in
    terraform) printf 'https://releases.hashicorp.com/terraform/%s/terraform_%s_SHA256SUMS' "$v" "$v" ;;
    tflint) printf '%s/terraform-linters/tflint/releases/download/v%s/checksums.txt' "$gh" "$v" ;;
    tflint-ruleset-aws) printf '%s/terraform-linters/tflint-ruleset-aws/releases/download/v%s/checksums.txt' "$gh" "$v" ;;
    trivy) printf '%s/aquasecurity/trivy/releases/download/v%s/trivy_%s_checksums.txt' "$gh" "$v" "$v" ;;
    actionlint) printf '%s/rhysd/actionlint/releases/download/v%s/actionlint_%s_checksums.txt' "$gh" "$v" "$v" ;;
    shellcheck) ;;
    kubeconform) printf '%s/yannh/kubeconform/releases/download/v%s/CHECKSUMS' "$gh" "$v" ;;
    gitleaks) printf '%s/gitleaks/gitleaks/releases/download/v%s/gitleaks_%s_checksums.txt' "$gh" "$v" "$v" ;;
    kubectl) printf '%s.sha256' "$(tool_url "$tool" "$v" "$p")" ;;
    helm) printf '%s.sha256sum' "$(tool_url "$tool" "$v" "$p")" ;;
    kind) printf '%s.sha256sum' "$(tool_url "$tool" "$v" "$p")" ;;
    gator) printf '%s/open-policy-agent/gatekeeper/releases/download/v%s/sha256sums.txt' "$gh" "$v" ;;
    *) die "unknown tool: $tool" ;;
  esac
}

# tool_expected_sha TOOL VERSION PLATFORM -> SHA256 recorded in tools/checksums.txt.
tool_expected_sha() {
  awk -v t="$1" -v v="$2" -v p="$3" '!/^#/ && NF == 4 && $2 == t && $3 == v && $4 == p { print $1; exit }' \
    "$REPO_ROOT/tools/checksums.txt"
}

# tool_extract TOOL VERSION PLATFORM ARCHIVE TOOLS_DIR -> installs the binary from ARCHIVE.
tool_extract() {
  local tool=$1 v=$2 p=$3 archive=$4 tools_dir=$5 work src dest
  work="$(mktemp -d)"
  case "$archive" in
    *.zip) unzip -q -o "$archive" -d "$work" ;;
    *.tar.gz) tar -xzf "$archive" -C "$work" ;;
    *.tar.xz) tar -xJf "$archive" -C "$work" ;;
    *) cp "$archive" "$work/$tool" ;;
  esac
  case "$tool" in
    shellcheck) src="$work/shellcheck-v$v/shellcheck" ;;
    helm) src="$work/${p/_/-}/helm" ;;
    *) src="$work/$tool" ;;
  esac
  [[ -f "$src" ]] || die "binary for $tool not found inside $(basename "$archive")"
  if [[ "$tool" == tflint-ruleset-aws ]]; then
    # Layout expected by tflint for `plugin "aws" { source = "github.com/terraform-linters/tflint-ruleset-aws" }`.
    dest="$tools_dir/tflint-plugins/github.com/terraform-linters/tflint-ruleset-aws"
    rm -rf "$dest"
    mkdir -p "$dest/$v"
    install -m 0755 "$src" "$dest/$v/tflint-ruleset-aws"
  else
    mkdir -p "$tools_dir/bin"
    install -m 0755 "$src" "$tools_dir/bin/$tool"
  fi
  rm -rf "$work"
}

# tool_installed_path TOOL VERSION TOOLS_DIR -> path of the installed binary.
tool_installed_path() {
  if [[ "$1" == tflint-ruleset-aws ]]; then
    printf '%s/tflint-plugins/github.com/terraform-linters/tflint-ruleset-aws/%s/tflint-ruleset-aws' "$3" "$2"
  else
    printf '%s/bin/%s' "$3" "$1"
  fi
}
