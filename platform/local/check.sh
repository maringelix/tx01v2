#!/usr/bin/env bash
# Probes of the local platform (scripts/local-lab.sh check; harness stage e2e). Each probe proves a
# property with real traffic or a real API call and prints PASS <what>; the first failure stops the
# script (exit 1) after dumping diagnostics. The probes of a layer run only when it is installed. Throwaway resources live in the namespaces lab-probe and
# lab-probe-outside and are deleted at the end. Needs kubectl, docker, curl, terraform and the
# KUBECONFIG/TF_DATA_DIR of scripts/local-lab.sh; the curl calls to the load balancer need this
# machine (or container) on the lab network, which scripts/local-lab.sh arranges.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$HERE/../../scripts/lib/common.sh"
# shellcheck source=scripts/lib/local.sh
source "$REPO_ROOT/scripts/lib/local.sh"
export PATH="$REPO_ROOT/.tools/bin:$PATH"

AGNHOST_IMAGE="registry.k8s.io/e2e-test-images/agnhost:2.61@sha256:101f3357d1ad890c3090e78ea6c6a47dc5137cbe19836796e13d5dcb2b84d2e6"
CURL_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
PROBE_HOST=probe.tx01v2.local
WORK_DIR=""
PASSED=0
ACME_PROBE_IP=""
PEBBLE_FORWARD_PID=""

pass() {
  PASSED=$((PASSED + 1))
  log "PASS $*"
}

