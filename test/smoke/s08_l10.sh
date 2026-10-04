#!/usr/bin/env bash
# lesson: s08_l10 Pull Request generator: a live preview environment for every open PR
# Pull Request generator: a live environment for every open PR.
#
# The lesson's claim: a pullRequest generator filtered by label produces one Application per
# open, labeled PR, its targetRevision pinned to {{.head_sha}} so the running manifests come
# from the exact reviewed commit, and merging (or closing) the PR removes the Application, not
# just leaves it stale. This needs a real GitHub PR opened and merged against the live companion
# repo (gh pr create / gh pr merge), which this CI cannot do on every run without leaving PR
# history and branches behind on every pass. So this defends one repo-side fact: this image
# never carries the two tags an older version of this lesson bumped between.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L10 "targetRevision pinned to {{.head_sha}} means the running manifests are the exact reviewed commit; merging the PR removes the Application"
tier external

step "repo-side invariant: no manifest pins hashicorp/http-echo to the two tags this course must never use"
# As the Kustomize lesson (s02_l04.sh) warns: hashicorp/http-echo:1.4.2 and :1.5.0 both 404 on
# Docker Hub. An older version of this lesson bumped between exactly those two tags; the
# lesson now deliberately changes the PR's demonstrated diff to a ConfigMap
# literal instead, specifically to avoid staging that pull. This checks the repo never regresses
# into the tag the lesson flagged as a trap.
for bad in "1\.4\.2" "1\.5\.0"; do
  assert_file_lacks \
    "apps/storefront/base/deployment.yaml" \
    "hashicorp/http-echo:${bad}" \
    "storefront's base Deployment does not pin the 404ing hashicorp/http-echo:${bad//\\/} tag"
done

needs_external "a real GitHub pull request opened, labeled, and merged against the live companion repo (gh pr create / gh pr merge)" \
  "verified once by hand: an Application named pr-<N>-storefront appeared on a forced refresh after opening a labeled PR, its source.targetRevision equal to the PR's head SHA, serving the PR branch's own ConfigMap literal when curled; merging the PR removed the Application (and its resources, since preserveResourcesOnDeletion was never set) on the next refresh"
