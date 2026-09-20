#!/usr/bin/env bash
# S07 L03 — fencing what a project can touch: clusterResourceWhitelist, namespaceResourceBlacklist.
#
# The claim has two halves, and the lesson is explicit that they fail for DIFFERENT reasons:
# an empty (or absent) clusterResourceWhitelist means DENY EVERY cluster-scoped kind, not "allow
# everything" — that's a default-deny gate. A populated namespaceResourceBlacklist is the opposite
# shape: default-allow, with one namespaced kind carved out by name. Testing both against the SAME
# manifest set (as the runbook's own Step 1/2 does) can't tell them apart from a script — Argo CD's
# sync is atomic across the resource set, so a refusal generically named "the ClusterRole" and a
# refusal generically named "the ResourceQuota" both just show up as "sync did not reach Synced".
# This script isolates them: a ClusterRole synced alone proves the whitelist gate, a ResourceQuota
# synced alone (before and after the blacklist exists) proves the blacklist gate.
#
# Neither `apps/checkout/base` nor any other committed path in this repo ships a ClusterRole or a
# ResourceQuota yet — S07 L03 is the lesson that adds them, live, on camera. This script cannot add
# committed manifests (out of its writable scope) or point at content that doesn't exist, so it
# builds the two throwaway objects locally and pushes them straight to the Argo CD controller with
# `argocd app sync --local`, the CLI's own supported mechanism for testing against manifests that
# are not (yet) committed anywhere. This exercises the exact same project-admission code path a
# git-backed sync would. UNVERIFIED AGAINST A LIVE CLUSTER — run it once for real before trusting
# it; if `--local` behaves differently than documented here, that is a fact for this comment, not
# a reason to quietly weaken what it asserts.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L03 "clusterResourceWhitelist is default-deny for cluster-scoped kinds; namespaceResourceBlacklist is default-allow with one kind carved out — different gates, different failures"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l03-probe"
NS="s07l03-probe"
CR_NAME="s07l03-probe-clusterrole"
RQ_NAME="s07l03-probe-quota"
APP_CR="s07l03-clusterrole"
APP_RQ_BEFORE="s07l03-quota-before"
APP_RQ_AFTER="s07l03-quota-after"
TMPDIR=""

cleanup() {
  kubectl delete application "${APP_CR}" "${APP_RQ_BEFORE}" "${APP_RQ_AFTER}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete clusterrole "${CR_NAME}" >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  [ -n "${TMPDIR}" ] && rm -rf "${TMPDIR}"
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — this claim needs 'argocd app sync --local', which has no kubectl-only equivalent"
fi

step "fence a throwaway project — sourceRepos/destinations only, no whitelist or blacklist yet"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L03 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF

TMPDIR="$(mktemp -d)"
mkdir -p "${TMPDIR}/clusterrole" "${TMPDIR}/quota"
cat > "${TMPDIR}/clusterrole/clusterrole.yaml" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${CR_NAME}
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list"]
EOF
cat > "${TMPDIR}/quota/resourcequota.yaml" <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${RQ_NAME}
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
EOF

step "with no clusterResourceWhitelist, a ClusterRole is refused — default-deny, not a filter"
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_CR}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/checkout/base}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {syncOptions: ["CreateNamespace=true"]}
EOF
argocd app sync "${APP_CR}" --local "${TMPDIR}/clusterrole" >/dev/null 2>&1 || true
if kubectl get clusterrole "${CR_NAME}" >/dev/null 2>&1; then
  _fail "ClusterRole ${CR_NAME} exists with no clusterResourceWhitelist entry — cluster-scoped kinds are not default-deny"
else
  _pass "ClusterRole refused with clusterResourceWhitelist absent"
fi

step "whitelist exactly ClusterRole, and only ClusterRole syncs"
kubectl patch appproject "${PROJ}" -n argocd --type merge -p \
  '{"spec":{"clusterResourceWhitelist":[{"group":"rbac.authorization.k8s.io","kind":"ClusterRole"}]}}' >/dev/null
argocd app sync "${APP_CR}" --local "${TMPDIR}/clusterrole" >/dev/null 2>&1
if kubectl get clusterrole "${CR_NAME}" >/dev/null 2>&1; then
  _pass "ClusterRole ${CR_NAME} synced once whitelisted"
else
  _fail "ClusterRole still refused after whitelisting rbac.authorization.k8s.io/ClusterRole"
fi

step "before any namespaceResourceBlacklist, the same ResourceQuota kind syncs fine (baseline)"
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_RQ_BEFORE}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/checkout/base}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {syncOptions: ["CreateNamespace=true"]}
EOF
argocd app sync "${APP_RQ_BEFORE}" --local "${TMPDIR}/quota" >/dev/null 2>&1
if kubectl get resourcequota "${RQ_NAME}" -n "${NS}" >/dev/null 2>&1; then
  _pass "ResourceQuota synced with no blacklist in place — confirms the baseline before testing the deny"
else
  _fail "ResourceQuota did not sync even with no blacklist — cannot isolate the blacklist's effect from this failure"
fi
kubectl delete resourcequota "${RQ_NAME}" -n "${NS}" >/dev/null 2>&1 || true

step "blacklist ResourceQuota by name, and a fresh sync of the identical manifest is refused"
kubectl patch appproject "${PROJ}" -n argocd --type merge -p \
  '{"spec":{"namespaceResourceBlacklist":[{"group":"","kind":"ResourceQuota"}]}}' >/dev/null
kubectl apply -f - <<EOF >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_RQ_AFTER}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/checkout/base}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF
argocd app sync "${APP_RQ_AFTER}" --local "${TMPDIR}/quota" >/dev/null 2>&1 || true
if kubectl get resourcequota "${RQ_NAME}" -n "${NS}" >/dev/null 2>&1; then
  _fail "ResourceQuota ${RQ_NAME} exists after being blacklisted by kind — namespaceResourceBlacklist is not being enforced"
else
  _pass "ResourceQuota refused once blacklisted — 'Error from server (NotFound)', exactly as the runbook expects at this step"
fi

smoke_done
