#!/usr/bin/env bash
# Actual filesystem data recovery by Velero/Kopia, not just a PVC object restored with empty data.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# shellcheck source=scripts/lib/local.sh
source "$REPO_ROOT/scripts/lib/local.sh"
require_cmd kubectl docker sha256sum openssl
require_lab_context
NODE="$LOCAL_CLUSTER-control-plane"
NS=lab-probe-pvc
PV=lab-probe-pvc
NODE_PATH=/var/local/tx01v2-velero-probe
CREATED=0
[[ "$(docker inspect "$NODE" --format '{{index .Config.Labels "io.x-k8s.kind.cluster"}}')" == "$LOCAL_CLUSTER" ]] ||
  die 'PVC drill: node container does not belong to the local lab'
if kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl get pv "$PV" >/dev/null 2>&1; then
  die 'PVC drill: probe namespace or PV already exists; refusing to adopt it'
fi
docker exec "$NODE" test ! -e "$NODE_PATH" || die 'PVC drill: backing path already exists'
cleanup() {
  local rc=$? server_pod=''
  trap - EXIT
  if ((CREATED)); then
    if ((rc)); then
      # CR status contains repository/volume errors, not the Secrets or backed-up object contents.
      kubectl -n velero get backups,restores,backuprepositories,podvolumebackups,podvolumerestores -o yaml >&2 || rc=1
      kubectl -n velero logs -l velero.io/component=server -c velero --tail=150 --prefix=true >&2 || rc=1
      server_pod="$(kubectl -n velero get pods -l velero.io/component=server -o jsonpath='{.items[0].metadata.name}')" || rc=1
      if [[ -n "$server_pod" ]]; then
        kubectl -n velero exec "$server_pod" -c velero -- /velero backup logs "$NS" >&2 || rc=1
      fi
    fi
    kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=120s >/dev/null || rc=1
    kubectl delete pv "$PV" --ignore-not-found --wait=true --timeout=60s >/dev/null || rc=1
    kubectl -n velero delete backup,restore "$NS" --ignore-not-found >/dev/null || rc=1
    docker exec "$NODE" sh -ec '
      case "$1" in /var/local/tx01v2-velero-probe) ;; *) exit 1 ;; esac
      test "$(cat "$1/.owned-by-lab")" = "$2"
      rm -rf -- "$1"
    ' sh "$NODE_PATH" "$LOCAL_CLUSTER" || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
docker exec "$NODE" sh -ec '
  mkdir -m 0770 "$1"
  printf "%s" "$2" >"$1/.owned-by-lab"
  chown -R 65532:65532 "$1"
' sh "$NODE_PATH" "$LOCAL_CLUSTER"
CREATED=1
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $PV
  labels:
    lab.continuity/probe: "$NS"
spec:
  capacity:
    storage: 64Mi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  local:
    path: $NODE_PATH
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values: ["$NODE"]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
  namespace: $NS
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ""
  volumeName: $PV
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: holder
  namespace: $NS
  annotations:
    backup.velero.io/backup-volumes: data
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: holder
      image: curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777
      command: [sh, -c, "while :; do sleep 3600; done"]
      readinessProbe:
        exec:
          command: [sh, -c, "test -d /data"]
        periodSeconds: 2
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 100m
          memory: 32Mi
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data
EOF
kubectl -n "$NS" wait pod/holder --for=condition=Ready --timeout=180s >/dev/null
PVC_UID="$(kubectl -n "$NS" get pvc data -o jsonpath='{.metadata.uid}')"
PAYLOAD="$(openssl rand -hex 64)"
EXPECTED="$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')"
printf '%s' "$PAYLOAD" | kubectl -n "$NS" exec -i holder -- sh -c 'cat > /data/precious.bin'
kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: $NS
  namespace: velero
spec:
  includedNamespaces: [$NS]
  snapshotVolumes: false
  ttl: 1h0m0s
EOF
wait_phase() {
  local kind=$1 phase='' i
  for ((i = 1; i <= 120; i++)); do
    phase="$(kubectl -n velero get "$kind" "$NS" -o jsonpath='{.status.phase}')"
    [[ "$phase" == Completed ]] && return
    [[ "$phase" == Failed || "$phase" == PartiallyFailed ]] && break
    sleep 3
  done
  die "PVC drill: $kind ended as '$phase'"
}
wait_phase backup
PVB="$(kubectl -n velero get podvolumebackups -l "velero.io/backup-name=$NS" -o jsonpath='{.items[*].status.phase}')"
[[ "$PVB" == Completed ]] || die "PVC drill: expected one completed volume data backup, got '$PVB'"
kubectl delete namespace "$NS" --wait=true --timeout=120s >/dev/null
kubectl delete pv "$PV" --wait=true --timeout=60s >/dev/null
# The namespace, PVC, PV and original bytes are gone. Keep the directory itself owned for cleanup.
docker exec "$NODE" sh -ec '
  test "$(cat "$1/.owned-by-lab")" = "$2"
  rm -- "$1/precious.bin"
  test ! -e "$1/precious.bin"
' sh "$NODE_PATH" "$LOCAL_CLUSTER"
kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: $NS
  namespace: velero
spec:
  backupName: $NS
EOF
wait_phase restore
kubectl -n "$NS" wait pod/holder --for=condition=Ready --timeout=180s >/dev/null
[[ "$(kubectl -n "$NS" get pvc data -o jsonpath='{.metadata.uid}')" != "$PVC_UID" ]] ||
  die 'PVC drill: the original PVC survived'
GOT="$(kubectl -n "$NS" exec holder -- sha256sum /data/precious.bin | awk '{print $1}')"
[[ "$GOT" == "$EXPECTED" ]] || die 'PVC drill: restored file checksum does not match'
PVR="$(kubectl -n velero get podvolumerestores -l "velero.io/restore-name=$NS" -o jsonpath='{.items[*].status.phase}')"
[[ "$PVR" == Completed ]] || die "PVC drill: expected one completed volume data restore, got '$PVR'"
log "PASS Velero PVC data: new claim UID, original bytes deleted, SHA256=$GOT"