cleanup() {
  local rc=$?
  if [[ -n "$PEBBLE_FORWARD_PID" ]]; then
    kill "$PEBBLE_FORWARD_PID" >/dev/null 2>&1 || true
    wait "$PEBBLE_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if ((rc != 0)); then
    log "diagnostics:"
    kubectl get pods --all-namespaces -o wide 2>&1 | sed 's/^/  /' >&2 || true
    kubectl -n lab-probe get gateway,httproute,certificate,peerauthentication,authorizationpolicy -o wide 2>&1 | sed 's/^/  /' >&2 || true
    kubectl get events --all-namespaces --sort-by=.lastTimestamp 2>&1 | tail -n 30 | sed 's/^/  /' >&2 || true
    # CI uploads this directory as an artifact (never Secret values: get/describe only).
    if [[ -n "${LOCAL_DIAGNOSTICS_DIR:-}" ]]; then
      mkdir -p "$LOCAL_DIAGNOSTICS_DIR"
      kubectl get pods --all-namespaces -o wide >"$LOCAL_DIAGNOSTICS_DIR/pods.txt" 2>&1 || true
      kubectl get events --all-namespaces --sort-by=.lastTimestamp >"$LOCAL_DIAGNOSTICS_DIR/events.txt" 2>&1 || true
      kubectl describe pods --all-namespaces >"$LOCAL_DIAGNOSTICS_DIR/describe-pods.txt" 2>&1 || true
      helm list --all-namespaces >"$LOCAL_DIAGNOSTICS_DIR/helm.txt" 2>&1 || true
      kubectl top pods --all-namespaces >"$LOCAL_DIAGNOSTICS_DIR/top.txt" 2>&1 || true
    fi
  fi
  kubectl delete clusterissuer pebble-local --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n cert-manager delete secret pebble-local-account --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace lab-probe lab-probe-outside lab-probe-policy lab-probe-backup lab-probe-gitops lab-acme \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n argocd delete application lab-probe --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n argocd delete appproject lab-probe --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n dx01v2 delete externalsecret lab-probe-db --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n dx01v2 delete deployment lab-probe-scan --ignore-not-found --wait=false >/dev/null 2>&1 || true
  [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
  exit "$rc"
}

# pod_spec_security -> the Pod Security "restricted" fields every probe pod uses.
restricted_pod() { # NAME SERVICE_ACCOUNT IMAGE ARGS_JSON
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  labels:
    app.kubernetes.io/name: $1
spec:
  serviceAccountName: $2
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: $3
      args: $4
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
}

# curl_from NAMESPACE SERVICE_ACCOUNT URL -> runs one curl pod, prints its output, returns curl's code.
curl_from() {
  local ns=$1 sa=$2 url=$3 name phase="" i
  name="curl-$sa-$RANDOM"
  restricted_pod "$name" "$sa" "$CURL_IMAGE" "[\"-sS\", \"-m\", \"5\", \"-o\", \"/dev/null\", \"-w\", \"%{http_code}\", \"$url\"]" |
    kubectl -n "$ns" apply -f - >/dev/null
  for i in $(seq 1 90); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl -n "$ns" logs "$name" 2>&1 | tail -n 1
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1
  [[ "$phase" == Succeeded ]]
}

probe_namespaces() {
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lab-probe
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: lab-probe-outside
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
EOF
  for sa in echo client intruder; do
    kubectl -n lab-probe create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl -n lab-probe-outside create serviceaccount client --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

deploy_echo() {
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: echo
  template:
    metadata:
      labels:
        app.kubernetes.io/name: echo
    spec:
      serviceAccountName: echo
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: echo
          image: $AGNHOST_IMAGE
          args: ["netexec", "--http-port=8080"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector:
    app.kubernetes.io/name: echo
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF
  kubectl -n lab-probe rollout status deployment/echo --timeout=180s >/dev/null
}

# mTLS STRICT + identity-based L4 authorization, enforced by ztunnel.
check_mesh() {
  local code
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls:
    mode: STRICT
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: echo-allow-client-and-gateway
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: echo
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - cluster.local/ns/lab-probe/sa/client
              - cluster.local/ns/lab-probe/sa/probe-istio
      to:
        - operation:
            ports: ["8080"]
EOF
  sleep 5
  code="$(curl_from lab-probe client http://echo.lab-probe:8080/hostname)" || die "mesh: the allowed client could not reach echo ($code)"
  [[ "$code" == 200 ]] || die "mesh: the allowed client got HTTP $code"
  pass "mesh: client (ambient, allowed identity) -> echo:8080 over mTLS: HTTP 200"
  if code="$(curl_from lab-probe intruder http://echo.lab-probe:8080/hostname)"; then
    die "mesh: the intruder identity reached echo (HTTP $code): AuthorizationPolicy not enforced"
  fi
  pass "mesh: intruder (ambient, other identity) -> echo:8080 refused by AuthorizationPolicy ($code)"
  if code="$(curl_from lab-probe-outside client http://echo.lab-probe:8080/hostname)"; then
    die "mesh: a plaintext client outside the mesh reached echo (HTTP $code): STRICT not enforced"
  fi
  pass "mesh: plaintext client outside the mesh -> echo:8080 refused by STRICT mTLS ($code)"
}

# HTTPS through the Gateway API gateway (Istio) behind the emulated cloud load balancer, with a
# certificate cert-manager issued from lab-ca.
check_gateway() {
  local ip="" i code body
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: probe
  annotations:
    cert-manager.io/cluster-issuer: lab-ca
spec:
  gatewayClassName: istio
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: $PROBE_HOST
    - name: https
      protocol: HTTPS
      port: 443
      hostname: $PROBE_HOST
      tls:
        mode: Terminate
        certificateRefs:
          - name: probe-tls
    - name: acme-validation
      protocol: HTTP
      port: 5002
      hostname: $PROBE_HOST
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe-redirect
spec:
  parentRefs:
    - name: probe
      sectionName: http
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: probe
spec:
  parentRefs:
    - name: probe
      sectionName: https
  rules:
    - backendRefs:
        - name: echo
          port: 8080
EOF
  # cert-manager creates the Certificate from the Gateway annotation a moment after the Gateway exists.
  retry 60 2 kubectl -n lab-probe get certificate probe-tls >/dev/null 2>&1 ||
    die "gateway: cert-manager did not create the Certificate probe-tls for the Gateway"
  kubectl -n lab-probe wait --for=condition=Ready certificate/probe-tls --timeout=180s >/dev/null ||
    die "gateway: cert-manager did not issue probe-tls from lab-ca"
  pass "cert-manager: Certificate probe-tls issued by ClusterIssuer lab-ca"
  kubectl -n lab-probe wait --for=condition=Programmed gateway/probe --timeout=300s >/dev/null ||
    die "gateway: Gateway probe not Programmed"
  for i in $(seq 1 120); do
    ip="$(kubectl -n lab-probe get gateway probe -o jsonpath='{.status.addresses[0].value}')"
    [[ "$ip" =~ ^[0-9.]+$ ]] && break
    sleep 1
  done
  [[ "$ip" =~ ^[0-9.]+$ ]] || die "gateway: no load balancer address (cloud-provider-kind)"
  ACME_PROBE_IP="$ip"
  pass "gateway: Gateway probe Programmed with the load balancer address $ip (cloud-provider-kind)"
  tf_out ca_cert_pem >"$WORK_DIR/ca.pem"
  for i in $(seq 1 60); do
    body="$(curl -sS -m 5 --cacert "$WORK_DIR/ca.pem" --resolve "$PROBE_HOST:443:$ip" "https://$PROBE_HOST/hostname" 2>/dev/null)" && break
    sleep 2
  done
  [[ "$body" == echo-* ]] || die "gateway: HTTPS through $ip failed (got '${body:-nothing}')"
  pass "gateway: https://$PROBE_HOST via $ip verified against the lab CA -> echo pod $body"
  # Like the ALB, the edge passes an external X-Request-Id through (EnvoyFilter gateway-preserve-request-id),
  # also a UUID-shaped one, which Envoy would otherwise rewrite to mark its tracing decision.
  local id
  for id in lab-probe-request-id 9f3c2a71-5b8e-4d2a-9c41-7e6f0b1d2c3a; do
    body="$(curl -sS -m 5 --cacert "$WORK_DIR/ca.pem" --resolve "$PROBE_HOST:443:$ip" \
      -H "X-Request-Id: $id" "https://$PROBE_HOST/header?key=X-Request-Id")"
    [[ "$body" == "$id" ]] || die "gateway: the edge changed the external X-Request-Id $id (upstream got '${body:-nothing}')"
  done
  pass "gateway: external X-Request-Ids (free text and UUID) reach the backend unchanged (ALB behaviour)"
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' --resolve "$PROBE_HOST:80:$ip" "http://$PROBE_HOST/hostname")"
  [[ "$code" == 301 ]] || die "gateway: HTTP must redirect to HTTPS (got $code)"
  pass "gateway: http://$PROBE_HOST -> 301 to HTTPS"
}

# The local twin runs the real OWASP CRS engine for SQLi and NGINX request limiting for a small
# burst. It is reachable only through the local Gateway and is deleted by cleanup.
check_waf() {
  local status i code saw_limited=0 saw_allowed=0
  kubectl apply -f "$REPO_ROOT/platform/local/manifests/waf-probe.yaml" >/dev/null
  kubectl -n lab-probe wait --for=condition=Available deployment/waf-probe --timeout=180s >/dev/null ||
    die "waf: the local OWASP CRS proxy did not become ready"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: waf-probe
spec:
  parentRefs:
    - name: probe
      sectionName: https
  hostnames: ["$PROBE_HOST"]
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /waf
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: waf-probe
          port: 8080
EOF
  for i in $(seq 1 45); do
    status="$(kubectl -n lab-probe get httproute waf-probe -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
    [[ "$status" == True ]] && break
    sleep 2
  done
  [[ "$status" == True ]] || die "waf: Gateway API did not attach the local WAF route"

  status="$(curl -sS -m 10 -o "$WORK_DIR/waf-benign.body" -w '%{http_code}' --cacert "$WORK_DIR/ca.pem" \
    --resolve "$PROBE_HOST:443:$ACME_PROBE_IP" "https://$PROBE_HOST/waf/hostname")" ||
    die "waf: the benign probe could not reach the local WAF"
  [[ "$status" == 200 && "$(cat "$WORK_DIR/waf-benign.body")" == echo-* ]] ||
    die "waf: benign traffic did not reach the backend (HTTP $status)"
  pass "waf: benign request passes through the local ModSecurity/OWASP CRS proxy"

  status="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "$WORK_DIR/ca.pem" \
    --resolve "$PROBE_HOST:443:$ACME_PROBE_IP" --get --data-urlencode "id=1' OR '1'='1" \
    "https://$PROBE_HOST/waf/hostname")" || die "waf: SQLi probe did not receive an HTTP response"
  [[ "$status" == 403 ]] || die "waf: OWASP CRS did not block the SQL injection probe (HTTP $status)"
  pass "waf: OWASP CRS blocks a SQL injection probe with HTTP 403"

  for i in $(seq 1 12); do
    (
      curl -sS -m 10 -o /dev/null -w '%{http_code}' --cacert "$WORK_DIR/ca.pem" \
        --resolve "$PROBE_HOST:443:$ACME_PROBE_IP" "https://$PROBE_HOST/waf/hostname" \
        >"$WORK_DIR/waf-rate-$i.status" 2>/dev/null || true
    ) &
  done
  wait
  for i in $(seq 1 12); do
    code="$(cat "$WORK_DIR/waf-rate-$i.status" 2>/dev/null || true)"
    [[ "$code" == 429 ]] && saw_limited=1
    [[ "$code" == 200 ]] && saw_allowed=1
  done
  ((saw_limited == 1 && saw_allowed == 1)) ||
    die "waf: concurrent burst must include both an allowed request and HTTP 429 (allowed=$saw_allowed blocked=$saw_limited)"
  pass "waf: NGINX rate limit allows a request and blocks a burst with HTTP 429"
}

# Pebble is a test CA, isolated to this ephemeral cluster. The short-lived profile gives cert-manager
# a real ACME renewal deadline in minutes; no environment variable bypasses HTTP-01 validation.
check_acme() {
  local ca_bundle status revision serial="" initial_serial renewal_time renewal_epoch now i
  kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: lab-acme
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/enforce-version: latest
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -keyout "$WORK_DIR/pebble-server.key" -out "$WORK_DIR/pebble-server.crt" \
    -subj "/CN=pebble.lab-acme.svc" \
    -addext "subjectAltName=DNS:pebble.lab-acme.svc,DNS:pebble.lab-acme.svc.cluster.local" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign,cRLSign" \
    -addext "extendedKeyUsage=serverAuth" >/dev/null 2>&1 || die "acme: could not create the ephemeral Pebble API TLS certificate"
  kubectl -n lab-acme create secret tls pebble-server-tls --cert="$WORK_DIR/pebble-server.crt" \
    --key="$WORK_DIR/pebble-server.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "$REPO_ROOT/platform/local/manifests/pebble.yaml" >/dev/null
  kubectl -n lab-acme wait --for=condition=Available deployment/pebble deployment/challtestsrv --timeout=120s >/dev/null ||
    die "acme: Pebble or challtestsrv did not become ready"

  kubectl -n lab-acme port-forward service/challtestsrv 18055:management >"$WORK_DIR/challtestsrv-port-forward.log" 2>&1 &
  PEBBLE_FORWARD_PID=$!
  for i in $(seq 1 30); do
    status="$(curl -sS -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:18055/not-found 2>/dev/null || true)"
    [[ "$status" == 404 ]] && break
    sleep 1
  done
  [[ "$status" == 404 ]] || die "acme: challtestsrv management API port-forward did not start"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "{\"ip\":\"$ACME_PROBE_IP\"}" http://127.0.0.1:18055/set-default-ipv4 >/dev/null ||
    die "acme: could not route Pebble DNS validation to the local Gateway"

  ca_bundle="$(base64 <"$WORK_DIR/pebble-server.crt" | tr -d '\r\n')"
  kubectl apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: pebble-local
spec:
  acme:
    email: learner@example.org
    server: https://pebble.lab-acme.svc.cluster.local:14000/dir
    caBundle: "$ca_bundle"
    profile: shortlived
    privateKeySecretRef:
      name: pebble-local-account
    solvers:
      - http01:
          gatewayHTTPRoute:
            parentRefs:
              - name: probe
                namespace: lab-probe
                sectionName: acme-validation
        selector:
          dnsNames:
            - $PROBE_HOST
        waitInsteadOfSelfCheck: 10s
EOF
  kubectl wait --for=condition=Ready clusterissuer/pebble-local --timeout=90s >/dev/null ||
    die "acme: cert-manager could not register with the local ACME server"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: probe-acme
spec:
  secretName: probe-acme-tls
  # cert-manager's API minimum is one hour; the local Pebble profile actually issues 20m certs.
  duration: 1h
  dnsNames:
    - $PROBE_HOST
  issuerRef:
    name: pebble-local
    kind: ClusterIssuer
    group: cert-manager.io
  renewBefore: 15m
EOF
  kubectl -n lab-probe wait --for=condition=Ready certificate/probe-acme --timeout=180s >/dev/null ||
    die "acme: cert-manager did not issue an HTTP-01 certificate from Pebble"
  kubectl -n lab-probe get secret probe-acme-tls -o jsonpath='{.data.tls\.crt}' | base64 -d >"$WORK_DIR/probe-acme.crt"
  openssl x509 -in "$WORK_DIR/probe-acme.crt" -noout -checkhost "$PROBE_HOST" >/dev/null 2>&1 ||
    die "acme: issued certificate does not cover $PROBE_HOST"
  initial_serial="$(openssl x509 -in "$WORK_DIR/probe-acme.crt" -noout -serial | cut -d= -f2)"
  revision="$(kubectl -n lab-probe get certificate probe-acme -o jsonpath='{.status.revision}')"
  [[ "$revision" == 1 && -n "$initial_serial" ]] || die "acme: first issuance revision/serial was unexpected (revision=$revision)"
  pass "acme: Pebble completed DNS and HTTP-01 routing; cert-manager issued a hostname-valid certificate"

  renewal_time="$(kubectl -n lab-probe get certificate probe-acme -o jsonpath='{.status.renewalTime}')"
  renewal_epoch="$(date -d "$renewal_time" +%s 2>/dev/null || true)"
  now="$(date +%s)"
  if [[ ! "$renewal_epoch" =~ ^[0-9]+$ ]] || ((renewal_epoch < now - 10 || renewal_epoch > now + 600)); then
    die "acme: automatic renewal was not scheduled within ten minutes (renewalTime=${renewal_time:-missing})"
  fi

  for i in $(seq 1 144); do
    revision="$(kubectl -n lab-probe get certificate probe-acme -o jsonpath='{.status.revision}' 2>/dev/null || true)"
    if [[ "$revision" =~ ^[0-9]+$ ]] && ((revision >= 2)); then
      kubectl -n lab-probe get secret probe-acme-tls -o jsonpath='{.data.tls\.crt}' | base64 -d >"$WORK_DIR/probe-acme-renewed.crt"
      serial="$(openssl x509 -in "$WORK_DIR/probe-acme-renewed.crt" -noout -serial | cut -d= -f2)"
      [[ -n "$serial" && "$serial" != "$initial_serial" ]] && break
    fi
    sleep 5
  done
  [[ "$revision" =~ ^[0-9]+$ ]] && ((revision >= 2)) && [[ "$serial" != "$initial_serial" ]] ||
    die "acme: cert-manager did not automatically rotate the short-lived certificate within twelve minutes"
  kubectl -n lab-probe wait --for=condition=Ready certificate/probe-acme --timeout=30s >/dev/null ||
    die "acme: renewed certificate is not Ready"
  pass "acme: cert-manager automatically renewed the certificate (revision $revision, new serial $serial)"
}

check_external_secrets() {
  local keys
  kubectl -n dx01v2 apply -f - >/dev/null <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: lab-probe-db
spec:
  refreshInterval: 0s
  secretStoreRef:
    kind: ClusterSecretStore
    name: local-secrets
  target:
    name: lab-probe-db
  dataFrom:
    - extract:
        key: tx01v2-lab-db-app
EOF
  kubectl -n dx01v2 wait --for=condition=Ready externalsecret/lab-probe-db --timeout=120s >/dev/null ||
    die "external-secrets: ExternalSecret lab-probe-db not Ready"
  # shellcheck disable=SC2016 # a Go template, not a shell expansion
  keys="$(kubectl -n dx01v2 get secret lab-probe-db -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
  [[ "$keys" == "dbname host password port username " ]] || die "external-secrets: unexpected keys '$keys'"
  kubectl -n dx01v2 delete externalsecret lab-probe-db >/dev/null
  kubectl -n dx01v2 delete secret lab-probe-db --ignore-not-found >/dev/null
  pass "external-secrets: local-secrets -> dx01v2 Secret with keys $keys"
}

check_database() {
  local ip
  ip="$(tf_out db_ip)"
  # From the lab network, like a client inside the VPC: TLS with the lab CA, then plaintext refused.
  if ! { tf_out ca_cert_pem | docker run --rm -i --network "$(tf_out docker_network)" -e PGPASSWORD="$(tf_out db_password)" \
    "$(tf_out_image postgres)" sh -c "cat > /tmp/ca.pem && psql 'host=$(tf_out db_hostname) hostaddr=$ip port=5432 dbname=dx01v2 user=dx01v2 sslmode=verify-full sslrootcert=/tmp/ca.pem' -Atc 'select ssl from pg_stat_ssl where pid = pg_backend_pid()'" | grep -qx t; }; then
    die "database: verify-full TLS connection failed"
  fi
  pass "database: TLS verify-full against the lab CA (db.tx01v2.local at $ip)"
  if docker run --rm --network "$(tf_out docker_network)" -e PGPASSWORD=wrong "$(tf_out_image postgres)" \
    psql "host=$ip port=5432 dbname=dx01v2 user=dx01v2 sslmode=disable" -Atc 'select 1' >/dev/null 2>&1; then
    die "database: a plaintext connection was accepted"
  fi
  pass "database: plaintext connections refused (hostssl only)"
}

# tf_out_image KEY -> pinned image of terraform/envs/local/images.tf (the database client is the
# server image itself, already in the local Docker cache).
tf_out_image() {
  sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$LOCAL_TF_DIR/images.tf"
}

check_metrics_server() {
  local i
  for i in $(seq 1 60); do
    kubectl top nodes >/dev/null 2>&1 && {
      pass "metrics-server: kubectl top nodes ($(kubectl top nodes --no-headers | awk '{ print $2 " CPU, " $4 " memory" }'))"
      return 0
    }
    sleep 3
  done
  die "metrics-server: kubectl top nodes failed for 3 minutes"
}

# in_cluster_get URL [USER:PASSWORD] -> body of an HTTP GET made from a throwaway curl pod in
# lab-probe-outside (the monitoring Services are ClusterIP only, like the v2 rule "no public UI"),
# with basic authentication when given.
in_cluster_get() {
  local url=$1 name phase="" i args
  name="get-$RANDOM"
  args="\"-sS\", \"-m\", \"10\", \"--fail\""
  [[ -z "${2:-}" ]] || args+=", \"-u\", \"$2\""
  restricted_pod "$name" client "$CURL_IMAGE" "[$args, \"$url\"]" |
    kubectl -n lab-probe-outside apply -f - >/dev/null
  for i in $(seq 1 90); do
    phase="$(kubectl -n lab-probe-outside get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl -n lab-probe-outside logs "$name" 2>/dev/null
  kubectl -n lab-probe-outside delete pod "$name" --wait=false >/dev/null 2>&1
  [[ "$phase" == Succeeded ]]
}

PROM=http://kube-prometheus-stack-prometheus.monitoring.svc:9090

check_prometheus() {
  local body i down
  for i in $(seq 1 30); do
    body="$(in_cluster_get "$PROM/api/v1/query?query=up")" && [[ "$body" == *'"status":"success"'* ]] && break
    sleep 5
  done
  [[ "$body" == *'"status":"success"'* ]] || die "prometheus: query API not answering"
  for job in kube-state-metrics node-exporter apiserver kubelet; do
    [[ "$body" == *"\"job\":\"$job\""* ]] || die "prometheus: no target of job $job"
  done
  # Targets whose up value is "0" (awk counts without failing when there is none).
  down="$(awk -v RS='"value":\\[' 'NR > 1 && /^[0-9.]+,"0"\]/ { n++ } END { print n + 0 }' <<<"$body")"
  pass "prometheus: targets of kube-state-metrics, node-exporter, apiserver and kubelet scraped ($down down)"
}

# A PrometheusRule that always fires, routed by Alertmanager to the sink: proves rule evaluation,
# alert routing and delivery end to end (the v1 Slack route was never tested).
check_alerting() {
  local i run
  run="$(date +%s)-$RANDOM"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lab-probe
spec:
  groups:
    - name: lab-probe
      rules:
        - alert: LabProbeAlwaysFiring
          expr: vector(1)
          labels:
            # warning, not info: the default inhibit rules of kube-prometheus-stack mute info alerts
            # once InfoInhibitor fires in the same namespace (a race the CI lost once).
            severity: warning
            probe_run: "$run"
          annotations:
            summary: Synthetic alert of platform/local/check.sh
EOF
  local logs="" webhook=0 slack=0
  for i in $(seq 1 120); do
    logs="$(kubectl -n monitoring logs deployment/alert-sink --since=15m 2>/dev/null)" || logs=""
    grep -F '"path":"/alertmanager"' <<<"$logs" | grep -qF "$run" && webhook=1
    grep -F '"path":"/slack"' <<<"$logs" | grep -qF "$run" && slack=1
    ((webhook == 1)) && break
    sleep 5
  done
  ((webhook == 1)) || die "alerting: LabProbeAlwaysFiring (probe_run $run) never reached alert-sink in 10 minutes"
  pass "alerting: PrometheusRule LabProbeAlwaysFiring -> Alertmanager -> alert-sink"
  check_slack "$run" "$slack"
  kubectl -n lab-probe delete prometheusrule lab-probe >/dev/null
}

# The Slack receiver (the v1 channels): without LOCAL_SLACK_WEBHOOK_URL it posts to the Slack path of
# the sink, which must have received the alert in Slack's message format; with a real webhook,
# Alertmanager must count successful Slack notifications and no failed one.
check_slack() {
  local run=$1 seen=$2 webhook i body sent failed
  webhook="$(kubectl -n monitoring get secret alertmanager-slack -o jsonpath='{.data.webhook-url}' | base64 -d)"
  if [[ "$webhook" == http://alert-sink.monitoring.svc:8080/slack ]]; then
    for i in $(seq 1 24); do
      ((seen == 1)) && break
      kubectl -n monitoring logs deployment/alert-sink --since=15m 2>/dev/null | grep -F '"path":"/slack"' |
        grep -F '\"attachments\"' | grep -qF "$run" && seen=1
      sleep 5
    done
    ((seen == 1)) || die "alerting: the Slack receiver never posted LabProbeAlwaysFiring (probe_run $run)"
    pass "alerting: the Slack receiver posts the alert as a Slack message (to the sink; LOCAL_SLACK_WEBHOOK_URL sends it to a real channel)"
    return 0
  fi
  for i in $(seq 1 24); do
    body="$(in_cluster_get http://kube-prometheus-stack-alertmanager.monitoring.svc:9093/metrics)" || body=""
    sent="$(awk '/^alertmanager_notifications_total\{.*integration="slack"/ { n += $NF } END { print n + 0 }' <<<"$body")"
    failed="$(awk '/^alertmanager_notifications_failed_total\{.*integration="slack"/ { n += $NF } END { print n + 0 }' <<<"$body")"
    ((sent > 0)) && break
    sleep 5
  done
  ((sent > 0)) || die "alerting: Alertmanager sent no Slack notification to LOCAL_SLACK_WEBHOOK_URL"
  ((failed == 0)) || die "alerting: $failed Slack notifications failed (check the webhook of LOCAL_SLACK_WEBHOOK_URL)"
  pass "alerting: $sent Slack notifications delivered to the webhook of LOCAL_SLACK_WEBHOOK_URL, none failed"
}

check_loki() {
  local body i
  for i in $(seq 1 36); do
    body="$(in_cluster_get 'http://loki.monitoring.svc:3100/loki/api/v1/query?query=count_over_time(%7Bnamespace%3D%22lab-probe%22%7D%5B10m%5D)')" &&
      [[ "$body" == *'"result":[{'* ]] && {
      pass "logging: Alloy ships pod logs to Loki (namespace lab-probe found)"
      return 0
    }
    sleep 5
  done
  die "logging: no logs of namespace lab-probe in Loki after 3 minutes"
}

check_grafana() {
  local body
  body="$(in_cluster_get http://kube-prometheus-stack-grafana.monitoring.svc/api/health)" ||
    die "grafana: /api/health failed"
  [[ "$body" == *'"database": "ok"'* || "$body" == *'"database":"ok"'* ]] || die "grafana: unhealthy ($body)"
  [[ "$(kubectl -n monitoring get service kube-prometheus-stack-grafana -o jsonpath='{.spec.type}')" == ClusterIP ]] ||
    die "grafana: the Service must stay ClusterIP (no public UI)"
  pass "grafana: healthy, ClusterIP only, admin password from the local state"
}

TEMPO=http://tempo.monitoring.svc:3200
COLLECTOR=http://opentelemetry-collector.monitoring.svc:4318
GRAFANA=http://kube-prometheus-stack-grafana.monitoring.svc

# hex BYTES -> random lowercase hex (W3C trace and span ids).
hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# in_cluster_post_json URL FILE -> HTTP code of a POST of the JSON FILE, made from a throwaway curl pod
# in lab-probe-outside (the payload travels in a ConfigMap; nothing is in the mesh there).
in_cluster_post_json() {
  local url=$1 file=$2 name phase="" i
  name="post-$RANDOM"
  kubectl -n lab-probe-outside create configmap "$name" --from-file=payload.json="$file" --dry-run=client -o yaml |
    kubectl apply -f - >/dev/null
  kubectl -n lab-probe-outside apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  serviceAccountName: client
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: $CURL_IMAGE
      args: ["-sS", "-m", "10", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Content-Type: application/json",
             "--data-binary", "@/payload/payload.json", "$url"]
      volumeMounts:
        - name: payload
          mountPath: /payload
          readOnly: true
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 64Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
  volumes:
    - name: payload
      configMap:
        name: $name
EOF
  for i in $(seq 1 90); do
    phase="$(kubectl -n lab-probe-outside get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl -n lab-probe-outside logs "$name" 2>&1 | tail -n 1
  kubectl -n lab-probe-outside delete pod "$name" --wait=false >/dev/null 2>&1
  kubectl -n lab-probe-outside delete configmap "$name" >/dev/null 2>&1
  [[ "$phase" == Succeeded ]]
}

# tempo_trace TRACE_ID -> the trace as Tempo returns it (OTLP JSON), polled for up to 2 minutes (the
# Collector batches, Tempo flushes); fails when it never shows up.
tempo_trace() {
  local body="" i
  for i in $(seq 1 40); do
    body="$(in_cluster_get "$TEMPO/api/traces/$1")" && [[ "$body" == *'"spanId"'* ]] && {
      printf '%s' "$body"
      return 0
    }
    sleep 3
  done
  return 1
}

# Observability 2.0: one OpenTelemetry pipeline. A span sent over OTLP reaches Tempo through the
# Collector; an Istio Gateway continues an incoming W3C trace, hands its own span to the backend and
# reports it; the spanmetrics connector turns spans into RED series in Prometheus with exemplars that
# carry the trace id; Grafana reaches Tempo and links logs, traces and metrics.
check_tracing() {
  local trace span now body code ip gw_trace gw_parent got services start auth
  trace="$(hex 16)"
  span="$(hex 8)"
  now=$(($(date +%s) * 1000000000))
  cat >"$WORK_DIR/span.json" <<EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"lab-probe"}}]},
"scopeSpans":[{"scope":{"name":"platform/local/check.sh"},"spans":[{"traceId":"$trace","spanId":"$span",
"name":"lab-probe-span","kind":2,"startTimeUnixNano":"$((now - 50000000))","endTimeUnixNano":"$now",
"status":{"code":1}}]}]}]}
EOF
  code="$(in_cluster_post_json "$COLLECTOR/v1/traces" "$WORK_DIR/span.json")" ||
    die "tracing: the OTLP/HTTP request to the OpenTelemetry Collector failed (${code:-no answer})"
  [[ "$code" == 200 ]] || die "tracing: the OpenTelemetry Collector refused an OTLP/HTTP span (HTTP $code)"
  body="$(tempo_trace "$trace")" || die "tracing: the span of trace $trace never reached Tempo"
  [[ "$body" == *lab-probe-span* ]] || die "tracing: Tempo returned trace $trace without the span lab-probe-span"
  pass "tracing: an OTLP/HTTP span sent to the OpenTelemetry Collector is stored in Tempo (trace $trace)"
  ip="$(kubectl -n lab-probe get gateway probe -o jsonpath='{.status.addresses[0].value}')"
  gw_trace="$(hex 16)"
  gw_parent="$(hex 8)"
  got="$(curl -sS -m 5 --cacert "$WORK_DIR/ca.pem" --resolve "$PROBE_HOST:443:$ip" \
    -H "traceparent: 00-$gw_trace-$gw_parent-01" "https://$PROBE_HOST/header?key=traceparent")"
  [[ "$got" =~ ^00-$gw_trace-[0-9a-f]{16}-01$ && "$got" != "00-$gw_trace-$gw_parent-01" ]] ||
    die "tracing: the Gateway did not continue the incoming trace (the backend got traceparent '${got:-nothing}')"
  pass "tracing: the Istio Gateway continues an incoming W3C trace and passes its own span id to the backend"
  body="$(tempo_trace "$gw_trace")" || die "tracing: the Gateway span of trace $gw_trace never reached Tempo"
  services="$(grep -oE '"service.name","value":\{"stringValue":"[^"]+"' <<<"$body" | sed -E 's/.*"stringValue":"//; s/"$//' | sort -u | tr '\n' ' ')"
  pass "tracing: the Gateway span of trace $gw_trace is in Tempo (service ${services% })"
  # spanmetrics flushes every 15 s and Prometheus scrapes it every 10 s (an exemplar lives one flush).
  for _ in $(seq 1 40); do
    body="$(in_cluster_get "$PROM/api/v1/query?query=traces_span_metrics_calls_total%7Bservice_name%3D%22lab-probe%22%7D")" &&
      [[ "$body" == *'"result":[{'* ]] && break
    sleep 5
  done
  [[ "$body" == *'"result":[{'* ]] || die "tracing: no spanmetrics series (traces_span_metrics_calls_total) of service lab-probe in Prometheus"
  start=$(($(date +%s) - 900))
  for _ in $(seq 1 20); do
    body="$(in_cluster_get "$PROM/api/v1/query_exemplars?query=traces_span_metrics_duration_seconds_bucket%7Bservice_name%3D%22lab-probe%22%7D&start=$start&end=$(($(date +%s) + 60))")" &&
      [[ "$body" == *"$trace"* ]] && break
    sleep 5
  done
  [[ "$body" == *"$trace"* ]] || die "tracing: Prometheus has no exemplar with the trace id $trace (spanmetrics, exemplar storage)"
  pass "tracing: spanmetrics (RED) of the span are in Prometheus, with an exemplar that carries its trace id"
  auth="admin:$(tf_out grafana_admin_password)"
  body="$(in_cluster_get "$GRAFANA/api/datasources/uid/tempo/health" "$auth")" ||
    die "grafana: the health check of the Tempo datasource failed"
  [[ "$body" == *'"status":"OK"'* ]] || die "grafana: the Tempo datasource is not healthy ($body)"
  body="$(in_cluster_get "$GRAFANA/api/datasources/uid/loki" "$auth")" ||
    die "grafana: the Loki datasource is missing"
  [[ "$body" == *'"datasourceUid":"tempo"'* ]] || die "grafana: the Loki datasource has no derived field to Tempo"
  pass "grafana: Tempo datasource healthy; logs -> traces (Loki derived field) and metrics -> traces (exemplars) linked"
}

