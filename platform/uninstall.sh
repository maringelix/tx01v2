#!/usr/bin/env bash
# Removes the platform layer before `terraform destroy`, so no load balancer created by the AWS Load
# Balancer Controller is left behind (they would block the VPC deletion and keep billing):
#   1. delete every Ingress (and Service of type LoadBalancer) in the cluster
#   2. wait until no load balancer, target group or security group tagged
#      elbv2.k8s.aws/cluster=<cluster> exists (the controller deletes them)
#   3. uninstall the OpenTelemetry Collector, the External Secrets Operator and the AWS Load
#      Balancer Controller releases
# CLOUD-MUTATING. Fails loudly on any error or timeout. Needs the same tools as platform/install.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../scripts/lib/common.sh"
# shellcheck source=scripts/lib/aws.sh
source "$REPO_ROOT/scripts/lib/aws.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

LB_WAIT_SECONDS="${LB_WAIT_SECONDS:-900}"

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

# controller_leftovers CLUSTER -> load balancers, target groups and security groups the controller
# created for CLUSTER that still exist (one per line).
controller_leftovers() {
  local cluster=$1 sgs
  elbv2_arns_with_tag lb elbv2.k8s.aws/cluster "$cluster"
  elbv2_arns_with_tag tg elbv2.k8s.aws/cluster "$cluster"
  sgs="$(aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" \
    --query 'SecurityGroups[].GroupId' --output text)"
  printf '%s\n' "$sgs" | words_to_lines
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

main() {
  require_cmd aws kubectl helm
  require_aws_region

  local cluster
  cluster="${CLUSTER_NAME:-$(lab_param cluster-name)}"
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster" --alias "$cluster"
  kubectl get --raw /readyz >/dev/null || die "the Kubernetes API of $cluster is not reachable"

  log "deleting every Ingress in $cluster"
  kubectl delete ingress --all --all-namespaces --wait=true --timeout=10m
  delete_load_balancer_services
  wait_for_controller_resources "$cluster"

  log "uninstalling the platform releases"
  helm uninstall opentelemetry-collector --namespace observability --ignore-not-found --wait=watcher --timeout 10m
  helm uninstall external-secrets --namespace external-secrets --ignore-not-found --wait=watcher --timeout 10m
  helm uninstall aws-load-balancer-controller --namespace kube-system --ignore-not-found --wait=watcher --timeout 10m
  log "platform removed from $cluster"
}

main "$@"
