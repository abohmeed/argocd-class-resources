#!/usr/bin/env bash
# S10 L03 — blue/green: the preview Service verifies before promotion, and abort snaps back.
#
# The claim is behavioural, not textual: activeService keeps serving the OLD version until a
# human promotes; previewService exposes the NEW version for verification first; a blind
# promotion (no verification) can ship a broken version to real traffic, and abort snaps it back
# instantly because Argo Rollouts holds the previous ReplicaSet rather than scaling it to zero.
# Single cluster throughout, so this runs at cluster tier — it drives the actual sequence the
# runbook narrates: wrong version promoted blind, aborted, then done properly.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S10-L03 "blue/green holds the old version on activeService until promoted, previewService exposes the new one first, and abort snaps traffic back"
tier cluster

NS="s10l03-probe"
NAME="storefront-probe"
PLUGIN_DIR="$(mktemp -d)"

cleanup() {
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${PLUGIN_DIR}"
}
trap cleanup EXIT

poll_ready_replicas() {
  local name="$1" ns="$2" want="$3" timeout="${4:-180}" deadline got=""
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    got="$(kubectl get rollout "${name}" -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    [ "${got}" = "${want}" ] && return 0
    sleep 5
  done
  _fail "${name} never reached ${want} ready replicas within ${timeout}s (last: ${got:-?})"
}

curl_in() {
  local svc="$1"
  kubectl run "curlcheck-${RANDOM}" --rm -i --restart=Never -n "${NS}" \
    --image=curlimages/curl:8.11.0 -- curl -s --max-time 10 "http://${svc}" 2>/dev/null || true
}

step "install Argo Rollouts ${ARGO_ROLLOUTS_VERSION} and the kubectl plugin (needed to promote/abort)"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml" >/dev/null
wait_for_rollout "deployment/argo-rollouts" "argo-rollouts"
OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
curl -sL -o "${PLUGIN_DIR}/kubectl-argo-rollouts" \
  "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/kubectl-argo-rollouts-${OS}-${ARCH}"
chmod +x "${PLUGIN_DIR}/kubectl-argo-rollouts"
export PATH="${PLUGIN_DIR}:${PATH}"
kubectl argo rollouts version >/dev/null || _fail "kubectl argo rollouts plugin did not install"

step "stand up a blueGreen Rollout at v1"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: {name: ${NAME}-active, namespace: ${NS}}
spec: {selector: {app: ${NAME}}, ports: [{name: http, port: 80, targetPort: http}]}
---
apiVersion: v1
kind: Service
metadata: {name: ${NAME}-preview, namespace: ${NS}}
spec: {selector: {app: ${NAME}}, ports: [{name: http, port: 80, targetPort: http}]}
---
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: ${NAME}, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${NAME}}}
  template:
    metadata: {labels: {app: ${NAME}}}
    spec:
      containers:
        - name: storefront
          image: ${HTTP_ECHO_IMAGE}
          args: ["-listen=:5678", "-text=\$(BANNER)"]
          env: [{name: BANNER, value: "probe-v1"}]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
  strategy:
    blueGreen:
      activeService: ${NAME}-active
      previewService: ${NAME}-preview
      autoPromotionEnabled: false
EOF
poll_ready_replicas "${NAME}" "${NS}" 1 180
[ "$(curl_in "${NAME}-active")" = "probe-v1" ] && _pass "active service serves v1" || _fail "active service did not serve v1 before any rollout"

step "roll forward a WRONG version — active must still serve v1 until promoted"
kubectl patch rollout "${NAME}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"probe-v2-WRONG"}]' >/dev/null
poll_ready_replicas "${NAME}" "${NS}" 2 180
[ "$(curl_in "${NAME}-active")" = "probe-v1" ] && _pass "active service still serves v1 — nothing promoted yet" \
  || _fail "active service changed before promotion — blue/green did not hold"
[ "$(curl_in "${NAME}-preview")" = "probe-v2-WRONG" ] && _pass "preview service serves the new (wrong) version, verifiable before promotion" \
  || _fail "preview service did not serve the new version"

step "promote blind — the wrong version reaches real traffic, exactly the blind spot this lesson opens on"
kubectl argo rollouts promote "${NAME}" -n "${NS}" >/dev/null
sleep 3
[ "$(curl_in "${NAME}-active")" = "probe-v2-WRONG" ] && _pass "blind promotion shipped the wrong version to active traffic" \
  || _fail "expected the blind promotion to ship the wrong version — blue/green semantics changed"

step "abort — traffic snaps back instantly because the previous ReplicaSet was never scaled to zero"
kubectl argo rollouts abort "${NAME}" -n "${NS}" >/dev/null
sleep 3
[ "$(curl_in "${NAME}-active")" = "probe-v1" ] && _pass "abort snapped active traffic back to v1" \
  || _fail "abort did not restore v1 — the lesson's central abort behaviour does not reproduce; RESTAGE BEFORE RECORDING"

step "do it properly: fix it, verify preview, then promote"
kubectl patch rollout "${NAME}" -n "${NS}" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"probe-v2"}]' >/dev/null
poll_ready_replicas "${NAME}" "${NS}" 2 180
[ "$(curl_in "${NAME}-preview")" = "probe-v2" ] && _pass "preview verified correct before promoting" \
  || _fail "preview did not serve the corrected version"
kubectl argo rollouts promote "${NAME}" -n "${NS}" >/dev/null
sleep 3
[ "$(curl_in "${NAME}-active")" = "probe-v2" ] && _pass "verified promotion shipped the correct version" \
  || _fail "active did not serve v2 after a verified promotion"

smoke_done
