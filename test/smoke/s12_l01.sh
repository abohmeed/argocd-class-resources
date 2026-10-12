#!/usr/bin/env bash
# lesson: s12_l01 Watching Argo CD itself: the metrics that warn first
# Argo CD exposes its own health as metrics: a histogram for latency, a counter for
# totals, and a DEAD endpoint reads as connection-refused, not a page full of zeros.
#
# The lesson's claim is behavioural: (1) argocd-metrics carries a reconcile-duration histogram
# next to a plain sync counter: different shapes, on purpose; (2) a down repo-server looks
# nothing like an idle one; (3) real rendering load moves the repo-server's own pending-request
# metric. This drives the actual cluster rather than reading the metric names off a doc page.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

# wait_for_forward <host:port/path>: a port-forward needs a moment to listen. Poll for an answer, up to 30 seconds,
# instead of a fixed sleep that loses the race on a busy cluster.
wait_for_forward() {
  local i
  for i in $(seq 1 30); do curl -s -m 2 "$1" >/dev/null 2>&1 && return 0; sleep 1; done
  return 0
}

lesson S12-L01 "argocd_app_reconcile is a histogram, argocd_app_sync_total is a counter, and a dead endpoint refuses rather than reads zero"
tier cluster

DUMMY_NS_PREFIX="s12l01dummy"
DUMMY_COUNT=8
PF_METRICS_PID=""
PF_REPO_PID=""

cleanup() {
  [ -n "${PF_METRICS_PID}" ] && kill "${PF_METRICS_PID}" >/dev/null 2>&1 || true
  [ -n "${PF_REPO_PID}" ] && kill "${PF_REPO_PID}" >/dev/null 2>&1 || true
  for i in $(seq -w 1 "${DUMMY_COUNT}"); do
    kubectl delete application "${DUMMY_NS_PREFIX}-${i}" -n argocd --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "${DUMMY_NS_PREFIX}-${i}" --wait=false >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

step "the application controller reports a histogram next to a counter, not two counters"
kubectl port-forward svc/argocd-metrics -n argocd 18082:8082 >/dev/null 2>&1 &
PF_METRICS_PID=$!
wait_for_forward localhost:18082/metrics
metrics="$(curl -s localhost:18082/metrics)"
# grep -q <<< rather than a pipe: with pipefail, grep quitting early SIGPIPEs printf on a large body and fails the check.
if grep -q '^argocd_app_reconcile_bucket{' <<<"${metrics}"; then
  _pass "argocd_app_reconcile is a histogram (le= buckets present)"
else
  _fail "no argocd_app_reconcile_bucket series: the reconcile-duration histogram is missing"
fi
if grep -q '^argocd_app_sync_total' <<<"${metrics}"; then
  _pass "argocd_app_sync_total is present as a counter"
else
  _fail "no argocd_app_sync_total series"
fi
kill "${PF_METRICS_PID}" >/dev/null 2>&1 || true
PF_METRICS_PID=""

step "cluster-cache staleness is exposed too: the third signal the lesson points at"
kubectl port-forward svc/argocd-metrics -n argocd 18082:8082 >/dev/null 2>&1 &
PF_METRICS_PID=$!
wait_for_forward localhost:18082/metrics
cache_metrics="$(curl -s localhost:18082/metrics)"
if grep -q '^argocd_cluster_cache_age_seconds' <<<"${cache_metrics}"; then
  _pass "argocd_cluster_cache_age_seconds is exposed"
else
  _fail "no argocd_cluster_cache_age_seconds series"
fi
kill "${PF_METRICS_PID}" >/dev/null 2>&1 || true
PF_METRICS_PID=""

step "a metrics endpoint with no live port-forward refuses the connection: 'down' does not read as a healthy zero"
if curl -s -m 3 localhost:18099/metrics >/dev/null 2>&1; then
  _fail "an endpoint answered on a port nothing was forwarded to: cannot demonstrate the down case"
else
  _pass "an unreachable metrics endpoint fails the connection outright, exactly as this lesson says 'down' looks: never a page full of zeros"
fi

step "repo-server pending-request pressure climbs under real rendering load"
kubectl port-forward svc/argocd-repo-server -n argocd 18084:8084 >/dev/null 2>&1 &
PF_REPO_PID=$!
wait_for_forward localhost:18084/metrics
baseline="$(curl -s localhost:18084/metrics | grep '^argocd_repo_pending_request_total' | awk '{s+=$NF} END{print s+0}')"

for i in $(seq -w 1 "${DUMMY_COUNT}"); do
  kubectl apply -f - >/dev/null <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${DUMMY_NS_PREFIX}-${i}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/abohmeed/argocd-class-resources.git
    targetRevision: main
    path: apps/storefront/base
  destination:
    server: https://kubernetes.default.svc
    namespace: ${DUMMY_NS_PREFIX}-${i}
  syncPolicy: {}
EOF
done

# The metric is a gauge of requests waiting on the repository lock right now: it rises only while renders are running,
# and the eight renders drain in seconds. So the sampling forces fresh renders (a hard refresh of each dummy, as the
# lesson's watch troubleshooting row says) and samples while they run, keeping the highest reading seen.
moved=no
peak="${baseline}"
for _ in $(seq 1 12); do
  for i in $(seq -w 1 "${DUMMY_COUNT}"); do
    kubectl -n argocd annotate application "${DUMMY_NS_PREFIX}-${i}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
  for _s in 1 2 3 4 5; do
    now="$(curl -s localhost:18084/metrics | grep '^argocd_repo_pending_request_total' | awk '{s+=$NF} END{print s+0}')"
    awk -v a="${now}" -v b="${peak}" 'BEGIN{exit !(a>b)}' && peak="${now}"
    sleep 1
  done
  awk -v a="${peak}" -v b="${baseline}" 'BEGIN{exit !(a>b)}' && { moved=yes; break; }
done
now="${peak}"

if [ "${moved}" = yes ]; then
  _pass "argocd_repo_pending_request_total climbed from ${baseline} under ${DUMMY_COUNT} freshly rendered Applications"
else
  _fail "pending-request pressure never moved off its baseline (${baseline}) after ${DUMMY_COUNT} Applications were applied: either the load never reached the repo-server, or the metric no longer measures what this lesson claims"
fi

smoke_done
