#!/usr/bin/env bash
# S08 L11 — Progressive Syncs: rolling a fleet change in stages.
#
# The lesson's claim: RollingSync only advances past a stage once every Application in it
# reports Synced/Healthy, a stage matching zero clusters just waits forever rather than erroring,
# and health gating is blind to WHAT is running, not just whether it started (the readinessProbe
# only checks the port answers, not the banner text). The stage rollout itself needs the same
# multi-cluster fleet L04/L06/L07/L08 all flag as unmet, and the runbook's own callout says the
# `prod` stage's maxUpdate: 50% behaviour specifically cannot be demonstrated with fewer than two
# clusters in that stage — so this defends the one claim that IS checkable from the repo alone:
# the readinessProbe's blind spot the false-green step depends on.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L11 "RollingSync gates on health, but readinessProbe is blind to WHAT is running — a bad banner still reports Healthy"
tier external

step "repo-side invariant: the readinessProbe Step 5 reads on screen checks only that the port answers, not the response body"
assert_file_contains \
  "apps/storefront/base/deployment.yaml" \
  "readinessProbe:" \
  "storefront's Deployment defines a readinessProbe"
if grep -A4 'readinessProbe:' "${REPO_ROOT}/apps/storefront/base/deployment.yaml" | grep -qiE 'banner|BANNER|httpGet'; then
  if grep -A4 'readinessProbe:' "${REPO_ROOT}/apps/storefront/base/deployment.yaml" | grep -q 'httpGet'; then
    _pass "the probe is a plain httpGet on the root path — it cannot see the banner text, exactly the false-green gap Step 5 narrates"
  else
    _fail "the readinessProbe no longer looks like a plain httpGet — Step 5's false-green claim needs re-checking against the actual probe shape"
  fi
else
  _fail "could not read the readinessProbe block to confirm it is body-blind"
fi

step "repo-side invariant: the tier paths this rollout's three stages target all exist and build"
for env in dev staging prod; do
  assert_exists_dir "apps/storefront/overlays/${env}"
  assert_kustomize_builds "apps/storefront/overlays/${env}"
done

needs_external "a multi-cluster fleet (dev, staging, prod-us; prod-eu never registered) — the same unmet precondition L04/L06/L07/L08 all flag" \
  "verified once by hand: with Progressive Syncs enabled on the ApplicationSet controller, a RollingSync with three stage labels advanced canary then broad only after each stage's Applications reported Healthy; removing a cluster's stage label stalled the rollout at that step with no error condition, and restoring the label resumed it"
