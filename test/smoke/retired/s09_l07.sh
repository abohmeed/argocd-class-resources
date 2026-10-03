#!/usr/bin/env bash
# S09 L07 — the Cluster generator meets a real fleet.
#
# The lesson's committed deliverable, applicationsets/fleet-storefront.yaml, is checkable without
# a cluster at all: its shape either matches the documented idiom (modern dot-templating,
# missingkey=error, a selector on the bare argocd.argoproj.io/secret-type label so the hub is
# excluded BY CONSTRUCTION, never by an explicit exclusion nobody wrote) or it does not. What is
# NOT checkable here is the live behaviour — three real Applications appearing against staging
# and prod-us, and zero against the hub — because that needs the actual fleet from S09 L02/L03/L04,
# which this single-node CI cannot stand up.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L07 "a Cluster generator selecting on argocd.argoproj.io/secret-type excludes the hub by construction, and templates the overlay path per cluster from a label"
tier repo

MANIFEST="applicationsets/fleet-storefront.yaml"

step "the fleet ApplicationSet is committed"
assert_exists_file "${MANIFEST}"
assert_yaml_wellformed "${MANIFEST}"

step "modern templating throughout — the legacy dot-less {{name}} form is a hard parse error on 3.5"
assert_no_legacy_appset_templating
assert_file_contains "${MANIFEST}" 'goTemplate: *true' "goTemplate: true is set"
assert_file_contains "${MANIFEST}" 'missingkey=error' "goTemplateOptions sets missingkey=error, so a typo'd label fails loudly instead of deploying to the wrong place"

step "the selector is exactly the label the hub can never carry"
# in-cluster is synthesised in memory and has no Secret, so it carries no
# argocd.argoproj.io/secret-type label at all — a selector on that label alone excludes it by
# construction. Documented behaviour (S09.md fact-check), not an inferred trick.
assert_file_contains "${MANIFEST}" 'argocd\.argoproj\.io/secret-type: *cluster' \
  "the Cluster generator selects on argocd.argoproj.io/secret-type: cluster — the exact label the hub's in-cluster entry never has"

step "the overlay path and destination namespace are templated from the tier label, never hardcoded to one cluster"
assert_file_contains "${MANIFEST}" "apps/storefront/overlays/\{\{ \.metadata\.labels\.tier \}\}" \
  "the source path resolves per cluster from its tier label"
assert_file_contains "${MANIFEST}" '\{\{ \.server \}\}' \
  "the destination server is templated from the generator's own {{ .server }}, never a literal address"
assert_file_lacks "${MANIFEST}" '(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})' \
  "no destination is a hardcoded private IP"

step "the overlays the template resolves to actually build"
assert_kustomize_builds "apps/storefront/overlays/staging"
assert_kustomize_builds "apps/storefront/overlays/prod"

needs_external "three registered cluster Secrets (staging, prod-us, and the hub's absence of one) to watch the generator actually produce and exclude Applications" \
  "verified by construction above (no Secret => no label => excluded), and by hand on a live fleet: labelling the two managed clusters produced exactly storefront-staging and storefront-prod-us, and zero Applications targeted the hub — this needs the real multi-cluster fleet, which this single k3s CI node does not have"
