#!/usr/bin/env bash
# S09 L08 — sharding the application controller (alpha).
#
# The corrected fact this lesson teaches: algorithm selection lives in argocd-cmd-params-cm
# (backing ARGOCD_CONTROLLER_SHARDING_ALGORITHM / --sharding-method), NOT argocd-cm, and only
# round-robin/consistent-hashing are alpha-tracked — legacy (the plain default) is not. That
# wiring is checkable straight from the pinned vendor manifest, no live cluster needed.
#
# What is deliberately NOT attempted here: actually converting argocd-application-controller
# from a Deployment to a StatefulSet and sharding it to three replicas. That conversion is a
# ONE-WAY structural change to the shared control plane — this runbook's own Teardown says so
# ("None of this is undone — S09 L09 builds directly on a sharded, three-replica controller").
# CI's cluster job runs every per-lesson cluster-tier script back to back against ONE shared k3s
# node; a script that permanently reshapes argocd-application-controller with no revert path
# would corrupt every other cluster-tier script that runs after it in the same job, which is a
# worse failure mode than declaring this one external.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L08 "sharding algorithm selection lives in argocd-cmd-params-cm, not argocd-cm, and only two of the three algorithms are alpha"
tier repo

INSTALL="bootstrap/install.yaml"

step "the pinned Argo CD manifest wires sharding through argocd-cmd-params-cm, not argocd-cm"
assert_exists_file "${INSTALL}"
# The env var ARGOCD_CONTROLLER_SHARDING_ALGORITHM must be sourced from argocd-cmd-params-cm,
# specifically — checked as a contiguous block so a future re-pin that moves it to argocd-cm
# (the easy place to look first, and the wrong one) is caught here rather than on camera.
block="$(awk '/name: ARGOCD_CONTROLLER_SHARDING_ALGORITHM/{f=1} f{print; if(/name: argocd-cmd-params-cm|name: argocd-cm$/) exit}' "${REPO_ROOT}/${INSTALL}")"
if [ -z "${block}" ]; then
  _fail "ARGOCD_CONTROLLER_SHARDING_ALGORITHM is not wired in ${INSTALL} at all — the pinned manifest changed shape; restage before recording"
elif printf '%s' "${block}" | grep -q 'name: argocd-cmd-params-cm'; then
  _pass "ARGOCD_CONTROLLER_SHARDING_ALGORITHM is sourced from argocd-cmd-params-cm, exactly as the lesson corrects"
else
  _fail "ARGOCD_CONTROLLER_SHARDING_ALGORITHM is NOT sourced from argocd-cmd-params-cm in this pinned manifest — the lesson's central correction no longer holds; RESTAGE BEFORE RECORDING:\n${block}"
fi

needs_external "the live application-controller StatefulSet conversion, Dynamic Cluster Distribution, and shard reassignment" \
  "verified once by hand per this lesson's runbook; not attempted here because converting argocd-application-controller from a Deployment to a sharded StatefulSet is a one-way change to the shared control plane every other cluster-tier script in this suite depends on, and this CI cluster has no isolated cluster to sacrifice for it"
