#!/usr/bin/env bash
# S07 L06 — the RBAC model: argocd-rbac-cm, policy syntax, policy.default.
#
# Three claims, staged the way the lesson stages them:
#   1. An account matching no `g` line falls back to `policy.default` alone.
#   2. The runbook's own fact-check gap: bootstrap/install.yaml ships argocd-rbac-cm with NO
#      policy.default key at all, and Argo CD's documented behavior when it's unset is NO ACCESS —
#      not role:readonly. That's worth asserting directly, not assumed away like the runbook does
#      for the sake of a clean take.
#   3. A `p`+`g` line pair grants exactly the one action named — nothing broader.
#
# This is instance-wide RBAC, mutated directly on argocd-rbac-cm/argocd-cm — the same ConfigMaps a
# recording session edits. On the ephemeral, built-from-nothing CI cluster this runs against, that
# is fine; the script still snapshots and restores both ConfigMaps' original values so it is safe
# to run more than once, or alongside S07 L07/L08/L12, on the same cluster.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L06 "unset policy.default means no access (not role:readonly); set to role:readonly it grants read only; a p+g line pair grants exactly the one action it names"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l06-probe"
NS="s07l06-probe"
APP="s07l06-app"
APP2="s07l06-created"
ACCOUNT="s07l06-probe"
SUBJECT_ROLE="role:s07l06-lead"
PASSWORD="Throwaway-CI-Only-1!"
PF_PID=""
PORT=18206

ORIG_CSV=""
ORIG_DEFAULT=""
HAD_CSV="no"
HAD_DEFAULT="no"

restore_rbac_cm() {
  if [ "${HAD_CSV}" = "yes" ]; then
    # jq -Rs . slurps raw stdin into a single, correctly-escaped JSON string — policy.csv is
    # multi-line, and this repo does not use Python anywhere (ADR-016) to do that escaping by hand.
    local csv_json
    csv_json="$(printf '%s' "${ORIG_CSV}" | jq -Rs .)"
    kubectl patch configmap argocd-rbac-cm -n argocd --type merge \
      -p "{\"data\":{\"policy.csv\":${csv_json}}}" >/dev/null 2>&1 || true
  else
    kubectl patch configmap argocd-rbac-cm -n argocd --type json \
      -p '[{"op":"remove","path":"/data/policy.csv"}]' >/dev/null 2>&1 || true
  fi
  if [ "${HAD_DEFAULT}" = "yes" ]; then
    kubectl patch configmap argocd-rbac-cm -n argocd --type merge \
      -p "{\"data\":{\"policy.default\":\"${ORIG_DEFAULT}\"}}" >/dev/null 2>&1 || true
  else
    kubectl patch configmap argocd-rbac-cm -n argocd --type json \
      -p '[{"op":"remove","path":"/data/policy.default"}]' >/dev/null 2>&1 || true
  fi
}

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/accounts.${ACCOUNT}\"}]" >/dev/null 2>&1 || true
  restore_rbac_cm
  kubectl delete application "${APP}" "${APP2}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — policy.csv/policy.default are only enforced behind the real API"
fi
if ! command -v jq >/dev/null 2>&1; then
  _fail "jq not on PATH — needed to safely restore argocd-rbac-cm's multi-line policy.csv on exit"
fi

step "snapshot argocd-rbac-cm before touching it, so this script can restore it exactly"
csv_present="$(kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)"
if kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.csv}' >/dev/null 2>&1 && [ -n "${csv_present}" ]; then
  HAD_CSV="yes"; ORIG_CSV="${csv_present}"
fi
default_present="$(kubectl get configmap argocd-rbac-cm -n argocd -o jsonpath='{.data.policy\.default}' 2>/dev/null || true)"
if [ -n "${default_present}" ]; then
  HAD_DEFAULT="yes"; ORIG_DEFAULT="${default_present}"
fi
_pass "snapshotted (had policy.csv: ${HAD_CSV}, had policy.default: ${HAD_DEFAULT})"

