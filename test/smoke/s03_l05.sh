#!/usr/bin/env bash
# ACD-138
# S03 L05: ignoreDifferences hides a field from the diff; it does not protect it from a sync.
# RespectIgnoreDifferences does protect it, and only on a resource that already exists.
#
# Git declares the field: apps/storefront/base/deployment.yaml carries
# northwind.io/scanned-at: "pending" (D-334). A webhook-style timestamp written onto the live
# object is therefore drift, and every apply of the manifest puts "pending" back.
#
# The claims, in order, each one falsifiable on its own:
#   1. a timestamp on the live object reads as OutOfSync, because Git says "pending".
#   2. ignoreDifferences makes that field invisible to diff/sync-status.
#   3. that same field is still RESET to "pending" by the very next sync: ignoreDifferences is
#      diff-only.
#   4. adding syncOptions: [RespectIgnoreDifferences=true] is what actually protects the field
#      on an apply, but ONLY when the object already exists; a fresh creation still gets the
#      manifest as written, "pending" and all.
#   5. with selfHeal on and no ignoreDifferences, a hand-written timestamp is reverted to
#      "pending" on its own; with ignoreDifferences + RespectIgnoreDifferences=true it survives.
# If Argo CD ever changed so ignoreDifferences alone protected a field on sync (collapsing the
# distinction the whole lesson is built on), or RespectIgnoreDifferences started protecting a
# freshly-created object too, this would go quiet with a green dashboard and no test to catch it.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L05 "ignoreDifferences hides drift from the diff; only RespectIgnoreDifferences protects the field on sync, and only if the object already exists"
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
FROM_GIT="pending"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

app_yaml() {
  # $1: "true" to include ignoreDifferences for the annotation, else ""
  # $2: "true" to also set syncOptions: RespectIgnoreDifferences=true, else ""
  # $3: "true" to turn on automated sync with selfHeal, else "" (manual policy)
  local with_ignore="$1" with_respect="$2" with_selfheal="${3:-}"
  local sync_options='["CreateNamespace=true"]'
  [ "${with_respect}" = "true" ] && sync_options='["CreateNamespace=true", "RespectIgnoreDifferences=true"]'
  local automated=""
  [ "${with_selfheal}" = "true" ] && automated='    automated: {selfHeal: true}'
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev: the dev overlay pins its own namespace, and a manifest's own
  # namespace wins over destination.namespace, so this probe would silently land in the real,
  # shared storefront-dev namespace. base pins none, so destination.namespace applies cleanly.
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
${automated}
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
baseline="$(annotation_now)"
if [ "${baseline}" = "${FROM_GIT}" ]; then
  _pass "the live Deployment carries ${ANNOTATION_KEY}=${FROM_GIT}, as Git declares it"
else
  _fail "expected ${ANNOTATION_KEY}='${FROM_GIT}' after the baseline sync (Git declares it), got '${baseline:-empty}'"
fi

step "simulate the webhook: overwrite the annotation on the live Deployment with a timestamp"
stamp1="$(date -u +%FT%TZ)"
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=${stamp1}" --overwrite >/dev/null
argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
sync1="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${sync1}" = "OutOfSync" ]; then
  _pass "OutOfSync: Git says '${FROM_GIT}', the live object says '${stamp1}', so it counts as drift, as the lesson opens on"
else
  _fail "expected OutOfSync after the simulated webhook annotation (Git declares '${FROM_GIT}'), got '${sync1:-empty}'"
fi

step "add ignoreDifferences: the diff goes quiet, but the timestamp is still only on the LIVE object"
app_yaml "true" "" | kubectl apply -f - >/dev/null
argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
sync2="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
still_there="$(annotation_now)"
if [ "${sync2}" = "Synced" ] && [ "${still_there}" = "${stamp1}" ]; then
  _pass "ignoreDifferences hid the field: Synced again, and the timestamp is still sitting on the live object while Git says '${FROM_GIT}'"
else
  _fail "expected Synced with the annotation still '${stamp1}', got sync=${sync2:-?} annotation='${still_there:-empty}': ignoreDifferences did not behave as a diff-only mask"
