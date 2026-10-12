#!/usr/bin/env bash
# lesson: s03_l03 Sync status vs health status: two different questions
# Sync status and health status are independent axes.
#
# The lesson's whole point is the contrast: a bad image tag, once synced, makes the Application
# Synced (the cluster now matches the declared desired state exactly, bad tag included) AND
# Degraded (the container can't actually run) at the same time. If a future Argo CD ever folded
# health into the sync computation, or started refusing to mark a broken rollout "Synced", the
# lesson's central "the dashboard shows a green badge and the app is down" hook goes false. This
# drives a real cluster to the SAME independent-axes state the lesson reaches with a bad tag
# pushed to Git, using an Application-level image override instead of a commit to the shared
# companion repo (this script never writes to that repo).
#
# Measured on v3.5.3, and what the lesson now says: health reads Progressing first, and
# only turns Degraded once the Deployment's progressDeadlineSeconds passes (600 s by default).
# The probe lowers that deadline to 30 s with an Application-level kustomize patch, so it can
# assert the whole sequence the lesson shows (Synced + Progressing, then Synced + Degraded)
# in about a minute instead of ten.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L03 "a synced bad image tag reads Synced + Progressing, then Synced + Degraded once the progress deadline passes: sync and health answer different questions"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

APP="s03l03-probe"
NS="s03l03-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
BAD_IMAGE="ghcr.io/northwind/storefront:1.4.2-typo"
GOOD_IMAGE_OVERRIDE="hashicorp/http-echo:1.0"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

app_yaml() {
  local image_override="$1"
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source:
    repoURL: "${REPO}"
    targetRevision: main
    # base, NOT overlays/dev: the dev overlay pins its own namespace, and a manifest's own
    # namespace wins over destination.namespace, so this probe would silently land in the real,
    # shared storefront-dev namespace. base pins none, so destination.namespace applies cleanly.
    path: apps/storefront/base
    kustomize:
      images: ["${image_override}"]
      patches:
        - target: {kind: Deployment, name: storefront}
          patch: |-
            - op: add
              path: /spec/progressDeadlineSeconds
              value: 30
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF
}

step "sync a KNOWN-broken image tag as the declared desired state (Application-level override, no Git write)"
# hashicorp/http-echo=<bad tag> replaces the base image name and tag in one kustomize override,
# exactly as the lesson's Step 1 does by editing apps/storefront/base/deployment.yaml directly.
app_yaml "hashicorp/http-echo=${BAD_IMAGE}" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null 2>&1 || true

step "read both fields on the same object"
deadline=$(( $(date +%s) + 150 ))
sync="" health="" seen_progressing=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  sync="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "${sync}" = "Synced" ] && [ "${health}" = "Progressing" ] && seen_progressing=yes
  [ "${sync}" = "Synced" ] && [ "${health}" = "Degraded" ] && break
  sleep 3
done
if [ -n "${seen_progressing}" ]; then
  _pass "Synced + Progressing first, while the new Pod fails to pull: the state the lesson reads on screen"
else
  _fail "never saw Synced + Progressing before the deadline passed; the lesson's first reading (Progressing, not Degraded) did not reproduce"
fi
if [ "${sync}" = "Synced" ] && [ "${health}" = "Degraded" ]; then
  _pass "then sync=Synced, health=Degraded once the (lowered) progress deadline passed: the cluster matches the declared bad tag exactly, and it still doesn't run"
else
  _fail "expected Synced+Degraded after the 30 s progress deadline, got sync=${sync:-?} health=${health:-?}: either the bad tag didn't sync cleanly or health no longer reports the pull failure independently"
fi

step "confirm the reason is what the lesson names: an image pull failure, not something else"
if kubectl get events -n "${NS}" --field-selector reason=Failed 2>/dev/null | grep -qiE 'pull|image'; then
  _pass "an image-pull failure event is present: Degraded means what the lesson says it means"
else
  _fail "no image-pull failure event found in ${NS}: Degraded health for an unrelated reason would misrepresent the lesson's cause"
fi

step "fix the tag: health recovers only once the rollout actually completes"
app_yaml "hashicorp/http-echo=${GOOD_IMAGE_OVERRIDE}" | kubectl apply -f - >/dev/null
argocd app sync "${APP}" >/dev/null
wait_for_rollout "deployment/storefront" "${NS}"
wait_for_sync "${APP}" 120

step "OutOfSync but Healthy: a live scale-up drifts from Git while the extra Pod runs fine"
kubectl scale deployment storefront -n "${NS}" --replicas=2 >/dev/null
deadline=$(( $(date +%s) + 60 ))
drift_sync=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  drift_sync="$(argocd app get "${APP}" --refresh -o json >/dev/null 2>&1; kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [ "${drift_sync}" = "OutOfSync" ] && break
  sleep 5
done
drift_health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
if [ "${drift_sync}" = "OutOfSync" ] && [ "${drift_health}" = "Healthy" ]; then
  _pass "OutOfSync + Healthy: drift without breakage, the mirror image of the earlier case"
else
  _fail "expected OutOfSync+Healthy after a live scale-up, got sync=${drift_sync:-?} health=${drift_health:-?}: watching health alone would no longer hide this kind of drift the way the lesson says it does"
fi

smoke_done
