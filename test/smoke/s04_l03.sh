#!/usr/bin/env bash
# lesson: s04_l03 Promoting builds from staging to production through directory changes
# Promotion is a one-line edit to overlays/prod, never a branch merge.
#
# The lesson deliberately reproduces the branch-merge tangle first (two feature branches merged
# into a shared `staging` branch, one reviewed and one not, both riding into a `prod` branch
# together), then undoes it. What this defends is the state that must be true AFTER that undo:
# no trace of the branch-merge trap left in the tree, the promotable field (images.newTag)
# isolated to a single line so editing it really is a one-line diff, and base left completely
# untouched by any environment's delta, which is what makes the diff reviewable in the first
# place. No git commands run here: this checkout is not a git working copy in this environment,
# so every check is file-content, matching the way this script is actually run.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L03 "promotion is a one-line edit to overlays/prod's image tag, and base never carries an environment-specific value"
tier repo

step "the branch-merge trap's placeholder file was cleaned up, not left in the tree"
if [ -e "${REPO_ROOT}/apps/checkout/SPIKE_NOTES.md" ]; then
  _fail "apps/checkout/SPIKE_NOTES.md still exists. Step 1's branch-merge trap was never torn down, and Step 3's cleanup claim does not hold"
fi
_pass "no leftover SPIKE_NOTES.md from the branch-merge trap"

step "the temporary JSON6902 failure demo from the previous lesson never reached this overlay"
# The only patch a per-environment overlay may carry is the replicas count: the base is a Rollout
# from S10-L02 on, and kustomize's replicas field refuses a Rollout, so the count is a patch. Any
# other patch path is the illustration-only failure this step rules out (a JSON6902 that breaks).
for env in staging prod; do
  f="apps/storefront/overlays/${env}/kustomization.yaml"
  if grep -q '^patches:' "${REPO_ROOT}/${f}"; then
    paths="$(grep -E '^[[:space:]]*path:' "${REPO_ROOT}/${f}" | sed -E 's/^[[:space:]]*path:[[:space:]]*//')"
    other="$(printf '%s\n' "${paths}" | grep -vE '^/spec/replicas$' | grep -v '^$' || true)"
    if [ -n "${paths}" ] && [ -z "${other}" ]; then
      _pass "overlays/${env} patches only the replicas count (/spec/replicas), not a demo failure"
    else
      _fail "overlays/${env} carries a patch on something other than /spec/replicas: ${other:-no path at all}"
    fi
  else
    _pass "overlays/${env} carries no patches: block"
  fi
done

step "base never carries an environment-specific value: the delta lives ONLY in the overlay"
assert_file_lacks "apps/storefront/base/configmap.yaml" 'storefront v1: (staging|prod)' \
  "base/configmap.yaml has no staging/prod-specific banner text; that text belongs to the overlay's configMapGenerator alone"

step "the promotable field is isolated to one line: editing it changes nothing else"
tmp_orig="$(mktemp)"
tmp_edit="$(mktemp)"
cp "${REPO_ROOT}/apps/storefront/overlays/prod/kustomization.yaml" "${tmp_orig}"
sed -E 's/newTag: "[^"]*"/newTag: "9.9.9"/' "${tmp_orig}" > "${tmp_edit}"   # whatever tag prod runs today
changed="$(diff -u "${tmp_orig}" "${tmp_edit}" | grep -cE '^[+-][^+-]' || true)"
rm -f "${tmp_orig}" "${tmp_edit}"
if [ "${changed}" -eq 2 ]; then
  _pass "bumping images.newTag touches exactly one line (one removed, one added): this is the whole promotion"
else
  _fail "bumping images.newTag touched ${changed} diff line(s), not 2, so promotion to prod is no longer a one-line, reviewable edit"
fi

step "the overlay is well-formed YAML before and after that kind of edit"
assert_yaml_wellformed "apps/storefront/overlays/prod/kustomization.yaml"

smoke_done
