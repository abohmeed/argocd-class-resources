#!/usr/bin/env bash
# S12 L12 — three independent logs (git history, Argo CD's sync history, the Kubernetes API
# audit log) correlate into one traceable story: who committed it, when Argo CD synced it, and
# which service account the API server saw apply it.
#
# The third log is the blocker for running this anywhere but by hand: k3s does not enable API
# audit logging by default, turning it on needs sudo access to the node's systemd/k3s config and
# a full k3s restart, and no earlier lesson in this course does that. Flipping it on for a shared
# CI cluster is the exact non-trivial, ongoing performance cost the runbook itself warns against
# doing silently. What IS checkable from here: the git half of the correlation, which needs
# nothing but this checkout's own history.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L12 "git history, Argo CD sync history and the API audit log correlate on the same change"
tier external

step "the repo carries real, attributable git history to correlate against"
if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _fail "cannot check git history: ${REPO_ROOT} is not a git checkout here (environment fault, not a defect in the content) — this script expects to run inside the pushed argocd-class-resources checkout, where git history is real"
fi
last_commit="$(git -C "${REPO_ROOT}" log -1 --format='%H %an %aI' 2>/dev/null || true)"
if [ -n "${last_commit}" ]; then
  _pass "git log resolves a commit with author and timestamp: ${last_commit}"
else
  _fail "this is a git checkout, but git log -1 returned nothing — no history to correlate against"
fi

needs_external "a scratch k3s host with Kubernetes API audit logging enabled (sudo, a policy file, a k3s config edit and a restart)" \
  "verified once by hand instead: an identifiable ConfigMap change was committed, argocd app history showed the matching revision's sync timestamp, and grep against /var/log/k3s-audit.log found the same update entry with user.username naming Argo CD's own application-controller service account — not a human identity"
