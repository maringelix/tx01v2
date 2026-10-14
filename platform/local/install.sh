#!/usr/bin/env bash
# Installs the platform of the local lab on the kind cluster of terraform/envs/local (called by
# scripts/local-lab.sh up; re-running it upgrades in place). Components, in order:
#   1. cluster preparation: namespaces, registry hosting ConfigMap, load balancer label of the node
#   2. Gateway API CRDs (standard channel, pinned asset)
#   3. Istio ambient (base, istiod, istio-cni, ztunnel; GatewayClass istio)
#   4. cert-manager + ClusterIssuer lab-ca (lab CA of terraform/envs/local)
#   5. External Secrets Operator + ClusterSecretStore local-secrets (Secrets of lab-secrets)
#   6. contract of the local lab: ConfigMaps lab-contract and lab-ca (namespace lab-system)
#   7. metrics-server
#   8. observability: kube-prometheus-stack (Prometheus with exemplars, Alertmanager -> alert-sink and
#      Slack, Grafana), Loki, Alloy, Tempo, OpenTelemetry Collector, Istio tracing (Telemetry)
#   9. operations: Argo CD, Gatekeeper + policies, Trivy Operator, Velero (S3 emulator), Chaos Mesh
# LOCAL_PROFILE selects the layers (default full): core = 1-7, observability = 1-8,
# operations = 1-7 + 9, full = 1-9. The CI runs full; a laptop with little free memory can validate
# one layer per round (scripts/local-lab.sh e2e destroys the lab at the end).
# LOCAL_SLACK_WEBHOOK_URL (optional, an https Slack incoming webhook): Alertmanager also posts warning
# and critical alerts there; without it the Slack receiver posts to the in-cluster sink.
# LOCAL ONLY: it never talks to AWS. Needs kubectl, helm, terraform and curl (scripts/install-tools.sh),
# the KUBECONFIG and TF_DATA_DIR exported by scripts/local-lab.sh. Secret values come from the local
# Terraform state and go to kubectl through stdin, never through arguments or logs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../../scripts/lib/common.sh"
# shellcheck source=scripts/lib/local.sh
source "$REPO_ROOT/scripts/lib/local.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

WORK_DIR=""
LOCAL_PROFILE="${LOCAL_PROFILE:-full}"
case "$LOCAL_PROFILE" in
  core | observability | operations | full) ;;
  *) die "LOCAL_PROFILE must be core, observability, operations or full (got '$LOCAL_PROFILE')" ;;
esac

