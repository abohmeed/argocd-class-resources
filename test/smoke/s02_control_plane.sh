#!/usr/bin/env bash
# The 262144-byte wall, and server-side apply as the fix.
#
# This is the course's first big deliberate failure. If upstream ever changes so that a plain
# client-side apply succeeds, this test goes red and the lesson no longer shows the error it explains.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_PIN}/manifests/install.yaml"

step "install Argo CD ${ARGOCD_PIN} with server-side apply"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "${MANIFEST}"
_pass "server-side apply succeeded"

step "confirm the ApplicationSet CRD really is past the annotation ceiling"
size="$(kubectl get crd applicationsets.argoproj.io -o json | wc -c | tr -d ' ')"
if [ "${size}" -gt 262144 ]; then
  _pass "ApplicationSet CRD is ${size} bytes: over the 262144-byte ceiling, so the lesson's failure is real"
else
  _fail "ApplicationSet CRD is only ${size} bytes; the client-side-apply failure may no longer reproduce, so the lesson no longer matches what students will see"
fi

step "wait for every Argo CD workload to finish rolling out before checking components"
# Without this the check below raced the install: in run 37111303388 it looked for
# argocd-repo-server while that pod was still PodInitializing and failed. Every Deployment and the
# application-controller StatefulSet must report a completed rollout first (bounded, 300s each).
for d in $(kubectl -n argocd get deploy -o name); do
  kubectl -n argocd rollout status "${d}" --timeout=300s >/dev/null \
    || _fail "${d} did not finish rolling out within 300s"
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s >/dev/null \
  || _fail "statefulset/argocd-application-controller did not finish rolling out within 300s"
_pass "every Argo CD Deployment and the application-controller StatefulSet rolled out"

step "every component the architecture lesson names is actually running"
# Read the object list ONCE. Piping kubectl straight into grep -q under pipefail can fail the
# pipeline with SIGPIPE when grep exits early, which reads as "NOT present" for a running component.
objects="$(kubectl get all -n argocd -o name)"
for c in argocd-server argocd-repo-server argocd-application-controller argocd-redis \
         argocd-applicationset-controller argocd-notifications-controller argocd-dex-server; do
  if grep -q "${c}" <<<"${objects}"; then
    _pass "${c} present"
  else
    _fail "${c} NOT present: the architecture lesson names it, so either the lesson or this list is wrong"
  fi
done

printf '\n\033[32ms02 passed\033[0m\n'
