#!/usr/bin/env bash
# Removes the platform layer before `terraform destroy`, so no load balancer created by the AWS Load
# Balancer Controller is left behind (they would block the VPC deletion and keep billing):
#   1. delete the Argo CD Applications of the profile full, if any (their self-heal would create the
#      Ingress again)
#   2. delete every Ingress (and Service of type LoadBalancer) in the cluster
#   3. wait until no load balancer, target group or security group tagged
#      elbv2.k8s.aws/cluster=<cluster> exists (the controller deletes them)
#   4. uninstall the OpenTelemetry Collector, the External Secrets Operator and the AWS Load
#      Balancer Controller releases
# The add-ons of the profile full create EBS-backed observability PVCs and an S3 bucket that Terraform
# owns. Remove the PVCs and wait for the EBS CSI controller to delete their volumes before destroying
# the cluster; otherwise the AWS volumes can outlive the lab.
# CLOUD-MUTATING. Fails loudly on any error or timeout. Needs the same tools as platform/install.sh.
# It acts only on the cluster of the contract (tx01v2-lab) and only when that cluster carries the tag
# Project=tx01v2; no environment variable changes the target. The kubeconfig is temporary: the
# ~/.kube/config and the current context of the machine stay as they were.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

LB_WAIT_SECONDS="${LB_WAIT_SECONDS:-900}"
WORK_DIR=""

cleanup() {
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
}

# The Applications of the profile full are not deleted in cascade (no finalizer): the Ingress is deleted
# explicitly next. The parent goes first, or it would create the child again.
stop_gitops() {
  kubectl get crd applications.argoproj.io >/dev/null 2>&1 || return 0
  log "deleting the Argo CD Applications (self-heal would create the Ingress again)"
  kubectl --namespace argocd delete applications.argoproj.io platform --ignore-not-found --wait=true --timeout=5m
  kubectl delete applications.argoproj.io --all --all-namespaces --wait=true --timeout=5m
}

delete_load_balancer_services() {
  local out svc
  out="$(kubectl get services --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}')"
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue
    log "deleting Service $svc (type LoadBalancer)"
    kubectl delete service --namespace "${svc%%/*}" "${svc#*/}" --wait=true --timeout=5m
  done <<<"$out"
}

# The controller deletes its ALBs, target groups and security groups asynchronously; it must keep
# running until they are gone, or they stay behind and block the VPC deletion.
wait_for_controller_resources() {
  local cluster=$1 deadline=$((SECONDS + LB_WAIT_SECONDS)) remaining
  while :; do
    remaining="$(controller_leftovers "$cluster")"
    if [[ -z "$remaining" ]]; then
      log "no load balancer, target group or security group tagged elbv2.k8s.aws/cluster=$cluster remains"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      die "resources of the load balancer controller still present after ${LB_WAIT_SECONDS}s:"$'\n'"$remaining"
    fi
    log "waiting for $(wc -l <<<"$remaining") controller resource(s) to be deleted"
    sleep 15
  done
}

# Keep ExternalDNS running until it has removed only its app alias and TXT ownership record. With the
# chart's sync policy and the ingress deleted above, these Route53 records are no longer desired.
wait_for_dns_records() {
  local enabled domain zone records remaining deadline=$((SECONDS + 360))
  enabled="$(lab_param dns/enabled)"
  [[ "$enabled" == false ]] && return 0
  [[ "$enabled" == true ]] || die "DNS contract dns/enabled must be true or false"
  domain="$(lab_param dns/domain-name)"
  zone="$(lab_param dns/zone-id)"
  [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] ||
    die "DNS contract has an invalid app domain name; refusing to query Route53"
  [[ "$zone" =~ ^Z[A-Z0-9]+$ ]] || die "DNS contract has an invalid Route53 public hosted zone ID"
  while :; do
    records="$(aws route53 list-resource-record-sets --hosted-zone-id "$zone" --output json)" ||
      die "could not inspect the app DNS records in the configured Route53 zone"
    remaining="$(jq -r --arg app "${domain}." --arg ownership "a-_external-dns-${domain}." \
      '[.ResourceRecordSets[]? | select((.Name == $app and .Type == "A") or (.Name == $ownership and .Type == "TXT"))] | length' <<<"$records")"
    [[ "$remaining" == 0 ]] && {
      log "ExternalDNS removed the app alias and TXT ownership record"
      return 0
    }
    ((SECONDS < deadline)) || die "ExternalDNS did not remove the app records within 360s; inspect the ExternalDNS events and Route53 records before destroying the lab"
    log "waiting for ExternalDNS to remove the app alias and TXT ownership record"
    sleep 10
  done
}

