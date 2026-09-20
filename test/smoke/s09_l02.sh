#!/usr/bin/env bash
# S09 L02 — standing up a second and third cluster with Multipass, at an address discovered
# at merge time.
#
# The 2023 course hardcoded three Multipass VM IPs into an HAProxy config and broke the first
# time a home network handed out different addresses. This lesson's whole point is the opposite
# habit: read the address from `multipass info --format json` at the moment it is needed, never
# paste one in. That habit is checkable without a cluster at all — a committed manifest that
# hardcodes a private IP anywhere is the lesson's failure mode, caught here structurally.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L02 "extra k3s clusters are merged into kubeconfig from an address discovered at merge time, never a hardcoded IP"
tier external

step "repo-side invariant: no committed manifest hardcodes a private or loopback IP"
# RFC1918 ranges plus the loopback address the runbook explicitly shows on screen as the
# WRONG address (k3s's own kubeconfig talks to itself over 127.0.0.1 until the real address is
# substituted in). None of those literals belong in a tracked manifest; the whole lesson is
# that the address is read from Multipass at merge time and passed as a shell variable, not
# typed in twice. bootstrap/install.yaml is the vendored, pinned upstream Argo CD manifest —
# out of this lesson's scope — so it is excluded rather than silently making the scan pass by
# reading nothing.
# An array, not a space-joined string — REPO_ROOT itself contains spaces
# ("Mastering GitOps with Argo CD"), and an unquoted path list silently word-splits and turns
# one file into several nonexistent grep targets.
targets=()
for d in apps applicationsets bootstrap teams; do
  [ -d "${REPO_ROOT}/${d}" ] && targets+=("${REPO_ROOT}/${d}")
done
[ "${#targets[@]}" -gt 0 ] || _fail "none of apps/, applicationsets/, bootstrap/, teams/ exist — nothing for this scan to read"
hits="$(grep -rInE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|127\.0\.0\.1)([^0-9]|$)' \
  --include='*.yaml' --include='*.yml' --exclude=install.yaml "${targets[@]}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no hardcoded private or loopback IP in any committed manifest"
else
  _fail "hardcoded private/loopback IP found — the address must be discovered at merge time, never pasted:\n${hits}"
fi

step "repo-side invariant: the dead Multipass VM names from the pre-D-241 draft are gone"
# ANCHORING.md: S09.md, S09.quiz.md and the S09 scripts were renamed off cluster2/cluster3 on
# 2026-09-20. A fleet whose clusters are called cluster2 teaches nothing about why the fleet
# exists, and a stray reintroduction anywhere in the committed manifests is this lesson's own
# defect. Scoped to the same manifest directories as the IP scan — NOT the whole repo, which
# would just match this comment and this check's own source, the way a legacy-templating
# scanner over its own explanatory prose would.
hits2="$(grep -rIln 'cluster2\|cluster3' "${targets[@]}" 2>/dev/null || true)"
if [ -z "${hits2}" ]; then
  _pass "no dead cluster2/cluster3 names in any committed manifest"
else
  _fail "dead cluster name found (ANCHORING.md D-241 renamed these to staging/prod-us):\n${hits2}"
fi

needs_external "two additional Multipass k3s VMs (staging, prod-us) plus jq to parse 'multipass info --format json'" \
  "verified by hand: .info.<name>.ipv4[0] is an empty array until the instance reports Running, so the lab polls rather than reading it straight after launch; this is a single k3s CI node and Multipass VM provisioning cannot run here"
