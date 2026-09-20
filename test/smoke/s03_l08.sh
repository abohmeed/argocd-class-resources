#!/usr/bin/env bash
# S03 L08 — rollback restores service; only a durable fix to the source of truth closes the gap.
#
# The lesson's claim: `argocd app rollback` (or the UI's Rollback button) re-applies a manifest
# Argo CD already rendered before — it restores the running workload FAST, but it does nothing
# to the Application's own declared source, which still says the bad thing. That leaves the
# Application OutOfSync, and if selfHeal is on, the very next reconcile would silently undo the
# rescue. Only fixing the source itself (a `git revert` in the real lesson) makes the two agree
# again. This drives a real cluster to the same shape of incident using an isolated probe
# Application whose "source of truth" is an inline kustomize image override — changing that
# override is this script's stand-in for a git commit, so nothing is pushed to the shared
# companion repo, but the rollback-then-diverge-then-fix sequence is the real thing.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L08 "rollback restores the running workload but leaves the Application's own source declaring the bad state; only fixing the source closes the gap"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

APP="s03l08-probe"
NS="s03l08-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
GOOD_IMAGE="hashicorp/http-echo=hashicorp/http-echo:1.0"
BAD_IMAGE="hashicorp/http-echo=ghcr.io/northwind/storefront:1.4.2-typo"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

app_yaml() {
  local image="$1"
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source:
    repoURL: "${REPO}"
    targetRevision: main
    # base, NOT overlays/prod — the prod overlay pins its own namespace, and a manifest's own
    # namespace wins over destination.namespace, so this probe would silently land in the real
    # storefront-prod namespace S03 L08's own runbook builds. base pins none, so
    # destination.namespace applies cleanly. Replica count (base: 1, prod: 3) is not part of
    # what this script defends.
    path: apps/storefront/base
    kustomize:
      images: ["${image}"]
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF
}

step "ship the good image first, so there is a known-good history entry to roll back to"
app_yaml "${GOOD_IMAGE}" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null
wait_for_rollout "deployment/storefront" "${NS}"
wait_for_sync "${APP}" 180

step "ship the incident: the source of truth itself now declares the bad tag, and a normal sync ships it"
app_yaml "${BAD_IMAGE}" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null 2>&1 || true
deadline=$(( $(date +%s) + 90 ))
bad_health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  bad_health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "${bad_health}" = "Degraded" ] && break
  sleep 5
done
[ "${bad_health}" = "Degraded" ] \
  && _pass "prod is broken — Degraded, matching the incident the lesson opens on" \
  || _fail "expected Degraded after shipping the bad tag, got '${bad_health:-empty}' — the incident never actually happened, so nothing below is testing what the lesson claims"

step "find the last good revision"
good_id="$(argocd app history "${APP}" 2>/dev/null | awk 'NR>1{print $1}' | sort -n | head -1)"
[ -n "${good_id}" ] || _fail "argocd app history returned no revisions — cannot test rollback without a history to roll back through"
_pass "last good revision is history ID ${good_id}"

step "roll back — service must be restored fast"
argocd app rollback "${APP}" "${good_id}" >/dev/null
wait_for_rollout "deployment/storefront" "${NS}"
live_image="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [ "${live_image}" = "hashicorp/http-echo:1.0" ]; then
  _pass "rollback restored the working image on the live Deployment: ${live_image}"
else
  _fail "expected hashicorp/http-echo:1.0 running after rollback, got '${live_image:-empty}' — rollback did not actually restore service"
fi

step "the gap rollback leaves behind: the Application's OWN source still declares the bad tag"
argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
after_rollback_sync="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${after_rollback_sync}" = "OutOfSync" ]; then
  _pass "OutOfSync after rollback — the live cluster runs the good image, but the declared source still says the bad one. This is the divergence a durable fix has to close."
else
  _fail "expected OutOfSync after a rollback whose source was never fixed, got '${after_rollback_sync:-empty}' — rollback is not supposed to reconcile the source of truth, only the live objects"
fi

step "the durable fix: correct the source itself (this script's stand-in for git revert), and Git/cluster agree again"
app_yaml "${GOOD_IMAGE}" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null
wait_for_sync "${APP}" 120
_pass "source fixed and synced — Synced/Healthy, no divergence left standing"

smoke_done