fi

step "prove it is diff-only: an explicit sync still resets the ignored field to Git's value"
argocd app sync "${APP}" >/dev/null
after_sync="$(annotation_now)"
if [ "${after_sync}" = "${FROM_GIT}" ]; then
  _pass "the annotation is back to '${FROM_GIT}' after an explicit sync: ignoreDifferences changed what the dashboard shows, not what a sync applies"
else
  _fail "after an explicit sync with only ignoreDifferences set (no RespectIgnoreDifferences), expected '${FROM_GIT}', got '${after_sync:-empty}': this contradicts the documented, and load-bearing, distinction this lesson teaches"
fi

step "add RespectIgnoreDifferences: THIS is what actually protects the field, on an object that already exists"
app_yaml "true" "true" | kubectl apply -f - >/dev/null
stamp2="$(date -u +%FT%TZ)"
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=${stamp2}" --overwrite >/dev/null
argocd app sync "${APP}" >/dev/null
protected="$(annotation_now)"
if [ "${protected}" = "${stamp2}" ]; then
  _pass "RespectIgnoreDifferences=true protected the field through an explicit sync: the timestamp survived: ${protected}"
else
  _fail "expected the annotation to stay '${stamp2}' through a sync with RespectIgnoreDifferences=true, got '${protected:-empty}': the one setting that is supposed to actually protect the field failed to"
fi

step "prove the documented limit: it only protects a resource that already exists"
kubectl delete deployment storefront -n "${NS}" >/dev/null
argocd app sync "${APP}" >/dev/null
kubectl rollout status deployment/storefront -n "${NS}" --timeout=120s >/dev/null 2>&1 || true
after_recreate="$(annotation_now)"
if [ "${after_recreate}" = "${FROM_GIT}" ]; then
  _pass "on a fresh creation, the manifest is applied as written ('${FROM_GIT}'): RespectIgnoreDifferences has no live object to protect a field of"
else
  _fail "after a full recreation expected '${FROM_GIT}', got '${after_recreate:-empty}': RespectIgnoreDifferences is protecting fields on OBJECT CREATION too now, which is a documented limit the lesson explicitly says does not hold"
fi

step "selfHeal with no ignoreDifferences: a hand-written timestamp is put back to Git's value on its own"
app_yaml "" "" "true" | kubectl apply -f - >/dev/null
wait_for_sync "${APP}" 180
stamp3="$(date -u +%FT%TZ)"
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=${stamp3}" --overwrite >/dev/null
reverted=no
for _ in $(seq 1 24); do
  sleep 5
  [ "$(annotation_now)" = "${FROM_GIT}" ] && { reverted=yes; break; }
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
done
if [ "${reverted}" = yes ]; then
  _pass "selfHeal reverted the timestamp '${stamp3}' back to '${FROM_GIT}', as the lesson shows on screen"
else
  _fail "selfHeal did NOT revert the timestamp within 120s (annotation='$(annotation_now)'): the problem the lesson opens on does not reproduce"
fi

step "selfHeal with ignoreDifferences + RespectIgnoreDifferences=true: the timestamp survives"
app_yaml "true" "true" "true" | kubectl apply -f - >/dev/null
wait_for_sync "${APP}" 180
stamp4="$(date -u +%FT%TZ)"
kubectl annotate deployment storefront -n "${NS}" "${ANNOTATION_KEY}=${stamp4}" --overwrite >/dev/null
survived=yes
for _ in $(seq 1 6); do
  sleep 5
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
  [ "$(annotation_now)" = "${stamp4}" ] || { survived=no; break; }
done
sync5="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${survived}" = yes ] && [ "${sync5}" = "Synced" ]; then
  _pass "with selfHeal on, the timestamp '${stamp4}' stood for 30s and the app stayed Synced: the field is now the webhook's, not Git's"
else
  _fail "expected the timestamp '${stamp4}' to survive selfHeal with the app Synced, got annotation='$(annotation_now)' sync=${sync5:-?}: ignoreDifferences + RespectIgnoreDifferences no longer hold the field against selfHeal"
fi

smoke_done
