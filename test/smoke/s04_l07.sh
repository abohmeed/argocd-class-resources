#!/usr/bin/env bash
# S04 L07 — A single source can't read valueFiles from another repository; spec.sources can.
#
# The lesson's claim is a hard failure/success pair: `helm.valueFiles` on a single `source`
# block can only resolve paths inside THAT source's own repoURL, so pointing it at a file that
# lives in a genuinely different repository fails at sync — a missing-file error, not a
# permissions error. `spec.sources`, with a named `ref:` and a `$values/...` valueFiles entry,
# is what actually reaches across the repository boundary. This drives both attempts against
# the two real, distinct, public companion repositories this course uses for the chart and the
# values (argocd-class-resources and argocd-class-values — confirmed as two separate, reachable
# GitHub repositories, not the same URL twice).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L07 "a single source cannot read valueFiles from a different repository; spec.sources with ref:/\$values can"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

APP="s04l07-storefront-multisource"
NS="s04l07-storefront-multisource"
CHART_REPO="https://github.com/abohmeed/argocd-class-resources.git"
VALUES_REPO="https://github.com/abohmeed/argocd-class-values.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "a single source cannot resolve a valueFiles path that lives in a different repository"
cat <<APPEOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source:
    repoURL: "${CHART_REPO}"
    targetRevision: main
    path: charts/storefront
    helm:
      valueFiles: ["values/storefront/values-prod.yaml"]
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy: {}
APPEOF
out="$(argocd app sync "${APP}" 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qiE 'values-prod\.yaml|no such file|not found'; then
  _pass "single-source sync fails naming the missing values file, not a permissions error"
else
  _fail "single-source sync did not fail the way the lesson claims (rc=${rc}):\n${out}"
fi
kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true

step "spec.sources with ref:/\$values reaches across the repository boundary and actually renders"
cat <<APPEOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  sources:
    - repoURL: "${CHART_REPO}"
      targetRevision: main
      path: charts/storefront
      helm:
        valueFiles: ["\$values/values/storefront/values-prod.yaml"]
    - repoURL: "${VALUES_REPO}"
      targetRevision: HEAD
      ref: values
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
APPEOF
wait_for_sync "${APP}" 240

step "the value that rendered came from the values repository, not the chart's own default"
rendered="$(argocd app manifests "${APP}" 2>/dev/null | grep -A1 'replicas:' | head -2 || true)"
if printf '%s' "${rendered}" | grep -qE 'replicas: [2-9]'; then
  _pass "rendered replicas came from values-prod.yaml, not the chart's own default of 1"
else
  _fail "rendered manifest still shows the chart's own default replica count — the second source's values file was never actually read:\n${rendered}"
fi

step "the two sources stay independent — S04 L04's chart-only Application is untouched"
if argocd app get storefront-helm >/dev/null 2>&1; then
  diff_out="$(argocd app diff storefront-helm 2>&1 || true)"
  [ -z "${diff_out}" ] && _pass "storefront-helm (S04 L04) shows no diff — the values-repo edit did not leak into the chart source" \
    || _fail "storefront-helm shows an unexpected diff after this lesson's edits:\n${diff_out}"
else
  _pass "storefront-helm not present in this run — independence check skipped, nothing to leak into"
fi

smoke_done
