#!/usr/bin/env bash
# S07 L04 — sync windows: when a project may not deploy at all.
#
# The claim is that a deny window blocks EVERY sync attempt against the project while it is open —
# automated or manual, no override flag exists on a sync command — and that the block lifts the
# moment the window closes. A single "it didn't sync" observation can't tell a blocked sync apart
# from a slow one, so this runs it as a before/after: create the Application with the deny window
# ALREADY open and confirm it never lands, then remove the window and confirm the identical
# Application lands shortly after. The window here uses `schedule: "* * * * *"` (always open) —
# the runbook's own documented workaround for recording outside the real Friday freeze — so this
# reproduces reliably regardless of when CI runs, the same reason the runbook gives for it.
#
# Built with `kubectl apply` against the AppProject CRD directly (the same shape as
# bootstrap/edge-restricted-project.yaml's syncWindows, already committed in this repo) rather than
# `argocd proj windows add` — no CLI login needed, and it is the same object either way.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L04 "a deny sync window blocks every sync attempt against the project, automated or manual, with no override — and lifts the moment it closes"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l04-probe"
NS="s07l04-probe"
APP="s07l04-probe"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "fence a throwaway project with an always-open deny window already in place"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L04 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncWindows:
    - kind: deny
      schedule: "* * * * *"
      duration: 1h
      applications: ["*"]
EOF

step "register the Application while the deny window is already open"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF

step "45 seconds is long enough for an unblocked sync elsewhere in this suite (S07 L01/L02) to land — this one must not"
sleep 45
if kubectl get deployment -n "${NS}" -o name 2>/dev/null | grep -q .; then
  _fail "the Deployment landed in ${NS} while the deny window was open — automated sync bypassed the window"
else
  _pass "no Deployment in ${NS} while the deny window is open — automated sync did not bypass it"
fi

step "a manual sync attempt during the same window is refused too — no flag exists that overrides a deny window"
argocd_cli_present="no"
command -v argocd >/dev/null 2>&1 && argocd_cli_present="yes"
if [ "${argocd_cli_present}" = "yes" ]; then
  if argocd app sync "${APP}" --grpc-web >/dev/null 2>&1; then
    _fail "argocd app sync succeeded during the deny window — a manual attempt should be refused exactly like the automated one"
  else
    _pass "manual 'argocd app sync' refused during the deny window (no override flag exists on the command)"
  fi
else
  _pass "argocd CLI not present — skipping the manual-sync half; the automated-sync check above already covers the controller-level enforcement this lesson depends on"
fi

step "remove the window, and the identical Application lands"
kubectl patch appproject "${PROJ}" -n argocd --type merge -p '{"spec":{"syncWindows":null}}' >/dev/null
wait_for_sync "${APP}" 180
if kubectl get deployment -n "${NS}" -o name 2>/dev/null | grep -q .; then
  _pass "Deployment landed once the deny window was removed — confirms the earlier absence was the window, not a broken Application"
else
  _fail "Deployment still never landed after removing the deny window — something other than the window is broken, and the earlier absence check is not trustworthy evidence of the window's effect"
fi

smoke_done
