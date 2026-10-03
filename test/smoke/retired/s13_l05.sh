#!/usr/bin/env bash
# S13 L05 — the Source Hydrator ships INSIDE Argo CD 3.5.3's own components, gated by a flag —
# it is not a separate controller with its own manifest to install.
#
# This directly contradicts this lesson's own runbook and script, which have the producer run
# `kubectl apply -n argocd -f hydrator.yaml` against a separate "hydrate controller" that the
# runbook's own ⚠ banner admits does not exist anywhere in this repo or upstream. The pinned
# v3.5.3 install manifest this course already carries settles it two ways at once: the
# Application CRD already defines `sourceHydrator` natively (no separate CRD to install), and
# both the applicationset-controller and the application-controller read
# ARGOCD_HYDRATOR_ENABLED from `hydrator.enabled` in argocd-cmd-params-cm — a feature flag on
# EXISTING components, not a workload to deploy. This is repo-tier: everything here is checked
# against the file this repo already commits, not a live cluster.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S13-L05 "the Source Hydrator is a flag on existing components, not a separate hydrator.yaml controller"
tier repo

step "no hydrator.yaml (or anything claiming to be a standalone hydrate controller) is committed to this repo"
if find "${REPO_ROOT}" -iname 'hydrator.yaml' -not -path '*/.git/*' 2>/dev/null | grep -q .; then
  _fail "a hydrator.yaml now exists in this repo — if a real, separate hydrate-controller manifest has shipped, this lesson's runbook gap is resolved and this script's claim needs revisiting"
else
  _pass "no separate hydrator.yaml exists — nothing in this repo installs a standalone hydrate controller"
fi

step "the pinned v3.5.3 install manifest already defines sourceHydrator natively on the Application CRD"
assert_file_contains "bootstrap/install.yaml" 'sourceHydrator:' \
  "the Application CRD in the pinned install manifest already carries sourceHydrator — nothing extra to install for the CRD to accept it"

step "ARGOCD_HYDRATOR_ENABLED is wired from hydrator.enabled in argocd-cmd-params-cm — a flag on existing components"
assert_file_contains "bootstrap/install.yaml" 'ARGOCD_HYDRATOR_ENABLED' \
  "the pinned install manifest already wires ARGOCD_HYDRATOR_ENABLED"
assert_file_contains "bootstrap/install.yaml" 'key: hydrator\.enabled' \
  "ARGOCD_HYDRATOR_ENABLED reads from the hydrator.enabled key in argocd-cmd-params-cm — a ConfigMap flag, not a workload"

smoke_done
