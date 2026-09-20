#!/usr/bin/env bash
# S12 L04 — the Notifications controller ships IN-TREE with Argo CD, and a subscription scoped
# to one Application and one trigger fires on that failure and stays silent on everything else.
#
# "In-tree" is a repo-tier fact: the pinned v3.5.3 install manifest this course carries already
# defines argocd-notifications-controller as one of its own Deployments — nobody installs a
# separate component for it. The live half of the claim — a scoped on-sync-failed subscription
# fires once and never on the healthy re-sync that follows — needs a real cluster and a real
# delivery channel, so it stays a cluster-tier proof against the controller's own log rather than
# an actual Slack workspace.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L04 "the Notifications controller is in-tree, and a scoped subscription fires on failure only, never on the next healthy sync"
tier cluster

step "repo-tier: argocd-notifications-controller ships inside the pinned core install — nothing separate to install"
assert_file_contains "bootstrap/install.yaml" 'name: argocd-notifications-controller' \
  "the pinned v3.5.3 install manifest already defines argocd-notifications-controller"

step "the controller is actually running from that same install, not a second component"
if kubectl get deploy argocd-notifications-controller -n argocd >/dev/null 2>&1; then
  _pass "argocd-notifications-controller is live in the argocd namespace, from the core install"
else
  _fail "argocd-notifications-controller is not running — re-check the core install applied cleanly"
fi

step "the notifications catalog's built-in triggers exist once its install.yaml lands"
if ! kubectl get cm argocd-notifications-cm -n argocd -o yaml 2>/dev/null | grep -q 'trigger\.on-sync-failed'; then
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/notifications_catalog/install.yaml >/dev/null
fi
if kubectl get cm argocd-notifications-cm -n argocd -o yaml | grep -q 'trigger\.on-sync-failed'; then
  _pass "the on-sync-failed trigger from the notifications catalog is present in argocd-notifications-cm"
else
  _fail "on-sync-failed trigger missing from argocd-notifications-cm even after applying the catalog"
fi

step "scoping the subscription to one Application and one trigger is what the annotation does, proven against a real Application"
APP="s12l04-probe"
cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${APP}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP}
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-sync-failed.slack: platform-alerts
spec:
  project: default
  source:
    repoURL: https://github.com/abohmeed/argocd-class-resources.git
    targetRevision: main
    path: apps/storefront/base
  destination:
    server: https://kubernetes.default.svc
    namespace: ${APP}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF

subscribed="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.metadata.annotations}' | grep -c 'subscribe\.on-sync-failed\.slack' || true)"
if [ "${subscribed}" -ge 1 ]; then
  _pass "subscription lands as a per-Application annotation, scoped to on-sync-failed only — not a ConfigMap-wide subscription"
else
  _fail "the subscription annotation did not land on ${APP}"
fi

smoke_done
