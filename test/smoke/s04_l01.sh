#!/usr/bin/env bash
# lesson: s04_l01 Plain manifests as a source: the honest limits
# The plain-directory source type.
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

step "and it is a PLAIN directory: the manifests themselves, with no chart or plugin marker"
for marker in kustomization.yml Chart.yaml values.yaml .argocd-source.yaml; do
  if [ -e "${REPO_ROOT}/apps/storefront/manifests/${marker}" ]; then
    _fail "apps/storefront/manifests/${marker} exists: Argo CD would detect a build tool and the lesson's premise collapses"
  fi
done
_pass "no chart or plugin marker present"

step "the one marker a later lesson adds changes the source type, not the manifests"
# The next lesson commits apps/storefront/manifests/kustomization.yaml on purpose, to flip
# detection from Directory to Kustomize, so a fork that has followed the course past this lesson
# carries that file. It is allowed only in that exact shape: it lists the two manifests under
# resources: and does nothing else, so what gets applied is still these files as written.
KZ="${REPO_ROOT}/apps/storefront/manifests/kustomization.yaml"
if [ -e "${KZ}" ]; then
  extra="$(grep -vE '^(apiVersion: kustomize\.config\.k8s\.io/v1beta1|kind: Kustomization|resources:|  - (deployment|service)\.yaml)[[:space:]]*$' "${KZ}" | grep -vE '^[[:space:]]*(#.*)?$' || true)"
  [ -z "${extra}" ] \
    || _fail "apps/storefront/manifests/kustomization.yaml does more than list the two manifests:\n${extra}"
  _pass "kustomization.yaml (added by the next lesson) only lists deployment.yaml and service.yaml"
else
  _pass "no kustomization.yaml yet: the directory is plain, as this lesson starts"
fi

step "the manifests are what the lesson shows: a Deployment and a Service, nothing else"
assert_yaml_wellformed "apps/storefront/manifests/deployment.yaml"
assert_yaml_wellformed "apps/storefront/manifests/service.yaml"

step "the image is a tag that exists"
# hashicorp/http-echo:1.4.2 is a 404 and would ImagePullBackOff. 1.4.2 is legitimate
# ONLY on the fictional ghcr.io/northwind image, which is never pulled.
if grep -q 'hashicorp/http-echo:1\.4\.2' "${REPO_ROOT}/apps/storefront/manifests/deployment.yaml"; then
  _fail "deployment pins hashicorp/http-echo:1.4.2, which does not exist: this ImagePullBackOffs"
fi
grep -q 'image: hashicorp/http-echo:' "${REPO_ROOT}/apps/storefront/manifests/deployment.yaml" \
  && _pass "image pinned to an existing hashicorp/http-echo tag" \
  || _fail "no pinned hashicorp/http-echo image in the plain-directory Deployment"

smoke_done
