#!/usr/bin/env bash
# lesson: s14_l05 Rehearsing a Bad Release and a Lost Control Plane
# Part one: a Rollout's canary analysis step that names a typo'd AnalysisTemplate
# HANGS (never fails, never promotes), and fixing the reference lets a real HTTP check pass or
# fail the canary on its own.
#
# Part two of this lesson (deleting Argo CD's own namespace outright and restoring it from
# `argocd admin export`) is the same class of destructive, irreversible-on-a-shared-cluster
# action the disaster-recovery rehearsal (s12_l06.sh) already declares external for: repeating
# it here would either skip it silently or take down every other lesson's cluster state. This
# script proves part one for real and declares part two, matching s12_l06.sh.
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
  || _fail "no Running pod in argo-rollouts: this lesson's precondition (Argo Rollouts from s10_l02.sh and s10_l04.sh) is not met on this cluster"
command -v kubectl-argo-rollouts >/dev/null 2>&1 || kubectl argo rollouts version >/dev/null 2>&1 \
  || _fail "the kubectl argo rollouts plugin is not available on PATH"

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# A canary runs its steps only for a NEW revision: the first revision of a Rollout deploys at once. So the lesson's
# order is reproduced here: a stable v1 first (no analysis step), then a v2 whose analysis step names the typo'd template.
step "a stable v1 first: the Rollout deploys with no analysis step, as the lesson's stable release does"
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: s14l05-probe
spec:
  selector: {app.kubernetes.io/name: s14l05-probe}
  ports: [{name: http, port: 80, targetPort: http}]
---
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
          args: ["-listen=:5678", "-text=s14l05 probe v1"]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
  strategy:
    canary:
      steps:
        - setWeight: 25
        - setWeight: 100
EOF
v1_phase=""
for _ in $(seq 1 60); do
  v1_phase="$(kubectl get rollout s14l05-probe -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${v1_phase}" = "Healthy" ] && break
  sleep 3
done
[ "${v1_phase}" = "Healthy" ] && _pass "stable v1 is Healthy" || _fail "stable v1 never became Healthy (phase '${v1_phase:-none}')"

step "a v2 whose analysis step names a template that does not exist hangs: it does not fail and does not promote"
# The lesson's typo, on purpose: the step names s14l05-check-typo, and the real template is s14l05-check (created below).
# The new v2 text is the revision that starts the canary; the analysis step is where the typo sits.
kubectl -n "${NS}" patch rollout s14l05-probe --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-listen=:5678","-text=s14l05 probe v2"]},
  {"op":"replace","path":"/spec/strategy/canary/steps","value":[{"setWeight":25},{"analysis":{"templates":[{"templateName":"s14l05-check-typo"}]}},{"setWeight":100}]}]' >/dev/null
sleep 60
early_runs="$(kubectl get analysisrun -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${early_runs}" = "0" ]; then
  _pass "no AnalysisRun was created for a reference to a nonexistent AnalysisTemplate: the step does not run, exactly as this lesson claims"
else
  _fail "an AnalysisRun was created despite the template name being wrong: the hang did not reproduce as this lesson describes"
fi
held_phase="$(kubectl get rollout s14l05-probe -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [ "${held_phase}" != "Healthy" ]; then
  _pass "the rollout did not promote: it reads ${held_phase:-none}, held on the step that names the missing template"
else
  _fail "the rollout reads Healthy with a missing template: it promoted past a step it could not run"
fi

step "fixing the reference (and the template under its real name) lets the analysis run to a verdict on its own"
# The lesson's fix: the corrected reference on the Rollout, and the template under the corrected name.
kubectl apply -n "${NS}" -f - >/dev/null <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: s14l05-check
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
                        test "$BODY" = "s14l05 probe v2"
EOF
kubectl -n "${NS}" patch rollout s14l05-probe --type=json \
  -p='[{"op":"replace","path":"/spec/strategy/canary/steps/1/analysis/templates/0/templateName","value":"s14l05-check"}]' >/dev/null

# With the reference fixed, the analysis runs and reaches a verdict. The check may pass or fail (the lesson's own 1.5.0
# build is built to fail it); what the fix must do is let the AnalysisRun run to a result.
ok=no
status=""
for _ in $(seq 1 30); do
  sleep 10
  status="$(kubectl get analysisrun -n "${NS}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  case "${status}" in Successful|Failed) ok=yes; break ;; esac
done
if [ "${ok}" = yes ]; then
  _pass "with the correct template name the AnalysisRun runs to a verdict: ${status}"
else
  _fail "the AnalysisRun never reached a verdict within the timeout: the fix this lesson teaches did not hold on this cluster (last status: '${status:-none}')"
fi

smoke_done
