#!/usr/bin/env bash
# Offline fork rehearsal for the cloud platform profiles. No AWS, Kubernetes, or GitHub calls.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

core="$(bash platform/render-manifests.sh us-east-1)"
full="$(bash platform/render-manifests.sh us-east-1 --full forked-lab)"

for component in argocd gatekeeper-system istio-system cert-manager; do
  if grep -qF "name: $component" <<<"$core"; then
    echo "core profile unexpectedly rendered full-only component $component" >&2
    exit 1
  fi
  grep -qF "name: $component" <<<"$full" || {
    echo "full profile is missing $component" >&2
    exit 1
  }
done

grep -qF 'https://github.com/forked-lab/tx01v2.git' <<<"$full"
grep -qF 'https://github.com/forked-lab/dx01v2.git' <<<"$full"
if grep -qE '__[A-Z][A-Z0-9_]*__' <<<"$full"; then
  echo "full profile contains an unresolved fork placeholder" >&2
  exit 1
fi

if bash platform/render-manifests.sh us-east-1 --full >"$work/missing-owner.out" 2>&1; then
  echo "full manifest render accepted a missing fork owner" >&2
  exit 1
fi
if bash platform/install.sh --profile full >"$work/missing-owner-install.out" 2>&1; then
  echo "full installer accepted a missing fork owner" >&2
  exit 1
fi
grep -qF 'needs --github-owner' "$work/missing-owner-install.out"

if bash platform/install.sh --profile unsupported >"$work/invalid-profile.out" 2>&1; then
  echo "installer accepted an unsupported profile" >&2
  exit 1
fi

if bash platform/render-manifests.sh invalid-region >"$work/invalid-region.out" 2>&1; then
  echo "manifest render accepted an invalid region" >&2
  exit 1
fi

echo "PASS offline fork profiles: core/full render, owner substitution, missing prerequisites, invalid profile and region"
