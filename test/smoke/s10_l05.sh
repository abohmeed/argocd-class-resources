#!/usr/bin/env bash
# S10 L05 — automated promotion and abort with AnalysisTemplates.
#
# The load-bearing claim, proven by execution and recorded in FACTCHECK-RESULTS.md (J-1): the
# Web metric provider returns Successful on any response that fails to parse as JSON, WITHOUT
# evaluating successCondition at all — so a Web-provider gate against a plain-text service like
# storefront can never fail, silently testing nothing. The Job provider is what the lessons use
# for any real pass/fail gate. This is fully reproducible on a single cluster: a canary Rollout
# with an AnalysisTemplate wired at the first step, using the Job provider exactly as the
# runbook specifies, watched promoting a good version unattended and aborting a broken one
# unattended. No Gateway, no traffic-routing plugin needed — analysis and abort are the
# Rollouts controller's own mechanics, independent of which traffic router (if any) is wired in.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S10-L05 "an AnalysisTemplate on the Job provider promotes a matching canary and aborts a mismatched one, unattended"
tier cluster

NS="s10l05-probe"
NAME="storefront-probe"

cleanup() {
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "repo-side guard: no committed AnalysisTemplate in this repo uses the Web provider for a pass/fail gate"
# The Web provider's silent-pass-on-non-JSON behaviour (FACTCHECK-RESULTS.md J-1) makes it the
# wrong choice for any gate that is supposed to be able to fail. If a future edit adds one, this
# is the check that should catch it before it reaches camera.
if [ -d "${REPO_ROOT}/platform/rollouts" ]; then
  hits="$(grep -rIl 'kind: AnalysisTemplate' "${REPO_ROOT}/platform/rollouts" 2>/dev/null || true)"
  bad=""
  # A while/read loop, not `for f in ${hits}` — REPO_ROOT contains spaces ("Mastering GitOps
  # with Argo CD"), and an unquoted word-split would tear one path into several bogus ones.
  while IFS= read -r f; do
    [ -z "${f}" ] && continue
    # A metric's provider is a nested key — "web:" indented directly under "provider:" — not
    # the word "web" appearing anywhere (e.g. in a comment explaining why it is banned).
    grep -qE '^[[:space:]]+web:[[:space:]]*$' "${f}" && bad="${bad}
  ${f#"${REPO_ROOT}"/}"
  done <<< "${hits}"
  if [ -z "${hits}" ]; then
    _pass "no AnalysisTemplate committed yet — S10 L05 authors it live"
  elif [ -z "${bad}" ]; then
    _pass "every committed AnalysisTemplate avoids the Web provider"
  else
    _fail "an AnalysisTemplate uses the Web provider for a gate — it returns Successful on non-JSON without evaluating successCondition:${bad}"
  fi
else
  _pass "platform/rollouts/ not committed yet — S10 L05 authors the AnalysisTemplate live"
fi

step "install Argo Rollouts ${ARGO_ROLLOUTS_VERSION}"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argo-rollouts -f "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml" >/dev/null
wait_for_rollout "deployment/argo-rollouts" "argo-rollouts"

step "wire a canary at 20% with a Job-provider analysis step, correct banner, and watch it promote unattended"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<'YAML' | sed "s/__NS__/${NS}/g" | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata: {name: probe-stable, namespace: __NS__}
spec: {selector: {app: probe}, ports: [{name: http, port: 80, targetPort: http}]}
---
apiVersion: v1
kind: Service
metadata: {name: probe-canary, namespace: __NS__}
spec: {selector: {app: probe}, ports: [{name: http, port: 80, targetPort: http}]}
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: {name: probe-banner-matches, namespace: __NS__}
spec:
  args: [{name: expected-banner}]
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
                  - name: banner-matches
                    image: curlimages/curl:8.11.0
                    command: ["sh", "-c"]
                    args:
                      - |
                        actual=$(curl -s --max-time 10 http://probe-canary.__NS__.svc.cluster.local)
                        expected="{{ args.expected-banner }}"
                        echo "expected: $expected"
                        echo "actual:   $actual"
                        test "$actual" = "$expected"
YAML

roll_out_canary() {
  # $1 = banner value to ship, $2 = expected-banner argument for the AnalysisTemplate
  local banner="$1" expect="$2"
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: ${NAME}, namespace: ${NS}}
spec:
  replicas: 1
  selector: {matchLabels: {app: probe}}
  template:
    metadata:
      labels: {app: probe}
      annotations: {rollouts.probe/revision: "${banner}"}
    spec:
      containers:
        - name: storefront
          image: ${HTTP_ECHO_IMAGE}
          args: ["-listen=:5678", "-text=\$(BANNER)"]
          env: [{name: BANNER, value: "${banner}"}]
          ports: [{name: http, containerPort: 5678}]
          readinessProbe: {httpGet: {path: /, port: http}, initialDelaySeconds: 2}
  strategy:
    canary:
      stableService: probe-stable
      canaryService: probe-canary
      steps:
        - setWeight: 20
        - analysis:
            templateName: probe-banner-matches
            args:
              - name: expected-banner
                value: "${expect}"
        - setWeight: 100
YAML
}

poll_rollout_phase() {
  local want="$1" timeout="${2:-180}" deadline phase=""
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    phase="$(kubectl get rollout "${NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [ "${phase}" = "${want}" ] && return 0
    sleep 5
  done
  echo "${phase}"
  return 1
}

roll_out_canary "probe-v1" "probe-v1"
if poll_rollout_phase "Healthy" 180 >/dev/null; then
  _pass "first canary (matching analysis) promoted to Healthy unattended"
else
  _fail "first canary never reached Healthy — the Job-provider analysis did not pass a correct banner; RESTAGE BEFORE RECORDING"
fi

step "roll a MISMATCHED banner forward and watch the same Job provider abort it unattended"
roll_out_canary "probe-v2-broken" "probe-v2-expected"
degraded=no
deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  phase="$(kubectl get rollout "${NAME}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "${phase}" = "Degraded" ]; then
    degraded=yes
    break
  fi
  sleep 5
done
if [ "${degraded}" = yes ]; then
  _pass "the mismatched canary was aborted (Degraded) by the Job-provider analysis, unattended — the exact guard a Web-provider gate would have silently skipped"
else
  _fail "the mismatched canary was NOT aborted within 180s (last phase: ${phase:-?}) — the Job-provider abort behaviour does not reproduce; RESTAGE BEFORE RECORDING"
fi

analysisrun_failed="$(kubectl get analysisrun -n "${NS}" -o jsonpath='{.items[?(@.status.phase=="Failed")].metadata.name}' 2>/dev/null || true)"
[ -n "${analysisrun_failed}" ] && _pass "a Failed AnalysisRun is readable for why it aborted (${analysisrun_failed})" \
  || _fail "no Failed AnalysisRun found — the abort reason would not be readable on camera"

smoke_done