installed() { helm -n "$2" status "$1" >/dev/null 2>&1; }

# GitOps: a commit pushed to the lab git server reaches the cluster through Argo CD, and so does the
# next one (reconciliation, not a one-shot apply).
check_gitops() {
  local repo="$WORK_DIR/gitops" key="$WORK_DIR/git_key" i value
  tf_out git_admin_private_key >"$key"
  chmod 600 "$key"
  export GIT_SSH_COMMAND="ssh -i $key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK_DIR/known_hosts"
  git init -q -b main "$repo"
  git -C "$repo" config user.email you@example.com
  git -C "$repo" config user.name "local lab probe"
  write_cm() {
    cat >"$repo/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-probe
  namespace: lab-probe-gitops
data:
  revision: "$1"
EOF
    git -C "$repo" add configmap.yaml
    git -C "$repo" commit -qm "revision $1"
    git -C "$repo" push -q --force "$(tf_out git_ssh_url)/lab-probe-gitops" main
  }
  write_cm one
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lab-probe-gitops
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: lab-probe
  namespace: argocd
spec:
  sourceRepos:
    - $(tf_out git_http_url)/lab-probe-gitops.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: lab-probe-gitops
  namespaceResourceWhitelist:
    - group: ""
      kind: ConfigMap
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: lab-probe
  namespace: argocd
spec:
  project: lab-probe
  source:
    repoURL: $(tf_out git_http_url)/lab-probe-gitops.git
    targetRevision: main
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: lab-probe-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
  for i in $(seq 1 60); do
    value="$(kubectl -n lab-probe-gitops get configmap lab-probe -o jsonpath='{.data.revision}' 2>/dev/null)" || value=""
    [[ "$value" == one ]] && break
    sleep 3
  done
  [[ "$value" == one ]] || die "gitops: Argo CD did not sync revision one from the lab git server"
  pass "gitops: Argo CD synced the first commit of the lab git server"
  write_cm two
  # Ask for an immediate refresh instead of waiting for the reconciliation period.
  kubectl -n argocd annotate application lab-probe argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  for i in $(seq 1 60); do
    value="$(kubectl -n lab-probe-gitops get configmap lab-probe -o jsonpath='{.data.revision}' 2>/dev/null)" || value=""
    [[ "$value" == two ]] && break
    sleep 3
  done
  [[ "$value" == two ]] || die "gitops: the second commit never reached the cluster"
  kubectl -n lab-probe-gitops delete configmap lab-probe >/dev/null
  for i in $(seq 1 40); do
    kubectl -n lab-probe-gitops get configmap lab-probe >/dev/null 2>&1 && break
    sleep 3
  done
  kubectl -n lab-probe-gitops get configmap lab-probe >/dev/null 2>&1 || die "gitops: selfHeal did not recreate a deleted object"
  pass "gitops: a second commit reconciled and a deleted object self-healed"
  kubectl -n argocd delete application lab-probe --wait=true --timeout=120s >/dev/null
}

