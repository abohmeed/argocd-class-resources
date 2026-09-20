#!/usr/bin/env bash
# S07 L07 — the 3.0 breaking change: RBAC stops inheriting to sub-resources.
#
# The claim: a policy granting update/delete on `applications` alone no longer reaches the Pods,
# Deployments and Services an Application manages — since Argo CD 3.0 that inheritance is gone.
# Deleting a managed Pod is refused until the policy adds the explicit `update/*`/`delete/*`
# wildcard actions. This is CLI-testable end to end via `argocd app delete-resource`, which is the
# same RPC the UI's Pod-actions-menu Delete button calls — no browser needed to exercise the claim,
# even though the runbook records it through the UI for the viewer's benefit.
#
# Same port-forward-to-argocd-server approach as S07 L05/L06: the runbook's `argocd.local` assumes
# the producer's TLS gateway (S02 L06), which the bare CI cluster never builds.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L07 "since Argo CD 3.0, update/delete on applications alone no longer reaches a managed Pod — only the explicit update/* and delete/* wildcard actions do"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l07-probe"
NS="s07l07-probe"
APP="s07l07-app"
ACCOUNT="s07l07-probe"
SUBJECT_ROLE="role:s07l07-lead"
PASSWORD="Throwaway-CI-Only-1!"
PF_PID=""
PORT=18207

restore_rbac_cm() {
  kubectl patch configmap argocd-rbac-cm -n argocd --type json \
    -p '[{"op":"remove","path":"/data/policy.csv"}]' >/dev/null 2>&1 || true
}

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/accounts.${ACCOUNT}\"}]" >/dev/null 2>&1 || true
  restore_rbac_cm
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — application-vs-sub-resource RBAC is only enforced behind the real API"
fi

step "fence a throwaway project, sync a throwaway app so it has a real Pod, and a throwaway account"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L07 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {automated: {}, syncOptions: ["CreateNamespace=true"]}
EOF
wait_for_sync "${APP}" 180
POD_NAME="$(kubectl get pods -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${POD_NAME}" ] || _fail "no Pod found in ${NS} after a reported sync — nothing to test the delete against"
_pass "target Pod is ${POD_NAME}"

kubectl patch configmap argocd-cm -n argocd --type merge -p \
  "{\"data\":{\"accounts.${ACCOUNT}\":\"login\"}}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p \
  "{\"data\":{\"policy.csv\":\"p, ${SUBJECT_ROLE}, applications, update, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete, ${PROJ}/*, allow\ng, ${ACCOUNT}, ${SUBJECT_ROLE}\"}}" >/dev/null

step "reach argocd-server and set the account's password"
kubectl -n argocd port-forward svc/argocd-server "${PORT}:443" >/tmp/s07l07-portforward.log 2>&1 &
PF_PID=$!
up="no"
for _ in $(seq 1 20); do curl -sk "https://localhost:${PORT}/healthz" >/dev/null 2>&1 && { up="yes"; break; }; sleep 1; done
[ "${up}" = "yes" ] || _fail "argocd-server never answered on the port-forward"
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
argocd account update-password --account "${ACCOUNT}" --new-password "${PASSWORD}" \
  --current-password "${ADMIN_PW}" --grpc-web >/dev/null

step "pre-3.0-shaped policy (applications: update, delete only) — deleting the managed Pod is refused"
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
if argocd app delete-resource "${APP}" --kind Pod --resource-name "${POD_NAME}" --namespace "${NS}" --grpc-web >/dev/null 2>&1; then
  _fail "the account deleted a managed Pod with only 'applications update/delete' granted — 3.0's sub-resource inheritance removal is not in effect"
else
  _pass "Pod delete refused — applications-level update/delete does not reach a managed sub-resource"
fi
if argocd app set "${APP}" --dest-namespace "${NS}" --grpc-web >/dev/null 2>&1; then
  _pass "the Application object itself is still reachable (a no-op update succeeds) — only what it manages is out of reach, not the Application"
else
  _fail "even a no-op update to the Application object was refused — the account's applications-level update policy is not working at all, which breaks the contrast this lesson makes"
fi
if ! kubectl get pod "${POD_NAME}" -n "${NS}" >/dev/null 2>&1; then
  _fail "the Pod is gone despite the delete being refused — investigate before trusting this script's earlier pass"
fi

step "add the explicit update/* and delete/* wildcard actions — the same delete now succeeds"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p \
  "{\"data\":{\"policy.csv\":\"p, ${SUBJECT_ROLE}, applications, update, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, update/*, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete/*, ${PROJ}/*, allow\ng, ${ACCOUNT}, ${SUBJECT_ROLE}\"}}" >/dev/null
sleep 5
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
if argocd app delete-resource "${APP}" --kind Pod --resource-name "${POD_NAME}" --namespace "${NS}" --grpc-web >/dev/null 2>&1; then
  _pass "with update/* and delete/* granted, the same Pod delete now succeeds"
else
  _fail "delete-resource still refused after adding the explicit sub-resource wildcard actions"
fi

smoke_done
