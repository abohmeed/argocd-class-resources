#!/usr/bin/env bash
# ACD-198
# S08 L12: Template patching, the exception the template can't express.
#
# Re-anchored 2026-10-04 to the restored lesson (D-343). The earlier answer key moved an "edge"
# entry into another AppProject through templatePatch, and Argo CD v3.5.3 does not support
# spec.project in a templatePatch (ApplicationSet Template docs: "The spec.project field is not
# supported in templatePatch"), so that patch never took effect. The lesson now patches
# staging-eu, inside the production fleet (env=production: prod-us and staging-eu), with a
# monitoring annotation and selfHeal: false, merged as a strategic merge patch after the template
# renders. Everything here is checkable from the committed answer key, with no cluster needed.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L12 "the staging-eu templatePatch adds an annotation and turns selfHeal off on that one entry, and never sets spec.project, which a templatePatch does not support"
tier repo

APPSET_FILE="applicationsets/storefront.yaml"

step "the committed ApplicationSet exists and is well-formed YAML"
assert_exists_file "${APPSET_FILE}"
assert_yaml_wellformed "${APPSET_FILE}"

step "modern templating: goTemplate: true and missingkey=error are both set"
assert_file_contains "${APPSET_FILE}" 'goTemplate: true' "goTemplate: true is set (templatePatch only works with it)"
assert_file_contains "${APPSET_FILE}" 'missingkey=error' "missingkey=error is set"

step "the fleet is the production fleet the lesson opens on"
assert_file_contains "${APPSET_FILE}" 'env: production' \
  "the Cluster generator selects env=production (prod-us and staging-eu)"
assert_file_contains "${APPSET_FILE}" 'selfHeal: true' \
  "the template keeps selfHeal: true for every entry; only the patch turns it off"

step "the patch itself: an exact match on staging-eu, an annotation, and selfHeal off"
assert_file_contains "${APPSET_FILE}" '\{\{ if eq \.name "staging-eu" \}\}' \
  "the templatePatch guards on eq .name, the exact match the lesson puts back after the overreach"
assert_file_lacks "${APPSET_FILE}" 'eq \.metadata\.labels\.env "production"' \
  "the committed file does not carry the lesson's deliberately broad env-label match (staged live, then reverted)"
assert_file_contains "${APPSET_FILE}" 'monitoring\.northwind\.io/tier: restricted' \
  "the patch adds monitoring.northwind.io/tier: restricted"
assert_file_contains "${APPSET_FILE}" 'selfHeal: false' \
  "the patch sets selfHeal: false"

step "the regression check: no spec.project inside the templatePatch"
# Only the lines of the templatePatch block scalar count; the template itself rightly sets
# project: default.
patch_project="$(awk '/^  templatePatch: \|/{p=1; next} p && /^  [^ ]/{p=0} p' "${REPO_ROOT}/${APPSET_FILE}" | grep -n 'project:' || true)"
if [ -z "${patch_project}" ]; then
  _pass "the templatePatch sets no project: a project change in a patch is unsupported and would silently not apply"
else
  _fail "the templatePatch in ${APPSET_FILE} sets a project:\n${patch_project}\nspec.project is not supported in a templatePatch; put a different project in the template instead"
fi

step "the generated path every entry resolves to exists and builds"
assert_exists_dir "apps/storefront/overlays/prod"
assert_kustomize_builds "apps/storefront/overlays/prod"

step "no legacy dot-less templating anywhere in the ApplicationSet corpus"
assert_no_legacy_appset_templating

smoke_done
