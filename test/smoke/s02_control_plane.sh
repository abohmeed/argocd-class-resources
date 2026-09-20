#!/usr/bin/env bash
# S02 L03 — the 262144-byte wall, and server-side apply as the fix.
#
# This is the course's first marquee failure-on-camera. If upstream ever changes so that a plain
# client-side apply succeeds, this test goes red and the lesson needs restaging BEFORE a take.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_PIN}/manifests/install.yaml"

step "S02 L02/L03 — install Argo CD ${ARGOCD_PIN} with server-side apply"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts -f "${MANIFEST}"
_pass "server-side apply succeeded"

step "S02 L03 — confirm the ApplicationSet CRD really is past the annotation ceiling"
size="$(kubectl get crd applicationsets.argoproj.io -o json | wc -c | tr -d ' ')"
if [ "${size}" -gt 262144 ]; then
  _pass "ApplicationSet CRD is ${size} bytes — over the 262144-byte ceiling, so the lesson's failure is real"
else
  _fail "ApplicationSet CRD is only ${size} bytes; the client-side-apply failure may no longer reproduce — RESTAGE THE LESSON before recording"
fi

step "S02 L04 — every component the architecture lesson names is actually running"
for c in argocd-server argocd-repo-server argocd-application-controller argocd-redis \
         argocd-applicationset-controller argocd-notifications-controller argocd-dex-server; do
  if kubectl get all -n argocd -o name | grep -q "${c}"; then
    _pass "${c} present"
  else
    _fail "${c} NOT present — the architecture lesson names it, so either the lesson or this list is wrong"
  fi
done

printf '\n\033[32ms02 passed\033[0m\n'
