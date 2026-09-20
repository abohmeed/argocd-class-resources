#!/usr/bin/env bash
# S01 L04 — the base/overlay split actually has teeth: editing the OVERLAY changes what
# renders, editing the BASE would not, and the reason is a specific field, `behavior: merge`
# on the overlay's configMapGenerator.
#
# The lesson's whole warning ("editing base/configmap.yaml instead looks equivalent and is
# not") only holds if that merge behaviour is real. If someone ever "simplified" the overlay's
# configMapGenerator to `behavior: replace` (or dropped `behavior:` entirely, which defaults to
# create-and-fail-on-collision), the rendered banner would stop coming from the overlay at all,
# and the whole Step 8 demonstration — and its Step 8 warning — would be teaching a mechanism
# that no longer exists. So this renders the overlay client-side (no cluster needed — Kustomize
# build is pure file composition) and checks the ACTUAL rendered value, not the source files.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S01-L04 "the overlay's configMapGenerator (behavior: merge) wins over the base — editing the base would not move the rendered banner"
tier repo

step "both layers exist"
assert_exists_dir "apps/storefront/base"
assert_exists_dir "apps/storefront/overlays/dev"
assert_exists_file "apps/storefront/base/configmap.yaml"
assert_exists_file "apps/storefront/overlays/dev/kustomization.yaml"

step "the overlay renders at all"
assert_kustomize_builds "apps/storefront/overlays/dev"

step "the BASE's own literal is what the lesson says it is — 'base', not 'dev'"
assert_file_contains "apps/storefront/base/configmap.yaml" 'banner: .storefront v1 — base.' \
  "base ConfigMap literal reads 'storefront v1 — base'"

step "the overlay declares a MERGE, not a replace or a fresh generator"
assert_file_contains "apps/storefront/overlays/dev/kustomization.yaml" 'behavior: *merge' \
  "overlay's configMapGenerator uses behavior: merge — this is what lets it win over the base"

step "the RENDERED manifest carries the overlay's value, not the base's"
rendered="$(kubectl kustomize "${REPO_ROOT}/apps/storefront/overlays/dev" 2>/dev/null | grep -A1 '^data:' | grep 'banner:')"
case "${rendered}" in
  *'storefront v1 — dev'*)
    _pass "rendered banner is the overlay's value: ${rendered}"
    ;;
  *'storefront v1 — base'*)
    _fail "rendered banner is the BASE's value — the overlay's configMapGenerator is no longer winning; Step 8's warning (\"editing base looks equivalent and is not\") is now FALSE, because editing either one would look the same"
    ;;
  *)
    _fail "could not find a rendered banner value at all: '${rendered}'"
    ;;
esac

step "the image tag is the one that actually exists"
# hashicorp/http-echo:1.4.2 is a 404 and ImagePullBackOffs on camera; 1.0 is the only tag this
# lesson may ever show, in base or in the overlay's image override.
if grep -q 'hashicorp/http-echo:1\.4\.2' "${REPO_ROOT}/apps/storefront/base/deployment.yaml"; then
  _fail "base/deployment.yaml pins hashicorp/http-echo:1.4.2, which 404s — this ImagePullBackOffs on camera"
fi
assert_file_contains "apps/storefront/base/deployment.yaml" 'image: hashicorp/http-echo:1\.0' \
  "base pins the image tag that actually exists (1.0)"
assert_file_contains "apps/storefront/overlays/dev/kustomization.yaml" 'newTag: "1\.0"' \
  "overlay's image override also pins 1.0, not 1.4.2"

step "the banner is wired as an env var, not a mounted file — the mechanism Step 8's second half rests on"
# If configMapKeyRef were ever swapped for a mounted volume, a running pod WOULD pick up a
# ConfigMap edit without a restart, and the lecture's closing surprise ("the ConfigMap moved;
# the running container did not") would stop reproducing. This is the cheapest possible check
# that the wiring is still the env-var form the narration explains.
assert_file_lacks "apps/storefront/base/deployment.yaml" 'configMap:' \
  "no ConfigMap volume mount — banner is still env-var-sourced (configMapKeyRef), read once at container start"
assert_file_contains "apps/storefront/base/deployment.yaml" 'configMapKeyRef:' \
  "BANNER is still wired via configMapKeyRef"

smoke_done
