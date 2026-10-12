#!/usr/bin/env bash
# lesson: s02_l05 Registering an Application, and why automated sync alone will not revert a manual edit
# First reconciliation, and the drift `automated` on its own won't undo.
#
# The lesson's punchline is behavioural, not textual: `automated: {}` (no selfHeal, no prune)
# makes Argo CD DETECT a hand edit: Sync status flips to OutOfSync, but never REVERT it. If
# a future Argo CD release ever changed that default (made bare `automated` self-heal), the
# banner would silently flip back to the Git value and the lesson's entire "it noticed, it did
# not touch it" point would be false. So this drives a real Application through the exact
# sequence the lesson shows and watches which half happens.
#
# This does not disturb the "argocd" namespace, nor the shared storefront-dev namespace or the
# Application other lessons build on it. It probes the BASE (apps/storefront/base) into its own throwaway namespace, the
# same way the S03 scripts do: the dev overlay pins namespace storefront-dev, which would win over
# destination.namespace and land the probe on the real storefront-dev. Its Application and
# namespace have their own names so it can run in the same CI job as other cluster-tier scripts
# without colliding, and it tears itself down whether it passes or fails.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L05 "automated (with no selfHeal) detects a manual edit as OutOfSync but does not revert it"
tier cluster

APP="s02l05-probe"
NS="s02l05-probe"   # the probe's own namespace; storefront-dev is never touched (see the header)
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "register a bare 'automated: {}' Application against storefront's dev overlay"
# base, NOT overlays/dev: the dev overlay pins namespace storefront-dev in its kustomization.yaml, and
# that wins over destination.namespace, so an overlay probe would land in the real storefront-dev.
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: baseline/before-rollouts, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 240

deployment_env_form() {
  kubectl get deploy storefront -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].env[0]}' 2>/dev/null
}
from_git="$(deployment_env_form)"
case "${from_git}" in
  *configMapKeyRef*) _pass "synced: BANNER is still wired via configMapKeyRef, from Git" ;;
  *) _fail "no configMapKeyRef env wiring after sync: cannot run the drift check" ;;
esac

step "hand-edit the Deployment's env: this must show up as OutOfSync"
kubectl patch deployment storefront -n "${NS}" --type json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/env/0","value":{"name":"BANNER","value":"MANUALLY EDITED"}}]' >/dev/null
kubectl rollout status deployment/storefront -n "${NS}" --timeout=90s >/dev/null 2>&1 || true

sync_status=""
for _ in $(seq 1 24); do
  sync_status="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  [ "${sync_status}" = "OutOfSync" ] && break
  sleep 5
done
if [ "${sync_status}" = "OutOfSync" ]; then
  _pass "Sync status flipped to OutOfSync: Argo CD noticed the drift"
else
  _fail "Sync status never reached OutOfSync (last: ${sync_status:-?}): drift detection itself is broken; nothing downstream of this can be trusted"
fi

step "the manual edit must still be LIVE: automated alone must not have reverted it"
still_edited="$(deployment_env_form)"
case "${still_edited}" in
  *'MANUALLY EDITED'*)
    _pass "manual edit still standing: automated detected but did not revert, which is this lesson's whole point"
    ;;
  *configMapKeyRef*)
    _fail "the manual edit was reverted with selfHeal OFF: 'automated: {}' now self-heals on its own, and the lesson's central contrast (it noticed, it did not touch it) no longer holds"
    ;;
  *)
    _fail "unexpected env form after the edit: ${still_edited}"
    ;;
esac

smoke_done