# Admission policies in deny: an image without tag from outside the lab registry, without resources,
# probe or labels is refused with the reasons; a compliant pod is accepted (both server dry runs).
check_policies() {
  local out
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lab-probe-policy
  labels:
    pod-security.kubernetes.io/enforce: restricted
    policy.lab/enforce: "true"
EOF
  if out="$(kubectl -n lab-probe-policy run bad --image=docker.io/library/busybox --restart=Never --dry-run=server \
    --overrides='{"apiVersion":"v1","metadata":{"labels":null},"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"bad","image":"docker.io/library/busybox","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1)"; then
    die "policies: a non-compliant pod was accepted"
  fi
  for want in allowed-repos image-pinned container-resources required-probes required-labels; do
    [[ "$out" == *"[$want]"* ]] || die "policies: constraint $want did not refuse the pod: $out"
  done
  pass "policies: Gatekeeper denies an unpinned image from outside the lab registry without resources, probe or labels (5 constraints)"
  kubectl -n lab-probe-policy apply --dry-run=server -f - >/dev/null <<EOF ||
apiVersion: v1
kind: Pod
metadata:
  name: good
  labels:
    app.kubernetes.io/name: good
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: good
      image: registry.tx01v2.local/probe/agnhost:2.61
      readinessProbe:
        httpGet:
          path: /
          port: 8080
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
EOF
    die "policies: a compliant pod was refused"
  if kubectl -n lab-probe-policy create service nodeport bad --tcp=80:80 --dry-run=server >/dev/null 2>&1; then
    die "policies: a NodePort Service was accepted"
  fi
  pass "policies: a compliant pod is accepted and a NodePort Service is refused"
}