prepare_cluster() {
  local registry
  registry="$(tf_out registry_push)"
  # A single-node cluster runs the workloads on the control plane: let the load balancers reach it.
  kubectl label nodes --all node.kubernetes.io/exclude-from-external-load-balancers- >/dev/null 2>&1 || true
  kubectl apply -f "$HERE/manifests/namespaces.yaml" >/dev/null
  # KEP-1755: tells tools where the local registry is.
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "$registry"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

install_gateway_api() {
  local asset="$WORK_DIR/gateway-api-$GATEWAY_CRDS_VERSION.yaml" got
  download "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_CRDS_VERSION/standard-install.yaml" "$asset"
  got="$(sha256_of "$asset")"
  [[ "$got" == "$GATEWAY_CRDS_SHA256" ]] || die "refusing Gateway API $GATEWAY_CRDS_VERSION: SHA256 $got differs from platform/local/versions.env"
  log "Gateway API CRDs $GATEWAY_CRDS_VERSION (standard channel)"
  kubectl apply --server-side --force-conflicts -f "$asset" >/dev/null
  kubectl wait --for=condition=Established --timeout=120s \
    crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io >/dev/null
}

install_istio() {
  local charts="$WORK_DIR/charts"
  helm_install istio-base istio-system "$(pull_chart "$charts" "$ISTIO_REPO" base "$ISTIO_VERSION" "$ISTIO_BASE_SHA256")" \
    --values "$HERE/values/istio-base.yaml"
  helm_install istiod istio-system "$(pull_chart "$charts" "$ISTIO_REPO" istiod "$ISTIO_VERSION" "$ISTIOD_SHA256")" \
    --values "$HERE/values/istiod.yaml"
  helm_install istio-cni istio-system "$(pull_chart "$charts" "$ISTIO_REPO" cni "$ISTIO_VERSION" "$ISTIO_CNI_SHA256")" \
    --values "$HERE/values/istio-cni.yaml"
  helm_install ztunnel istio-system "$(pull_chart "$charts" "$ISTIO_REPO" ztunnel "$ISTIO_VERSION" "$ZTUNNEL_SHA256")" \
    --values "$HERE/values/ztunnel.yaml"
  # istiod creates the GatewayClass once it runs.
  retry 60 2 kubectl get gatewayclass istio >/dev/null 2>&1 || die "istiod did not create the GatewayClass istio"
  kubectl wait --for=condition=Accepted gatewayclass/istio --timeout=120s >/dev/null
  retry 10 6 kubectl apply -f "$HERE/manifests/gateway-request-id.yaml" >/dev/null ||
    die "could not apply the EnvoyFilter gateway-preserve-request-id (istiod webhook not ready?)"
}

install_cert_manager() {
  local charts="$WORK_DIR/charts" tls="$WORK_DIR/lab-ca"
  helm_install cert-manager cert-manager "$(pull_chart "$charts" "$CERT_MANAGER_REPO" cert-manager "$CERT_MANAGER_VERSION" "$CERT_MANAGER_SHA256")" \
    --values "$HERE/values/cert-manager.yaml"
  mkdir -m 700 "$tls"
  tf_out ca_cert_pem >"$tls/tls.crt"
  tf_out ca_private_key_pem >"$tls/tls.key"
  kubectl -n cert-manager create secret tls lab-ca --cert="$tls/tls.crt" --key="$tls/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$tls"
  retry 10 6 kubectl apply -f "$HERE/manifests/cluster-issuer.yaml" >/dev/null ||
    die "could not apply the ClusterIssuer lab-ca (cert-manager webhook not ready?)"
  kubectl wait --for=condition=Ready clusterissuer/lab-ca --timeout=120s >/dev/null
}

# The local twin of the Secrets Manager secrets of contract v1: same keys, Kubernetes-safe names.
write_lab_secrets() {
  local db_ip db_port db_name db_user db_password admin_token
  db_ip="$(tf_out db_ip)"
  db_port="$(tf_out db_port)"
  db_name="$(tf_out db_name)"
  db_user="$(tf_out db_username)"
  db_password="$(tf_out db_password)"
  admin_token="$(tf_out admin_token)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: tx01v2-lab-db-app
  namespace: lab-secrets
type: Opaque
stringData:
  host: "$db_ip"
  port: "$db_port"
  dbname: "$db_name"
  username: "$db_user"
  password: "$db_password"
---
apiVersion: v1
kind: Secret
metadata:
  name: tx01v2-lab-app-admin-token
  namespace: lab-secrets
type: Opaque
stringData:
  token: "$admin_token"
EOF
}

install_external_secrets() {
  local charts="$WORK_DIR/charts"
  helm_install external-secrets external-secrets "$(pull_chart "$charts" "$ESO_REPO" external-secrets "$ESO_CHART_VERSION" "$ESO_SHA256")" \
    --values "$REPO_ROOT/platform/values/external-secrets.yaml" --values "$HERE/values/external-secrets.yaml"
  write_lab_secrets
  retry 10 6 kubectl apply -f "$HERE/manifests/secret-store.yaml" >/dev/null ||
    die "could not apply the ClusterSecretStore local-secrets (ESO webhook not ready?)"
  kubectl wait --for=condition=Ready clustersecretstore/local-secrets --timeout=180s >/dev/null
}

# Contract of the local lab (docs/CONTRATO.md, "Lab local"): what the dx01v2 local deploy reads, like
# the SSM parameters /tx01v2/lab/* in the cloud.
publish_contract() {
  local ca="$WORK_DIR/ca.crt"
  tf_out ca_cert_pem >"$ca"
  kubectl -n lab-system create configmap lab-ca --from-file=ca.crt="$ca" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-contract
  namespace: lab-system
data:
  version: "2"
  cluster-name: "$(tf_out cluster_name)"
  network-cidr: "$(tf_out subnet_cidr)"
  registry: "$(tf_out registry)"
  registry-push: "$(tf_out registry_push)"
  db.endpoint-ip: "$(tf_out db_ip)"
  db.hostname: "$(tf_out db_hostname)"
  db.port: "$(tf_out db_port)"
  db.secret-name: tx01v2-lab-db-app
  db.ca-configmap: lab-system/lab-ca
  app.admin-token-secret-name: tx01v2-lab-app-admin-token
  eso.cluster-secret-store: local-secrets
  gateway.class: istio
  tls.cluster-issuer: lab-ca
  gitops.push-url: "$(tf_out git_ssh_url)/dx01v2-gitops"
  gitops.read-url: "$(tf_out git_http_url)/dx01v2-gitops.git"
  gitops.push-key-secret: lab-secrets/gitops-push-key
  argocd.project: dx01v2
  monitoring.prometheus-service-account: monitoring/kube-prometheus-stack-prometheus
  tracing.otlp-endpoint: http://opentelemetry-collector.monitoring.svc:4318
EOF
}

install_metrics_server() {
  local charts="$WORK_DIR/charts"
  helm_install metrics-server kube-system "$(pull_chart "$charts" "$METRICS_SERVER_REPO" metrics-server "$METRICS_SERVER_VERSION" "$METRICS_SERVER_SHA256")" \
    --values "$HERE/values/metrics-server.yaml"
}

# The webhook of the Slack receiver of Alertmanager (Secret alertmanager-slack, key webhook-url):
# LOCAL_SLACK_WEBHOOK_URL when set, else the Slack path of the in-cluster sink (the probes read it).
write_slack_webhook() {
  local url="${LOCAL_SLACK_WEBHOOK_URL:-}"
  if [[ -n "$url" ]]; then
    [[ "$url" =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9/_-]+$ ]] ||
      die "LOCAL_SLACK_WEBHOOK_URL must be an https URL of a Slack incoming webhook"
    log "Alertmanager: warning and critical alerts also go to the Slack webhook of LOCAL_SLACK_WEBHOOK_URL"
  else
    url=http://alert-sink.monitoring.svc:8080/slack
  fi
  printf '%s' "$url" | kubectl -n monitoring create secret generic alertmanager-slack \
    --from-file=webhook-url=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Prometheus, Alertmanager (-> alert-sink and Slack), Grafana (admin password from the local state,
# Secret grafana-admin), kube-state-metrics and node-exporter.
install_monitoring() {
  local charts="$WORK_DIR/charts" password tgz
  password="$(tf_out grafana_admin_password)"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$password"
EOF
  write_slack_webhook
  kubectl apply -f "$HERE/manifests/alert-sink.yaml" >/dev/null
  tgz="$(pull_chart "$charts" "$KPS_REPO" kube-prometheus-stack "$KPS_VERSION" "$KPS_SHA256")"
  # The operator validates PrometheusRules with an admission webhook (failurePolicy Fail) that is part
  # of the same release: on the first install the rules would reach the API before the operator serves
  # the webhook. First pass without rules, then the full release once the webhook answers.
  if ! helm -n monitoring status kube-prometheus-stack >/dev/null 2>&1; then
    helm_install kube-prometheus-stack monitoring "$tgz" --values "$HERE/values/kube-prometheus-stack.yaml" \
      --set defaultRules.create=false
  fi
  kubectl -n monitoring rollout status deployment/kube-prometheus-stack-operator --timeout=300s >/dev/null
  helm_install kube-prometheus-stack monitoring "$tgz" --values "$HERE/values/kube-prometheus-stack.yaml"
  # The operator creates these StatefulSets after Helm returns.
  retry 30 5 kubectl -n monitoring get statefulset prometheus-kube-prometheus-stack-prometheus alertmanager-kube-prometheus-stack-alertmanager >/dev/null 2>&1 ||
    die "the Prometheus Operator did not create Prometheus and Alertmanager"
  kubectl -n monitoring rollout status statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=300s >/dev/null
  kubectl -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=300s >/dev/null
  kubectl -n monitoring rollout status deployment/alert-sink --timeout=180s >/dev/null
}

# Loki (single binary) and Alloy (pod logs through the Kubernetes API).
install_logging() {
  local charts="$WORK_DIR/charts"
  helm_install loki monitoring "$(pull_chart "$charts" "$GRAFANA_REPO" loki "$LOKI_VERSION" "$LOKI_SHA256")" \
    --values "$HERE/values/loki.yaml"
  helm_install alloy monitoring "$(pull_chart "$charts" "$GRAFANA_REPO" alloy "$ALLOY_VERSION" "$ALLOY_SHA256")" \
    --values "$HERE/values/alloy.yaml"
}

# Traces: Tempo (store), the OpenTelemetry Collector (OTLP in, Tempo and spanmetrics out; its
# ServiceMonitor needs the CRDs of kube-prometheus-stack) and the mesh-wide Telemetry that makes every
# Istio Gateway report its spans to the Collector.
install_tracing() {
  local charts="$WORK_DIR/charts"
  helm_install tempo monitoring "$(pull_chart "$charts" "$GRAFANA_COMMUNITY_REPO" tempo "$TEMPO_VERSION" "$TEMPO_SHA256")" \
    --values "$HERE/values/tempo.yaml"
  helm_install opentelemetry-collector monitoring "$(pull_chart "$charts" "$OTEL_COLLECTOR_REPO" opentelemetry-collector "$OTEL_COLLECTOR_CHART_VERSION" "$OTEL_COLLECTOR_SHA256")" \
    --values "$HERE/values/otel-collector.yaml"
  retry 10 6 kubectl apply -f "$HERE/manifests/tracing.yaml" >/dev/null ||
    die "could not apply the Telemetry mesh-default (istiod webhook not ready?)"
}

install_gitops() {
  local charts="$WORK_DIR/charts" key="$WORK_DIR/gitops-push-key"
  helm_install argocd argocd "$(pull_chart "$charts" "$ARGOCD_REPO" argo-cd "$ARGOCD_VERSION" "$ARGOCD_SHA256")" \
    --values "$HERE/values/argo-cd.yaml"
  sed "s|__GITOPS_READ_URL__|$(tf_out git_http_url)/dx01v2-gitops.git|" "$HERE/manifests/argocd-project-dx01v2.yaml" |
    kubectl apply -f - >/dev/null
  # The key the dx01v2 local deploy pushes the GitOps repository with (the local twin of the deploy
  # role): readable only by cluster admins, like every Secret of lab-secrets.
  tf_out git_admin_private_key >"$key"
  kubectl -n lab-secrets create secret generic gitops-push-key --type=kubernetes.io/ssh-auth \
    --from-file=ssh-privatekey="$key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "$key"
}

install_policies() {
  local charts="$WORK_DIR/charts" kind
  helm_install gatekeeper gatekeeper-system "$(pull_chart "$charts" "$GATEKEEPER_REPO" gatekeeper "$GATEKEEPER_VERSION" "$GATEKEEPER_SHA256")" \
    --values "$HERE/values/gatekeeper.yaml"
  retry 10 6 kubectl apply -f "$HERE/policies/templates/" >/dev/null ||
    die "could not apply the Gatekeeper ConstraintTemplates"
  # Each template creates the CRD of its constraint kind.
  while read -r kind; do
    retry 30 2 kubectl get crd "${kind,,}.constraints.gatekeeper.sh" >/dev/null 2>&1 ||
      die "Gatekeeper did not create the CRD of $kind"
    kubectl wait --for=condition=Established "crd/${kind,,}.constraints.gatekeeper.sh" --timeout=60s >/dev/null
  done < <(sed -n 's/^        kind: \(Lab[A-Za-z]*\)$/\1/p' "$HERE"/policies/templates/*.yaml)
  retry 10 6 kubectl apply -f "$HERE/policies/constraints/" >/dev/null ||
    die "could not apply the Gatekeeper constraints"
}

install_trivy_operator() {
  local charts="$WORK_DIR/charts" values="$WORK_DIR/trivy-operator-values.yaml"
  sed "s|__REGISTRY_ENDPOINT__|$(tf_out registry_endpoint)|" "$HERE/values/trivy-operator.yaml" >"$values"
  helm_install trivy-operator trivy-system "$(pull_chart "$charts" "$TRIVY_OPERATOR_REPO" trivy-operator "$TRIVY_OPERATOR_VERSION" "$TRIVY_OPERATOR_SHA256")" \
    --values "$values"
}

# Velero writes to the S3 emulator; the credentials file goes to the Secret through stdin.
install_backup() {
  local charts="$WORK_DIR/charts" values="$WORK_DIR/velero-values.yaml"
  kubectl -n velero create secret generic velero-s3 --from-file=cloud=/dev/stdin --dry-run=client -o yaml \
    <<<"$(printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' "$(tf_out s3_access_key)" "$(tf_out s3_secret_key)")" |
    kubectl apply -f - >/dev/null
  sed -e "s|__S3_BUCKET__|$(tf_out s3_bucket_velero)|" -e "s|__S3_ENDPOINT__|$(tf_out s3_endpoint)|" \
    "$HERE/values/velero.yaml" >"$values"
  helm_install velero velero "$(pull_chart "$charts" "$VELERO_REPO" velero "$VELERO_VERSION" "$VELERO_SHA256")" \
    --values "$values"
  # shellcheck disable=SC2016 # expanded by the inner bash
  retry 30 5 bash -c '[[ "$(kubectl -n velero get backupstoragelocation default -o jsonpath="{.status.phase}")" == Available ]]' ||
    die "Velero: the backup storage location (S3 emulator) is not Available"
}

install_chaos() {
  local charts="$WORK_DIR/charts"
  helm_install chaos-mesh chaos-mesh "$(pull_chart "$charts" "$CHAOS_MESH_REPO" chaos-mesh "$CHAOS_MESH_VERSION" "$CHAOS_MESH_SHA256")" \
    --values "$HERE/values/chaos-mesh.yaml"
}

# On a failed install, the same diagnostics as the probes (CI uploads LOCAL_DIAGNOSTICS_DIR as an
# artifact; get/describe only, never Secret values), plus the node conditions and allocations (memory
# pressure, evictions).
on_exit() {
  local rc=$?
  if ((rc != 0)) && [[ -n "${LOCAL_DIAGNOSTICS_DIR:-}" ]]; then
    mkdir -p "$LOCAL_DIAGNOSTICS_DIR"
    kubectl get pods --all-namespaces -o wide >"$LOCAL_DIAGNOSTICS_DIR/pods.txt" 2>&1 || true
    kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOCAL_DIAGNOSTICS_DIR/events.txt" 2>&1 || true
    kubectl describe pods --all-namespaces >"$LOCAL_DIAGNOSTICS_DIR/describe-pods.txt" 2>&1 || true
    kubectl describe nodes >"$LOCAL_DIAGNOSTICS_DIR/describe-nodes.txt" 2>&1 || true
    helm list --all-namespaces --all >"$LOCAL_DIAGNOSTICS_DIR/helm.txt" 2>&1 || true
    kubectl top pods --all-namespaces >"$LOCAL_DIAGNOSTICS_DIR/top.txt" 2>&1 || true
    log "install failed: diagnostics in $LOCAL_DIAGNOSTICS_DIR"
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  return "$rc"
}

main() {
  require_cmd kubectl helm terraform curl
  kubectl version >/dev/null 2>&1 || die "the lab cluster is not reachable (run: scripts/local-lab.sh up)"
  local_load_versions
  WORK_DIR="$(mktemp -d)"
  chmod 700 "$WORK_DIR"
  trap on_exit EXIT
  prepare_cluster
  install_gateway_api
  install_istio
  install_cert_manager
  install_external_secrets
  publish_contract
  install_metrics_server
  if [[ "$LOCAL_PROFILE" == observability || "$LOCAL_PROFILE" == full ]]; then
    install_monitoring
    install_logging
    install_tracing
  fi
  if [[ "$LOCAL_PROFILE" == operations || "$LOCAL_PROFILE" == full ]]; then
    install_gitops
    install_policies
    install_trivy_operator
    install_backup
    install_chaos
  fi
  log "local platform ready (profile $LOCAL_PROFILE): $(helm list --all-namespaces --short | sort | tr '\n' ' ')"
}

main "$@"
