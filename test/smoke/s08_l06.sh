#!/usr/bin/env bash
# lesson: s08_l06 Git generator, file mode: config files drive the fleet
# Git generator, file mode.
#
# The lesson's claim: each key inside a matched clusters/*/config.json becomes a template
# parameter ({{.name}}, {{.server}}, {{.tier}}, {{.replicas}}), including one that feeds
# spec.source.kustomize.replicas: a per-cluster override on top of a per-tier overlay, and a
# malformed file (a typo'd key) fails ONLY that one file's render under missingkey=error,
# leaving the other clusters' Applications untouched. Both halves need `prod-us` registered
# with Argo CD (which needs the registered fleet from the multi-cluster section)
# and the `clusters/` directory this lesson builds live: neither exists in this repo yet.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L06 "each config.json key becomes a template parameter; a typo in ONE file fails only that file's render under missingkey=error"
tier external

step "repo-side invariant: the tiers this file-mode generator targets all exist and build"
for env in dev staging prod; do
  assert_exists_dir "apps/storefront/overlays/${env}"
  assert_kustomize_builds "apps/storefront/overlays/${env}"
done

step "repo-side invariant: clusters/ does not exist yet: this lesson builds it live"
if [ -d "${REPO_ROOT}/clusters" ]; then
  _fail "clusters/ already exists in the repo: if the lesson's config.json files have since been committed, this script (and its 'external' tier) is stale and should be upgraded to assert against them directly"
else
  _pass "clusters/ is not yet committed, consistent with the lesson building it live"
fi

needs_external "prod-us registered with Argo CD (built in the multi-cluster section) and clusters/*/config.json committed live" \
  "verified once by hand: clusters/prod-us/config.json's replicas: 3 landed on spec.source.kustomize.replicas verbatim with nothing typed by hand; a typo'd clusters/prod-eu/config.json (replias instead of replicas) produced a rendering error naming the missing key while dev-storefront/staging-storefront/prod-us-storefront stayed Synced/Healthy, unaffected"
