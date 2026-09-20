#!/usr/bin/env bash
# S02 L03 — the 262144-byte wall is a REAL client-side-apply failure, and --server-side
# --force-conflicts is what actually clears it.
#
# `s02_control_plane.sh` already installs Argo CD server-side and checks the ApplicationSet CRD
# is over the annotation ceiling — but it never reproduces the FAILURE this lesson is named
# for: a plain `kubectl apply` upgrading a pre-3.3 install. If upstream ever shrank that CRD
# back under the wall, or server-side apply stopped being the fix, this marquee "watch it fail,
# then watch the fix work" moment would silently stop reproducing. So this drives that exact
# sequence and checks the failure is real before checking the fix is real.
#
# No probe-namespace isolation here: Argo CD's own install.yaml pins `namespace: argocd` inside
# most of its objects, so `kubectl apply -n <other>` does not actually redirect them — the
# runbook's own Preconditions do the same thing this script does (delete namespace argocd,
# reinstall from a clean baseline). Like `s02_control_plane.sh`, this ends with Argo CD
# ${ARGOCD_PIN} installed server-side in "argocd" and DELIBERATELY leaves it — S02 L04 and
# everything after it depends on exactly that state (this lesson's runbook: "Teardown: None").
# A future run_all.sh cluster-tier pass should run this on its own cluster, same as
# s02_control_plane.sh, not chained after another script that also owns "argocd".
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L03 "a client-side kubectl apply from pre-3.3 to ${ARGOCD_PIN} fails on the 262144-byte annotation ceiling; --server-side --force-conflicts is what fixes it"
tier cluster

BASELINE="https://raw.githubusercontent.com/argoproj/argo-cd/v3.2.12/manifests/install.yaml"
TARGET="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_PIN}/manifests/install.yaml"

step "start from a clean slate — delete any prior 'argocd' namespace"
kubectl delete namespace argocd --wait=true --timeout=120s >/dev/null 2>&1 || true

step "install the pre-3.3 baseline (v3.2.12), client-side — 'this always worked before'"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd -f "${BASELINE}" >/dev/null
_pass "v3.2.12 baseline applied client-side, exactly as the docs' own command does"

step "the plain 'upgrade' anyone following the docs would run must FAIL"
out="$(kubectl apply -n argocd -f "${TARGET}" 2>&1)"; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'may not be more than 262144 bytes'; then
  _pass "client-side apply failed with the exact 262144-byte annotation error the lesson shows on screen"
elif [ "${rc}" -eq 0 ]; then
  _fail "client-side apply from v3.2.12 to ${ARGOCD_PIN} SUCCEEDED — the marquee failure this lesson is built on no longer reproduces; either the ApplicationSet CRD shrank back under the wall or something else changed. RESTAGE BEFORE RECORDING."
else
  _fail "client-side apply failed, but not with the 262144-byte error the lesson names on camera:\n${out}"
fi

step "--server-side --force-conflicts is what actually fixes it"
if kubectl apply --server-side --force-conflicts -n argocd -f "${TARGET}" >/dev/null 2>&1; then
  _pass "server-side apply with --force-conflicts succeeded where the plain apply failed"
else
  _fail "server-side apply with --force-conflicts ALSO failed — the lesson's fix is broken, not just its problem"
fi

step "the CRD really is past the ceiling — proves the failure was real, not a fluke of this run"
size="$(kubectl get crd applicationsets.argoproj.io -o json | wc -c | tr -d ' ')"
if [ "${size}" -gt 262144 ]; then
  _pass "ApplicationSet CRD is ${size} bytes — genuinely over the 262144-byte ceiling"
else
  _fail "ApplicationSet CRD is only ${size} bytes — under the ceiling, so Step 2's failure was not actually caused by what the lesson says it was caused by"
fi

step "field managers really did stack — the mechanism S02 L03's closing beat points at"
managers="$(kubectl get crd applicationsets.argoproj.io -o jsonpath='{range .metadata.managedFields[*]}{.manager}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
if [ "${managers}" -gt 1 ]; then
  _pass "${managers} distinct field managers on the CRD — client-side and server-side applies both left their mark, as the lesson shows"
else
  _fail "only ${managers} field manager on the CRD — expected the leftover client-side manager plus the new server-side one"
fi

step "every component the pods rely on is up before the next lesson's Preconditions check it"
kubectl wait --for=condition=Available deploy/argocd-server -n argocd --timeout=180s >/dev/null 2>&1 \
  && _pass "argocd-server is Available" \
  || _fail "argocd-server never became Available after the server-side apply"

smoke_done
