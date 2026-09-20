#!/usr/bin/env bash
# S07 L01 — the blast radius of one Argo CD instance.
#
# The lesson's claim is not "storefront-dev moves namespace" — it's that the built-in `default`
# AppProject ships wildcard sourceRepos/destinations, so ANY Application registered against it can
# be retargeted into ANY namespace, and CreateNamespace=true brings that namespace into existence
# with no approval step anywhere in the path. That is what this defends.
#
# It deliberately does NOT reuse the real `storefront-dev` Application the runbook retargets.
# Two reasons: (1) that Application is live, cumulative, recording-day state this suite must never
# touch (S07 L02 depends on the namespace it leaves behind); (2) storefront-dev's overlay
# (apps/storefront/overlays/dev) carries a Kustomize-level `namespace: storefront-dev`, which the
# runbook itself flags as an UNVERIFIED risk — Kustomize's namespace transformer may stamp objects
# into storefront-dev regardless of the Application's own destination, which would make a CI
# script that depends on it flaky for a reason that has nothing to do with this lesson's claim.
# apps/storefront/manifests carries no such marker (see S04 L01), so a throwaway Application built
# from it isolates the actual claim — default-project permissiveness — from that open question.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L01 "the default AppProject's wildcard sourceRepos/destinations let any Application retarget into any namespace, with CreateNamespace=true creating it, and nobody approves the move"
tier cluster

NS="s07l01-probe"
APP="s07l01-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "confirm the probe namespace does not already exist"
if kubectl get namespace "${NS}" >/dev/null 2>&1; then
  _fail "${NS} already exists — a previous run's cleanup did not complete; delete it by hand before re-running"
fi
_pass "${NS} does not exist yet"

step "register an Application in the unscoped default project, targeting ${NS}, with no approval step"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 180

step "the namespace exists and holds the plain-directory manifests, created without a human approving anything"
if kubectl get deployment -n "${NS}" -o name 2>/dev/null | grep -q .; then
  _pass "Deployment landed in ${NS} — nothing gated this retarget"
else
  _fail "no Deployment in ${NS} after a reported sync — the retarget did not actually land"
fi

step "confirm WHY: the default project's own sourceRepos/destinations are still the wildcard Argo CD ships"
proj_repos="$(kubectl get appproject default -n argocd -o jsonpath='{.spec.sourceRepos}' 2>/dev/null || true)"
proj_dest="$(kubectl get appproject default -n argocd -o jsonpath='{.spec.destinations[*].namespace}' 2>/dev/null || true)"
if printf '%s' "${proj_repos}" | grep -q '\*' && printf '%s' "${proj_dest}" | grep -q '\*'; then
  _pass "default project still carries wildcard sourceRepos and a wildcard destination namespace — this is the root cause, not a fluke"
else
  _fail "default project no longer looks wildcard-permissive (sourceRepos=${proj_repos} destinations=${proj_dest}) — if this was deliberately fenced, S07 L01's premise (an unfenced default project) no longer holds and the lesson needs to change, not this check"
fi

smoke_done
