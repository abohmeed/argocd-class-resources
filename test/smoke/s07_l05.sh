#!/usr/bin/env bash
# S07 L05 — project roles and tokens: automation that isn't cluster-admin.
#
# The claim: a project role token granted exactly one action on one project (`sync` on `checkout`)
# works for that one thing, in that one project, and is denied everywhere else — including a
# different project's app, which the token's role never named at all.
#
# This lesson tests Argo CD's OWN internal RBAC (policy evaluated by argocd-server against a
# token), which only fires through the real API — a kubectl-only test would bypass it entirely.
# The runbook logs in against `argocd.local`, the producer's TLS gateway from S02 L06; a bare CI
# cluster (see test/smoke/s02_control_plane.sh) never builds that gateway, so this port-forwards
# straight to the argocd-server Service instead. Same RBAC evaluation, no gateway dependency.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L05 "a project role token scoped to one action on one project works there and is denied everywhere else, including a different project's app"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l05-probe"
NS="s07l05-probe"
NS_OUT="s07l05-outscope"
APP_IN="s07l05-inscope"
APP_OUT="s07l05-outscope"
ROLE="ci-sync-probe"
PF_PID=""
PORT=18205

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  kubectl delete application "${APP_IN}" "${APP_OUT}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" "${NS_OUT}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — project-role tokens and their enforcement only exist behind the real API, not kubectl"
fi

step "fence a throwaway project, and register one in-scope app and one out-of-scope app (different project)"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L05 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_IN}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {syncOptions: ["CreateNamespace=true"]}
EOF
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_OUT}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS_OUT}"}
  syncPolicy: {syncOptions: ["CreateNamespace=true"]}
EOF

step "reach argocd-server directly (no producer TLS gateway on a bare CI cluster)"
kubectl -n argocd port-forward svc/argocd-server "${PORT}:443" >/tmp/s07l05-portforward.log 2>&1 &
PF_PID=$!
up="no"
for _ in $(seq 1 20); do
  curl -sk "https://localhost:${PORT}/healthz" >/dev/null 2>&1 && { up="yes"; break; }
  sleep 1
done
[ "${up}" = "yes" ] || _fail "argocd-server never answered on the port-forward — cannot test RBAC without the real API"

ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster — cannot obtain admin credentials"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
_pass "logged in as admin over the port-forward"

step "create an empty role, grant it exactly one action, and issue a token"
argocd proj role create "${PROJ}" "${ROLE}" --grpc-web >/dev/null
argocd proj role add-policy "${PROJ}" "${ROLE}" -a sync -o '*' --grpc-web >/dev/null
TOKEN="$(argocd proj role create-token "${PROJ}" "${ROLE}" --grpc-web 2>/dev/null | tail -1 | tr -d '[:space:]')"
[ -n "${TOKEN}" ] || _fail "no token came back from 'argocd proj role create-token'"
_pass "role ${ROLE} created with one policy (sync, *) and a token issued"

step "the token syncs the in-scope app"
if argocd app sync "${APP_IN}" --grpc-web --auth-token "${TOKEN}" >/dev/null 2>&1; then
  _pass "token synced ${APP_IN}, inside its own project — exactly what the one policy line grants"
else
  _fail "the token could not sync ${APP_IN}, which its own role's sync/* policy should cover"
fi

step "the SAME token is denied on an app in a different project"
if argocd app sync "${APP_OUT}" --grpc-web --auth-token "${TOKEN}" >/dev/null 2>&1; then
  _fail "the ${PROJ}-scoped token synced ${APP_OUT}, which belongs to a different project — the role has no policy line naming it"
else
  _pass "token denied on ${APP_OUT} — the role's reach stops at its own project, exactly as the lesson claims"
fi

smoke_done
