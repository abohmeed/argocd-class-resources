#!/usr/bin/env bash
# S08 L08 — Merge generator: layering an override without forking the fleet.
#
# The lesson's claim: a Merge generator with mergeKeys: [name] lets a small List generator
# override ONE entry from a Matrix base (matched by the shared key) without forking the
# template, applied via templatePatch guarded by {{ if eq .name "..." }} — and the override
# lands on that one Application only, every sibling unchanged. This needs the same multi-cluster
# fleet L07 needs (its own callout says so explicitly), plus a cluster carrying env: production
# for the override target — unmet per L04's still-open precondition. The runbook's own callout
# also warns the literal override target (prod-eu) may not exist as a base entry at all until
# that gap closes, and tells the producer to substitute prod-us and flag it rather than force
# the name — so this script does not assert a specific cluster name either.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L08 "Merge(matrix, list) overrides ONE entry matched by mergeKeys; the templatePatch guard confines the change to that entry alone"
tier external

step "repo-side invariant: the override target's env-specific paths (storefront, checkout on prod) exist and build"
assert_exists_dir "apps/storefront/overlays/prod"
assert_exists_dir "apps/checkout/overlays/prod"
assert_kustomize_builds "apps/storefront/overlays/prod"
assert_kustomize_builds "apps/checkout/overlays/prod"

needs_external "a multi-cluster fleet with at least one env: production cluster registered (L04's still-unmet precondition, carried forward through L07) — the override target this lesson's List generator names may not even appear in the Matrix base until it exists" \
  "verified once by hand: a List-generator override with mergeKeys: [name] matching one Matrix-base entry by cluster name added the extra annotation and replica count to that Application only; a sibling (same service, different cluster) carried no such annotation"
