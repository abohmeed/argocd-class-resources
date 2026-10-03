#!/usr/bin/env bash
# S12 L02 — one ServiceMonitor selector covers all three Argo CD metrics services because all
# three name their port literally "metrics", and the PrometheusRule this lesson writes must
# actually parse before it is ever trusted at 3am.
#
# The lesson stands up Prometheus Operator itself as a dependency (this course does not install
# it anywhere earlier) and proves two things: the ServiceMonitor's label selector genuinely
# reaches all three services, and the alert rules are syntactically valid. The full "which alert
# fires first under load" race is a multi-minute timing test this script does not attempt —
# that is a judgment call for a human watching the take, not a boolean CI can assert honestly.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L02 "one label selector reaches all three Argo CD metrics services, and both alert rules parse"
tier cluster

step "all three Argo CD metrics services name their port literally 'metrics' — what makes one selector cover all three"
for svc in argocd-metrics argocd-server-metrics argocd-repo-server; do
  port_name="$(kubectl get svc "${svc}" -n argocd -o jsonpath='{.spec.ports[?(@.port==8082 || @.port==8083 || @.port==8084)].name}' 2>/dev/null || true)"
  if printf '%s' "${port_name}" | grep -qw metrics; then
    _pass "${svc} names its metrics port 'metrics'"
  else
    _fail "${svc} does not expose a port literally named 'metrics' (got: '${port_name}') — the ServiceMonitor's single selector would miss it"
  fi
done

step "Prometheus Operator's CRDs are installed — the lesson's own precondition, proven rather than assumed"
if kubectl get crd servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  _pass "ServiceMonitor and PrometheusRule CRDs are present"
else
  _fail "Prometheus Operator CRDs are missing — install kube-prometheus-stack per this lesson's runbook before recording"
fi

step "the PrometheusRule this lesson writes is syntactically valid before it is ever applied"
tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT
cat > "${tmpfile}" <<'EOF'
groups:
  - name: argocd-health
    rules:
      - alert: ArgoCDReconcileDurationHigh
        expr: histogram_quantile(0.95, sum(rate(argocd_app_reconcile_bucket[5m])) by (le)) > 5
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "Argo CD reconcile duration (p95) above 5s for 10 minutes"
      - alert: ArgoCDRepoServerQueueGrowing
        expr: deriv(argocd_repo_pending_request_total[5m]) > 0
        for: 5m
        labels:
          severity: page
        annotations:
          summary: "Argo CD repo-server pending-request count is climbing"
EOF
if command -v promtool >/dev/null 2>&1; then
  if promtool check rules "${tmpfile}" >/dev/null 2>&1; then
    _pass "both alert rules parse under promtool"
  else
    _fail "promtool rejects the rule file:\n$(promtool check rules "${tmpfile}" 2>&1)"
  fi
elif command -v docker >/dev/null 2>&1; then
  if docker run --rm -v "${tmpfile}:/work/rules.yaml" prom/prometheus promtool check rules /work/rules.yaml >/dev/null 2>&1; then
    _pass "both alert rules parse under promtool (containerised)"
  else
    _fail "promtool rejects the rule file (containerised check)"
  fi
else
  _fail "cannot check the rule file: neither promtool nor docker is on PATH (environment fault, not a defect in the rules)"
fi

smoke_done
