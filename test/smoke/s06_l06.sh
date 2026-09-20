#!/usr/bin/env bash
# S06 L06 — a worked PreSync migration, done right.
#
# The claim is about PHASE ordering, not wave ordering alone: PreSync hooks all run before any
# ordinary Sync-phase resource, regardless of wave. So a plain, non-hook ConfigMap — however
# "obviously fine" it looks — is not guaranteed to exist yet when a PreSync-hook Job tries to
# mount it, and the mount hangs. Making the ConfigMap itself a PreSync hook, one wave ahead of the
# Job, is what actually fixes it. Driven through a scratch Application synced with `--local`, using
# a trivial container that reads the mounted file instead of the lesson's real SQL migration — the
# phase-ordering mechanism this defends doesn't depend on what the mounted content is used for.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l06"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
WORKDIR="$(mktemp -d)"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

lesson S06-L06 "a plain, non-hook ConfigMap is not guaranteed to exist before a PreSync Job that mounts it — making it a PreSync hook one wave ahead fixes that"
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

argocd app create "${APP}" --repo "${REPO}" --path apps/checkout/base \
  --dest-namespace "${NS}" --dest-server https://kubernetes.default.svc \
  --sync-policy none >/dev/null

step "the ConfigMap is a PLAIN resource (no hook), the Job is a PreSync hook that mounts it — reproduce the ordering break"
mkdir -p "${WORKDIR}"
cat > "${WORKDIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - configmap.yaml
  - job.yaml
EOF
cat > "${WORKDIR}/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: probe-payload
  namespace: ${NS}
data:
  payload.txt: "s06l06-ok"
EOF
cat > "${WORKDIR}/job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: probe-migrate
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
          command: ["sh", "-c", "cat /payload/payload.txt"]
          volumeMounts:
            - name: payload
              mountPath: /payload
      volumes:
        - name: payload
          configMap:
            name: probe-payload
EOF
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
sleep 20
if kubectl wait --for=condition=complete job/probe-migrate -n "${NS}" --timeout=1s >/dev/null 2>&1; then
  _fail "the PreSync Job completed even with a non-hook ConfigMap — the ordering break this lesson demonstrates did not reproduce; a change upstream may have altered phase ordering"
else
  _pass "the PreSync Job has NOT completed — it started before its non-hook ConfigMap existed, exactly as the lesson says it will"
fi

step "fix it: the ConfigMap becomes a PreSync hook at wave -1, one wave ahead of the Job"
kubectl delete job probe-migrate -n "${NS}" --ignore-not-found >/dev/null 2>&1
cat > "${WORKDIR}/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: probe-payload
  namespace: ${NS}
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/sync-wave: "-1"
data:
  payload.txt: "s06l06-ok"
EOF
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
kubectl wait --for=condition=complete job/probe-migrate -n "${NS}" --timeout=60s >/dev/null 2>&1 \
  || _fail "the PreSync Job still did not complete even after the ConfigMap became a wave -1 PreSync hook — the fix the lesson teaches does not reproduce"
output="$(kubectl logs job/probe-migrate -n "${NS}" 2>/dev/null || true)"
[ "${output}" = "s06l06-ok" ] \
  && _pass "with the ConfigMap wave-ordered ahead of it, the Job completed and read the mounted content correctly" \
  || _fail "Job completed but read '${output}', not 's06l06-ok' — the mount is not picking up the intended ConfigMap"

smoke_done
