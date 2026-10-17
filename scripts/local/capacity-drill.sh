#!/usr/bin/env bash
# Actual HPA, PDB, eviction, VPA and cost allocation on the owned three-node kind lab.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/local.sh
source "$REPO_ROOT/scripts/lib/local.sh"
# shellcheck source=scripts/lib/finops.sh
source "$REPO_ROOT/scripts/lib/finops.sh"
require_cmd kubectl docker jq
require_lab_context
finops_load_pins
NS=lab-capacity
CREATED=0
DRAINED=''
[[ "$(kubectl get nodes -o json | jq '.items | length')" == 3 ]] || die 'capacity drill requires LOCAL_TOPOLOGY=ha'
kubectl get namespace "$NS" >/dev/null 2>&1 && die 'capacity namespace already exists; refusing adoption'
WORK_DIR="$(mktemp -d)"
cleanup() {
  local rc=$?
  trap - EXIT
  if ((rc && CREATED)); then
    kubectl -n "$NS" get pods,hpa,pdb,vpa -o wide >&2 || rc=1
    kubectl -n "$NS" get events --sort-by=.lastTimestamp >&2 || rc=1
    kubectl -n finops logs deployment/opencost --tail=80 >&2 || rc=1
  fi
  if [[ -n "$DRAINED" ]]; then kubectl uncordon "$DRAINED" >/dev/null || rc=1; fi
  if ((CREATED)); then kubectl delete namespace "$NS" --wait=true --timeout=120s >/dev/null || rc=1; fi
  rm -rf "$WORK_DIR"
  exit "$rc"
}
trap cleanup EXIT
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
    cost.lab/owner: learner
    cost.lab/environment: ci
EOF
CREATED=1
kubectl -n "$NS" create configmap fixture \
  --from-file=server.cjs="$REPO_ROOT/platform/finops/capacity-server.cjs" \
  --from-file=client.cjs="$REPO_ROOT/platform/finops/capacity-client.cjs" >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: capacity, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: capacity}}
  template:
    metadata:
      labels: {app: capacity, cost.lab/owner: learner, cost.lab/environment: ci}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: {matchLabels: {app: capacity}}
      containers:
        - name: server
          image: $CAPACITY_NODE_IMAGE
          command: [node, /fixture/server.cjs]
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 300m, memory: 128Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          readinessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 2}
          livenessProbe: {httpGet: {path: /healthz, port: 8080}, periodSeconds: 5}
          volumeMounts: [{name: fixture, mountPath: /fixture, readOnly: true}]
      volumes: [{name: fixture, configMap: {name: fixture}}]
---
apiVersion: v1
kind: Service
metadata: {name: capacity, namespace: $NS}
spec: {selector: {app: capacity}, ports: [{port: 8080, targetPort: 8080}]}
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: capacity, namespace: $NS}
spec: {minAvailable: 1, selector: {matchLabels: {app: capacity}}}
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: capacity, namespace: $NS}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: capacity}
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource: {name: cpu, target: {type: Utilization, averageUtilization: 60}}
  behavior:
    scaleUp: {stabilizationWindowSeconds: 0}
    scaleDown: {stabilizationWindowSeconds: 30, policies: [{type: Pods, value: 2, periodSeconds: 15}]}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata: {name: capacity, namespace: $NS}
spec:
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: capacity}
  updatePolicy: {updateMode: "Off"}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: fixture-only, namespace: $NS}
spec:
  podSelector: {}
  policyTypes: [Ingress]
  ingress: [{from: [{podSelector: {}}], ports: [{port: 8080, protocol: TCP}]}]
EOF
kubectl -n "$NS" rollout status deployment/capacity --timeout=180s >/dev/null
POD="$(kubectl -n "$NS" get pods -l app=capacity -o jsonpath='{.items[0].metadata.name}')"
pdb_observed() { [[ "$(kubectl -n "$NS" get pdb capacity -o jsonpath='{.status.currentHealthy}')" == 1 ]]; }
retry 30 2 pdb_observed ||
  die 'PDB never observed the healthy singleton'
if kubectl create --raw "/api/v1/namespaces/$NS/pods/$POD/eviction" -f - >"$WORK_DIR/eviction.log" 2>&1 <<EOF
{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$POD","namespace":"$NS"}}
EOF
then die 'PDB incorrectly allowed eviction of the last healthy replica'; fi
grep -q 'disruption budget' "$WORK_DIR/eviction.log" || die 'eviction failed for a reason other than the PDB'
client() {
  local mode=$1
  kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata: {name: $mode, namespace: $NS}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 300
  template:
    metadata: {labels: {app: capacity-client}}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      nodeSelector: {kubernetes.io/hostname: "$LOCAL_CLUSTER-control-plane"}
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: client
          image: $CAPACITY_NODE_IMAGE
          command: [node, /fixture/client.cjs]
          env: [{name: MODE, value: "$mode"}]
          resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {cpu: 200m, memory: 96Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: fixture, mountPath: /fixture, readOnly: true}]
      volumes: [{name: fixture, configMap: {name: fixture}}]
EOF
}
client burn
PEAK=1
for _ in $(seq 1 90); do
  PEAK="$(kubectl -n "$NS" get deployment capacity -o jsonpath='{.status.readyReplicas}')"
  [[ "$PEAK" == 3 ]] && break
  sleep 2
