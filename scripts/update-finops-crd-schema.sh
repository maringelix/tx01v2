#!/usr/bin/env bash
# Kubernetes 1.36.4 API schema, because the standard catalog omits the CRD envelope.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
require_cmd jq curl
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
download 'https://raw.githubusercontent.com/kubernetes/kubernetes/bb826b1d48562f110659e64e8ec444327433db95/api/openapi-spec/v3/apis__apiextensions.k8s.io__v1_openapi.json' "$work/openapi.json"
[[ "$(sha256_of "$work/openapi.json")" == 1c7dd621bece6661867bcc29471f774a46b36c02567d59815c7c72f6d08aa512 ]] ||
  die 'Kubernetes CRD OpenAPI checksum mismatch'
mkdir -p "$REPO_ROOT/platform/finops/schemas"
jq '{
  "$schema":"http://json-schema.org/draft-04/schema#",
  description:"Generated from Kubernetes v1.36.4 bb826b1d48562f110659e64e8ec444327433db95; scripts/update-finops-crd-schema.sh",
  "$ref":"#/definitions/io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1.CustomResourceDefinition",
  definitions:.components.schemas
} | walk(if type == "object" and (."$ref"? | type == "string") then .["$ref"] |= sub("^#/components/schemas/";"#/definitions/") else . end)' \
  "$work/openapi.json" >"$REPO_ROOT/platform/finops/schemas/customresourcedefinition.json"
