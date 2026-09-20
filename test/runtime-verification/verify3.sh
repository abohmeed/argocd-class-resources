#!/bin/bash
K="sudo k3s kubectl"
r(){ printf '%-6s %-26s %s\n' "$1" "$2" "$3"; }
NS=storefront-dev
$K create namespace $NS >/dev/null 2>&1

cat <<'YAML' | $K apply -n storefront-dev -f - >/dev/null 2>&1
apiVersion: apps/v1
kind: Deployment
metadata: {name: storefront}
spec:
  replicas: 1
  selector: {matchLabels: {app: storefront}}
  template:
    metadata: {labels: {app: storefront}}
    spec:
      containers:
      - name: storefront
        image: hashicorp/http-echo:1.0.0
        args: ["-text=storefront v2 - canary", "-listen=:5678"]
        ports: [{containerPort: 5678}]
---
apiVersion: v1
kind: Service
metadata: {name: storefront}
spec:
  selector: {app: storefront}
  ports: [{port: 80, targetPort: 5678}]
YAML
$K rollout status deploy/storefront -n $NS --timeout=120s >/dev/null 2>&1
BANNER=$($K run curlcheck -n $NS --rm -i --restart=Never --image=curlimages/curl:8.11.0 --quiet -- \
         -sf http://storefront.storefront-dev.svc.cluster.local 2>/dev/null | tr -d '\r')
r INFO "storefront-banner" "served: '$(echo $BANNER)'"

run_ar(){ # $1 name  $2 yaml
  echo "$2" | $K apply -n $NS -f - >/dev/null 2>&1
  for i in $(seq 1 40); do
    P=$($K get analysisrun "$1" -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$P" in Successful|Failed|Error|Inconclusive) break;; esac
    sleep 3
  done
  echo "$P"
}

echo
echo "===== K. Job provider, banner MATCHES (should be Successful) ====="
P1=$(run_ar job-good "$(cat <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata: {name: job-good}
spec:
  args: [{name: expected-banner, value: "storefront v2 - canary"}]
  metrics:
  - name: banner-matches
    provider:
      job:
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              containers:
              - name: check-banner
                image: curlimages/curl:8.11.0
                command: [sh, -c, 'actual=$(curl -sf http://storefront.storefront-dev.svc.cluster.local); echo "expected: {{args.expected-banner}}"; echo "actual:   $actual"; [ "$actual" = "{{args.expected-banner}}" ]']
YAML
)")
[ "$P1" = "Successful" ] && r PASS "job-good" "phase=$P1" || r FAIL "job-good" "phase=$P1"

echo
echo "===== L. Job provider, banner BROKEN (must be Failed) ====="
P2=$(run_ar job-bad "$(cat <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata: {name: job-bad}
spec:
  args: [{name: expected-banner, value: "storefront v3 - THIS IS WRONG"}]
  metrics:
  - name: banner-matches
    provider:
      job:
        spec:
          backoffLimit: 0
          template:
            spec:
              restartPolicy: Never
              containers:
              - name: check-banner
                image: curlimages/curl:8.11.0
                command: [sh, -c, 'actual=$(curl -sf http://storefront.storefront-dev.svc.cluster.local); echo "expected: {{args.expected-banner}}"; echo "actual:   $actual"; [ "$actual" = "{{args.expected-banner}}" ]']
YAML
)")
if [ "$P2" = "Failed" ]; then r PASS "job-bad-FAILS" "phase=$P2 — the lesson's abort beat really fires"; else r FAIL "job-bad-FAILS" "phase=$P2 — expected Failed"; fi
JOBPOD=$($K get pods -n $NS -l job-name --no-headers 2>/dev/null | tail -1 | awk '{print $1}')
[ -n "$JOBPOD" ] && $K logs "$JOBPOD" -n $NS 2>/dev/null | sed 's/^/       /'

echo
echo "===== M. Web provider on the SAME plain-text banner (L-128) ====="
echo "       successCondition is deliberately impossible: result == 'NEVER_MATCHES'"
P3=$(run_ar web-shortcircuit "$(cat <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisRun
metadata: {name: web-shortcircuit}
spec:
  metrics:
  - name: banner-web
    successCondition: "result == 'NEVER_MATCHES_ANYTHING'"
    provider:
      web:
        url: "http://storefront.storefront-dev.svc.cluster.local"
        timeoutSeconds: 10
YAML
)")
if [ "$P3" = "Successful" ]; then
  r PASS "web-short-circuits" "phase=$P3 on an IMPOSSIBLE condition — successCondition was never evaluated"
else
  r INFO "web-short-circuits" "phase=$P3 — condition WAS evaluated; the short-circuit did not reproduce"
fi
$K get analysisrun web-shortcircuit -n $NS -o jsonpath='{.status.metricResults[0]}' 2>/dev/null | head -c 400; echo