# Trivy Operator: a workload of the app namespace gets a configuration audit and a vulnerability
# report (its image comes from the lab registry, read through the mirror of the scan jobs).
check_trivy() {
  local image push i n
  push="$(tf_out registry_push)/probe/agnhost:2.61"
  image="$(tf_out registry)/probe/agnhost:2.61"
  docker pull -q "$AGNHOST_IMAGE" >/dev/null
  docker tag "$AGNHOST_IMAGE" "$push"
  docker push -q "$push" >/dev/null
  kubectl -n dx01v2 apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lab-probe-scan
  labels:
    app.kubernetes.io/name: lab-probe-scan
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: lab-probe-scan
  template:
    metadata:
      labels:
        app.kubernetes.io/name: lab-probe-scan
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: main
          image: $image
          args: ["netexec", "--http-port=8080"]
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 64Mi
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
EOF
  kubectl -n dx01v2 rollout status deployment/lab-probe-scan --timeout=180s >/dev/null ||
    die "trivy: the probe workload (image from the lab registry, Gatekeeper-compliant) did not start"
  pass "registry: the kind node pulled $image; Gatekeeper admitted it in dx01v2"
  for i in $(seq 1 60); do
    n="$(kubectl -n dx01v2 get configauditreports -o name 2>/dev/null | awk '/replicaset-lab-probe-scan-/ { n++ } END { print n + 0 }')" || n=0
    ((n > 0)) && break
    sleep 5
  done
  ((n > 0)) || die "trivy: no ConfigAuditReport for lab-probe-scan after 5 minutes"
  pass "trivy: ConfigAuditReport written for the probe workload"
  for i in $(seq 1 120); do
    n="$(kubectl -n dx01v2 get vulnerabilityreports -o name 2>/dev/null | awk '/replicaset-lab-probe-scan-/ { n++ } END { print n + 0 }')" || n=0
    ((n > 0)) && break
    sleep 5
  done
  ((n > 0)) || die "trivy: no VulnerabilityReport for lab-probe-scan after 10 minutes"
  pass "trivy: VulnerabilityReport written (HIGH/CRITICAL: $(kubectl -n dx01v2 get "$(kubectl -n dx01v2 get vulnerabilityreports -o name | grep -m1 replicaset-lab-probe-scan-)" -o jsonpath='{.report.summary.criticalCount}/{.report.summary.highCount}' | awk -F/ '{ print $1 " critical, " $2 " high" }'))"
  kubectl -n dx01v2 delete deployment lab-probe-scan --wait=false >/dev/null
}

