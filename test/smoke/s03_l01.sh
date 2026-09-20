#!/usr/bin/env bash
# S03 L01 — the Application's own contract, and the error it produces when a field is wrong.
#
# The lesson's opening beat is a teammate's Application manifest that Argo CD refuses to sync
# because `spec.source.path` names a directory that does not exist. Step 3 of the runbook types
# `apps/storefront/overlays/development` ON PURPOSE — the typo is the lesson, not a mistake to
# fix. If that path ever started existing (someone creates `overlays/development/` for real, or
# renames `overlays/dev/` to it), the "Failed to load target state" error the whole lecture is
# built around stops reproducing, and the recording no longer matches the repo. So this defends
# the ABSENCE of the wrong path and the PRESENCE of the right one, in the same breath.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L01 "spec.source.path apps/storefront/overlays/development does not exist, on purpose — that absence IS the error the lecture reads on screen"
tier repo

step "the path the lesson types by mistake must stay absent"
if [ -e "${REPO_ROOT}/apps/storefront/overlays/development" ]; then
  _fail "apps/storefront/overlays/development now EXISTS — Step 3's deliberate typo no longer 404s, and the lesson's central error stops reproducing. Do not create this path; if it must exist for another reason, S03-L01 needs a different broken path."
else
  _pass "apps/storefront/overlays/development is absent, as the lesson requires"
fi

step "the path the lesson fixes it to in Step 8 must be the real one"
assert_exists_dir "apps/storefront/overlays/dev"
assert_exists_file "apps/storefront/overlays/dev/kustomization.yaml"
assert_yaml_wellformed "apps/storefront/overlays/dev/kustomization.yaml"

step "only dev, staging, prod (and canary) exist under overlays/ — development is not a near-miss typo of a fourth real one"
for expected in dev staging prod canary; do
  assert_exists_dir "apps/storefront/overlays/${expected}"
done

step "the overlay actually builds and renders a Deployment, so the FIXED path (Step 8) has something real to converge to"
assert_kustomize_builds "apps/storefront/overlays/dev"
assert_renders_kind "apps/storefront/overlays/dev" "Deployment"

smoke_done
