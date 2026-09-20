#!/usr/bin/env bash
# S10 L02 — the Rollout CRD: a separate project, wired to the same cluster.
#
# The claim is behavioural: Argo Rollouts is installed SEPARATELY from Argo CD (its own CRDs,
# its own controller), and once installed, a Rollout's PodTemplateSpec is identical to a
# Deployment's — converting one to the other changes nothing about how the pod runs. This drives
# a real Deployment through a real conversion to a real Rollout with an empty canary{} strategy
# (S10 L02's own placeholder, replaced by a real strategy in L03/L04) and watches it reach
# Healthy. Single cluster throughout — S10 never leaves the hub — so this runs at cluster tier.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S10-L02 "Argo Rollouts installs separately from Argo CD, and a Rollout's PodTemplateSpec is identical to a Deployment's"
tier cluster

NS="s10l02-probe"
NAME="storefront-probe"

cleanup() {
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

poll_rollout_healthy() {
  local name="$1" ns="$2" timeout="${3:-180}" deadline phase=""
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    phase="$(kubectl get rollout "${name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "Healthy" ] && return 0
    sleep 5
  done
  _fail "${name} did not reach Healthy within ${timeout}s (last phase: ${phase:-?})"
}

step "install Argo Rollouts ${ARGO_ROLLOUTS_VERSION} — a separate project, a separate controller"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml" >/dev/null
wait_for_rollout "deployment/argo-rollouts" "argo-rollouts"

step "set up the probe: a plain Deployment on the pinned http-echo image"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
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
          args: ["-listen=:5678", "-text=probe-v1"]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
EOF
wait_for_rollout "deployment/${NAME}" "${NS}"

step "convert to a Rollout — same PodTemplateSpec, only kind and strategy move"
kubectl delete deployment "${NAME}" -n "${NS}" >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
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
          args: ["-listen=:5678", "-text=probe-v1"]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 32Mi}}
  strategy:
    canary: {}
EOF

step "the Rollout reaches Healthy on the same pod template, no ImagePullBackOff, no CRD-health gap"
poll_rollout_healthy "${NAME}" "${NS}" 180
ready="$(kubectl get rollout "${NAME}" -n "${NS}" -o jsonpath='{.status.readyReplicas}')"
[ "${ready}" = "1" ] && _pass "1 ready replica under the Rollout, converted from the Deployment with no template change" \
  || _fail "expected 1 ready replica after conversion, got '${ready}'"

smoke_done
