#!/usr/bin/env bash
# S03 L07 — ignoreDifferences hides a field from the diff; it does not protect it from a sync.
# RespectIgnoreDifferences does protect it, and only on a resource that already exists.
#
# Three claims, in order, each one falsifiable on its own:
#   1. ignoreDifferences makes an out-of-Git field invisible to diff/sync-status.
#   2. that same field is still WIPED by the very next sync — ignoreDifferences is diff-only.
#   3. adding syncOptions: [RespectIgnoreDifferences=true] is what actually protects the field
#      on an apply — but ONLY when the object already exists; a fresh creation still gets the
#      bare manifest, hole and all.
# If Argo CD ever changed so ignoreDifferences alone protected a field on sync (collapsing the
# distinction the whole lesson is built on), or RespectIgnoreDifferences started protecting a
# freshly-created object too, this would go quiet with a green dashboard and no test to catch it.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L07 "ignoreDifferences hides drift from the diff; only RespectIgnoreDifferences protects the field on sync, and only if the object already exists"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

APP="s03l07-probe"
NS="s03l07-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
ANNOTATION_KEY="northwind.io/scanned-at"
JSON_POINTER='/metadata/annotations/northwind.io~1scanned-at'

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

app_yaml() {
  # $1: "true" to include ignoreDifferences for the simulated annotation, else ""
  # $2: "true" to also set syncOptions: RespectIgnoreDifferences=true, else ""
  local with_ignore="$1" with_respect="$2"
  local sync_options='["CreateNamespace=true"]'
  [ "${with_respect}" = "true" ] && sync_options='["CreateNamespace=true", "RespectIgnoreDifferences=true"]'
  cat <<EOF
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
    syncOptions: ${sync_options}
EOF
  if [ "${with_ignore}" = "true" ]; then
    cat <<EOF
  ignoreDifferences:
    - group: apps
      kind: Deployment
      name: storefront
      jsonPointers: ["${JSON_POINTER}"]
EOF
  fi
}

annotation_now() {
  kubectl get deployment storefront -n "${NS}" -o jsonpath="{.metadata.annotations.${ANNOTATION_KEY//./\\.}}" 2>/dev/null || true
}

step "baseline sync, manual policy so every step below is an explicit, observable action"
app_yaml "" "" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null
wait_for_sync "${APP}" 180

step "simulate the webhook: annotate the live Deployment, a field Git knows nothing about"
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=$(date -u +%FT%TZ)" --overwrite >/dev/null
argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
sync1="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${sync1}" = "OutOfSync" ]; then
  _pass "OutOfSync — Git has no such annotation, so it counts as drift, as the lesson opens on"
else
  _fail "expected OutOfSync after the simulated webhook annotation, got '${sync1:-empty}'"
fi

step "add ignoreDifferences — the diff goes quiet, but the annotation is still only on the LIVE object"
app_yaml "true" "" | kubectl apply -f - >/dev/null
argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
sync2="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
still_there="$(annotation_now)"
if [ "${sync2}" = "Synced" ] && [ -n "${still_there}" ]; then
  _pass "ignoreDifferences hid the field — Synced again, and the annotation is still sitting on the live object, still absent from Git"
else
  _fail "expected Synced with the annotation still present, got sync=${sync2:-?} annotation='${still_there:-empty}' — ignoreDifferences did not behave as a diff-only mask"
fi

step "prove it is diff-only: an explicit sync still wipes the ignored field"
argocd app sync "${APP}" >/dev/null
after_sync="$(annotation_now)"
if [ -z "${after_sync}" ]; then
  _pass "the annotation is gone after an explicit sync — ignoreDifferences changed what the dashboard shows, not what a sync applies"
else
  _fail "the annotation survived an explicit sync with only ignoreDifferences set (no RespectIgnoreDifferences) — this contradicts the documented, and load-bearing, distinction this lesson teaches"
fi

step "add RespectIgnoreDifferences — THIS is what actually protects the field, on an object that already exists"
app_yaml "true" "true" | kubectl apply -f - >/dev/null
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=$(date -u +%FT%TZ)" --overwrite >/dev/null
argocd app sync "${APP}" >/dev/null
protected="$(annotation_now)"
if [ -n "${protected}" ]; then
  _pass "RespectIgnoreDifferences=true protected the field through an explicit sync — the annotation survived: ${protected}"
else
  _fail "the annotation did not survive a sync with RespectIgnoreDifferences=true set — the one setting that is supposed to actually protect the field failed to"
fi

step "prove the documented limit: it only protects a resource that already exists"
kubectl delete deployment storefront -n "${NS}" >/dev/null
argocd app sync "${APP}" >/dev/null
kubectl rollout status deployment/storefront -n "${NS}" --timeout=120s >/dev/null 2>&1 || true
after_recreate="$(annotation_now)"
if [ -z "${after_recreate}" ]; then
  _pass "on a fresh creation, the annotation-shaped hole is applied as-written — RespectIgnoreDifferences has no live object to protect a field of"
else
  _fail "the annotation survived a full recreation ('${after_recreate}') — RespectIgnoreDifferences is protecting fields on OBJECT CREATION too now, which is a documented limit the lesson explicitly says does not hold"
fi

smoke_done
