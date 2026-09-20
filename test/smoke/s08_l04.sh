#!/usr/bin/env bash
# S08 L04 — Cluster generator: the fleet finds itself.
#
# The lesson's own runbook carries a BLOCKING PRECONDITION: it narrates a fleet of registered
# clusters (dev, staging, prod-us, plus staging-eu added live) that this course does not build
# until S09 L02/L03 (Multipass VMs, then `argocd cluster add`). Until that infrastructure
# exists, "an Application appears for every cluster whose Secret carries env: production" and
# "a cluster with no env label is silently excluded, and appears the moment it's labeled" are
# claims that need real multi-cluster registration this repo's CI does not have — so this
# script asserts the one thing that IS checkable without it, and declares the rest.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L04 "the Cluster generator's selector silently excludes an unlabeled cluster, and includes it the moment it is labeled"
tier external

step "repo-side invariant: the path the prod Application targets actually exists and builds"
assert_exists_dir "apps/storefront/overlays/prod"
assert_kustomize_builds "apps/storefront/overlays/prod"
assert_renders_kind "apps/storefront/overlays/prod" "Deployment"

needs_external "a registered multi-cluster fleet (dev, staging, prod-us, and a staging-eu context to add live) — built in S09 L02/L03, after this section in course numbering" \
  "verified once by hand on a real fleet: a Cluster generator selector matching env: production produced exactly one Application for the one Secret carrying that label; labeling a second, previously-unmatched cluster Secret produced a second Application within one reconcile, with no edit to the ApplicationSet itself"
