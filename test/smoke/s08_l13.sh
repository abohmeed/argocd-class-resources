#!/usr/bin/env bash
# S08 L13 — Operating ApplicationSets safely: deletion, the alpha Web UI, the rare generators.
#
# The lesson's central, checkable claim is the deletion contrast: by default, deleting an
# ApplicationSet cascades and takes its generated Applications' live resources with it
# (Deployments and Services included, not just the Application objects); with
# preserveResourcesOnDeletion: true, the SAME delete removes the Application objects but leaves
# the live Deployments and Services running, untouched. This runs entirely on the single
# dev/hub cluster — no multi-cluster dependency — so it is fully checkable here. The Web UI half
# (Steps 5-7) needs a browser and is not attempted.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L13 "the default cascade deletes live resources with the ApplicationSet; preserveResourcesOnDeletion: true keeps the Deployments running after the same delete"
tier cluster

APPSET="test-services"
NS1="payments-dev"
NS2="search-dev"
NS3="loyalty-dev"

cleanup() {
  kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS1}" "${NS2}" "${NS3}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

base_appset() {
  local preserve="$1"
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: ${APPSET}, namespace: argocd}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  ${preserve:+preserveResourcesOnDeletion: true}
  generators:
    - list:
        elements:
          - service: payments
            path: apps/payments/overlays/dev
          - service: search
            path: apps/search/overlays/dev
          - service: loyalty
            path: apps/loyalty/overlays/dev
  template:
    metadata:
      name: '{{.service}}-dev'
    spec:
      project: default
      source:
        repoURL: https://github.com/abohmeed/argocd-class-resources.git
        targetRevision: main
        path: '{{.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.service}}-dev'
      syncPolicy:
        automated: {selfHeal: true, prune: true}
        syncOptions: ["CreateNamespace=true"]
EOF
}

deployments_left() {
  kubectl get deployments --all-namespaces --no-headers 2>/dev/null \
    | grep -cE "${NS1}|${NS2}|${NS3}" || true
}

step "Step 1 — build the fleet, confirm three Applications Synced/Healthy with running Deployments"
base_appset "" | kubectl apply -f - >/dev/null
wait_for_sync "payments-dev" 180
wait_for_sync "search-dev" 180
wait_for_sync "loyalty-dev" 180
n="$(deployments_left)"
[ "${n}" -eq 3 ] && _pass "3 Deployments running (payments, search, loyalty)" \
  || _fail "expected 3 Deployments across the three -dev namespaces, found ${n}"

step "Step 2 — the default cascade: deleting the ApplicationSet takes the Deployments with it"
kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=90s >/dev/null
remaining=""
for _ in $(seq 1 12); do
  sleep 5
  remaining="$(kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=${APPSET} --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${remaining}" -eq 0 ] && break
done
[ "${remaining}" = 0 ] && _pass "all three Applications gone after deleting the ApplicationSet" \
  || _fail "${remaining} Application(s) still exist after deleting ${APPSET}"

n="$(deployments_left)"
[ "${n}" -eq 0 ] \
  && _pass "the default cascade removed the Deployments too — not paused, not out of sync, gone" \
  || _fail "expected 0 Deployments left after the default cascade, found ${n} — the default deletion policy no longer cascades to live resources; RESTAGE BEFORE RECORDING"

step "Step 3 — rebuild WITH preserveResourcesOnDeletion: true"
base_appset "true" | kubectl apply -f - >/dev/null
wait_for_sync "payments-dev" 180
wait_for_sync "search-dev" 180
wait_for_sync "loyalty-dev" 180
preserve_flag="$(kubectl get applicationset "${APPSET}" -n argocd -o jsonpath='{.spec.preserveResourcesOnDeletion}')"
[ "${preserve_flag}" = "true" ] && _pass "preserveResourcesOnDeletion: true is actually applied before the delete" \
  || _fail "spec.preserveResourcesOnDeletion reads '${preserve_flag}', expected true — the delete below would prove nothing"

step "Step 3 — delete it again: Application objects gone, Deployments and Services survive, still serving"
kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=90s >/dev/null
remaining=""
for _ in $(seq 1 12); do
  sleep 5
  remaining="$(kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=${APPSET} --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${remaining}" -eq 0 ] && break
done
[ "${remaining}" = 0 ] && _pass "all three Application OBJECTS are gone, same as the default case" \
  || _fail "${remaining} Application(s) still exist — preserveResourcesOnDeletion should not keep the Application object itself"

n="$(deployments_left)"
if [ "${n}" -eq 3 ]; then
  _pass "all 3 Deployments are STILL RUNNING after the ApplicationSet and its Applications are gone — the lesson's central contrast holds"
else
  _fail "expected 3 Deployments to survive with preserveResourcesOnDeletion: true, found ${n} — the fleet came through unmanaged AND unharmed only if this holds; RESTAGE BEFORE RECORDING"
fi

ready="$(kubectl get deployment payments -n "${NS1}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready}" = "1" ] && _pass "the surviving payments Deployment is not just present, it is actually serving (readyReplicas: 1)" \
  || _fail "payments Deployment in ${NS1} shows readyReplicas='${ready}', expected 1"

smoke_done
