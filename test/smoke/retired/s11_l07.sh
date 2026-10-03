#!/usr/bin/env bash
# S11 L07 — a green GitHub delivery does not mean the payload reached Argo CD.
#
# The whole demo is a live ngrok tunnel between GitHub and a private cluster's argocd-server —
# nothing about ngrok, a webhook secret, or GitHub's Recent Deliveries tab is reproducible from
# a checkout with no cluster and no public endpoint. What IS checkable from here: the runbook's
# own troubleshooting table names a specific, repo-side failure mode — "reconciliation fires but
# takes the full poll interval, not instantly" happens when the webhook payload names a
# different repository than the Application actually watches. That only holds if the
# Application's source repo matches the one repository this whole course's webhook config
# points at.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S11-L07 "the webhook only wakes the Application whose repoURL it actually names"
tier external

step "storefront-dev watches the one repository this course's webhook is ever configured against"
assert_file_contains "bootstrap/apps/storefront-dev.yaml" \
  'repoURL: https://github\.com/abohmeed/argocd-class-resources\.git' \
  "storefront-dev's source repoURL matches the config repo the webhook fires from — a payload for any other repo would never touch this Application"

step "no ngrok URL is left committed anywhere in this repo"
# A stale tunnel URL baked into a manifest is exactly the silent-failure mode this lesson
# teaches — the fix belongs in GitHub's webhook settings, never in git history.
hits="$(grep -rIn --exclude-dir=.git -E 'https?://[a-z0-9-]+\.ngrok(-free)?\.app' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no ngrok URL committed to the repo"
else
  _fail "a stale ngrok URL is committed — this is exactly the silently-dead webhook this lesson warns about:\n${hits}"
fi

needs_external "a private cluster, an ngrok tunnel, and GitHub's own webhook delivery UI" \
  "verified once by hand instead: a green Recent Deliveries checkmark persisted after ngrok was restarted with a new URL while the webhook still pointed at the old one, and argocd-server's log showed nothing until the webhook's Payload URL was updated to the new tunnel"
