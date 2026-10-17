#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
select_lab_target primary
[[ "$LAB_CLUSTER" == tx01v2-lab && "$LAB_SSM_PREFIX" == /tx01v2/lab ]]
select_lab_target secondary
[[ "$LAB_CLUSTER" == tx01v2-lab-dr && "$LAB_SSM_PREFIX" == /tx01v2/lab-dr ]]
if (select_lab_target unrelated) >/dev/null 2>&1; then die 'arbitrary cluster accepted'; fi
out="$(bash "$REPO_ROOT/platform/render-manifests.sh" us-west-2 --full example-owner --target secondary)"
[[ "$out" == *'dxRevision: gitops/aws-dr'* && "$out" == *'name: lab-daily-dr'* ]]
echo 'PASS fixed regional cluster/contract, separate GitOps source and backup schedule'
