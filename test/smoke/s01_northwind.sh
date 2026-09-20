#!/usr/bin/env bash
# S01 L04 + L05 — build Northwind from empty, then hand it to Argo CD.
#
# This script IS the lesson's commands. If the lesson changes, this changes with it in the same PR;
# CI diffs the two. That is the mechanism that makes repo drift structurally impossible.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

NS="storefront-dev"

step "S01 L04 — apply the overlay by hand, with no Argo CD in the loop"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "${REPO_ROOT}/apps/storefront/overlays/dev"
wait_for_rollout deployment/storefront "${NS}"

step "S01 L04 — the banner is served from an env var, so a ConfigMap edit alone does NOT change it"
before="$(kubectl exec -n "${NS}" deploy/storefront -- wget -qO- localhost:5678 2>/dev/null || true)"
[ -n "${before}" ] && _pass "banner served: ${before}" || _fail "banner not served"

kubectl patch configmap -n "${NS}" \
  "$(kubectl get cm -n "${NS}" -o name | grep storefront-banner | head -1 | cut -d/ -f2)" \
  --type merge -p '{"data":{"banner":"storefront v2 — edited in place"}}'
sleep 5
after="$(kubectl exec -n "${NS}" deploy/storefront -- wget -qO- localhost:5678 2>/dev/null || true)"
if [ "${before}" = "${after}" ]; then
  _pass "banner unchanged after ConfigMap edit — the teaching point holds (env var is read at start)"
else
  _fail "banner changed without a restart; the lesson's closing surprise does not reproduce"
fi

step "cleanup"
kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
printf '\n\033[32ms01 passed\033[0m\n'
