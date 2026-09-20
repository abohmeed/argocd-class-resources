#!/usr/bin/env bash
# S04 L02 — Kustomize detection from one file, and overlays that inherit an existing base.
#
# The lesson's claim: Argo CD's source-type detection flips from Directory to Kustomize purely
# because a kustomization.yaml exists at the source path — no field on the Application changes.
# The repo-side half of that claim is mechanical and checkable without a cluster: the path this
# course still teaches as "plain directory" (S04 L01's manifests/) must carry NO build marker,
# and every path this lesson points Argo CD at as Kustomize (base/, overlays/staging,
# overlays/prod) must carry one. If either drifts, the "flip" the lecture demonstrates on camera
# stops being caused by what the narration says it's caused by.
#
# The lesson also warns that a missing `resources:` entry syncs CLEAN over an empty namespace —
# invisible on the dashboard, the worst kind of failure. This defends against that trap ever
# shipping in the committed overlays: `resources:` must actually resolve to the base, not just
# exist as a key.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L02 "kustomization.yaml presence is what flips source-type detection, and no committed overlay ships with an empty resources: trap"
tier repo

step "the plain-directory source (S04 L01) still carries no build marker"
for marker in kustomization.yaml kustomization.yml Chart.yaml values.yaml .argocd-source.yaml; do
  if [ -e "${REPO_ROOT}/apps/storefront/manifests/${marker}" ]; then
    _fail "apps/storefront/manifests/${marker} exists — this lesson's Step 1 flip depends on this directory currently having none, and S04 L01's own claim collapses with it"
  fi
done
_pass "apps/storefront/manifests/ still has no kustomization/Chart/values marker"

step "the base and both new overlays DO carry the marker that triggers Kustomize detection"
assert_exists_file "apps/storefront/base/kustomization.yaml"
assert_exists_file "apps/storefront/overlays/staging/kustomization.yaml"
assert_exists_file "apps/storefront/overlays/prod/kustomization.yaml"

step "neither overlay shipped with the missing-resources trap — each actually pulls in the base"
assert_file_contains "apps/storefront/overlays/staging/kustomization.yaml" '^\s*-\s*\.\./\.\./base\s*$' \
  "overlays/staging resolves resources: to ../../base, not an empty list"
assert_file_contains "apps/storefront/overlays/prod/kustomization.yaml" '^\s*-\s*\.\./\.\./base\s*$' \
  "overlays/prod resolves resources: to ../../base, not an empty list"

step "each overlay's per-environment delta is a real, pullable image tag"
assert_file_contains "apps/storefront/overlays/staging/kustomization.yaml" 'newTag: "1\.0"' \
  "staging pins hashicorp/http-echo to the one tag that actually exists"
assert_file_contains "apps/storefront/overlays/prod/kustomization.yaml" 'newTag: "1\.0"' \
  "prod pins hashicorp/http-echo to the one tag that actually exists"
if grep -qE 'newTag: "1\.4\.2"' \
  "${REPO_ROOT}/apps/storefront/overlays/staging/kustomization.yaml" \
  "${REPO_ROOT}/apps/storefront/overlays/prod/kustomization.yaml" 2>/dev/null; then
  _fail "an overlay pins hashicorp/http-echo:1.4.2 — that tag does not exist and ImagePullBackOffs on camera"
fi
_pass "no overlay pins the non-existent hashicorp/http-echo:1.4.2 tag"

step "the overlays and base are well-formed YAML"
assert_yaml_wellformed "apps/storefront/base/kustomization.yaml"
assert_yaml_wellformed "apps/storefront/overlays/staging/kustomization.yaml"
assert_yaml_wellformed "apps/storefront/overlays/prod/kustomization.yaml"

smoke_done
