#!/usr/bin/env bash
# S08 L02 — ApplicationSet anatomy and modern templating.
#
# The lesson's whole premise is three behavioural claims about goTemplate: true:
#   1. the legacy dot-less {{name}} form is a HARD PARSE ERROR, not a silent misrender;
#   2. the dotted {{.name}} form renders and syncs correctly;
#   3. a missing-key typo under the dotted form renders SILENTLY (empty string) unless
#      goTemplateOptions: [missingkey=error] is set, at which point the same typo becomes loud.
# This defends all three by actually applying each variant and reading the controller's own
# status, not by grepping committed YAML — none of appset.yaml is committed (it is a scratch
# file the runbook itself never commits).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L02 "legacy {{name}} is a hard parse error under goTemplate: true; {{.name}} works; missingkey=error turns a silent typo loud"
tier cluster

APPSET="storefront-fleet"
NS1="storefront-dev"
NS2="storefront-staging"

cleanup() {
  kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS1}" "${NS2}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

conditions_of() {
  kubectl get applicationset "${APPSET}" -n argocd -o jsonpath='{.status.conditions}' 2>/dev/null
}

step "the paths the List generator names actually exist"
assert_exists_dir "apps/storefront/overlays/dev"
assert_exists_dir "apps/storefront/overlays/staging"

step "Step 4/5 — apply the legacy dot-less {{name}} form and expect a parse error, not a silent bad render"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: ${APPSET}, namespace: argocd}
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: dev
          - name: staging
  template:
    metadata:
      name: '{{name}}-storefront'
    spec:
      project: default
      source:
        repoURL: https://github.com/abohmeed/argocd-class-resources.git
        targetRevision: main
        path: 'apps/storefront/overlays/{{.name}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'storefront-{{.name}}'
      syncPolicy:
        automated: {selfHeal: true, prune: true}
        syncOptions: ["CreateNamespace=true"]
EOF

found=no
for _ in $(seq 1 12); do
  sleep 5
  if conditions_of | grep -q 'not defined'; then found=yes; break; fi
done
if [ "${found}" = yes ]; then
  _pass "legacy {{name}} under goTemplate: true fails to parse — the lesson's Step 5 claim holds"
else
  _fail "no parse error surfaced for the legacy {{name}} form within 60s — either it silently rendered (a real behaviour change) or the condition never propagated; RESTAGE BEFORE RECORDING. Last conditions: $(conditions_of)"
fi

step "Step 6/7 — the dotted form fixes it: clean render, both Applications Synced/Healthy"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: ${APPSET}, namespace: argocd}
spec:
  goTemplate: true
  generators:
    - list:
        elements:
          - name: dev
          - name: staging
  template:
    metadata:
      name: '{{.name}}-storefront'
    spec:
      project: default
      source:
        repoURL: https://github.com/abohmeed/argocd-class-resources.git
        targetRevision: main
        path: 'apps/storefront/overlays/{{.name}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'storefront-{{.name}}'
      syncPolicy:
        automated: {selfHeal: true, prune: true}
        syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "dev-storefront" 180
wait_for_sync "staging-storefront" 180

step "Step 9 — a typo under the dotted form ({{.naem}}) renders CLEAN and silently empties the path"
kubectl patch applicationset "${APPSET}" -n argocd --type merge \
  -p '{"spec":{"template":{"spec":{"source":{"path":"apps/storefront/overlays/{{.naem}}"}}}}}' >/dev/null
sleep 15
path_now="$(kubectl get application dev-storefront -n argocd -o jsonpath='{.spec.source.path}' 2>/dev/null)"
err_now="$(conditions_of | grep -o 'not defined\|naem' || true)"
# Go's text/template renders a missing key as the literal string `<no value>` under the default
# missingkey=invalid, NOT as an empty string. Either one is the silent case the lesson turns on —
# the path is wrong and nothing complains. The first version of this accepted only the empty
# string and so failed on the very behaviour it was written to prove.
if { [ -z "${path_now}" ] || [ "${path_now}" != "${path_now#*<no value>}" ]; } && [ -z "${err_now}" ]; then
  _pass "the typo rendered a silently wrong path ('${path_now:-<empty>}') with no error surfaced — the silent case the lesson turns on"
else
  _fail "expected a silently wrong path — empty or containing '<no value>' — but got path='${path_now}' with conditions mentioning '${err_now}'; the missingkey default may have changed upstream; RESTAGE BEFORE RECORDING"
fi

step "Step 10 — missingkey=error turns the SAME typo loud"
kubectl patch applicationset "${APPSET}" -n argocd --type merge \
  -p '{"spec":{"goTemplateOptions":["missingkey=error"]}}' >/dev/null
loud=no
for _ in $(seq 1 12); do
  sleep 5
  if conditions_of | grep -qi 'naem'; then loud=yes; break; fi
done
if [ "${loud}" = yes ]; then
  _pass "missingkey=error surfaced the 'naem' typo as a rendering error — Step 10's claim holds"
else
  _fail "missingkey=error did not surface the typo within 60s; RESTAGE BEFORE RECORDING. Last conditions: $(conditions_of)"
fi

step "Step 11 — fix the typo, confirm clean and Synced again"
kubectl patch applicationset "${APPSET}" -n argocd --type merge \
  -p '{"spec":{"template":{"spec":{"source":{"path":"apps/storefront/overlays/{{.name}}"}}}}}' >/dev/null
sleep 10
clean_path="$(kubectl get application dev-storefront -n argocd -o jsonpath='{.spec.source.path}' 2>/dev/null)"
[ "${clean_path}" = "apps/storefront/overlays/dev" ] \
  && _pass "dev-storefront's source path is back to apps/storefront/overlays/dev" \
  || _fail "dev-storefront's source path is '${clean_path}', expected apps/storefront/overlays/dev after the fix"
wait_for_sync "dev-storefront" 120
wait_for_sync "staging-storefront" 120

smoke_done
