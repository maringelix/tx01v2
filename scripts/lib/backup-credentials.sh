# shellcheck shell=bash
# Call after the owned Velero namespace exists and before starting any repository.
ensure_velero_repository_credentials() {
  set +x
  local provided="${VELERO_REPOSITORY_PASSWORD:-}" current
  if kubectl -n velero get secret velero-repo-credentials >/dev/null 2>&1; then
    if [[ -n "$provided" ]]; then
      current="$(kubectl -n velero get secret velero-repo-credentials -o jsonpath='{.data.repository-password}' | base64 -d)"
      [[ "$current" == "$provided" ]] || die 'Velero repository password differs; refusing to make existing backups unreadable'
    fi
    return
  fi
  [[ "$provided" =~ ^[a-f0-9]{64}$ ]] ||
    die 'Set VELERO_REPOSITORY_PASSWORD to the same escrowed 64-hex key in both regions before the first backup'
  printf '%s' "$provided" | kubectl -n velero create secret generic velero-repo-credentials \
    --from-file=repository-password=/dev/stdin >/dev/null
}
