#!/usr/bin/env bash
# Installs the platform layer on the lab cluster (never done by Terraform). Two profiles:
#   core (default)
#     1. AWS Load Balancer Controller (kube-system, IngressClass alb)
#     2. External Secrets Operator (external-secrets)
#     3. platform/manifests (namespaces dx01v2 and observability, deployer RBAC, ClusterSecretStore)
#     4. OpenTelemetry Collector (observability): OTLP from the app, traces to AWS X-Ray
#   full = core + the local lab's shared charts plus cloud-only integrations, all pinned by chart
#     archive SHA256 and image digests (platform/full/charts.txt, platform/local/versions.env), with
#     the cloud values (platform/values/full) and manifests in platform/manifests/full:
#     5. Istio ambient (istio-system), the Gateway API CRDs and cert-manager
#     6. kube-prometheus-stack, Loki, Alloy and Tempo (monitoring); the Collector sends traces to Tempo too
#     7. Argo CD (argocd): the Application platform syncs platform/gitops of your tx01v2 fork, which
#        registers the app dx01v2 from your dx01v2 fork
#     8. Gatekeeper policies, Kyverno promotion-attestation admission, Trivy Operator, Velero (S3
#        bucket of the lab, Pod Identity) and Chaos Mesh
# usage: platform/install.sh [--profile core|full] [--github-owner OWNER]
#   --github-owner  the GitHub user or organization that owns your forks (required by the profile full)
# Environment: AWS_REGION and the credentials of a principal listed in cluster_admin_principal_arns;
# SLACK_WEBHOOK_URL (optional, an https Slack incoming webhook: the profile full also posts warning and
# critical alerts there; it goes to a Secret through stdin, never to a file or an argument).
# CLOUD-MUTATING: run it only when you mean to (docs/RUNBOOK.md). Needs AWS CLI v2, kubectl and helm
# (scripts/install-tools.sh kubectl helm), plus openssl and curl for the profile full.
# Re-running it upgrades in place. It installs only on the cluster of the contract (tx01v2-lab,
# tagged Project=tx01v2); the kubeconfig and the Helm repositories live in a temporary directory, so the
# ~/.kube/config, the current context and the Helm settings of the machine stay as they were. Not run
# in the cloud yet (v2): the profile full is validated by render, kubeconform and gator only.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
# shellcheck source=scripts/lib/platform.sh
source "$REPO_ROOT/scripts/lib/platform.sh"
# shellcheck source=scripts/lib/finops.sh
source "$REPO_ROOT/scripts/lib/finops.sh"
# shellcheck source=scripts/lib/backup-credentials.sh
source "$REPO_ROOT/scripts/lib/backup-credentials.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

# The Gateway API CRDs that Istio uses for waypoints and the mesh lab's HTTPRoute retries; EKS has none.
GATEWAY_API_RELEASES=https://github.com/kubernetes-sigs/gateway-api/releases/download
OWNER_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$'
WORK_DIR=""
PROFILE=core
ENABLE_FINOPS=false
TARGET=primary
ACTIVATE_DNS=false
OWNER=""
REGION=""
VELERO_BUCKET=""
DNS_ENABLED=false
DNS_DOMAIN_NAME=""
DNS_ZONE_ID=""
DNS_CERTIFICATE_ARN=""
ALB_SOURCE_CIDR=""

usage() {
  echo "usage: $0 [--profile core|full] [--github-owner OWNER] [--target primary|secondary] [--finops] [--activate-dns]" >&2
  exit 2
}

cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

apply_manifests() {
  local attempt
  # The ESO admission webhook can need a few seconds after `helm --wait` to serve its certificate.
  for attempt in 1 2 3 4 5; do
    if "$HERE/render-manifests.sh" "$REGION" | kubectl apply -f -; then
      return 0
    fi
    log "kubectl apply failed (attempt $attempt/5); retrying in 15 s"
    sleep 15
  done
  die "could not apply platform/manifests"
}

# apply_full FILE -> applies one file of platform/manifests/full, once the CRDs it uses exist (the
# webhooks of Istio and Argo CD can need a few seconds after their charts return).
apply_full() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$HERE/render-manifests.sh" "$REGION" --full "$OWNER" --alb-source-cidr "$ALB_SOURCE_CIDR" --target "$TARGET" --only "$1" | kubectl apply -f - >/dev/null; then
      return 0
    fi
    log "kubectl apply of platform/manifests/$1 failed (attempt $attempt/5); retrying in 15 s"
    sleep 15
  done
  die "could not apply platform/manifests/$1"
}

