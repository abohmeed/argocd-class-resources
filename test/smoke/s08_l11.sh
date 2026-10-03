#!/usr/bin/env bash
# ACD-197
# S08 L11 — Progressive Syncs: rolling a fleet change in stages.
#
# The lesson's claims (restored 2026-10-03, D-343, rewritten to the v3.5.3 docs): Progressive
# Syncs is Beta (since v3.3.0, still Beta in 3.5.3) and OFF until enabled on the ApplicationSet
# controller, so an unenabled RollingSync is silently ignored; steps select by the labels on the
# GENERATED Applications, not on clusters; RollingSync turns off automated sync on every
# Application it generates; a step advances only once every Application in it is healthy, and
# health gating is blind to WHAT is running (the readinessProbe only checks the port answers,
# not the banner text); an Application that no step selects is left out of the rolling sync
# (nothing stalls, it sits OutOfSync until synced by hand). The staged rollout itself needs the
# four-cluster fleet (dev, staging, staging-eu, prod-us), so this defends what IS checkable from
# the repo alone: the feature ships off in the pinned install, and the probe's blind spot.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L11 "Progressive Syncs ships off and must be enabled; RollingSync gates on health, but the readinessProbe is blind to WHAT is running, so a bad banner still reports Healthy"
tier external

step "repo-side invariant: the pinned install wires Progressive Syncs to argocd-cmd-params-cm, and ships it OFF"
assert_file_contains "bootstrap/install.yaml" 'ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS' \
  "the ApplicationSet controller reads ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_PROGRESSIVE_SYNCS"
assert_file_contains "bootstrap/install.yaml" 'key: applicationsetcontroller\.enable\.progressive\.syncs' \
  "that variable reads the applicationsetcontroller.enable.progressive.syncs key the lesson sets"
if grep -qE '^ *applicationsetcontroller\.enable\.progressive\.syncs: *"?true' "${REPO_ROOT}/bootstrap/install.yaml"; then
  _fail "Progressive Syncs is already enabled in bootstrap/install.yaml: the lesson's enable step, and its warning that RollingSync is silently ignored without it, no longer match the repo"
else
  _pass "Progressive Syncs is not enabled in the pinned install: it is off until the lesson turns it on"
fi

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

step "repo-side invariant: the tier paths the four targets deploy from all exist and build"
for env in dev staging prod; do
  assert_exists_dir "apps/storefront/overlays/${env}"
  assert_kustomize_builds "apps/storefront/overlays/${env}"
done

needs_external "a registered four-cluster fleet (dev, staging, staging-eu, prod-us) and Progressive Syncs enabled on the ApplicationSet controller" \
  "take-day check: with Progressive Syncs enabled, a RollingSync over stage labels on the generated Applications (canary, broad with maxUpdate: 50%, prod) advances a step only after its Applications report Healthy; the generated Applications carry no automated sync; an Application whose stage label no step matches is left out of the rollout and sits OutOfSync, with no error, until the label is fixed"
