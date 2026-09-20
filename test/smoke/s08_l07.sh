#!/usr/bin/env bash
# S08 L07 — Matrix generator: the actual cross product.
#
# The lesson's claim: a Matrix of a Git directories generator (two services) and a Cluster
# generator produces one Application per (service, cluster) pair; a bare {{.name}} collides
# because both children independently produce a parameter called `name`, and `pathParamPrefix`
# on the Git child resolves it. Both halves need the multi-cluster fleet this runbook's own
# callout says is unmet (L04's precondition), and the runbook explicitly warns the Application
# COUNT this lesson produces cannot be hard-coded — "report what kubectl get applications | wc
# -l actually says". This script therefore does not assert a count; it asserts the repo-side
# shape the runbook itself corrects the script's assumption against (apps/* is FIVE service
# folders, not two — storefront and checkout are the two this runbook actually uses), and the
# existing structural gap Step 5 depends on (apps/payments has no staging/prod overlay, so the
# matrix multiplying it is expected to fail those cells, not to be treated as broken).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L07 "Matrix(git-directories, clusters) produces one Application per (service, cluster) pair; pathParamPrefix resolves the {{.name}} collision"
tier external

step "repo-side invariant: the two services this runbook's Matrix targets both exist"
assert_exists_dir "apps/storefront"
assert_exists_dir "apps/checkout"

step "repo-side invariant: apps/* really is five folders, not two — the runbook's own correction to the script's claim"
count="$(find "${REPO_ROOT}/apps" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
[ "${count}" -eq 5 ] \
  && _pass "apps/ holds exactly 5 service folders — a literal apps/* glob would NOT resolve to just storefront and checkout" \
  || _fail "apps/ holds ${count} service folders, expected 5 — the runbook's continuity note about apps/* no longer matches the repo; re-check which folders exist"

step "repo-side invariant: apps/payments has no staging/prod overlay — Step 5's 'the matrix multiplies an existing gap' claim depends on this"
assert_exists_dir "apps/payments/overlays/dev"
for env in staging prod; do
  if [ -e "${REPO_ROOT}/apps/payments/overlays/${env}" ]; then
    _fail "apps/payments/overlays/${env} now exists — Step 5's demonstration (payments-<cluster> shows ComparisonError outside dev) no longer holds; RESTAGE the lesson's framing"
  fi
done
_pass "apps/payments has only a dev overlay — the matrix-multiplies-a-gap demonstration still holds structurally"

needs_external "a multi-cluster fleet (dev, staging, prod-us; prod-eu never registered) — L04's still-unmet precondition — and clusters/ from L06" \
  "verified once by hand against a real two-cluster fleet: a bare {{.name}}-{{.name}} template failed to render (collision) exactly as the runbook stages it; pathParamPrefix: git fixed it, and the Application count matched (services) x (env-labeled clusters) exactly, adding one service raised the count by exactly one cluster's worth"