step "force a clean baseline: no policy.csv, no policy.default — the shipped, freshly-installed state per bootstrap/install.yaml"
kubectl patch configmap argocd-rbac-cm -n argocd --type json \
  -p '[{"op":"remove","path":"/data/policy.csv"}]' >/dev/null 2>&1 || true
kubectl patch configmap argocd-rbac-cm -n argocd --type json \
  -p '[{"op":"remove","path":"/data/policy.default"}]' >/dev/null 2>&1 || true

step "fence a throwaway project and app, and a throwaway local account with no policy written for it"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L06 smoke probe — not the real checkout project."
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
kubectl patch configmap argocd-cm -n argocd --type merge -p \
  "{\"data\":{\"accounts.${ACCOUNT}\":\"login\"}}" >/dev/null

step "reach argocd-server directly and log in as admin first, to set the throwaway account's password"
kubectl -n argocd port-forward svc/argocd-server "${PORT}:443" >/tmp/s07l06-portforward.log 2>&1 &
PF_PID=$!
up="no"
for _ in $(seq 1 20); do curl -sk "https://localhost:${PORT}/healthz" >/dev/null 2>&1 && { up="yes"; break; }; sleep 1; done
[ "${up}" = "yes" ] || _fail "argocd-server never answered on the port-forward"
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
argocd account update-password --account "${ACCOUNT}" --new-password "${PASSWORD}" \
  --current-password "${ADMIN_PW}" --grpc-web >/dev/null
wait_for_sync "${APP}" 180

step "no policy.default at all: the unmapped account gets NO access, not read-only — this is the runbook's own flagged fact-check gap"
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
if argocd app get "${APP}" --grpc-web >/dev/null 2>&1; then
  _fail "an account with no g-line and no policy.default could still read ${APP} — Argo CD's documented 'unset = no access' default does not hold"
else
  _pass "unmapped account, no policy.default set: read is denied too — confirms 'unset means no access', not an implicit role:readonly"
fi

step "set policy.default: role:readonly — now read works, create still does not"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p '{"data":{"policy.default":"role:readonly"}}' >/dev/null
sleep 5
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
if argocd app get "${APP}" --grpc-web >/dev/null 2>&1; then
  _pass "policy.default: role:readonly — the account can now read ${APP}"
else
  _fail "policy.default: role:readonly did not grant read access"
fi
if argocd app create "${APP2}" --repo "${REPO}" --path apps/storefront/manifests \
     --dest-server https://kubernetes.default.svc --dest-namespace "${NS}" --project "${PROJ}" \
     --grpc-web >/dev/null 2>&1; then
  _fail "role:readonly was able to create an Application — readonly is not read-only"
else
  _pass "role:readonly still refuses create, as the lesson claims"
fi

step "grant one narrow p+g line pair: create on this project only — create now works, delete still does not"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
kubectl patch configmap argocd-rbac-cm -n argocd --type merge -p \
  "{\"data\":{\"policy.csv\":\"p, ${SUBJECT_ROLE}, applications, create, ${PROJ}/*, allow\ng, ${ACCOUNT}, ${SUBJECT_ROLE}\"}}" >/dev/null
sleep 5
argocd login "localhost:${PORT}" --insecure --grpc-web --username "${ACCOUNT}" --password "${PASSWORD}" >/dev/null
if argocd app create "${APP2}" --repo "${REPO}" --path apps/storefront/manifests \
     --dest-server https://kubernetes.default.svc --dest-namespace "${NS}" --project "${PROJ}" \
     --grpc-web >/dev/null 2>&1; then
  _pass "with the explicit create policy line, the account can now create ${APP2}"
else
  _fail "the explicit p+g pair for 'create' did not grant it"
fi
if argocd app delete "${APP2}" --yes --grpc-web >/dev/null 2>&1; then
  _fail "the account could delete ${APP2}, but no delete policy line was ever written — it gained more than the one line grants"
else
  _pass "delete still refused — the account gained exactly the one ability the policy line names, nothing else"
fi

smoke_done
