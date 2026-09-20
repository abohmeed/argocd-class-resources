#!/usr/bin/env bash
# S07 L12 — service account impersonation: stopping Argo CD being a god object.
#
# The claim: once `application.sync.impersonation.enabled` is on and an AppProject names a scoped
# ServiceAccount via `destinationServiceAccounts`, the controller syncs AS that ServiceAccount —
# so a sync succeeds for whatever its Role grants (Deployments/Services/ConfigMaps here), but
# reading logs or deleting a Pod through Argo CD is refused by underlying KUBERNETES RBAC on the
# impersonated identity, even for an account (here: admin) whose own Argo CD-level RBAC would
# otherwise allow both without question. That last part is the whole point: this is a different,
# lower layer than S07 L06–L08's policy.csv, and it overrides what policy.csv would allow.
#
# `application.sync.impersonation.enabled` is a global flag on argocd-cm — snapshotted and
# restored so this is safe to run alongside the rest of the S07 suite on the same cluster.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L12 "impersonation makes the controller sync as a scoped ServiceAccount — its Role's grants succeed, but logs and Pod delete are refused by Kubernetes RBAC underneath, even for an admin Argo CD session"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l12-probe"
NS="s07l12-probe"
APP="s07l12-app"
SA="s07l12-controller"
PF_PID=""
PORT=18212
HAD_IMPERSONATION="no"
ORIG_IMPERSONATION=""

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  if [ "${HAD_IMPERSONATION}" = "yes" ]; then
    kubectl patch configmap argocd-cm -n argocd --type merge \
      -p "{\"data\":{\"application.sync.impersonation.enabled\":\"${ORIG_IMPERSONATION}\"}}" >/dev/null 2>&1 || true
  else
    kubectl patch configmap argocd-cm -n argocd --type json \
      -p '[{"op":"remove","path":"/data/application.sync.impersonation.enabled"}]' >/dev/null 2>&1 || true
  fi
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete rolebinding "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete role "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete serviceaccount "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH — argocd app logs / delete-resource are only reachable behind the real API"
fi

step "the scoped ServiceAccount: full control of Deployments/Services/ConfigMaps, read-only on Pods, no logs subresource"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: {name: ${SA}, namespace: ${NS}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: ${SA}, namespace: ${NS}}
rules:
  - apiGroups: ["", "apps"]
    resources: ["deployments", "services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ${SA}, namespace: ${NS}}
subjects:
  - {kind: ServiceAccount, name: ${SA}, namespace: ${NS}}
roleRef: {kind: Role, name: ${SA}, apiGroup: rbac.authorization.k8s.io}
EOF

can_delete="$(kubectl auth can-i delete pods --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}")"
can_logs="$(kubectl auth can-i get pods --subresource=log --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}")"
can_update="$(kubectl auth can-i update deployments --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}")"
if [ "${can_delete}" = "no" ] && [ "${can_logs}" = "no" ] && [ "${can_update}" = "yes" ]; then
  _pass "ServiceAccount's Kubernetes RBAC is exactly as scoped: no pod delete, no pod logs, yes deployment update"
else
  _fail "ServiceAccount's Role does not have the expected shape (delete=${can_delete} logs=${can_logs} update=${can_update}) — the rest of this test cannot isolate impersonation's effect from a Role that is wrong to begin with"
fi

step "wire it in: destinationServiceAccounts on the project, impersonation enabled instance-wide"
present="$(kubectl get configmap argocd-cm -n argocd -o jsonpath='{.data.application\.sync\.impersonation\.enabled}' 2>/dev/null || true)"
if [ -n "${present}" ]; then HAD_IMPERSONATION="yes"; ORIG_IMPERSONATION="${present}"; fi
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L12 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  destinationServiceAccounts:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}", defaultServiceAccount: "${SA}"}
EOF
kubectl patch configmap argocd-cm -n argocd --type merge -p \
  '{"data":{"application.sync.impersonation.enabled":"true"}}' >/dev/null

step "sync succeeds — the SA's Role covers everything a plain Deployment+Service sync touches"
cat <<EOF | kubectl apply -f - >/dev/null
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
[ -n "${POD_NAME}" ] || _fail "no Pod found in ${NS} after a reported sync"

step "reach argocd-server as admin — an account whose OWN Argo CD RBAC has no reason to be denied logs or delete"
kubectl -n argocd port-forward svc/argocd-server "${PORT}:443" >/tmp/s07l12-portforward.log 2>&1 &
PF_PID=$!
up="no"
for _ in $(seq 1 20); do curl -sk "https://localhost:${PORT}/healthz" >/dev/null 2>&1 && { up="yes"; break; }; sleep 1; done
[ "${up}" = "yes" ] || _fail "argocd-server never answered on the port-forward"
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster"
argocd login "localhost:${PORT}" --insecure --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null

step "admin's own logs read is refused — blocked underneath by the impersonated SA's Kubernetes RBAC, not by policy.csv"
out="$(timeout 20 argocd app logs "${APP}" --grpc-web 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  _fail "admin could read logs through the impersonated app — the impersonated ServiceAccount has no pods/log permission, so this should have been refused underneath, regardless of admin's own Argo CD RBAC"
else
  _pass "admin's logs read refused (exit ${rc}) — Kubernetes RBAC on the impersonated identity overrides what admin's own Argo CD RBAC would otherwise allow"
fi

step "admin's own Pod delete is refused the same way"
if argocd app delete-resource "${APP}" --kind Pod --resource-name "${POD_NAME}" --namespace "${NS}" --grpc-web >/dev/null 2>&1; then
  _fail "admin deleted the Pod through the impersonated app — the SA's Role only grants get/list/watch on Pods, delete should have been refused"
else
  _pass "Pod delete refused — the impersonated SA never had delete on Pods, and impersonation means that is what actually governs, not admin's own reach"
fi

smoke_done
