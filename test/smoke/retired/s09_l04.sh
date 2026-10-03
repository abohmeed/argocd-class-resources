#!/usr/bin/env bash
# S09 L04 — the CLI convenience (argocd cluster add), and the in-cluster entry the CLI cannot
# remove.
#
# Two behavioural claims, both proven only against a real second cluster (prod-us) and a live
# argocd CLI session: `argocd cluster add` writes exactly the labelled-Secret shape S09 L03
# hand-authored, and `argocd cluster rm in-cluster` ERRORS rather than no-opping — the docs say
# the in-cluster entry cannot be removed this way, and the fix is the
# cluster.inClusterEnabled: "false" key in argocd-cm, not a CLI verb. None of that runs on a
# single-node CI cluster. What is checkable here is the repo-side invariant this lesson and L03
# share: no committed manifest hardcodes a cluster address, and the dead cluster2/cluster3 names
# never come back.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L04 "argocd cluster add writes the same Secret shape as a hand-authored one, and cluster rm in-cluster ERRORS rather than no-opping"
tier external

step "repo-side invariant: no hardcoded private/loopback IP in any committed manifest"
# An array, not a space-joined string — REPO_ROOT contains spaces ("Mastering GitOps with Argo
# CD"), and a space-joined path list silently word-splits into bogus grep targets that read
# nothing and report a green tick for a scan that never ran.
targets=()
for d in apps applicationsets bootstrap teams platform; do
  [ -d "${REPO_ROOT}/${d}" ] && targets+=("${REPO_ROOT}/${d}")
done
hits="$(grep -rInE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|127\.0\.0\.1)([^0-9]|$)' \
  --include='*.yaml' --include='*.yml' --exclude=install.yaml "${targets[@]}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no hardcoded private or loopback IP in any committed manifest"
else
  _fail "hardcoded private/loopback IP found — addresses are discovered at merge time (S09 L02), never pasted:\n${hits}"
fi

step "repo-side invariant: if platform/argocd-cm.yaml is committed, it disables in-cluster the documented way"
if [ -f "${REPO_ROOT}/platform/argocd-cm.yaml" ]; then
  assert_file_contains "platform/argocd-cm.yaml" 'cluster\.inClusterEnabled: *"?false"?' \
    "platform/argocd-cm.yaml sets cluster.inClusterEnabled: \"false\" — the only documented way to disable the in-cluster entry"
else
  _pass "platform/argocd-cm.yaml not committed yet — S09 L04 authors it live, from the running cluster's own state"
fi

needs_external "a second cluster (prod-us) and a live argocd CLI session against the hub" \
  "verified by hand: 'argocd cluster rm in-cluster' returns FATA rpc error: code = NotFound rather than succeeding, and 'cluster.inClusterEnabled: \"false\"' in argocd-cm is what actually removes it from 'argocd cluster list' — this needs a second registered cluster and a real argocd CLI session, neither available on this single k3s CI node"
