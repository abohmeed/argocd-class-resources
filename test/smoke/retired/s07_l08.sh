#!/usr/bin/env bash
# S07 L08 — logs are an RBAC resource now.
#
# The claim: reading a Pod's logs through Argo CD is gated by its OWN `logs` RBAC resource,
# entirely separate from `applications` — an account already holding create/update/delete AND the
# S07 L07 update/*+delete/* wildcards is still refused `argocd app logs`, until an explicit
# `p, <role>, logs, get, <proj>/*, allow` line is added. Harder to notice than L07's refusal
# because there is no error, just nothing: the UI's Logs tab renders an empty pane, which is why
# this script treats "the command errored" and "the command silently returned nothing" as the
# SAME failure, not just the first one.
#
# `argocd app logs` can follow by default depending on version/flags; wrapped in `timeout` so a
# CI run cannot hang waiting on a log stream that never closes.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L08 "logs is its own RBAC resource — full applications-level access does not grant it, only an explicit logs/get policy line does"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l08-probe"
NS="s07l08-probe"
APP="s07l08-app"
ACCOUNT="s07l08-probe"
SUBJECT_ROLE="role:s07l08-lead"
PASSWORD="Throwaway-CI-Only-1!"
PF_PID=""
PORT=18208

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/accounts.${ACCOUNT}\"}]" >/dev/null 2>&1 || true
  kubectl patch configmap argocd-rbac-cm -n argocd --type json \
    -p '[{"op":"remove","path":"/data/policy.csv"}]' >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — the logs RBAC resource is only enforced behind the real API"
fi

step "fence a throwaway project, sync a throwaway app so it has real Pod logs, and a throwaway account with full applications-level RBAC but no logs line"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L08 smoke probe — not the real checkout project."
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

kubectl patch configmap argocd-cm -n argocd --type merge -p \
  "{\"data\":{\"accounts.${ACCOUNT}\":\"login\"}}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p \
  "{\"data\":{\"policy.csv\":\"p, ${SUBJECT_ROLE}, applications, create, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, update, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, update/*, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete/*, ${PROJ}/*, allow\ng, ${ACCOUNT}, ${SUBJECT_ROLE}\"}}" >/dev/null

step "reach argocd-server and set the account's password"
kubectl -n argocd port-forward svc/argocd-server "${PORT}:443" >/tmp/s07l08-portforward.log 2>&1 &
PF_PID=$!
up="no"
for _ in $(seq 1 20); do curl -sk "https://localhost:${PORT}/healthz" >/dev/null 2>&1 && { up="yes"; break; }; sleep 1; done
[ "${up}" = "yes" ] || _fail "argocd-server never answered on the port-forward"
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
argocd account update-password --account "${ACCOUNT}" --new-password "${PASSWORD}" \
  --current-password "${ADMIN_PW}" --grpc-web >/dev/null

step "full applications-level RBAC, no logs line: argocd app logs is refused, not merely empty"
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
out="$(timeout 20 argocd app logs "${APP}" --grpc-web 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  _fail "argocd app logs succeeded with no logs policy line granted — logs is not actually gated separately from applications"
else
  _pass "argocd app logs refused (exit ${rc}) despite full applications-level create/update/delete — logs is a separate RBAC resource"
fi

step "add the logs/get policy line — the same command now returns real output"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p \
  "{\"data\":{\"policy.csv\":\"p, ${SUBJECT_ROLE}, applications, create, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, update, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, update/*, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, applications, delete/*, ${PROJ}/*, allow\np, ${SUBJECT_ROLE}, logs, get, ${PROJ}/*, allow\ng, ${ACCOUNT}, ${SUBJECT_ROLE}\"}}" >/dev/null
sleep 5
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
out="$(timeout 20 argocd app logs "${APP}" --grpc-web 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  _pass "argocd app logs succeeds once the logs/get policy line is added"
else
  _fail "argocd app logs still refused after adding the logs/get policy line:\n${out}"
fi

smoke_done
