#!/usr/bin/env bash
# S12 L10 — a stuck PreSync hook is diagnosable by name (a missing image-pull secret), not just
# "stuck"; and ignoreDifferences alone does not stop selfHeal reverting a re-applied field away —
# it needs RespectIgnoreDifferences too, proven against a real, reconciling Application.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L10 "a stuck PreSync hook names its own blocker, and ignoreDifferences alone does not stop selfHeal reverting a flapped field"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

HOOK_NS="s12l10-hook"
APP="s12l10-probe"
NS="s12l10-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  [ -n "${FLAP_PID:-}" ] && kill "${FLAP_PID}" >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "${HOOK_NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "a PreSync hook missing its image-pull secret is diagnosable by name, not just stuck"
kubectl create namespace "${HOOK_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "${HOOK_NS}" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: stuck-hook
  annotations:
    argocd.argoproj.io/hook: PreSync
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: registry-creds-that-do-not-exist
      containers:
        - name: migrate
          image: ghcr.io/northwind/does-not-matter:1.0
          command: ["true"]
EOF
sleep 8
pod_events="$(kubectl describe pod -n "${HOOK_NS}" -l job-name=stuck-hook 2>/dev/null | grep -A3 Events || true)"
if printf '%s' "${pod_events}" | grep -qi 'registry-creds-that-do-not-exist'; then
  _pass "the hook pod's own Events name the missing image-pull secret — diagnosable, not just hung"
else
  _fail "expected the hook pod's Events to name 'registry-creds-that-do-not-exist':\n${pod_events}"
fi
succ="$(kubectl get job stuck-hook -n "${HOOK_NS}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
[ "${succ}" = "1" ] && _fail "the hook Job unexpectedly succeeded — it should be unable to complete without the secret" \
  || _pass "the hook Job has not completed — this is what 'stuck' looks like, distinct from 'failed'"

step "wire up a real Application, automated + selfHeal, watching apps/storefront/base"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {selfHeal: true}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 180

step "a repeatedly re-applied label IS reverted by selfHeal alone — the flap this lesson opens on"
(
  while true; do
    kubectl -n "${NS}" patch deployment storefront --type=json \
      -p='[{"op":"add","path":"/spec/template/metadata/labels/injected-by","value":"webhook-sim"}]' \
      >/dev/null 2>&1
    sleep 4
  done
) &
FLAP_PID=$!
sleep 45
kill "${FLAP_PID}" >/dev/null 2>&1 || true
FLAP_PID=""
sleep 20
still_present="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.spec.template.metadata.labels.injected-by}' 2>/dev/null || true)"
if [ -z "${still_present}" ]; then
  _pass "with plain selfHeal and no ignoreDifferences, the flapped label was reverted away — reproduces the lesson's opener"
else
  _fail "the flapped label is still present after selfHeal had time to revert it — the opener does not reproduce"
fi

step "ignoreDifferences + RespectIgnoreDifferences stops selfHeal from stripping the field back out"
kubectl -n argocd patch application "${APP}" --type merge -p '
spec:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/template/metadata/labels/injected-by
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
    - RespectIgnoreDifferences=true
' >/dev/null

kubectl -n "${NS}" patch deployment storefront --type=json \
  -p='[{"op":"add","path":"/spec/template/metadata/labels/injected-by","value":"webhook-sim"}]' >/dev/null
argocd app sync "${APP}" >/dev/null 2>&1 || kubectl -n argocd annotate application "${APP}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sleep 30

survived="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.spec.template.metadata.labels.injected-by}' 2>/dev/null || true)"
if [ "${survived}" = "webhook-sim" ]; then
  _pass "with ignoreDifferences AND RespectIgnoreDifferences, a sync no longer strips the field back out"
else
  _fail "the field was still removed even with ignoreDifferences + RespectIgnoreDifferences set — the fix this lesson teaches does not hold on this cluster"
fi

smoke_done
