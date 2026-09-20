#!/usr/bin/env bash
# S03 L06 — automated, selfHeal and prune are three separate switches.
#
# The lesson's claim is behavioural, not textual: `automated` alone DETECTS drift and leaves it,
# `selfHeal` reverts a hand edit, and `prune` puts back something deleted. If Argo CD ever
# changed so that `automated` reverted on its own, the lesson would be teaching a distinction
# that no longer exists — and a student would only find out by not being able to reproduce it.
# So this drives the actual cluster and watches which switch does what.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L06 "automated detects, selfHeal reverts, prune restores — three switches, three behaviours"
tier cluster

APP="s03l06-probe"
NS="s03l06-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "create the Application with automated ONLY — no selfHeal, no prune"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev. The dev overlay pins a namespace of its own in its kustomization,
  # and a namespace set in the manifest wins over the Application's destination — so pointing
  # this probe at the overlay silently deploys into storefront-dev, collides with whatever is
  # already there, and sits OutOfSync forever. base pins no namespace, so the destination
  # applies and this script gets a namespace to itself.
  # (No backticks in here: this is an unquoted heredoc, so backticks are command substitution.)
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 240

banner_of() {
  kubectl get cm storefront-banner -n "${NS}" -o jsonpath='{.data.banner}' 2>/dev/null
}
from_git="$(banner_of)"
[ -n "${from_git}" ] && _pass "synced, banner from Git is '${from_git}'" || _fail "no banner after sync"

step "hand-edit the ConfigMap — automated alone must DETECT the drift and leave it standing"
kubectl patch cm storefront-banner -n "${NS}" --type merge -p '{"data":{"banner":"EDITED BY HAND"}}' >/dev/null
sleep 25
if [ "$(banner_of)" = "EDITED BY HAND" ]; then
  _pass "edit still standing — automated detected but did not revert, which is the lesson's first point"
else
  _fail "the hand edit was reverted with selfHeal OFF — the lesson's distinction between automated and selfHeal no longer holds; RESTAGE BEFORE RECORDING"
fi

step "turn selfHeal on — now the same edit must be reverted"
kubectl patch application "${APP}" -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true}}}}' >/dev/null
reverted=no
for _ in $(seq 1 24); do
  sleep 8
  [ "$(banner_of)" = "${from_git}" ] && { reverted=yes; break; }
done
if [ "${reverted}" = yes ]; then
  _pass "selfHeal reverted the hand edit back to '${from_git}'"
else
  _fail "selfHeal did NOT revert within 190s — the lesson's central demonstration does not reproduce"
fi

smoke_done
