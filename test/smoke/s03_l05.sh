#!/usr/bin/env bash
# S03 L05 — resource tracking moved from a label to an annotation in Argo CD 3.0.
#
# The lesson's claim: on this cluster (3.5.3), `application.resourceTrackingMethod` defaults to
# `annotation` — Argo CD stamps managed resources with `argocd.argoproj.io/tracking-id` in
# metadata.annotations, NOT the pre-3.0 `app.kubernetes.io/instance` label. If a future edit to
# bootstrap/install.yaml's argocd-cm ever forces `label` tracking (or the default changes again
# upstream), a resource orphaning risk the lesson explicitly warns against (GitHub issue 17361)
# becomes live, and the "annotation is what you'll actually see" claim goes false. This checks
# the committed config for the override the lesson says should NOT be there, then drives a real
# sync and reads the live object's own metadata — not a guess about what the default should be.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L05 "resource tracking is annotation-based by default on this cluster (3.0+), not the pre-3.0 label"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "repo-side invariant: no forced label tracking is committed"
assert_file_lacks "bootstrap/install.yaml" "resourceTrackingMethod:[[:space:]]*label" \
  "argocd-cm does not force label-based tracking — annotation stays the effective default"

APP="s03l05-probe"
NS="s03l05-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "sync a Deployment under a fresh, isolated Application"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev — the dev overlay pins its own namespace, and a manifest's own
  # namespace wins over destination.namespace, so this probe would silently land in the real,
  # shared storefront-dev namespace. base pins none, so destination.namespace applies cleanly.
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF
argocd app sync "${APP}" >/dev/null
wait_for_sync "${APP}" 180

step "the live Deployment carries the 3.0+ annotation, and NOT the pre-3.0 tracking label"
tracking_id="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || true)"
instance_label="$(kubectl get deployment storefront -n "${NS}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>/dev/null || true)"

if [ -n "${tracking_id}" ]; then
  _pass "argocd.argoproj.io/tracking-id is present: ${tracking_id}"
else
  _fail "no argocd.argoproj.io/tracking-id annotation on the live Deployment — this cluster is no longer tracking by annotation, and the lesson's 'this is what 3.0+ actually looks like' claim is false"
fi

if [ -z "${instance_label}" ]; then
  _pass "app.kubernetes.io/instance (the pre-3.0 tracking label) is absent — tracking is annotation-only, as the lesson says"
else
  _fail "app.kubernetes.io/instance='${instance_label}' is present on the live Deployment — this cluster is tracking by LABEL, the exact pre-3.0 behavior S03 L05 says this cluster left behind; either a label override landed in argocd-cm or the default itself regressed"
fi

smoke_done
