#!/usr/bin/env bash
# S03 L02 — reconciliation is a timer, and refresh/hard-refresh short-circuit it.
#
# The lesson's claim is behavioural: drift is noticed on its own within the shipped
# reconciliation window (timeout.reconciliation=120s, +/- jitter up to 60s) with no command run
# against the Application, and `--refresh` forces the same detection immediately instead of
# waiting. If the defaults were ever overridden in bootstrap/install.yaml, or if a future Argo CD
# stopped reconciling on a timer at all, the lecture's "is it broken or does it just not know
# yet" hook would stop being true. This drives a real cluster and watches both paths.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L02 "drift is noticed on a ~120-180s timer with no command run, and --refresh forces the same detection immediately"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "repo-side invariant: the shipped reconciliation defaults are not overridden"
# argocd-cm has no data: key at all in the committed bootstrap/install.yaml (vanilla upstream
# shape) — if a timeout.reconciliation override is ever added there, the 120-180s window this
# script waits on, and the number the narration says out loud, both go stale silently.
# Match an actual SETTING, not the wiring. The stock install.yaml mentions
# `key: timeout.reconciliation` three times — those are `configMapKeyRef` entries wiring the
# controller's env to a key that argocd-cm does not define, which is exactly how a default stays
# a default. An override would be a YAML key WITH a value (`  timeout.reconciliation: 300s`) in
# argocd-cm's data block. The first version of this matched the references and failed on a
# perfectly stock manifest.
assert_file_lacks "bootstrap/install.yaml" "^[[:space:]]+timeout\.reconciliation:[[:space:]]*[^[:space:]]" \
  "no timeout.reconciliation override in argocd-cm — the lesson's 120-180s window is still the shipped default"

APP="s03l02-probe"
NS="s03l02-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "create the Application, manual sync policy so nothing auto-applies while we watch"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev — the dev overlay pins its own namespace in kustomization.yaml, and a
  # namespace set in the manifest wins over destination.namespace, so this probe would silently
  # land in the real, shared storefront-dev namespace instead of its own isolated one. base pins
  # no namespace, so destination.namespace below applies cleanly.
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF
argocd app sync "${APP}" >/dev/null
wait_for_sync "${APP}" 180

step "drift the live object without touching Git — the same shape of change a push would cause"
kubectl patch configmap storefront-banner -n "${NS}" --type merge -p '{"data":{"banner":"drifted by hand"}}' >/dev/null

step "watch the reconciliation loop notice on its own, no --refresh, no argocd app get in between"
started=$(date +%s)
detected=no
for _ in $(seq 1 40); do
  sleep 5
  sync="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  if [ "${sync}" = "OutOfSync" ]; then
    detected=yes
    break
  fi
done
elapsed=$(( $(date +%s) - started ))
if [ "${detected}" = yes ]; then
  _pass "reconciliation noticed the drift on its own after ~${elapsed}s, no command run against the Application — matches the shipped 120-180s window"
else
  _fail "no OutOfSync after 200s with nothing run against the Application — reconciliation is not happening on a timer any more, and the lesson's central hook (is it broken, or does it just not know yet) is now false"
fi

step "drift it again, then force detection with --refresh instead of waiting"
kubectl patch configmap storefront-banner -n "${NS}" --type merge -p '{"data":{"banner":"drifted again"}}' >/dev/null
refresh_start=$(date +%s)
argocd app get "${APP}" --refresh >/dev/null 2>&1
sync_now="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
refresh_elapsed=$(( $(date +%s) - refresh_start ))
if [ "${sync_now}" = "OutOfSync" ] && [ "${refresh_elapsed}" -lt 30 ]; then
  _pass "--refresh reported OutOfSync in ~${refresh_elapsed}s — forced detection, not the timer"
else
  _fail "--refresh did not report OutOfSync quickly (got '${sync_now:-empty}' in ${refresh_elapsed}s) — --refresh no longer short-circuits the reconciliation timer"
fi

smoke_done
