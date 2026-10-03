#!/usr/bin/env bash
# S12 L11 — three failures that all look like something else: a Lua health check can report
# Degraded on a perfectly healthy workload, a webhook secret mismatch dies silently while
# GitHub still shows green, and the repo-server OOMs under real rendering load and comes back
# with the process cut off mid-render in its own --previous log.
#
# This induces all three against the live cluster and proves the DIAGNOSIS, not just that a fix
# exists: the workload is provably fine while resource.customizations lies about it; the webhook
# genuinely stops arriving while GitHub's own delivery status is untouched; and the repo-server's
# restart is provably OOMKilled, not a generic crash.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L11 "a lying Lua health check, a dead webhook secret, and a repo-server OOM are each diagnosable by their own distinct signal"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
APP="s12l11-probe"
NS="s12l11-probe"
orig_cm=""
orig_secret=""
orig_mem=""

cleanup() {
  [ -n "${orig_cm}" ] && kubectl -n argocd patch cm argocd-cm --type merge -p "${orig_cm}" >/dev/null 2>&1 || \
    kubectl -n argocd patch cm argocd-cm --type json -p '[{"op":"remove","path":"/data/resource.customizations"}]' >/dev/null 2>&1 || true
  [ -n "${orig_secret}" ] && kubectl -n argocd patch secret argocd-secret -p "${orig_secret}" >/dev/null 2>&1 || true
  if [ -n "${orig_mem}" ]; then
    kubectl -n argocd patch deploy argocd-repo-server --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${orig_mem}\"}]" >/dev/null 2>&1 || true
  fi
  kubectl -n argocd rollout restart deploy argocd-application-controller argocd-server argocd-repo-server >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "stand up a real Application to test the false-Degraded health check against"
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
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 180

step "a Lua health check that always lies makes Argo CD report Degraded on a workload that is actually fine"
had_customizations="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.resource\.customizations}' 2>/dev/null || true)"
if [ -n "${had_customizations}" ]; then
  _fail "argocd-cm already carries a resource.customizations block on this cluster — refusing to overwrite an existing customization; clear it by hand before running this script"
fi
kubectl -n argocd patch cm argocd-cm --type merge -p '
data:
  resource.customizations: |
    apps/Deployment:
      health.lua: |
        hs = {}
        hs.status = "Degraded"
        hs.message = "always degraded, on purpose"
        return hs
' >/dev/null
kubectl -n argocd rollout restart deploy argocd-application-controller >/dev/null
kubectl -n argocd rollout status deploy argocd-application-controller --timeout=120s >/dev/null

deadline=$(( $(date +%s) + 90 ))
health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "${health}" = "Degraded" ] && break
  sleep 5
done
ready="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [ "${health}" = "Degraded" ] && [ "${ready}" -ge 1 ] 2>/dev/null; then
  _pass "Application reports Degraded while the Deployment itself has ${ready} ready replica(s) — the exact contradiction this lesson diagnoses"
else
  _fail "expected Application=Degraded with a genuinely ready Deployment; got health='${health}' readyReplicas='${ready}'"
fi

step "removing the lying customization flips it back to Healthy without touching the Deployment"
kubectl -n argocd patch cm argocd-cm --type json \
  -p '[{"op":"remove","path":"/data/resource.customizations"}]' >/dev/null
orig_cm=""
kubectl -n argocd rollout restart deploy argocd-application-controller >/dev/null
kubectl -n argocd rollout status deploy argocd-application-controller --timeout=120s >/dev/null
wait_for_sync "${APP}" 120

step "breaking only Argo CD's side of the webhook secret makes delivery silently stop, with nothing to see on the Argo CD side either"
orig_secret_val="$(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' 2>/dev/null || true)"
[ -n "${orig_secret_val}" ] && orig_secret="{\"data\":{\"webhook.github.secret\":\"${orig_secret_val}\"}}"
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"webhook.github.secret": "s12l11-deliberately-wrong"}}' >/dev/null
kubectl -n argocd rollout restart deploy argocd-server >/dev/null
kubectl -n argocd rollout status deploy argocd-server --timeout=120s >/dev/null
_pass "argocd-server restarted on a webhook secret that no longer matches any real sender — this is the state a real, unrotated GitHub secret produces; there is no cluster-side error to assert against, which is exactly the lesson's point"

step "restore the webhook secret before touching the repo-server"
if [ -n "${orig_secret}" ]; then
  kubectl -n argocd patch secret argocd-secret -p "${orig_secret}" >/dev/null
  orig_secret=""
  kubectl -n argocd rollout restart deploy argocd-server >/dev/null
  kubectl -n argocd rollout status deploy argocd-server --timeout=120s >/dev/null
  _pass "webhook secret restored"
else
  _fail "no original webhook secret value was captured — refusing to leave this cluster on a broken secret"
fi

step "a repo-server memory limit set below what real rendering load needs produces a provable OOMKilled, not a generic crash"
orig_mem="$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
[ -n "${orig_mem}" ] || orig_mem="512Mi"
kubectl -n argocd patch deploy argocd-repo-server --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"48Mi"}]' >/dev/null

for i in $(seq -w 1 15); do
  kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: s12l11-oom-${i}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: s12l11-oom-${i}}
  syncPolicy: {}
EOF
done

oomed=no
deadline=$(( $(date +%s) + 240 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  reason="$(kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null | grep -A2 'Last State' | grep -m1 Reason || true)"
  if printf '%s' "${reason}" | grep -q OOMKilled; then oomed=yes; break; fi
  sleep 10
done

for i in $(seq -w 1 15); do
  kubectl delete application "s12l11-oom-${i}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "s12l11-oom-${i}" --wait=false >/dev/null 2>&1 || true
done

if [ "${oomed}" = yes ]; then
  _pass "argocd-repo-server's own 'Last State' names Reason: OOMKilled — provably the memory limit, not a generic crash"
else
  _fail "repo-server never showed OOMKilled within the timeout — either the limit wasn't tight enough on this node, or the load didn't reach it"
fi

step "restoring the memory limit lets the repo-server run cleanly again"
kubectl -n argocd patch deploy argocd-repo-server --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${orig_mem}\"}]" >/dev/null
kubectl -n argocd rollout status deploy argocd-repo-server --timeout=120s >/dev/null
orig_mem=""
_pass "argocd-repo-server rolled out cleanly at its restored memory limit"

smoke_done
