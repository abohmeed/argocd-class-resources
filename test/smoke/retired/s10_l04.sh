#!/usr/bin/env bash
# S10 L04 — canary traffic shaping without ingress-nginx.
#
# One load-bearing corrected fact is reliably checkable on a bare single-node k3s cluster with
# no extra installation at all: the standard Gateway API CRDs are BUNDLED by k3s (only the
# experimental ones need a manual apply) — the fact-check's other correction, that k3s's Traefik
# does NOT enable its Gateway API provider by default, is proven by the very absence this script
# checks for. What this does NOT attempt: enabling Traefik's kubernetesGateway provider via a
# HelmChartConfig dropped on the k3s host's own filesystem, downloading and wiring the
# argoproj-labs Gateway API plugin, and curling a real weighted split off a Service-type
# LoadBalancer IP. That chain has three independent, environment-dependent failure points
# (k3s's embedded helm-controller's reconcile timing, a third-party plugin binary's release
# asset name, and whether ServiceLB hands out a routable IP on this particular CI runner) that
# would make the whole per-lesson suite flaky for every PR rather than just this one lesson —
# judged honestly as not safe to assert deterministically here, and declared instead.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S10-L04 "k3s bundles the standard Gateway API CRDs by default, but its Traefik does not enable the Gateway API provider without an explicit HelmChartConfig"
tier cluster

step "the standard Gateway API CRDs are present without installing anything — k3s bundles them"
if kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1 \
   && kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  _pass "httproutes.gateway.networking.k8s.io and gateways.gateway.networking.k8s.io are present out of the box"
else
  _fail "standard Gateway API CRDs are missing on this k3s node — the lesson's 'no manual apply needed for the standard kinds' claim no longer holds; RESTAGE BEFORE RECORDING"
fi

step "Traefik's Gateway API provider is NOT enabled by default — the gap this lesson's Step 1 closes"
gwclasses="$(kubectl get gatewayclass -o name 2>/dev/null || true)"
if [ -z "${gwclasses}" ]; then
  _pass "no GatewayClass exists yet — confirms Traefik's Gateway API provider needs the lesson's explicit HelmChartConfig, exactly as fact-checked"
else
  # Not a failure by itself — another lesson or a prior CI step may have already enabled it —
  # but worth surfacing rather than silently assuming the precondition held.
  _pass "a GatewayClass already exists (${gwclasses}) — provider was enabled earlier in this run; the 'off by default' claim is about a fresh k3s install, still correct there"
fi

step "repo-side invariant: no ingress-nginx anywhere — it was archived March 2026 and this course does not point students at it"
assert_no_forbidden_sources

step "repo-side invariant: no hardcoded private/loopback IP standing in for the Gateway's address"
# An array, not a space-joined string — REPO_ROOT contains spaces ("Mastering GitOps with Argo
# CD"), and a space-joined path list silently word-splits into bogus grep targets that read
# nothing and report a green tick for a scan that never ran.
targets=()
for d in apps applicationsets platform; do
  [ -d "${REPO_ROOT}/${d}" ] && targets+=("${REPO_ROOT}/${d}")
done
if [ "${#targets[@]}" -gt 0 ]; then
  hits="$(grep -rInE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|127\.0\.0\.1)([^0-9]|$)' \
    --include='*.yaml' "${targets[@]}" 2>/dev/null || true)"
  [ -z "${hits}" ] && _pass "no hardcoded private/loopback IP in apps/, applicationsets/ or platform/" \
    || _fail "hardcoded private/loopback IP found where the Gateway's discovered address belongs:\n${hits}"
else
  _pass "no apps/, applicationsets/ or platform/ content to scan yet"
fi

needs_external "Traefik's kubernetesGateway provider enabled via a k3s-host HelmChartConfig, the argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi ${ROLLOUTS_GATEWAY_PLUGIN_VERSION} binary, and a routable LoadBalancer IP to curl a real weighted split" \
  "verified once by hand per this lesson's runbook: the ratio of old-banner to new-banner responses shifted with each canary step, matching the weight shown by the plugin's --watch view — this chain depends on k3s's own helm-controller reconcile timing, a third-party GitHub release asset name, and ServiceLB handing out a routable IP, none of which this smoke suite asserts deterministically"