# install_chart CHART [HELM_ARG...] -> helm upgrade --install of one row of platform/full/charts.txt,
# from the archive checked against its pinned SHA256, with the values files of the row in order (the
# install-time placeholders are replaced in copies in the temporary directory).
install_chart() {
  local chart=$1 repo_key version_key sha_key name release ns values tgz f out content n=0
  local -a files=() args=()
  shift
  read -r repo_key version_key sha_key name release ns values <<<"$(chart_entry "$chart")"
  IFS=, read -ra files <<<"$values"
  mkdir -p "$WORK_DIR/values/$chart"
  for f in "${files[@]}"; do
    [[ -f "$HERE/$f" ]] || die "platform/full/charts.txt: platform/$f does not exist"
    n=$((n + 1))
    out="$WORK_DIR/values/$chart/$n-$(basename "$f")"
    content="$(<"$HERE/$f")"
    content="${content//__VELERO_BUCKET__/$VELERO_BUCKET}"
    content="${content//__AWS_REGION__/$REGION}"
    printf '%s\n' "$content" >"$out"
    args+=(--values "$out")
  done
  tgz="$(pull_chart "$WORK_DIR/charts" "${!repo_key}" "$name" "${!version_key}" "${!sha_key}")"
  log "installing $release ($name ${!version_key}, SHA256 verified) in $ns"
  helm upgrade --install "$release" "$tgz" --namespace "$ns" "${args[@]}" "$@" \
    --wait=watcher --rollback-on-failure --timeout 10m >/dev/null
}

install_istio() {
  local asset="$WORK_DIR/gateway-api-$GATEWAY_CRDS_VERSION-experimental.yaml" got
  download "$GATEWAY_API_RELEASES/$GATEWAY_CRDS_VERSION/experimental-install.yaml" "$asset"
  got="$(sha256_of "$asset")"
  [[ "$got" == "$GATEWAY_CRDS_EXPERIMENTAL_SHA256" ]] || die "refusing Gateway API $GATEWAY_CRDS_VERSION experimental channel: SHA256 $got differs from platform/local/versions.env"
  kubectl apply --server-side --force-conflicts -f "$asset" >/dev/null
  kubectl wait --for=condition=Established --timeout=120s \
    crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io >/dev/null
  install_chart base
  install_chart istiod
  install_chart cni
  install_chart ztunnel
  # istiod creates the GatewayClass once it runs.
  retry 60 2 kubectl get gatewayclass istio >/dev/null 2>&1 || die "istiod did not create the GatewayClass istio"
  retry 60 2 kubectl get gatewayclass istio-waypoint >/dev/null 2>&1 || die "istiod did not create the GatewayClass istio-waypoint"
}

install_waypoint() {
  apply_full full/waypoint.yaml
  kubectl wait --namespace dx01v2 --for=condition=Programmed gateway/dx01v2-waypoint --timeout=300s >/dev/null ||
    die "Istio did not program the dx01v2 ambient waypoint"
  kubectl label namespace dx01v2 istio.io/use-waypoint=dx01v2-waypoint --overwrite >/dev/null
}

install_external_dns() {
  local tgz replicas=1
  [[ "$TARGET" != secondary || "$ACTIVATE_DNS" == true ]] || replicas=0
  [[ "$DNS_ENABLED" == true ]] || {
    log "public DNS is disabled; ExternalDNS is not installed"
    return 0
  }
  tgz="$(pull_chart "$WORK_DIR/charts" "$EXTERNAL_DNS_REPO" external-dns \
    "$EXTERNAL_DNS_CHART_VERSION" "$EXTERNAL_DNS_CHART_SHA256")"
  log "installing ExternalDNS $EXTERNAL_DNS_CHART_VERSION (SHA256 verified) for the app record in its one public zone"
  helm upgrade --install external-dns "$tgz" \
    --namespace kube-system \
    --values "$HERE/values/external-dns.yaml" \
    --set "replicaCount=$replicas" \
    --set-string "domainFilters[0]=$DNS_DOMAIN_NAME" \
    --set-string "extraArgs.aws-zone-id-filter=$DNS_ZONE_ID" \
    --set-string "image.tag=${EXTERNAL_DNS_IMAGE_TAG}@${EXTERNAL_DNS_IMAGE_DIGEST}" \
    --wait=watcher --rollback-on-failure --timeout 10m >/dev/null
}

