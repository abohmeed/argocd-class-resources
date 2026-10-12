#!/usr/bin/env bash
# Repo-wide invariants. Runs on every PR, needs no cluster, finishes in seconds.
#
# These are the checks that would have caught the defects the previous version of this course
# shipped: unpinned images, plaintext Secrets, Bitnami charts, ingress-nginx, and legacy
# ApplicationSet templating that fails at parse time on Argo CD 3.5.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

step "Repo-wide invariants"
assert_no_forbidden_sources
assert_images_pinned
assert_no_plaintext_secrets
assert_no_legacy_appset_templating

step "Every overlay renders"
for app in storefront checkout; do
  for env in dev staging prod; do
    assert_kustomize_builds "apps/${app}/overlays/${env}"
  done
done

step "Overlays render what the lessons say they render"
assert_renders_kind "apps/storefront/overlays/dev" "Deployment"
assert_renders_kind "apps/storefront/overlays/dev" "Service"
assert_renders_kind "apps/storefront/overlays/dev" "ConfigMap"
assert_renders_kind "apps/checkout/overlays/dev" "StatefulSet"

printf '\n\033[32mrepo lint passed\033[0m\n'

step "Standalone manifests parse"
for m in bootstrap/self-manage-app.yaml \
         bootstrap/root-app.yaml \
         bootstrap/apps/storefront-dev.yaml \
         applicationsets/fleet.yaml \
         teams/_template/appproject.yaml; do
  assert_yaml_parses "$m"
done
