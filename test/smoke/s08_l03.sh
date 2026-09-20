#!/usr/bin/env bash
# S08 L03 — List generator: the smallest fleet you can name explicitly.
#
# Two claims: (1) a List generator with one map per element produces one Application per
# element, all three synced without any of them being hand-named; (2) the ApplicationSet
# controller owns the generated Application objects — a manual edit to a field it did not set
# gets reverted on the controller's own next reconcile, no selfHeal-style Argo CD sync policy
# involved at all. This defends the second claim live, since it is the one a static read of the
# repo cannot confirm (nothing here is committed — appset.yaml is scratch, same as L02).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L03 "List generator produces one Application per element; the AppSet controller reverts a manual edit to a field it never set"
tier cluster

APPSET="new-services"
NS1="payments-dev"
NS2="search-dev"
NS3="loyalty-dev"

cleanup() {
  kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS1}" "${NS2}" "${NS3}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "every path the List generator names is a real directory in the repo"
assert_exists_dir "apps/payments/overlays/dev"
assert_exists_dir "apps/search/overlays/dev"
assert_exists_dir "apps/loyalty/overlays/dev"

step "Step 2/3 — apply the List generator, one map per service"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: ${APPSET}, namespace: argocd}
spec:
  goTemplate: true
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

step "Step 4 — exactly three Applications, all Synced/Healthy, none hand-named"
wait_for_sync "payments-dev" 180
wait_for_sync "search-dev" 180
wait_for_sync "loyalty-dev" 180
count="$(kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=${APPSET} --no-headers | wc -l | tr -d ' ')"
[ "${count}" -eq 3 ] && _pass "exactly 3 Applications carry the application-set-name label" \
  || _fail "expected 3 Applications for ${APPSET}, found ${count}"

step "Step 5 — hand-edit a label the controller never set, and watch it get reverted"
kubectl label application payments-dev -n argocd "demo.northwind.io/manual-edit=true" --overwrite >/dev/null
immediately="$(kubectl get application payments-dev -n argocd -o jsonpath='{.metadata.labels.demo\.northwind\.io/manual-edit}')"
[ "${immediately}" = "true" ] && _pass "the manual label is present immediately after the edit" \
  || _fail "the manual label did not stick immediately after 'kubectl label' — cannot test the revert"

reverted=no
for _ in $(seq 1 24); do
  sleep 10
  still="$(kubectl get application payments-dev -n argocd -o jsonpath='{.metadata.labels.demo\.northwind\.io/manual-edit}' 2>/dev/null)"
  if [ -z "${still}" ]; then reverted=yes; break; fi
done
if [ "${reverted}" = yes ]; then
  _pass "the manual label was reverted by the ApplicationSet controller's own reconcile — the lesson's central claim holds"
else
  _fail "the manual label survived 240s of reconciles — the controller no longer enforces its generated manifest against drift on fields it owns; RESTAGE BEFORE RECORDING"
fi

smoke_done
