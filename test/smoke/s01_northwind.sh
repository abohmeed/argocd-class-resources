#!/usr/bin/env bash
# S02 L04 + L05 (ACD-82, ACD-83): build Northwind from empty, then hand it to Argo CD.
#
# This script IS the lesson's commands. If the lesson changes, this changes with it in the same PR;
# CI diffs the two. That is the mechanism that makes repo drift structurally impossible.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

NS="storefront-dev"

step "S02 L04 (ACD-82): apply the overlay by hand, with no Argo CD in the loop"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "${REPO_ROOT}/apps/storefront/overlays/dev"
wait_for_rollout deployment/storefront "${NS}"

# The banner is read the way the lesson reads it: port-forward to the Service, then curl. Until
# 2026-09-27 this ran `wget` inside the container, but hashicorp/http-echo ships no shell and no
# wget, so it always read an empty string and reported "banner not served".
banner() {
  local pf out=""
  kubectl port-forward -n "${NS}" svc/storefront 18080:80 >/dev/null 2>&1 &
  pf=$!
  for _ in $(seq 1 20); do
    out="$(curl -s --max-time 2 localhost:18080 2>/dev/null || true)"
    [ -n "${out}" ] && break
    sleep 1
  done
  kill "${pf}" 2>/dev/null || true
  wait "${pf}" 2>/dev/null || true
  printf '%s' "${out}"
}

step "S02 L04 (ACD-82): the banner is served from an env var, so a ConfigMap edit alone does NOT change it"
before="$(banner)"
[ -n "${before}" ] && _pass "banner served: ${before}" || _fail "banner not served"

kubectl patch configmap -n "${NS}" \
  "$(kubectl get cm -n "${NS}" -o name | grep storefront-banner | head -1 | cut -d/ -f2)" \
  --type merge -p '{"data":{"banner":"storefront v2 — edited in place"}}'
sleep 5
after="$(banner)"
if [ "${before}" = "${after}" ]; then
  _pass "banner unchanged after ConfigMap edit — the teaching point holds (env var is read at start)"
else
  _fail "banner changed without a restart; the lesson's closing surprise does not reproduce"
fi

step "cleanup"
kubectl delete namespace "${NS}" --wait=true --timeout=120s >/dev/null 2>&1 || true  # wait: s02_l05 next syncs the same overlay into this namespace
printf '\n\033[32ms01 passed\033[0m\n'
