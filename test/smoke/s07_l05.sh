#!/usr/bin/env bash
# lesson: s07_l05 Argo CD project roles and tokens: scoped CI credentials instead of cluster-admin
# Project roles and tokens: automation that isn't cluster-admin.
#
# The claim: a project role token granted two policies on one project (`get`, then `sync`, on
# `checkout`) syncs apps in that one project, and is denied everywhere else: including a
# different project's app, which the token's role never named at all. On Argo CD 3.5.3 a role holding
# only `sync` is refused the sync too: the token also needs `get` to see the Application.
#
# This lesson tests Argo CD's OWN internal RBAC (policy evaluated by argocd-server against a
# token), which only fires through the real API: a kubectl-only test would bypass it entirely.
# The lesson logs in against `argocd.local`, the TLS gateway built in s02_l09.sh, and so does this script.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L05 "a project role token scoped to get and sync on one project works there and is denied everywhere else, including a different project's app"
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
# The probe projects whitelist no cluster-scoped kinds, so a sync cannot create its namespace (CreateNamespace
# adds a Namespace object the project refuses). The namespaces are created here, as an operator would.
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "${NS_OUT}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH: project-role tokens and their enforcement only exist behind the real API, not kubectl"
fi

step "fence a throwaway project, and register one in-scope app and one out-of-scope app (different project)"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "Smoke-test probe: not the real checkout project."
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
  source: {repoURL: "${REPO}", targetRevision: baseline/before-rollouts, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {syncOptions: []}
EOF
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_OUT}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: baseline/before-rollouts, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS_OUT}"}
  syncPolicy: {syncOptions: []}
EOF

step "reach argocd-server through argocd.local, the lesson's own route"
# The lesson logs in through argocd.local (Do.md, S02-L09 step 12): Traefik terminates TLS on 443 with a
# self-signed certificate, and argocd-server behind it runs insecure.
SCHEME=https; LOGIN_TLS="--insecure"
up="no"
for _ in $(seq 1 20); do
  curl -sk "${SCHEME}://argocd.local/healthz" >/dev/null 2>&1 && { up="yes"; break; }
  sleep 1
done
[ "${up}" = "yes" ] || _fail "argocd-server never answered through argocd.local: cannot test RBAC without the real API"

ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster: cannot obtain admin credentials"
argocd login argocd.local ${LOGIN_TLS} --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
_pass "logged in as admin through argocd.local"

step "create an empty role, grant it get and then sync, and issue a token"
argocd proj role create "${PROJ}" "${ROLE}" --grpc-web >/dev/null
argocd proj role add-policy "${PROJ}" "${ROLE}" -a get -o '*' --grpc-web >/dev/null
argocd proj role add-policy "${PROJ}" "${ROLE}" -a sync -o '*' --grpc-web >/dev/null
# The CLI prints "  Token: <jwt>" on its own line after the ID and expiry lines: take the value after the label.
TOKEN="$(argocd proj role create-token "${PROJ}" "${ROLE}" --grpc-web 2>/dev/null | awk '/Token:/{print $2}')"
[ -n "${TOKEN}" ] || _fail "no token came back from 'argocd proj role create-token'"
_pass "role ${ROLE} created with two policies (get, *) and (sync, *), and a token issued"

step "the token syncs the in-scope app"
if argocd app sync "${APP_IN}" --grpc-web --auth-token "${TOKEN}" >/dev/null 2>&1; then
  _pass "token synced ${APP_IN}, inside its own project: exactly what its two policy lines grant"
else
  _fail "the token could not sync ${APP_IN}, which its own role's get/* and sync/* policies should cover"
fi

step "the SAME token is denied on an app in a different project"
if argocd app sync "${APP_OUT}" --grpc-web --auth-token "${TOKEN}" >/dev/null 2>&1; then
  _fail "the ${PROJ}-scoped token synced ${APP_OUT}, which belongs to a different project: the role has no policy line naming that project"
else
  _pass "token denied on ${APP_OUT}: the role's reach stops at its own project, exactly as the lesson claims"
fi

smoke_done