capture_observability_pvcs() {
  local entry namespace release statefulsets
  : >"$WORK_DIR/observability-pvcs.tsv"
  for entry in \
    'monitoring kube-prometheus-stack' \
    'monitoring loki' \
    'monitoring tempo'; do
    read -r namespace release <<<"$entry"
    kubectl get namespace "$namespace" --ignore-not-found --output name >"$WORK_DIR/observability-namespace"
    [[ -s "$WORK_DIR/observability-namespace" ]] || continue
    statefulsets="$(kubectl get statefulsets --namespace "$namespace" \
      --selector "app.kubernetes.io/instance=$release" --output json)"
    jq -r --arg namespace "$namespace" '
      .items[] as $sts |
      ($sts.spec.volumeClaimTemplates // [])[] as $claim |
      range(0; ($sts.spec.replicas // 1)) |
      [$namespace, ($claim.metadata.name + "-" + $sts.metadata.name + "-" + tostring)] | @tsv
    ' <<<"$statefulsets" >>"$WORK_DIR/observability-pvcs.tsv"
  done
}

uninstall_full_releases() {
  local entry release namespace
  for entry in \
    'chaos-mesh chaos-mesh' \
    'velero velero' \
    'trivy-operator trivy-system' \
    'gatekeeper gatekeeper-system' \
    'argo-cd argocd' \
    'tempo monitoring' \
    'alloy monitoring' \
    'loki monitoring' \
    'kube-prometheus-stack monitoring' \
    'cert-manager cert-manager' \
    'ztunnel istio-system' \
    'istio-cni istio-system' \
    'istiod istio-system' \
    'istio-base istio-system'; do
    read -r release namespace <<<"$entry"
    helm uninstall "$release" --namespace "$namespace" --ignore-not-found --wait=watcher --timeout 10m
  done
}

delete_observability_volumes() {
  local ns pvc remaining claim_refs deadline=$((SECONDS + 600))
  while IFS=$'\t' read -r ns pvc; do
    [[ -n "$ns" && -n "$pvc" ]] || continue
    kubectl delete pvc "$pvc" --namespace "$ns" --ignore-not-found --wait=true --timeout=10m
  done <"$WORK_DIR/observability-pvcs.tsv"
  claim_refs="$(jq -Rn '[inputs | split("\t") | {namespace: .[0], name: .[1]}]' \
    <"$WORK_DIR/observability-pvcs.tsv")"
  while :; do
    remaining="$(kubectl get pv -o json | jq -r --argjson claims "$claim_refs" '[
      .items[] as $pv |
      select($pv.spec.csi.driver == "ebs.csi.aws.com" and
        any($claims[]; .namespace == $pv.spec.claimRef.namespace and .name == $pv.spec.claimRef.name)) |
      $pv.metadata.name
    ] | join(" ")')"
    [[ -z "$remaining" ]] && break
    ((SECONDS < deadline)) || die "EBS observability volume(s) were not deleted before timeout: $remaining"
    log "waiting for EBS CSI to delete observability volume(s): $remaining"
    sleep 10
  done
  kubectl delete storageclass tx01v2-gp3 --ignore-not-found
}

main() {
  require_cmd aws kubectl helm jq
  require_aws_region

  local cluster=$LAB_CLUSTER
  require_lab_cluster "$cluster"
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  export KUBECONFIG="$WORK_DIR/kubeconfig"
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster" --kubeconfig "$KUBECONFIG" >/dev/null
  kubectl get --raw /readyz >/dev/null || die "the Kubernetes API of $cluster is not reachable"

  stop_gitops
  log "deleting every Ingress in $cluster"
  kubectl delete ingress --all --all-namespaces --wait=true --timeout=10m
  wait_for_dns_records
  delete_load_balancer_services
  wait_for_controller_resources "$cluster"

  log "uninstalling the platform releases"
  capture_observability_pvcs
  uninstall_full_releases
  delete_observability_volumes
  helm uninstall opentelemetry-collector --namespace observability --ignore-not-found --wait=watcher --timeout 10m
  helm uninstall external-dns --namespace kube-system --ignore-not-found --wait=watcher --timeout 10m
  helm uninstall external-secrets --namespace external-secrets --ignore-not-found --wait=watcher --timeout 10m
  helm uninstall aws-load-balancer-controller --namespace kube-system --ignore-not-found --wait=watcher --timeout 10m
  log "platform removed from $cluster"
}

main "$@"
