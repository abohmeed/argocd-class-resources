#!/usr/bin/env bash
# S11 L05 — wiring Argo CD Image Updater closes the registry-to-cluster gap.
#
# The lesson's demo lives almost entirely outside this repo: it installs a separate
# argoproj-labs controller, points it at ghcr.io/<owner>/storefront (a registry this repo
# does not control), and proves a deploy-key's scope by pushing against a second GitHub
# repository. None of that is reproducible from a checkout with no cluster and no GHCR token.
# What IS checkable from here: the repo-side precondition the runbook's own troubleshooting
# table names — "Image Updater commits but the Application never re-syncs" happens when
# selfHeal/automated is missing from the Application Image Updater is supposed to be closing
# the loop for. If that sync policy ever regresses, this lesson's own demo breaks before
# Image Updater is even involved.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S11-L05 "Image Updater's write-back only closes the loop if storefront-dev is on automated selfHeal"
tier external

step "the storefront-dev Application this lesson wires Image Updater against actually exists"
assert_exists_file "bootstrap/apps/storefront-dev.yaml"

step "and it carries automated + selfHeal — without this, Image Updater's own commit never deploys"
assert_file_contains "bootstrap/apps/storefront-dev.yaml" 'selfHeal: true' \
  "storefront-dev has selfHeal enabled — Image Updater's write-back actually reaches the cluster"

step "the image this repo runs is pinned, never :latest — the same discipline Image Updater needs from the registry side"
assert_file_lacks "apps/storefront/base/deployment.yaml" ':latest' \
  "apps/storefront/base/deployment.yaml never floats on :latest"

needs_external "argocd-image-updater (argoproj-labs, v1.1.1), a reachable GHCR image, and a scoped GitHub deploy key" \
  "verified once by hand instead: the default semver strategy silently ignores a SHA tag, newest-build picks it up and commits under Image Updater's own git identity, and the config-repo-scoped deploy key was refused with 'Permission denied (publickey)' when tried against the app repository"
