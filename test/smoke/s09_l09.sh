#!/usr/bin/env bash
# S09 L09 — scaling the repo-server and Redis, and finding the real bottleneck.
#
# Two corrected facts are checkable straight from the pinned vendor manifest, no live cluster
# needed: ARGOCD_REPO_SERVER_PARALLELISM_LIMIT is a real, wired env var backing
# --parallelismlimit, and argocd-redis's image is a plain official Redis build — never Bitnami,
# anywhere in Argo CD's own HA path (the blocking collision the fact-check cleared).
#
# What is NOT attempted here: the live diagnosis (kubectl top pressure comparison, scaling
# repo-server to 4 replicas, re-checking sync latency). That needs the sharded controller from
# S09 L08 and the multi-cluster fleet's real reconciliation load from S09 L07, neither of which
# exists on this single-node CI cluster — and L08's own script explains why the sharding
# precondition is not created here either.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L09 "ARGOCD_REPO_SERVER_PARALLELISM_LIMIT is a real wired env var, and Redis in Argo CD's own HA path is never Bitnami"
tier repo

INSTALL="bootstrap/install.yaml"

step "the pinned Argo CD manifest wires ARGOCD_REPO_SERVER_PARALLELISM_LIMIT"
assert_exists_file "${INSTALL}"
assert_file_contains "${INSTALL}" 'name: ARGOCD_REPO_SERVER_PARALLELISM_LIMIT' \
  "ARGOCD_REPO_SERVER_PARALLELISM_LIMIT is present in the pinned manifest, backing --parallelismlimit"

step "argocd-redis in this pinned manifest is never a Bitnami image"
line="$(grep -m1 'image: .*redis' "${REPO_ROOT}/${INSTALL}" || true)"
if [ -z "${line}" ]; then
  _fail "no redis image found in ${INSTALL} at all — the pinned manifest changed shape; restage before recording"
elif printf '%s' "${line}" | grep -qi bitnami; then
  _fail "argocd-redis pins a Bitnami image — Bitnami's free chart repo went paid in 2025, and this course bans it outright: ${line}"
else
  _pass "argocd-redis pins a non-Bitnami image (${line# })"
fi

step "repo-wide: no Bitnami source and no ingress-nginx anywhere (the course-wide bans)"
assert_no_forbidden_sources

needs_external "kubectl top pressure readings, a sharded controller (S09 L08) and real fleet reconciliation load (S09 L07) to show repo-server as the actual bottleneck" \
  "verified once by hand per this lesson's runbook; this single k3s CI node has neither the sharded controller nor a multi-cluster fleet to generate realistic reconciliation pressure"