# Prometheus, Alertmanager, Grafana (admin password generated here, kept in the Secret grafana-admin:
#   kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d),
# kube-state-metrics and node-exporter; then Loki, Alloy, Tempo and the traces of the Collector.
install_observability() {
  local hook="${SLACK_WEBHOOK_URL:-}"
  local -a slack=()
  if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    openssl rand -hex 16 | tr -d '\n' | kubectl -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin >/dev/null
  fi
  if [[ -n "$hook" ]]; then
    [[ "$hook" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9/_-]+$ ]] ||
      die "SLACK_WEBHOOK_URL must be an https URL of a Slack incoming webhook"
    printf '%s' "$hook" | kubectl -n monitoring create secret generic alertmanager-slack \
      --from-file=webhook-url=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    slack=(--values "$HERE/values/full/kube-prometheus-stack-slack.yaml")
    log "Alertmanager: warning and critical alerts also go to the Slack webhook of SLACK_WEBHOOK_URL"
  fi
  # The operator validates PrometheusRules with an admission webhook (failurePolicy Fail) that is part
  # of the same release: on the first install the rules would reach the API before the operator serves
  # the webhook. First pass without rules, then the full release once the webhook answers.
  if ! helm -n monitoring status kube-prometheus-stack >/dev/null 2>&1; then
    install_chart kube-prometheus-stack "${slack[@]}" --set defaultRules.create=false
  fi
  kubectl -n monitoring rollout status deployment/kube-prometheus-stack-operator --timeout=300s >/dev/null
  install_chart kube-prometheus-stack "${slack[@]}"
  # The operator creates these StatefulSets after Helm returns.
  retry 30 5 kubectl -n monitoring get statefulset prometheus-kube-prometheus-stack-prometheus alertmanager-kube-prometheus-stack-alertmanager >/dev/null 2>&1 ||
    die "the Prometheus Operator did not create Prometheus and Alertmanager"
  kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=300s >/dev/null
  kubectl -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=300s >/dev/null
  install_chart loki
  install_chart alloy
  install_chart tempo
  # The Collector of the core profile, upgraded with Tempo and the spanmetrics next to X-Ray (its
  # ServiceMonitor needs the CRDs installed above), and the mesh-wide tracing that reports to it.
  install_chart opentelemetry-collector --set-string config.exporters.awsxray.region="$REGION"
  apply_full full/tracing.yaml
}

# Argo CD, then the app of apps: the Application platform of your tx01v2 fork, and the RBAC with
# which the deploy role of dx01v2 asks Argo CD for a refresh.
install_gitops() {
  install_chart argo-cd
  kubectl wait --for=condition=Established --timeout=120s \
    crd/applications.argoproj.io crd/appprojects.argoproj.io >/dev/null
  apply_full full/argocd-platform.yaml
  apply_full full/rbac-argocd-deployer.yaml
}