# Backup and restore drill: back up a namespace to the S3 emulator, delete it, restore it, compare.
check_backup() {
  local i phase got
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: lab-probe-backup
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: precious
  namespace: lab-probe-backup
data:
  payload: restore-me
EOF
  kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: lab-probe
  namespace: velero
spec:
  includedNamespaces: [lab-probe-backup]
  snapshotVolumes: false
  ttl: 1h0m0s
EOF
  for i in $(seq 1 60); do
    phase="$(kubectl -n velero get backup lab-probe -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Completed || "$phase" == Failed || "$phase" == PartiallyFailed ]] && break
    sleep 3
  done
  [[ "$phase" == Completed ]] || die "backup: Velero backup ended as '${phase:-unknown}'"
  pass "backup: Velero backup of lab-probe-backup Completed in the S3 emulator"
  kubectl delete namespace lab-probe-backup --wait=true --timeout=120s >/dev/null
  kubectl apply -f - >/dev/null <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: lab-probe
  namespace: velero
spec:
  backupName: lab-probe
EOF
  for i in $(seq 1 60); do
    phase="$(kubectl -n velero get restore lab-probe -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Completed || "$phase" == Failed || "$phase" == PartiallyFailed ]] && break
    sleep 3
  done
  [[ "$phase" == Completed ]] || die "backup: Velero restore ended as '${phase:-unknown}'"
  got="$(kubectl -n lab-probe-backup get configmap precious -o jsonpath='{.data.payload}')"
  [[ "$got" == restore-me ]] || die "backup: the restored ConfigMap holds '$got'"
  pass "backup: namespace deleted and restored from the backup with its data"
  kubectl -n velero delete restore lab-probe >/dev/null
  kubectl -n velero delete backup lab-probe >/dev/null
}

