#!/usr/bin/env bash
# S08 L05 — Git generator, directory mode.
#
# The lesson's claim: a directories generator pointed at apps/storefront/overlays/* produces
# one Application per matched folder, named and sourced from {{.path.basename}}/{{.path.path}},
# with none of them hand-named — and a folder that later appears in Git is picked up with no
# edit to the ApplicationSet. The runbook's own choreography builds `canary` live and pushes
# three new commits (canary, prod-test, integration-test) to prove the discovery and the
# exclude-glob behaviour; this script does not replay that git history against the real
# upstream repo. Instead it defends the discovery claim against the overlays that are ALREADY
# committed there — dev, staging, prod, canary — which is exactly the "four real folders, zero
# hand-naming" claim without mutating the shared companion repo from CI.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L05 "a directories generator produces one Application per matched folder, named and sourced by {{.path.basename}}/{{.path.path}}, none hand-named"
tier cluster

APPSET="storefront-envs"
NAMESPACES="storefront-dev storefront-staging storefront-prod storefront-canary"

cleanup() {
  kubectl delete applicationset "${APPSET}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  kubectl delete namespace ${NAMESPACES} --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "the four overlay folders this generator must discover are already committed upstream"
assert_exists_dir "apps/storefront/overlays/dev"
assert_exists_dir "apps/storefront/overlays/staging"
assert_exists_dir "apps/storefront/overlays/prod"
assert_exists_dir "apps/storefront/overlays/canary"

step "Step 1/2 — apply the directory-mode generator against the real companion repo"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: ${APPSET}, namespace: argocd}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/abohmeed/argocd-class-resources.git
        revision: main
        directories:
          - path: apps/storefront/overlays/*
  template:
    metadata:
      name: 'storefront-{{.path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/abohmeed/argocd-class-resources.git
        targetRevision: main
        path: '{{.path.path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'storefront-{{.path.basename}}'
      syncPolicy:
        automated: {selfHeal: true, prune: true}
        syncOptions: ["CreateNamespace=true"]
EOF

found=no
for _ in $(seq 1 24); do
  sleep 10
  count="$(kubectl get applications -n argocd -l argocd.argoproj.io/application-set-name=${APPSET} --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${count}" -ge 4 ] && { found=yes; break; }
done
if [ "${found}" = yes ]; then
  _pass "four Applications discovered from four committed folders, none hand-named"
else
  _fail "expected 4 Applications (dev/staging/prod/canary) within 240s, found ${count:-0} — the directory generator did not discover every committed overlay; RESTAGE BEFORE RECORDING"
fi

step "each Application's source path is the matched folder's own path, verbatim"
for env in dev staging prod canary; do
  src="$(kubectl get application "storefront-${env}" -n argocd -o jsonpath='{.spec.source.path}' 2>/dev/null)"
  [ "${src}" = "apps/storefront/overlays/${env}" ] \
    && _pass "storefront-${env} sources from apps/storefront/overlays/${env}" \
    || _fail "storefront-${env} sources from '${src}', expected apps/storefront/overlays/${env}"
done

step "at least one discovered Application actually reaches Synced/Healthy"
wait_for_sync "storefront-canary" 180

smoke_done
