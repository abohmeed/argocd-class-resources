#!/usr/bin/env bash
# S06 L09 — sync options, and what selective sync gives up.
#
# Two claims, both about what Argo CD skips when you ask it to touch only one resource: a
# selective sync (`--resource ...`) does not add an entry to `argocd app history` the way a full
# sync does, and it does not run the phases hooks fire in — a PreSync hook sitting in the same
# Application is NOT re-triggered by a selective sync of an unrelated resource. The byte-ceiling /
# ServerSideApply mechanism this lesson also covers is already proven by S02 L03's own smoke test
# against the real ApplicationSet CRD (test/smoke/s02_control_plane.sh); this script does not
# duplicate it and focuses on what's unique to L09. All four sync options are also confirmed
# settable. Runs against a scratch Application this script owns.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l09"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
WORKDIR="$(mktemp -d)"

lesson S06-L09 "selective sync touches only the named resource — it skips both the history entry and the hook phases a full sync runs"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

cleanup() {
  argocd app delete "${APP}" --cascade --yes >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat > "${WORKDIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - hook-job.yaml
EOF
cat > "${WORKDIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: probe}
  template:
    metadata:
      labels: {app: probe}
    spec:
      containers:
        - name: probe
          image: ${HTTP_ECHO_IMAGE}
          args: ["-listen=:5678", "-text=probe-v1"]
EOF
cat > "${WORKDIR}/hook-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: probe-presync
  namespace: ${NS}
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: busybox:1.37
          command: ["sh", "-c", "true"]
EOF

argocd app create "${APP}" --repo "${REPO}" --path apps/checkout/base \
  --dest-namespace "${NS}" --dest-server https://kubernetes.default.svc \
  --sync-policy none >/dev/null

step "all four sync options set cleanly"
for opt in ServerSideApply=true CreateNamespace=true Replace=true SkipDryRunOnMissingResource=true; do
  argocd app set "${APP}" --sync-option "${opt}" >/dev/null
done
opts="$(argocd app get "${APP}" -o yaml 2>/dev/null | grep -A6 'syncOptions:' || true)"
for opt in ServerSideApply=true CreateNamespace=true Replace=true SkipDryRunOnMissingResource=true; do
  if printf '%s' "${opts}" | grep -qF "${opt}"; then
    _pass "sync option ${opt} is set"
  else
    _fail "sync option ${opt} did not stick — 'argocd app get' does not list it under syncOptions"
  fi
done

step "a full sync appears in history, and the PreSync hook fires"
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
kubectl wait --for=condition=complete job/probe-presync -n "${NS}" --timeout=60s >/dev/null 2>&1 \
  || _fail "PreSync hook never completed on the full sync — cannot test what selective sync skips relative to it"
hist_before="$(argocd app history "${APP}" 2>/dev/null | grep -c . || true)"
hook_rv_before="$(kubectl get job probe-presync -n "${NS}" -o jsonpath='{.metadata.resourceVersion}')"
_pass "full sync completed, history has ${hist_before} line(s), hook Job at resourceVersion ${hook_rv_before}"

step "selective sync of just the Deployment — no new history entry, no new hook run"
sed -i.bak 's/probe-v1/probe-v2/' "${WORKDIR}/deployment.yaml" && rm -f "${WORKDIR}/deployment.yaml.bak"
argocd app sync "${APP}" --local "${WORKDIR}" --resource apps:Deployment:probe >/dev/null 2>&1 || true
sleep 5
hist_after="$(argocd app history "${APP}" 2>/dev/null | grep -c . || true)"
[ "${hist_after}" -eq "${hist_before}" ] \
  && _pass "history is still ${hist_after} line(s) — the selective sync did not add an entry" \
  || _fail "history grew from ${hist_before} to ${hist_after} lines — a selective sync should not appear in rollback history"

hook_rv_after="$(kubectl get job probe-presync -n "${NS}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
[ "${hook_rv_after}" = "${hook_rv_before}" ] \
  && _pass "the PreSync hook Job is unchanged (still resourceVersion ${hook_rv_after}) — selective sync skipped the hook phase entirely" \
  || _fail "the PreSync hook Job changed (resourceVersion ${hook_rv_before} -> ${hook_rv_after}) — selective sync should not have touched the hook phases at all"

smoke_done