# Chaos engineering with a hypothesis: with 2 replicas behind a Service, killing one pod does not
# interrupt the service (at least 95% of 40 requests over 20 s succeed while the pod is killed).
check_chaos() {
  local name=chaos-client phase="" i ok
  kubectl -n lab-probe scale deployment echo --replicas=2 >/dev/null
  kubectl -n lab-probe rollout status deployment/echo --timeout=180s >/dev/null
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  serviceAccountName: client
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: $CURL_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          sleep 5; ok=0
          for i in \$(seq 1 40); do
            curl -s -m 2 -o /dev/null -w '%{http_code}' http://echo.lab-probe:8080/hostname | grep -q 200 && ok=\$((ok + 1))
            sleep 0.5
          done
          echo "ok=\$ok"
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  sleep 8
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-one-echo
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces: [lab-probe]
    labelSelectors:
      app.kubernetes.io/name: echo
EOF
  for i in $(seq 1 90); do
    phase="$(kubectl -n lab-probe get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  ok="$(kubectl -n lab-probe logs "$name" | sed -n 's/^ok=//p')"
  kubectl -n lab-probe get podchaos kill-one-echo -o jsonpath='{.status.experiment.containerRecords[0].events[0].type}' | grep -q Succeeded ||
    die "chaos: the PodChaos kill-one-echo was not injected"
  if [[ ! "$ok" =~ ^[0-9]+$ ]] || ((ok < 38)); then
    die "chaos: hypothesis refuted, only ${ok:-?}/40 requests succeeded while one pod was killed"
  fi
  pass "chaos: one echo pod killed by Chaos Mesh, $ok/40 requests succeeded (hypothesis held)"
  kubectl -n lab-probe delete podchaos kill-one-echo >/dev/null
}

