#!/usr/bin/env bash
# Installs the platform layer on the lab cluster (never done by Terraform):
#   1. AWS Load Balancer Controller (kube-system, IngressClass alb)
#   2. External Secrets Operator (external-secrets)
#   3. platform/manifests (namespaces dx01v2 and observability, deployer RBAC, ClusterSecretStore)
#   4. OpenTelemetry Collector (observability): OTLP from the app, traces to AWS X-Ray
# CLOUD-MUTATING: run it only when you mean to (docs/RUNBOOK.md). Needs AWS CLI v2, kubectl and helm
# (scripts/install-tools.sh kubectl helm), AWS_REGION and credentials of a principal listed in
# cluster_admin_principal_arns. Re-running it upgrades in place. It installs only on the cluster of
# the contract (tx01v2-lab, tagged Project=tx01v2); the kubeconfig and the Helm repositories live in a
# temporary directory, so the ~/.kube/config, the current context and the Helm settings of the
# machine stay as they were.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

# load_platform_versions -> reads platform/versions.env (KEY=VALUE lines) without executing it.
load_platform_versions() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^([A-Z0-9_]+)=([A-Za-z0-9._-]+)$ ]] || die "invalid line in platform/versions.env: $line"
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done <"$HERE/versions.env"
}

apply_manifests() {
  local region=$1 attempt
  # The ESO admission webhook can need a few seconds after `helm --wait` to serve its certificate.
  for attempt in 1 2 3 4 5; do
    if "$HERE/render-manifests.sh" "$region" | kubectl apply -f -; then
      return 0
    fi
    log "kubectl apply failed (attempt $attempt/5); retrying in 15 s"
    sleep 15
  done
  die "could not apply platform/manifests"
}

WORK_DIR=""
cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

main() {
  require_cmd aws kubectl helm
  require_aws_region
  load_platform_versions

  local cluster region vpc_id store tgz
  cluster="$(lab_param cluster-name)"
  region="$(lab_param region)"
  vpc_id="$(lab_param vpc-id)"
  store="$(lab_param eso/cluster-secret-store)"
  [[ "$region" == "$AWS_REGION" ]] || die "AWS_REGION=$AWS_REGION but the lab runs in $region"
  [[ "$cluster" == "$LAB_CLUSTER" ]] || die "contract key cluster-name is '$cluster', not $LAB_CLUSTER"
  require_lab_cluster "$cluster"

  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  export HELM_REPOSITORY_CONFIG="$WORK_DIR/helm/repositories.yaml" HELM_REPOSITORY_CACHE="$WORK_DIR/helm/cache"

  log "cluster $cluster in $region (VPC $vpc_id)"
  aws eks update-kubeconfig --region "$region" --name "$cluster" --kubeconfig "$KUBECONFIG" >/dev/null
  kubectl get --raw /readyz >/dev/null || die "the Kubernetes API is not reachable (endpoint_public_access_cidrs?) or this principal has no access entry"

  helm repo add eks https://aws.github.io/eks-charts --force-update
  helm repo add external-secrets https://charts.external-secrets.io --force-update
  helm repo update eks external-secrets

  log "installing aws-load-balancer-controller chart $LBC_CHART_VERSION"
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version "$LBC_CHART_VERSION" \
    --values "$HERE/values/aws-load-balancer-controller.yaml" \
    --set-string clusterName="$cluster" \
    --set-string region="$region" \
    --set-string vpcId="$vpc_id" \
    --wait=watcher --rollback-on-failure --timeout 10m

  log "installing external-secrets chart $ESO_CHART_VERSION"
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "$ESO_CHART_VERSION" \
    --values "$HERE/values/external-secrets.yaml" \
    --wait=watcher --rollback-on-failure --timeout 10m

  log "applying platform/manifests"
  apply_manifests "$region"

  # The Collector, from the chart archive checked against platform/versions.env.
  tgz="$WORK_DIR/opentelemetry-collector-$OTEL_COLLECTOR_CHART_VERSION.tgz"
  helm pull opentelemetry-collector --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
    --version "$OTEL_COLLECTOR_CHART_VERSION" --destination "$WORK_DIR"
  [[ -f "$tgz" && "$(sha256_of "$tgz")" == "$OTEL_COLLECTOR_CHART_SHA256" ]] ||
    die "refusing the opentelemetry-collector chart $OTEL_COLLECTOR_CHART_VERSION: missing, or its SHA256 differs from platform/versions.env"
  log "installing the opentelemetry-collector chart $OTEL_COLLECTOR_CHART_VERSION (SHA256 verified; traces to X-Ray in $region)"
  helm upgrade --install opentelemetry-collector "$tgz" \
    --namespace observability \
    --values "$HERE/values/otel-collector.yaml" \
    --set-string config.exporters.awsxray.region="$region" \
    --wait=watcher --rollback-on-failure --timeout 10m

  # Ready means ESO reached Secrets Manager with its Pod Identity credentials.
  kubectl wait --for=condition=Ready "clustersecretstore/$store" --timeout=180s
  kubectl get ingressclass alb >/dev/null
  log "platform ready: IngressClass alb, ClusterSecretStore $store, namespace dx01v2, OTLP endpoint opentelemetry-collector.observability.svc:4318"
}

main "$@"
