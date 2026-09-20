#!/usr/bin/env bash
# S14 L01 — self-manage-app.yaml governs the control plane one wave ahead of everything else,
# and root's own app-of-apps sync never touches it — because it deliberately does not live
# inside bootstrap/apps/, the one directory root watches.
#
# The 262144-byte client-side-apply wall for this same install is already defended in full by
# s12_l08.sh; this script does not repeat that reproduction. What is unique to THIS lesson: the
# sync-wave ordering between the control plane's own Application and everything built on top of
# it, and the repo layout that keeps root from ever trying to reconcile Argo CD's own install.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S14-L01 "self-manage-app.yaml sits outside bootstrap/apps/, so root never reconciles Argo CD's own install"
tier cluster

step "repo layout: self-manage-app.yaml is a sibling of root-app.yaml, not a child root-app.yaml watches"
assert_exists_file "bootstrap/self-manage-app.yaml"
assert_exists_file "bootstrap/root-app.yaml"
if [ -f "${REPO_ROOT}/bootstrap/apps/self-manage-app.yaml" ]; then
  _fail "self-manage-app.yaml now exists inside bootstrap/apps/ — root would try to reconcile Argo CD's own install as a child, which is exactly what this lesson says must never happen"
else
  _pass "self-manage-app.yaml is not inside bootstrap/apps/ — root cannot see it"
fi

step "root-app.yaml watches bootstrap/apps, and self-manage-app.yaml watches bootstrap itself — two different paths, on purpose"
assert_file_contains "bootstrap/root-app.yaml" 'path: bootstrap/apps' \
  "root's source path is bootstrap/apps"
assert_file_contains "bootstrap/self-manage-app.yaml" 'path: bootstrap$' \
  "the control-plane Application's source path is bootstrap itself, not bootstrap/apps"

step "on the live cluster, the argocd (self-manage) Application actually carries the wave -1 annotation"
if kubectl get application argocd -n argocd >/dev/null 2>&1; then
  wave="$(kubectl get application argocd -n argocd -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}' 2>/dev/null || true)"
  if [ "${wave}" = "-1" ]; then
    _pass "the argocd Application carries argocd.argoproj.io/sync-wave: \"-1\""
  else
    _fail "expected sync-wave '-1' on the argocd Application, got '${wave:-<unset>}' — Step 5's ordering annotation is missing"
  fi
else
  _fail "no Application named 'argocd' exists on this cluster — S14 L01's self-management bootstrap has not been applied"
fi

step "root never lists the argocd Application among the children it manages"
managed="$(kubectl get application root -n argocd -o jsonpath='{.status.resources[?(@.kind=="Application")].name}' 2>/dev/null || true)"
if printf '%s' "${managed}" | grep -qw argocd; then
  _fail "root's own managed resources include an Application named 'argocd' — root is reconciling the control plane's own install, which this lesson's repo layout exists to prevent"
else
  _pass "root's managed resources do not include the argocd Application — the control plane stays outside root's app-of-apps tree"
fi

smoke_done
