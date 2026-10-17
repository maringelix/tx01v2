#!/usr/bin/env bash
# Portable entry point and context guard; the real data recovery still has to pass Docker CI.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
cd "$REPO_ROOT"
bash -n scripts/local/volume-restore-drill.sh platform/local/check.sh platform/local/install.sh
grep -qFx "  bash \"\$REPO_ROOT/scripts/local/volume-restore-drill.sh\"" platform/local/check.sh ||
  die 'PVC recovery must be called through the repository root, including on a fork'
grep -qFx 'require_lab_context' scripts/local/volume-restore-drill.sh ||
  die 'PVC recovery must refuse any Kubernetes context outside the local kind lab'
grep -qF 'PodVolumeBackup' docs/CONTINUIDADE.md ||
  die 'continuity docs must distinguish data backup from Kubernetes object backup'
echo 'PASS: PVC restore entry point is portable and protected by the local context guard'
