#!/usr/bin/env bash
# S04 L01 — the plain-directory source type.
#
# The lesson's whole premise is that Argo CD, finding no kustomization/Helm/plugin markers under
# the path, falls back to its simplest source type and applies the manifests as written. One
# stray kustomization.yaml in this directory silently converts the source to Kustomize and the
# lesson teaches the wrong thing while appearing to work. That is what this defends.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L01 "a directory with no build markers is applied verbatim, as a plain directory"
tier repo

step "the directory the lesson syncs actually exists"
assert_exists_dir "apps/storefront/manifests"

step "and it is a PLAIN directory — no build marker of any kind"
for marker in kustomization.yaml kustomization.yml Chart.yaml values.yaml .argocd-source.yaml; do
  if [ -e "${REPO_ROOT}/apps/storefront/manifests/${marker}" ]; then
    _fail "apps/storefront/manifests/${marker} exists — Argo CD would detect a build tool and the lesson's premise collapses"
  fi
done
_pass "no kustomization, chart or plugin marker present"

step "the manifests are what the lesson narrates: a Deployment and a Service, nothing else"
assert_yaml_wellformed "apps/storefront/manifests/deployment.yaml"
assert_yaml_wellformed "apps/storefront/manifests/service.yaml"

step "the image is a tag that exists"
# hashicorp/http-echo:1.4.2 is a 404 and would ImagePullBackOff on camera. 1.4.2 is legitimate
# ONLY on the fictional ghcr.io/northwind image, which is never pulled.
if grep -q 'hashicorp/http-echo:1\.4\.2' "${REPO_ROOT}/apps/storefront/manifests/deployment.yaml"; then
  _fail "deployment pins hashicorp/http-echo:1.4.2, which does not exist — this ImagePullBackOffs on camera"
fi
grep -q 'image: hashicorp/http-echo:' "${REPO_ROOT}/apps/storefront/manifests/deployment.yaml" \
  && _pass "image pinned to an existing hashicorp/http-echo tag" \
  || _fail "no pinned hashicorp/http-echo image in the plain-directory Deployment"

smoke_done