# Gatekeeper and the policies of the lab: the templates and five of the constraints are those of the
# local lab; the allowed repositories are the ECR registry of the account.
install_policies() {
  local registry=$1 kind f repos="$WORK_DIR/allowed-repos.yaml"
  install_chart gatekeeper
  retry 10 6 kubectl apply -f "$HERE/local/policies/templates/" >/dev/null ||
    die "could not apply the Gatekeeper ConstraintTemplates"
  # Each template creates the CRD of its constraint kind.
  while read -r kind; do
    retry 30 2 kubectl get crd "${kind,,}.constraints.gatekeeper.sh" >/dev/null 2>&1 ||
      die "Gatekeeper did not create the CRD of $kind"
    kubectl wait --for=condition=Established "crd/${kind,,}.constraints.gatekeeper.sh" --timeout=60s >/dev/null
  done < <(sed -n 's/^        kind: \(Lab[A-Za-z]*\)$/\1/p' "$HERE"/local/policies/templates/*.yaml)
  for f in "$HERE"/local/policies/constraints/*.yaml; do
    [[ "$(basename "$f")" != allowed-repos.yaml ]] || continue
    retry 10 6 kubectl apply -f "$f" >/dev/null || die "could not apply the Gatekeeper constraint $(basename "$f")"
  done
  # The example registry of the constraint becomes the ECR registry of the account.
  sed "s|123456789012.dkr.ecr.us-east-1.amazonaws.com/dx01v2/|$registry|" "$HERE/full/policies/constraints/allowed-repos.yaml" >"$repos"
  retry 10 6 kubectl apply -f "$repos" >/dev/null || die "could not apply the Gatekeeper constraint allowed-repos"
}

install_backup() {
  ensure_velero_repository_credentials
  install_chart velero
  apply_full full/backup-schedule.yaml
  if [[ "$TARGET" == secondary ]]; then
    local recovery_bucket
    recovery_bucket="tx01v2-lab-recovery-$(aws sts get-caller-identity --query Account --output text)-$REGION"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: primary-recovery
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: $recovery_bucket
  accessMode: ReadOnly
  config:
    region: $REGION
EOF
  fi
  # shellcheck disable=SC2016 # expanded by the inner bash
  retry 30 5 bash -c '[[ "$(kubectl -n velero get backupstoragelocation default -o jsonpath="{.status.phase}")" == Available ]]' ||
    die "Velero: the backup storage location (S3 bucket of the lab) is not Available (is the Pod Identity association of terraform/modules/velero applied?)"
}

install_image_admission() {
  install_chart kyverno
  kubectl wait --for=condition=Established --timeout=180s \
    crd/imagevalidatingpolicies.policies.kyverno.io >/dev/null
  kubectl -n kyverno rollout status deployment/kyverno-admission-controller --timeout=300s >/dev/null ||
    die "Kyverno's admission controller is not ready; image verification stays fail-closed"
  apply_full full/image-verification.yaml
}

install_full() {
  local account
  require_cmd openssl curl
  load_pins "$HERE/local/versions.env"
  account="$(aws sts get-caller-identity --query Account --output text)"
  # The bucket of terraform/modules/velero: <name>-velero-<account id>-<region>.
  VELERO_BUCKET="$LAB_CLUSTER-velero-$account-$REGION"

  apply_full full/namespaces.yaml
  apply_full full/storageclass.yaml
  apply_full full/rbac-dx01v2-deployer-extra.yaml
  install_istio
  install_waypoint
  apply_full full/app-security.yaml
  install_chart cert-manager
  kubectl label namespace observability istio.io/dataplane-mode=ambient --overwrite >/dev/null
  install_observability
  apply_full full/app-monitoring.yaml
  apply_full full/continuity-monitoring.yaml
  install_policies "$account.dkr.ecr.$REGION.amazonaws.com/dx01v2/"
  install_image_admission
  # Argo CD may create application Pods as soon as its root Application is applied. Install both
  # admission layers first so no app workload can start before the policies are enforced.
  install_gitops
  install_chart trivy-operator
  install_backup
  install_chart chaos-mesh
  log "profile full ready: $(helm list --all-namespaces --short | sort | tr '\n' ' ')"
}

main() {
  while (($# > 0)); do
    case "$1" in
      --profile)
        [[ "${2:-}" == core || "${2:-}" == full ]] || usage
        PROFILE=$2
        shift 2
        ;;
      --github-owner)
        [[ "${2:-}" =~ $OWNER_RE ]] || usage
        OWNER=$2
        shift 2
        ;;
      --finops) ENABLE_FINOPS=true; shift ;;
      --target) [[ "${2:-}" == primary || "${2:-}" == secondary ]] || usage; TARGET=$2; shift 2 ;;
      --activate-dns) ACTIVATE_DNS=true; shift ;;
      *) usage ;;
    esac
  done
  [[ "$PROFILE" == core || -n "$OWNER" ]] || die "the profile full needs --github-owner, the GitHub user or organization of your forks"
  [[ "$ENABLE_FINOPS" == false || "$PROFILE" == full ]] || die '--finops requires profile full'
  require_cmd aws kubectl helm
  require_aws_region
  select_lab_target "$TARGET"
  load_pins "$HERE/versions.env"

  local cluster vpc_id store tgz
  cluster="$(lab_param cluster-name)"
  REGION="$(lab_param region)"
  vpc_id="$(lab_param vpc-id)"
  store="$(lab_param eso/cluster-secret-store)"
  DNS_ENABLED="$(lab_param dns/enabled)"
  DNS_DOMAIN_NAME="$(lab_param dns/domain-name)"
  DNS_ZONE_ID="$(lab_param dns/zone-id)"
  DNS_CERTIFICATE_ARN="$(lab_param dns/acm-certificate-arn)"
  ALB_SOURCE_CIDR="$(lab_param alb/source-cidr)"
  [[ "$REGION" == "$AWS_REGION" ]] || die "AWS_REGION=$AWS_REGION but the lab runs in $REGION"
  [[ "$cluster" == "$LAB_CLUSTER" ]] || die "contract key cluster-name is '$cluster', not $LAB_CLUSTER"
  case "$DNS_ENABLED" in
    false)
      [[ "$DNS_DOMAIN_NAME" == disabled && "$DNS_ZONE_ID" == disabled && "$DNS_CERTIFICATE_ARN" == disabled ]] ||
        die "DNS contract is inconsistent: disabled must use the disabled sentinel for domain, zone and ACM certificate"
      ;;
    true)
      [[ "$DNS_DOMAIN_NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] ||
        die "DNS contract has an invalid app domain name"
      [[ "$DNS_ZONE_ID" =~ ^Z[A-Z0-9]+$ ]] || die "DNS contract has an invalid Route53 public hosted zone ID"
      [[ "$DNS_CERTIFICATE_ARN" =~ ^arn:aws[a-z-]*:acm:${REGION}:[0-9]{12}:certificate/[0-9a-f-]+$ ]] ||
        die "DNS contract has no DNS-validated ACM certificate in $REGION"
      ;;
    *) die "DNS contract dns/enabled must be true or false" ;;
  esac
  require_lab_cluster "$cluster"

  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  mkdir -p "$WORK_DIR/helm/cache"
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  export HELM_REPOSITORY_CONFIG="$WORK_DIR/helm/repositories.yaml" HELM_REPOSITORY_CACHE="$WORK_DIR/helm/cache"

  log "cluster $cluster in $REGION (VPC $vpc_id), profile $PROFILE"
  aws eks update-kubeconfig --region "$REGION" --name "$cluster" --kubeconfig "$KUBECONFIG" >/dev/null
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
    --set-string region="$REGION" \
    --set-string vpcId="$vpc_id" \
    --wait=watcher --rollback-on-failure --timeout 10m

  install_external_dns
  install_cluster_autoscaler "$cluster" "$REGION"

  log "installing external-secrets chart $ESO_CHART_VERSION"
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace \
    --version "$ESO_CHART_VERSION" \
    --values "$HERE/values/external-secrets.yaml" \
    --wait=watcher --rollback-on-failure --timeout 10m

  log "applying platform/manifests"
  apply_manifests

  # The Collector, from the chart archive checked against platform/versions.env.
  tgz="$(pull_chart "$WORK_DIR/charts" https://open-telemetry.github.io/opentelemetry-helm-charts \
    opentelemetry-collector "$OTEL_COLLECTOR_CHART_VERSION" "$OTEL_COLLECTOR_CHART_SHA256")"
  log "installing the opentelemetry-collector chart $OTEL_COLLECTOR_CHART_VERSION (SHA256 verified; traces to X-Ray in $REGION)"
  helm upgrade --install opentelemetry-collector "$tgz" \
    --namespace observability \
    --values "$HERE/values/otel-collector.yaml" \
    --set-string config.exporters.awsxray.region="$REGION" \
    --wait=watcher --rollback-on-failure --timeout 10m

  # Ready means ESO reached Secrets Manager with its Pod Identity credentials.
  kubectl wait --for=condition=Ready "clustersecretstore/$store" --timeout=180s
  kubectl get ingressclass alb >/dev/null
  log "core platform ready: IngressClass alb, ClusterSecretStore $store, namespace dx01v2, OTLP endpoint opentelemetry-collector.observability.svc:4318"

  if [[ "$PROFILE" == full ]]; then
    install_full
    if [[ "$ENABLE_FINOPS" == true ]]; then
      install_finops_stack aws "$cluster" "$REGION" dx01v2
    fi
  fi
}

main "$@"
