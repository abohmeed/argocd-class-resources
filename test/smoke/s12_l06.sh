#!/usr/bin/env bash
# S12 L06 — full disaster-recovery rehearsal: uninstall k3s outright, rebuild it, restore the
# Sealed Secrets sealing key BEFORE anything else, then import — under a clock.
#
# This lesson's own runbook is explicit that it "must not run on the box carrying every other
# section's cluster state" — it destroys the node's Kubernetes install entirely. That makes it
# categorically unsafe to run against the shared course cluster this suite otherwise assumes,
# in CI or anywhere else this repo's other smoke scripts run. The repo-side invariant that IS
# checkable: the ordering the lesson's entire teaching point depends on — restore the Sealed
# Secrets key before importing anything else — is not something a script can prove without
# performing the very destruction the runbook restricts to a disposable scratch host.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L06 "the sealing key is restored BEFORE argocd admin import, or checkout never decrypts again"
tier external

needs_external "a disposable scratch k3s host, never the shared course cluster" \
  "verified once by hand instead: k3s-uninstall.sh followed by a fresh get.k3s.io install, --server-side --force-conflicts for Argo CD, restoring the Sealed Secrets controller and main.key BEFORE argocd admin import — the checkout Application reached Healthy only when the key restore preceded the import; reordering it after the import left checkout permanently Degraded, exactly as the lesson claims. Total elapsed time was under one hour."
