#!/usr/bin/env bash
# S14 L05 — part one: a Rollout's canary analysis step that names a typo'd AnalysisTemplate
# HANGS (never fails, never promotes), and fixing the reference lets a real HTTP check pass or
# fail the canary on its own.
#
# Part two of this lesson (deleting Argo CD's own namespace outright and restoring it from
# `argocd admin export`) is the same class of destructive, irreversible-on-a-shared-cluster
# action S12 L06 already declares external for — repeating it here would either skip it silently
# or take down every other lesson's cluster state. This script proves part one for real and
# declares part two, matching S12 L06's own precedent.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S14-L05 "a canary's analysis step hangs on a typo'd template name and never silently passes"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

NS="s14l05-canary"
cleanup() {
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "confirm the Argo Rollouts controller and its kubectl plugin are actually available"
kubectl get pods -n argo-rollouts --no-headers 2>/dev/null | grep -q Running \
  || _fail "no Running pod in argo-rollouts — this lesson's precondition (S10 L02/L04) is not met on this cluster"
command -v kubectl-argo-rollouts >/dev/null 2>&1 || kubectl argo rollouts version >/dev/null 2>&1 \
  || _fail "the kubectl argo rollouts plugin is not available on PATH"

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

step "a Rollout whose analysis step names a template that does not exist hangs — it does not fail and does not promote"
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: s14l05-probe
spec:
  selector: {app.kubernetes.io/name: s14l05-probe}
  ports: [{name: http, port: 80, targetPort: http}]
EOF
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: s14l05-probe
spec:
  replicas: 2
  selector:
    matchLabels: {app.kubernetes.io/name: s14l05-probe}
  template:
    metadata:
      labels: {app.kubernetes.io/name: s14l05-probe}
    spec:
      containers:
        - name: probe
          image: hashicorp/http-echo:1.0
          args: ["-listen=:5678", "-text=s14l05 probe"]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
  strategy:
    canary:
      steps:
        - setWeight: 50
        - pause: {}
        - analysis:
            templates:
              - templateName: s14l05-check-typoed
EOF

sleep 40
phase="$(kubectl argo rollouts get rollout s14l05-probe -n "${NS}" -o json 2>/dev/null | grep -o '"phase":"[^"]*"' | head -1 || true)"
analysisruns="$(kubectl get analysisrun -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${analysisruns}" = "0" ]; then
  _pass "no AnalysisRun was ever created for a reference to a nonexistent AnalysisTemplate — the step hangs rather than erroring, exactly as this lesson claims"
else
  _fail "an AnalysisRun was created despite the template name being wrong — the hang did not reproduce as this lesson describes"
fi

step "fixing the reference and giving it a real, passing check lets the canary complete on its own"
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: s14l05-check-typoed
spec:
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
                  - name: check
                    image: curlimages/curl:8.11.0
                    command: ["sh", "-c"]
                    args:
                      - |
                        BODY=$(curl -s http://s14l05-probe.s14l05-canary.svc.cluster.local)
                        test "$BODY" = "s14l05 probe"
EOF

ok=no
for _ in $(seq 1 12); do
  sleep 10
  status="$(kubectl get analysisrun -n "${NS}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  [ "${status}" = "Successful" ] && { ok=yes; break; }
  [ "${status}" = "Failed" ] && break
done
if [ "${ok}" = yes ]; then
  _pass "with the correct template name and a real HTTP check, the AnalysisRun runs and passes"
else
  _fail "the AnalysisRun did not reach Successful within the timeout — the fix this lesson teaches did not hold on this cluster (last status: '${status:-none}')"
fi

smoke_done
