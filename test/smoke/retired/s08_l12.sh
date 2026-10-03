#!/usr/bin/env bash
# S08 L12 — Template patching: the exception the template can't express.
#
# This lesson's committed answer key, applicationsets/storefront.yaml, carries a real defect
# this repo already hit and fixed once: the first draft's templatePatch put
# `SyncWindow=restricted-edge` under spec.syncPolicy.syncOptions — a plain []string that Argo CD
# accepts SILENTLY (verified live: ThisIsCompleteNonsense=yes was admitted without complaint).
# A sync window is an AppProject field (spec.syncWindows), not an Application field at all, so
# that draft would have rendered perfectly and done nothing. The fix moves the edge exception
# into spec.project, pointing at an AppProject (bootstrap/edge-restricted-project.yaml) that
# actually carries the window. This is fully checkable from the committed files, with no cluster
# needed — so this defends the fix statically and asserts its return never lands uncaught again.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L12 "the edge templatePatch sets spec.project (an AppProject-borne sync window), never a fake syncOptions entry that Argo CD would silently accept"
tier repo

APPSET_FILE="applicationsets/storefront.yaml"
PROJECT_FILE="bootstrap/edge-restricted-project.yaml"

step "the committed ApplicationSet and its target AppProject both exist and are well-formed YAML"
assert_exists_file "${APPSET_FILE}"
assert_exists_file "${PROJECT_FILE}"
assert_yaml_wellformed "${APPSET_FILE}"
assert_yaml_wellformed "${PROJECT_FILE}"

step "modern templating: goTemplate: true and missingkey=error are both set"
assert_file_contains "${APPSET_FILE}" 'goTemplate: true' "goTemplate: true is set"
assert_file_contains "${APPSET_FILE}" 'missingkey=error' "missingkey=error is set"

step "the regression check: no SyncWindow= ever appears LIVE in an Application's syncOptions again"
# The file's own comment NAMES SyncWindow= to explain why the fix moved away from it — that
# mention must not itself trip this check (the same lesson assert_no_legacy_appset_templating
# already learned about its own explanatory comment). Only a non-comment line counts.
hits="$(grep -n 'SyncWindow=' "${REPO_ROOT}/${APPSET_FILE}" | grep -vE '^[0-9]+: *#' || true)"
if [ -z "${hits}" ]; then
  _pass "no live SyncWindow= entry under syncOptions — that field is a plain []string Argo CD accepts silently, so this is the exact bug that shipped once"
else
  _fail "SyncWindow= found outside a comment in ${APPSET_FILE}:\n${hits}\nAppProject.spec.syncWindows is where a sync window belongs — see ${PROJECT_FILE}"
fi

step "the fix in place: the edge exception sets spec.project, not a sync window inline"
assert_file_contains "${APPSET_FILE}" 'project: edge-restricted' \
  "the templatePatch sets spec.project: edge-restricted for the edge target"

step "the guard is an EXACT match on the cluster name, not a substring match"
assert_file_contains "${APPSET_FILE}" '\{\{ if eq \.name "edge" \}\}' \
  "the templatePatch guards on eq, not contains — Step 5/6's overreach-then-fix narrative depends on this being eq in the committed, at-rest version of the file"
assert_file_lacks "${APPSET_FILE}" 'contains \.name "edge"' \
  "the committed file does not carry Step 5's deliberately loosened 'contains' condition — that is staged live and reverted before this file is left as the lesson's answer key"

step "the AppProject actually carries the sync window the templatePatch routes into"
assert_file_contains "${PROJECT_FILE}" 'syncWindows:' \
  "edge-restricted AppProject defines spec.syncWindows"
assert_file_contains "${PROJECT_FILE}" 'kind: AppProject' \
  "the file is an AppProject, confirming syncWindows lives on the project, not the Application"

step "the generated path the edge cluster's overlay resolves to exists and builds"
assert_exists_dir "apps/storefront/overlays/prod"
assert_kustomize_builds "apps/storefront/overlays/prod"

step "no legacy dot-less templating anywhere in the ApplicationSet corpus"
assert_no_legacy_appset_templating

smoke_done
