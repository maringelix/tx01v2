#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/backup-credentials.sh
source "$REPO_ROOT/scripts/lib/backup-credentials.sh"
work="$(mktemp -d)"
trap 'rm -rf -- "${work:?}"' EXIT
mkdir "$work/bin"
cat >"$work/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "-n velero get secret velero-repo-credentials"*)
    [[ -f "$MOCK_STATE/key" ]] || exit 1
    if [[ "$*" == *-o* ]]; then base64 <"$MOCK_STATE/key" | tr -d '\n'; fi ;;
  "-n velero create secret generic velero-repo-credentials --from-file=repository-password=/dev/stdin")
    cat >"$MOCK_STATE/key" ;;
  *) echo 'unexpected Kubernetes request' >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH" MOCK_STATE="$work"
if (unset VELERO_REPOSITORY_PASSWORD; ensure_velero_repository_credentials) >/dev/null 2>&1; then die 'missing repository key accepted'; fi
[[ ! -e "$work/key" ]]
VELERO_REPOSITORY_PASSWORD="$(printf '%064d' 1)"
ensure_velero_repository_credentials
[[ "$(cat "$work/key")" == "$VELERO_REPOSITORY_PASSWORD" ]]
ensure_velero_repository_credentials
if (VELERO_REPOSITORY_PASSWORD="$(printf '%064d' 2)"; ensure_velero_repository_credentials) >/dev/null 2>&1; then die 'repository key changed'; fi
echo 'PASS mandatory initial key, idempotent reuse and refusal of an incompatible repository key'
[[ "$(cat "$work/key")" == "$(printf '%064d' 1)" ]]
