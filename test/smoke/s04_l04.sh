#!/usr/bin/env bash
# S04 L04 — Argo CD renders a Helm chart itself; it never runs `helm install`.
#
# The lesson's surprise ("helm list shows nothing") is not really about the `helm list` command
# — it's about WHY. Argo CD's repo-server calls Helm as a library to inflate the chart (the
# equivalent of `helm template`), then applies the resulting manifests itself, so it never
# creates the release object (a Secret labelled owner=helm) that `helm list` actually reads
# from. Asserting the command's raw output is fragile — a namespace someone `helm install`ed
# into out of band can make `helm list` non-empty for reasons that have nothing to do with this
# lesson. Asserting the REASON — no release object exists even though the Deployment is real
# and healthy — is what actually fails if Argo CD's Helm integration ever changed to behave
# like the CLI.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L04 "Argo CD renders a Helm chart without ever creating a Helm release object, which is why helm list sees nothing"
tier cluster

APP="s04l04-storefront-helm"
NS="s04l04-storefront-helm"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "the chart this lesson builds is actually committed"
assert_exists_file "charts/storefront/Chart.yaml"
assert_exists_file "charts/storefront/values.yaml"

step "sync a Helm-sourced Application through Argo CD"
cat <<APPEOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: charts/storefront}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
APPEOF
wait_for_sync "${APP}" 240
wait_for_rollout deployment/storefront "${NS}"

step "the pods are real and healthy — this is not a surprise about something that never deployed"
running="$(kubectl get pods -n "${NS}" -l app.kubernetes.io/name=storefront \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
[ "${running}" -gt 0 ] && _pass "${running} pod(s) Running in ${NS}" \
  || _fail "no Running storefront pod in ${NS} — the chart never actually deployed"

step "no Helm release object exists in the namespace — Argo CD never ran helm install"
release_objects="$(kubectl get secret -n "${NS}" -l owner=helm -o name 2>/dev/null | wc -l | tr -d ' ')"
if [ "${release_objects}" -eq 0 ]; then
  _pass "no owner=helm release Secret in ${NS} — this is WHY helm list sees nothing, not a coincidence"
else
  _fail "a Helm release object exists in ${NS} — Argo CD's Helm source is now creating releases the way the CLI does, and this lesson's whole surprise is gone"
fi

step "helm list itself confirms the same thing, for the on-camera moment"
if command -v helm >/dev/null 2>&1; then
  out="$(helm list -n "${NS}" --short 2>/dev/null || true)"
  [ -z "${out}" ] && _pass "helm list -n ${NS} is empty" \
    || _fail "helm list -n ${NS} unexpectedly shows a release: ${out}"
else
  _fail "helm binary not on PATH — this cluster-tier lesson needs it (see runbook Preconditions)"
fi

smoke_done
