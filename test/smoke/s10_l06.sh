#!/usr/bin/env bash
# S10 L06 — seeing the rollout inside Argo CD, not just kubectl.
#
# The claim this lesson shows is a UI panel rendering step progress, traffic weight and pause
# state inside the Argo CD web UI — inherently something only a browser can confirm, and the
# runbook's own header flags that the extension-installer image tag and the exact release-asset
# URLs were never independently confirmed while writing it. What IS checkable without a browser
# is the mechanism the runbook substitutes for the (false, for this repo) argo-helm-chart
# premise: bootstrap/install.yaml is the pinned, unmodified upstream manifest, and
# bootstrap/self-manage-app.yaml is what reconciles it with ServerSideApply and prune off — the
# two facts that make "patch install.yaml directly" the only route that survives self-heal.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S10-L06 "the Rollouts UI extension is added to argocd-server's own tracked Deployment, not an argo-helm chart this repo never used"
tier external

INSTALL="bootstrap/install.yaml"
SELF_MANAGE="bootstrap/self-manage-app.yaml"

step "the premise the runbook corrects: this repo installs Argo CD from the pinned raw manifest, never a Helm chart"
assert_exists_file "${INSTALL}"
assert_file_contains "${INSTALL}" 'DO NOT EDIT' \
  "install.yaml is the auto-generated, pinned upstream manifest — the file this lesson's init container is added directly into"
assert_no_forbidden_sources
assert_file_contains "${INSTALL}" 'curl -sSL -o bootstrap/install\.yaml' \
  "install.yaml's own header says how it was produced — a raw curl of the upstream release manifest, not a Helm chart render"
# install.yaml itself legitimately mentions "helm" throughout — it is Argo CD's own Application
# CRD schema, which supports Helm as one Application SOURCE TYPE. That is not evidence of how
# ARGO CD ITSELF was installed. The real signal is an argo-helm CHART reference anywhere else
# under bootstrap/ — none should exist, or the runbook's "no chart release manages this
# Deployment" premise (and this lesson's whole mechanism) is stale.
chart_hits="$(grep -rIln 'argo-helm\|repository: https://argoproj\.github\.io/argo-helm' \
  --exclude-dir=.git --include='*.yaml' "${REPO_ROOT}/bootstrap" 2>/dev/null || true)"
if [ -z "${chart_hits}" ]; then
  _pass "no argo-helm chart reference under bootstrap/ — the extension-installer init container patched directly into install.yaml is the correct route for this repo"
else
  _fail "an argo-helm chart reference exists under bootstrap/ — if this repo now installs Argo CD via that chart, the extension SHOULD go through server.extensions instead, and this lesson's direct-patch mechanism is stale:\n${chart_hits}"
fi

step "self-manage-app.yaml reconciles install.yaml with the settings the runbook depends on"
assert_exists_file "${SELF_MANAGE}"
assert_file_contains "${SELF_MANAGE}" 'ServerSideApply=true' \
  "ServerSideApply=true is set — required since 3.3 for the ApplicationSet CRD's annotation-size ceiling, and what lets the extension init container merge in cleanly"
assert_file_contains "${SELF_MANAGE}" 'prune: false' \
  "prune: false on the control plane's own Application — a live kubectl edit on argocd-server that is not also committed to install.yaml gets reverted by self-heal, which is exactly why this lesson edits the tracked file instead"
assert_file_contains "${SELF_MANAGE}" 'selfHeal: true' \
  "selfHeal: true — confirms a live, uncommitted edit to argocd-server really would be reverted within one reconciliation, the reason this lesson never uses kubectl edit"

needs_external "a browser open on the Argo CD UI's storefront Rollout resource view, to confirm step progress, traffic weight and pause state actually render after the extension installs and argocd-server restarts" \
  "not verifiable from a terminal: rendering a UI panel needs a browser, and this runbook's own header flags that the extension-installer image tag (quay.io/argoprojlabs/argocd-extension-installer:v0.0.9) and the extension release URLs were never independently confirmed while writing it — verify both against the argoproj-labs/rollout-extension release page before recording, not on camera"
