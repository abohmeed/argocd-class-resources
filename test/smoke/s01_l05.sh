#!/usr/bin/env bash
# S01 L05 — first reconciliation, and the drift `automated` on its own won't undo.
#
# The lesson's punchline is behavioural, not textual: `automated: {}` (no selfHeal, no prune)
# makes Argo CD DETECT a hand edit — Sync status flips to OutOfSync — but never REVERT it. If
# a future Argo CD release ever changed that default (made bare `automated` self-heal), the
# banner would silently flip back to the Git value and the lesson's entire "it noticed, it did
# not touch it" framing would be false on camera. So this drives a real Application through the
# exact sequence the runbook shows and watches which half happens.
#
# This does not disturb the "argocd" namespace or the shared storefront-dev Application other
# lessons build (S02 L08 puts Argo CD under self-management; the course's real recording keeps
# this Application registered for good). It uses its own throwaway Application/namespace name
# so it can run in the same CI job as other cluster-tier scripts without colliding, and it tears
# itself down whether it passes or fails.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S01-L05 "automated (with no selfHeal) detects a manual edit as OutOfSync but does not revert it"
tier cluster

APP="s01l05-probe"
NS="s01l05-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "register a bare 'automated: {}' Application against storefront's dev overlay"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/overlays/dev}
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
  *configMapKeyRef*) _pass "synced — BANNER is still wired via configMapKeyRef, from Git" ;;
  *) _fail "no configMapKeyRef env wiring after sync — cannot run the drift check" ;;
esac

step "hand-edit the Deployment's env — this must show up as OutOfSync"
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
  _pass "Sync status flipped to OutOfSync — Argo CD noticed the drift"
else
  _fail "Sync status never reached OutOfSync (last: ${sync_status:-?}) — drift detection itself is broken; nothing downstream of this can be trusted"
fi

step "the manual edit must still be LIVE — automated alone must not have reverted it"
still_edited="$(deployment_env_form)"
case "${still_edited}" in
  *'MANUALLY EDITED'*)
    _pass "manual edit still standing — automated detected but did not revert, which is this lesson's whole point"
    ;;
  *configMapKeyRef*)
    _fail "the manual edit was reverted with selfHeal OFF — 'automated: {}' now self-heals on its own, and the lesson's central contrast (it noticed, it did not touch it) no longer holds; RESTAGE BEFORE RECORDING"
    ;;
  *)
    _fail "unexpected env form after the edit: ${still_edited}"
    ;;
esac

smoke_done
