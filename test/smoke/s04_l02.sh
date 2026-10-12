#!/usr/bin/env bash
# lesson: s04_l02 Kustomize as a source: base and overlays, auto-detected
# Kustomize detection from one file, and overlays that inherit an existing base.
#
# The lesson's claim: Argo CD's source-type detection flips from Directory to Kustomize purely
# because a kustomization.yaml exists at the source path: no field on the Application changes.
# The repo-side half of that claim is mechanical and checkable without a cluster: the path this
# course teaches as "plain directory" (the manifests/ directory from s04_l01.sh) gains exactly one marker,
# the kustomization.yaml this lesson commits, which lists the two manifests and nothing else; every path this lesson points Argo CD at as Kustomize (base/, overlays/staging,
# overlays/prod) must carry one. If either drifts, the "flip" the lesson demonstrates
# stops being caused by what the lesson says it's caused by.
#
# The lesson also warns that a missing `resources:` entry syncs CLEAN over an empty namespace:
# invisible on the dashboard, the worst kind of failure. This defends against that trap ever
# shipping in the committed overlays: `resources:` must actually resolve to the base, not just
# exist as a key.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L02 "kustomization.yaml presence is what flips source-type detection, and no committed overlay ships with an empty resources: trap"
tier repo

step "the plain-directory source (s04_l01.sh) gained exactly one marker: the kustomization.yaml this lesson commits"
for marker in kustomization.yml Chart.yaml values.yaml .argocd-source.yaml; do
  if [ -e "${REPO_ROOT}/apps/storefront/manifests/${marker}" ]; then
    _fail "apps/storefront/manifests/${marker} exists: the flip this lesson shows must come from kustomization.yaml alone"
  fi
done
assert_exists_file "apps/storefront/manifests/kustomization.yaml"
assert_file_contains "apps/storefront/manifests/kustomization.yaml" '^  - deployment\.yaml\s*$' \
  "kustomization.yaml lists deployment.yaml"
assert_file_contains "apps/storefront/manifests/kustomization.yaml" '^  - service\.yaml\s*$' \
  "kustomization.yaml lists service.yaml"
assert_file_lacks "apps/storefront/manifests/kustomization.yaml" '^(namespace|images|patches|replicas|configMapGenerator|namePrefix|nameSuffix|commonLabels|labels):' \
  "kustomization.yaml transforms nothing: the only change is the detected source type"
assert_kustomize_builds "apps/storefront/manifests"

step "the base and both new overlays DO carry the marker that triggers Kustomize detection"
assert_exists_file "apps/storefront/base/kustomization.yaml"
assert_exists_file "apps/storefront/overlays/staging/kustomization.yaml"
assert_exists_file "apps/storefront/overlays/prod/kustomization.yaml"

step "neither overlay shipped with the missing-resources trap: each actually pulls in the base"
assert_file_contains "apps/storefront/overlays/staging/kustomization.yaml" '^\s*-\s*\.\./\.\./base\s*$' \
  "overlays/staging resolves resources: to ../../base, not an empty list"
assert_file_contains "apps/storefront/overlays/prod/kustomization.yaml" '^\s*-\s*\.\./\.\./base\s*$' \
  "overlays/prod resolves resources: to ../../base, not an empty list"

step "each overlay's per-environment delta is a real, pullable image tag"
# 1.0 and 1.0.0 are both real tags of the same hashicorp/http-echo image. This lesson sets staging
# to 1.0.0 so its tag differs visibly from the base, and the promotion lesson that follows moves prod
# from 1.0 to 1.0.0, so either is correct here depending on how far the fork has gone.
assert_file_contains "apps/storefront/overlays/staging/kustomization.yaml" 'newTag: "1\.0(\.0)?"' \
  "staging pins hashicorp/http-echo to a tag that actually exists (1.0 or 1.0.0)"
assert_file_contains "apps/storefront/overlays/prod/kustomization.yaml" 'newTag: "1\.0(\.0)?"' \
  "prod pins hashicorp/http-echo to a tag that actually exists (1.0 or 1.0.0)"
if grep -qE 'newTag: "1\.4\.2"' \
  "${REPO_ROOT}/apps/storefront/overlays/staging/kustomization.yaml" \
  "${REPO_ROOT}/apps/storefront/overlays/prod/kustomization.yaml" 2>/dev/null; then
  _fail "an overlay pins hashicorp/http-echo:1.4.2: that tag does not exist and ImagePullBackOffs"
fi
_pass "no overlay pins the non-existent hashicorp/http-echo:1.4.2 tag"

step "the overlays and base are well-formed YAML"
assert_yaml_wellformed "apps/storefront/base/kustomization.yaml"
assert_yaml_wellformed "apps/storefront/overlays/staging/kustomization.yaml"
assert_yaml_wellformed "apps/storefront/overlays/prod/kustomization.yaml"

smoke_done
