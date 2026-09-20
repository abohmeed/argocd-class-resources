#!/usr/bin/env bash
# S14 L02 — an AppProject's sourceRepos/destinations pair is default-deny: retargeting an
# Application outside the allowed namespace pattern is REFUSED by the API, not merely hidden
# in a UI. The SSO/RBAC half of this lesson (Dex→Authentik, federated_claims.user_id, the
# Argo-CD-3.0 logs permission) needs a live identity provider this checkout cannot stand up, so
# that half is declared rather than faked.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S14-L02 "an AppProject's destinations pattern refuses a retarget outside it — a real fence, not a UI hint"
tier cluster

step "repo-tier: teams/checkout/appproject.yaml scopes destinations to checkout-*, with no cluster-scoped resources allowed"
assert_exists_file "teams/checkout/appproject.yaml"
assert_file_contains "teams/checkout/appproject.yaml" 'namespace: checkout-\*' \
  "checkout's AppProject destinations pattern is checkout-*"
assert_file_contains "teams/checkout/appproject.yaml" 'clusterResourceWhitelist: \[\]' \
  "checkout's AppProject grants no cluster-scoped resources by default"
assert_exists_file "teams/checkout/rbac-policy.csv.snippet"
assert_file_contains "teams/checkout/rbac-policy.csv.snippet" 'p, role:checkout-lead, logs, get, checkout/\*, allow' \
  "checkout's RBAC snippet grants the post-3.0 logs resource explicitly — update/delete alone would not"

PROJ="s14l02-fence"
APP="s14l02-fence-probe"
NS="s14l02-fence-probe"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "build a scratch AppProject with the same default-deny shape, and an Application inside it"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  sourceRepos: ["https://github.com/abohmeed/argocd-class-resources.git"]
  destinations:
    - server: "https://kubernetes.default.svc"
      namespace: "${NS}"
  clusterResourceWhitelist: []
EOF
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "https://github.com/abohmeed/argocd-class-resources.git", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {syncOptions: ["CreateNamespace=true"]}
EOF
wait_for_sync "${APP}" 120

step "retargeting it OUTSIDE the project's allowed namespace is refused, not silently accepted"
out="$(kubectl patch application "${APP}" -n argocd --type merge \
  -p '{"spec":{"destination":{"namespace":"argocd"}}}' 2>&1)" && rc=0 || rc=$?
current_ns="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)"
if [ "${rc}" -ne 0 ] || [ "${current_ns}" != "argocd" ]; then
  _pass "the AppProject fence held — the Application was not retargeted to a namespace outside its allowed pattern"
else
  _fail "the retarget to 'argocd' namespace SUCCEEDED against a project scoped to '${NS}' only — the fence this lesson builds did not hold:\n${out}"
fi

smoke_done