# echo_client NAME COUNT -> a client pod in lab-probe (allowed identity) sends COUNT requests to echo,
# 2 s timeout each, and prints "ok=<successes> median_ms=<median latency of the successes>".
echo_client() {
  local name=$1 count=$2 phase="" i
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  serviceAccountName: client
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: $CURL_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          sleep 2; ok=0; times=""
          for i in \$(seq 1 $count); do
            out=\$(curl -s -m 2 -o /dev/null -w '%{http_code} %{time_total}' http://echo.lab-probe:8080/hostname) || out="000 0"
            set -- \$out
            if [ "\$1" = 200 ]; then ok=\$((ok + 1)); times="\$times \$2"; fi
            sleep 0.3
          done
          median=\$(printf '%s\n' \$times | sort -n | awk 'NF { a[++n] = \$1 } END { if (n) printf "%d", a[int((n + 1) / 2)] * 1000; else print 0 }')
          echo "ok=\$ok median_ms=\$median"
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  for i in $(seq 1 120); do
    phase="$(kubectl -n lab-probe get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  kubectl -n lab-probe logs "$name" 2>&1 | tail -n 1
  kubectl -n lab-probe delete pod "$name" --wait=false >/dev/null 2>&1
  [[ "$phase" == Succeeded ]]
}

# chaos_injected KIND NAME -> waits until Chaos Mesh reports the experiment injected on every target.
chaos_injected() {
  local i status
  for i in $(seq 1 60); do
    status="$(kubectl -n lab-probe get "$1" "$2" -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}' 2>/dev/null)" || status=""
    [[ "$status" == True ]] && return 0
    sleep 2
  done
  return 1
}

# Hypothesis: with 100 ms of extra network latency on every echo pod, at least 19 of 20 requests still
# succeed within the 2 s timeout, and the median latency grows by at least 80 ms (the fault is real).
check_chaos_latency() {
  local out ok base chaos
  out="$(echo_client latency-before 10)" || die "chaos: the baseline client failed ($out)"
  base="$(sed -n 's/.*median_ms=//p' <<<"$out")"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: delay-echo
spec:
  action: delay
  mode: all
  selector:
    namespaces: [lab-probe]
    labelSelectors:
      app.kubernetes.io/name: echo
  delay:
    latency: 100ms
    jitter: 0ms
    correlation: "0"
  direction: to
  duration: 180s
EOF
  chaos_injected networkchaos delay-echo || die "chaos: the NetworkChaos delay-echo was not injected"
  out="$(echo_client latency-during 20)" || die "chaos: the client under latency failed ($out)"
  kubectl -n lab-probe delete networkchaos delay-echo >/dev/null
  ok="$(sed -n 's/^ok=\([0-9]*\).*/\1/p' <<<"$out")"
  chaos="$(sed -n 's/.*median_ms=//p' <<<"$out")"
  [[ "$ok" =~ ^[0-9]+$ && "$base" =~ ^[0-9]+$ && "$chaos" =~ ^[0-9]+$ ]] || die "chaos: unexpected client output '$out'"
  ((ok >= 19)) || die "chaos: hypothesis refuted, only $ok/20 requests succeeded with 100 ms of extra latency"
  ((chaos >= base + 80)) || die "chaos: the latency was not injected (median $base ms -> $chaos ms)"
  pass "chaos: 100 ms of network latency on every echo pod (NetworkChaos): $ok/20 requests succeeded, median $base -> $chaos ms (hypothesis held)"
}

# restarts_of_echo -> total container restarts of the echo pods.
restarts_of_echo() {
  kubectl -n lab-probe get pods -l app.kubernetes.io/name=echo \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{ n += $1 } END { print n + 0 }'
}

# Hypothesis: with a CPU and a memory stressor inside every echo container (StressChaos), at least 38
# of 40 requests succeed and no container is killed (the memory stays under the 64 Mi limit); the peak
# CPU that metrics-server reports proves the stress ran.
check_chaos_stress() {
  local before name=stress-client out ok cpu mem peak_cpu=0 peak_mem=0 phase="" i
  before="$(restarts_of_echo)"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: StressChaos
metadata:
  name: stress-echo
spec:
  mode: all
  selector:
    namespaces: [lab-probe]
    labelSelectors:
      app.kubernetes.io/name: echo
  stressors:
    cpu:
      workers: 1
      load: 100
    memory:
      workers: 1
      size: 24MB
  duration: 120s
EOF
  chaos_injected stresschaos stress-echo || die "chaos: the StressChaos stress-echo was not injected"
  kubectl -n lab-probe apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels:
    app.kubernetes.io/name: $name
spec:
  serviceAccountName: client
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    runAsGroup: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: $CURL_IMAGE
      command: ["sh", "-c"]
      args:
        - |
          ok=0
          for i in \$(seq 1 40); do
            curl -s -m 2 -o /dev/null -w '%{http_code}' http://echo.lab-probe:8080/hostname | grep -q 200 && ok=\$((ok + 1))
            sleep 1
          done
          echo "ok=\$ok"
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 32Mi
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
EOF
  # metrics-server refreshes every 15 s: sample the peak while the client runs (about 45 s).
  for i in $(seq 1 90); do
    while read -r _ cpu mem; do
      cpu="${cpu%m}"
      mem="${mem%Mi}"
      [[ "$cpu" =~ ^[0-9]+$ ]] && ((cpu > peak_cpu)) && peak_cpu=$cpu
      [[ "$mem" =~ ^[0-9]+$ ]] && ((mem > peak_mem)) && peak_mem=$mem
    done < <(kubectl -n lab-probe top pods -l app.kubernetes.io/name=echo --no-headers 2>/dev/null || :)
    phase="$(kubectl -n lab-probe get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)" || phase=""
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 1
  done
  out="$(kubectl -n lab-probe logs "$name" 2>&1 | tail -n 1)"
  kubectl -n lab-probe delete pod "$name" --wait=false >/dev/null 2>&1
  kubectl -n lab-probe delete stresschaos stress-echo >/dev/null
  ok="$(sed -n 's/^ok=//p' <<<"$out")"
  [[ "$ok" =~ ^[0-9]+$ ]] || die "chaos: unexpected client output under stress '$out'"
  ((ok >= 38)) || die "chaos: hypothesis refuted, only $ok/40 requests succeeded under CPU and memory stress"
  ((peak_cpu >= 200)) || die "chaos: the stress did not show in metrics-server (peak CPU ${peak_cpu}m)"
  [[ "$(restarts_of_echo)" == "$before" ]] || die "chaos: an echo container restarted under stress (OOM kill?)"
  pass "chaos: CPU and memory stress in every echo pod (StressChaos, peak ${peak_cpu}m CPU, ${peak_mem}Mi): $ok/40 requests succeeded, no restart (hypothesis held)"
}

main() {
  require_cmd kubectl docker curl terraform helm git ssh openssl
  require_lab_context
  kubectl version >/dev/null 2>&1 || die "the lab cluster is not reachable (run: scripts/local-lab.sh up)"
  WORK_DIR="$(mktemp -d)"
  trap cleanup EXIT
  check_database
  probe_namespaces
  deploy_echo
  check_mesh
  check_gateway
  check_waf
  check_acme
  check_external_secrets
  check_metrics_server
  if installed kube-prometheus-stack monitoring; then
    check_prometheus
    check_alerting
    check_loki
    check_grafana
    check_tracing
  fi
  installed argocd argocd && check_gitops
  installed gatekeeper gatekeeper-system && check_policies
  installed trivy-operator trivy-system && check_trivy
  installed velero velero && check_backup
  if installed chaos-mesh chaos-mesh; then
    check_chaos
    check_chaos_latency
    check_chaos_stress
  fi
  printf 'SUMMARY: local platform probes: %d passed\n' "$PASSED"
}

main "$@"