done
[[ "$PEAK" == 3 ]] || die 'HPA did not reach three healthy replicas under real CPU load'
client observe
# Only evict the isolated probe. Existing stateful platform pods are not drained.
DRAINED="$(kubectl -n "$NS" get pods -l app=capacity -o json |
  jq -er --arg prefix "$LOCAL_CLUSTER-worker" '[.items[].spec.nodeName | select(startswith($prefix))][0]')"
[[ "$(docker inspect "$DRAINED" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}')" == "$LOCAL_CLUSTER" ]] ||
  die 'refusing to drain a foreign node'
kubectl drain "$DRAINED" --pod-selector=app=capacity --ignore-daemonsets --delete-emptydir-data --timeout=120s >/dev/null
kubectl -n "$NS" rollout status deployment/capacity --timeout=120s >/dev/null
kubectl -n "$NS" get pods -l app=capacity -o json | jq -e --arg node "$DRAINED" \
  '[.items[] | select(.metadata.deletionTimestamp == null)] | length == 3 and all(.[]; .spec.nodeName != $node)' >/dev/null ||
  die 'probe did not reschedule onto the remaining nodes'
kubectl -n "$NS" wait job/observe --for=condition=Complete --timeout=180s >/dev/null
kubectl -n "$NS" logs job/observe | tail -n 1 >"$WORK_DIR/slo.json"
jq -e '.requests >= 100 and .failed / .requests <= 0.01 and .p99Ms <= 1000' "$WORK_DIR/slo.json" >/dev/null ||
  die 'capacity SLO failed during eviction'
kubectl uncordon "$DRAINED" >/dev/null
DRAINED=''
kubectl -n "$NS" delete job burn --wait=true >/dev/null
for _ in $(seq 1 120); do
  [[ "$(kubectl -n "$NS" get deployment capacity -o jsonpath='{.spec.replicas}')" == 1 ]] && break
  sleep 2
done
[[ "$(kubectl -n "$NS" get deployment capacity -o jsonpath='{.spec.replicas}')" == 1 ]] ||
  die 'HPA failed to return to its minimum after bounded load stopped'
kubectl -n "$NS" get vpa capacity -o json >"$WORK_DIR/vpa.json"
jq -e '.spec.updatePolicy.updateMode == "Off" and (.status.recommendation.containerRecommendations | length > 0)' \
  "$WORK_DIR/vpa.json" >/dev/null || die 'VPA recommendation is missing'
[[ "$(kubectl -n "$NS" get deployment capacity -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')" == 50m ]] ||
  die 'recommendation-only VPA changed requests'
# Query within the cluster; no public cost API.
kubectl -n "$NS" run allocation --image="$CAPACITY_NODE_IMAGE" --restart=Never \
  --overrides='{"spec":{"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"allocation","image":"'"$CAPACITY_NODE_IMAGE"'","command":["node","-e","fetch(\"http://opencost.finops:9003/allocation?window=10m&aggregate=namespace&includeIdle=true&step=1m&resolution=1m\").then(r=>{if(!r.ok)throw Error(r.status);return r.text()}).then(console.log).catch(e=>{console.error(e);process.exit(1)})"],"resources":{"requests":{"cpu":"10m","memory":"32Mi"},"limits":{"cpu":"200m","memory":"96Mi"}},"securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
kubectl -n "$NS" wait pod/allocation --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null
kubectl -n "$NS" logs allocation >"$WORK_DIR/allocation.json"
jq -e '[.. | objects | select(.name? == "lab-capacity" or .properties?.namespace? == "lab-capacity") |
  (.cpuCost // 0) + (.ramCost // 0)] | add > 0' "$WORK_DIR/allocation.json" >/dev/null ||
  die 'OpenCost did not allocate positive measured cost to the probe namespace'
OUT="${HARNESS_ARTIFACT_DIR:-$WORK_DIR}/capacity-finops.json"
mkdir -p "$(dirname "$OUT")"
jq -n --slurpfile slo "$WORK_DIR/slo.json" \
  '{topology:"three-node-kind",hpa:{min:1,peak:3,final:1},pdbRefusedSingleton:true,drainedOwnedWorker:true,
    vpaMode:"Off",allocation:"positive measured namespace cost; configured simulation rates",slo:$slo[0]}' >"$OUT"
cat "$OUT"
log 'PASS capacity: HPA up/down, PDB refusal, scoped drain with SLO, VPA Off and OpenCost allocation'
