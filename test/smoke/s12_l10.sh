#!/usr/bin/env bash
# lesson: s12_l10 Troubleshooting Argo CD: stuck syncs and OutOfSync loops
# A stuck PreSync hook is diagnosable by name (a missing image-pull secret), not just
# "stuck"; and ignoreDifferences alone does not stop selfHeal reverting a re-applied field away:
# it needs RespectIgnoreDifferences too, proven against a real, reconciling Application.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L10 "a stuck PreSync hook names its own blocker, and ignoreDifferences alone does not stop selfHeal reverting a flapped field"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

HOOK_NS="s12l10-hook"
APP="s12l10-probe"
NS="s12l10-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

# ---------------------------------------------------------------------------------------------
# DIAGNOSTICS ONLY. No assertion, verdict or pass/fail outcome changes, and a passing run takes the same time.
# A failing run takes longer: the digest runs after the verdict is set. The revert wait is at most 330 s.
#
# Competing hypotheses for the failing revert check (the memory limit is still the flapped 64Mi after the
# self-heal wait). The controller counts are scoped to the flap (from LOG_SINCE, set just before the flap),
# not the last 20 minutes.
#   H-backoff  selfHeal retries, but Argo CD spaces the attempts out (selfHealRemainingBackoff:
#              2, 6, 18, 54, 162, then 300 s; the cap is --self-heal-backoff-cap-seconds, default 300).
#              Seen as "already attempted sync ... (retrying in X)" log lines and autoHealAttemptsCount of
#              3 or more. CONFIRMED when backoff-retrying is 1 or more, the count is 3 or more, and the
#              limit is back at the Git value later in the wait. WEAKENED when the limit is still 64Mi at the
#              end of the wait with a backoff count of 0 or 1.
#   H-failed   the last auto-sync did not succeed, so Argo CD never retries ("failed previous
#              sync attempt ... will not retry"). CONFIRMED by phase Failed or Error, or a non-zero
#              failed-no-retry count. RULED OUT by phase Succeeded and a zero failed-no-retry count.
#   H-blind    Argo CD does not treat the limit as drift, so selfHeal never runs. CONFIRMED by the
#              "application status is Synced" lines with zero initiated-auto-sync lines, and argocd app
#              diff exit 0 with zero memory lines. RULED OUT if the diff names memory or any
#              initiated-auto-sync line appears.
#   H-stuck    an operation never clears ("another operation is in progress", phase Running), or
#              the refresh request was never consumed (refresh annotation still set). CONFIRMED by
#              operation-already-running above 0, or the refresh annotation still set. RULED OUT when both are zero.
#   H-flap     the 45 s flap did not land as intended. CONFIRMED by patches failed above 0 (first-error printed).
#
# run_all.sh prints only the last 20 lines of a failing script, so the digest below is kept to
# about 15 lines, and the same text is appended to the job summary when CI sets GITHUB_STEP_SUMMARY.
# ---------------------------------------------------------------------------------------------
SCRIPT_START="$(date +%s)"

# Step headers carry a UTC timestamp, so the log shows when each step started.
step() { printf '\n\033[1m==> [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$1"; }

# A call that can hang gets a ceiling where GNU timeout exists (the CI runner). Used as a prefix: ${BOUND_CMD:+${BOUND_CMD} 30}.
BOUND_CMD=""
if command -v timeout >/dev/null 2>&1; then BOUND_CMD="timeout --kill-after=5"; fi

# kget <jsonpath body>: one field of the test Application, empty on any error.
kget() { kubectl get application "${APP}" -n argocd -o "jsonpath=$1" 2>/dev/null || true; }

# app_brief: "sync/health/operation-phase" in one read, for the state series.
app_brief() {
  kubectl get application "${APP}" -n argocd -o go-template='{{.status.sync.status}}/{{.status.health.status}}/{{with .status.operationState}}{{.phase}}{{end}}' 2>/dev/null || echo "?"
}

# FLAP_MEM is the value the flap writes; BASE_MEM is the Git value read just before the flap (step 1).
FLAP_MEM="64Mi"
BASE_MEM=""
FLAP_TALLY=""
FLAP_ERR=""
ANNOT_RC=0
DIGEST=""
SERIES=""
LAST_STATE=""
POLL_T0="${SCRIPT_START}"
LOG_SINCE=""
PRESENCE=""

# mem_live: the Rollout's container memory limit, the field the flap writes and selfHeal reverts. Empty on error.
mem_live() {
  kubectl -n "${NS}" get rollout storefront -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true
}

# sample_state <memory limit>: adds a point to the series only when the state changes, to keep it short.
sample_state() {
  local limit="$1" t state
  t=$(( $(date +%s) - POLL_T0 ))
  state="limit=${limit:-none} $(app_brief)"
  if [ "${state}" != "${LAST_STATE}" ]; then
    SERIES="${SERIES}${SERIES:+ ; }+${t}s ${state}"
    LAST_STATE="${state}"
  fi
}

# diag <text>: one line on stdout, and kept for the job summary.
diag() {
  printf 'diag %s\n' "$*"
  DIGEST="${DIGEST}$*"$'\n'
}

# dump_digest <where> <mode>: the state that tells the hypotheses apart. mode is "revert" after the self-heal
# wait (the flap ran) or "step2" (it did not, so its lines say so instead of repeating step 1).
dump_digest() {
  local where="$1" mode="$2" sync health rec ann phase op_auto op_sa op_start op_fin op_rev op_msg
  local live lastapplied la managers res rt rj diff_file diff_out diff_rc diff_hits diff_first annot_txt
  local ctl status_lines since_arg pat last_line n_init n_backoff n_noretry n_busy ok_n err_n first_err
  DIGEST=""
  diag "digest at ${where}, $(date -u +%H:%M:%S), script t=$(( $(date +%s) - SCRIPT_START ))s"

  sync="$(kget '{.status.sync.status}')"
  health="$(kget '{.status.health.status}')"
  rec="$(kget '{.status.reconciledAt}')"
  ann="$(kget '{.metadata.annotations.argocd\.argoproj\.io/refresh}')"
  annot_txt=""
  if [ "${mode}" = "revert" ]; then annot_txt=" annotate-rc=${ANNOT_RC}"; fi
  diag "app ${APP}: sync=${sync:-?} health=${health:-?} reconciledAt=${rec:-?} refresh-annotation=${ann:-none}${annot_txt}"

  phase="$(kget '{.status.operationState.phase}')"
  op_auto="$(kget '{.status.operationState.operation.initiatedBy.automated}')"
  op_sa="$(kget '{.status.operationState.operation.sync.autoHealAttemptsCount}')"
  op_start="$(kget '{.status.operationState.startedAt}')"
  op_fin="$(kget '{.status.operationState.finishedAt}')"
  op_rev="$(kget '{.status.operationState.syncResult.revision}' | cut -c1-12)"
  op_msg="$(kget '{.status.operationState.message}' | cut -c1-120)"
  diag "operationState: phase=${phase:-none} initiatedBy.automated=${op_auto:-none} autoHealAttemptsCount=${op_sa:-none} startedAt=${op_start:-?} finishedAt=${op_fin:-?} rev=${op_rev:-?} message=\"${op_msg}\""

  live="$(mem_live)"
  # Captured first, then matched: a grep -q that exits early could SIGPIPE kubectl and flip this under pipefail.
  lastapplied="$(kubectl -n "${NS}" get rollout storefront -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' 2>/dev/null || true)"
  la=no
  case "${lastapplied}" in *'"memory"'*) la=yes ;; esac
  managers="$(kubectl -n "${NS}" get rollout storefront -o jsonpath='{.metadata.managedFields[*].manager}' 2>/dev/null || true)"
  res="$(kget '{range .status.resources[*]}{.kind}/{.name}={.status}{"\n"}{end}' | grep '^Rollout/' || true)"
  diag "rollout storefront: memory limit live=${live:-absent} (flapped ${FLAP_MEM}, Git ${BASE_MEM:-unread}) in-last-applied=${la} managers=${managers:-?} app-status.resources=${res:-none-listed}"

  rt="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null || true)"
  rj="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation\.jitter}' 2>/dev/null || true)"
  diag "argocd-cm: timeout.reconciliation=${rt:-default} timeout.reconciliation.jitter=${rj:-default}"

  diff_file="$(mktemp)"
  diff_rc=0
  ${BOUND_CMD:+${BOUND_CMD} 20} argocd app diff "${APP}" >"${diff_file}" 2>&1 || diff_rc=$?
  diff_out="$(cat "${diff_file}")"
  rm -f "${diff_file}"
  diff_hits="$(printf '%s\n' "${diff_out}" | grep -c 'memory' || true)"
  diff_first="$(printf '%s\n' "${diff_out}" | grep -m1 'memory' | cut -c1-120 || true)"
  diag "argocd app diff (20s cap): exit=${diff_rc} lines-naming-memory=${diff_hits:-0} first=\"${diff_first}\""

  # Scoped to this step: LOG_SINCE is set just before the flap (step 1) or just before the step 2 patch.
  since_arg="--since=20m"
  if [ -n "${LOG_SINCE}" ]; then since_arg="--since-time=${LOG_SINCE}"; fi
  ctl="$(kubectl -n argocd logs statefulset/argocd-application-controller "${since_arg}" --request-timeout=15s 2>/dev/null | grep -F "${APP}" || true)"
  n_init="$(printf '%s\n' "${ctl}" | grep -c 'Initiated automated sync' || true)"
  n_backoff="$(printf '%s\n' "${ctl}" | grep -c 'already attempted sync' || true)"
  n_noretry="$(printf '%s\n' "${ctl}" | grep -c 'will not retry' || true)"
  n_busy="$(printf '%s\n' "${ctl}" | grep -c 'another operation is in progress' || true)"
  status_lines="$(printf '%s\n' "${ctl}" | grep -o 'application status is [A-Za-z]*' | sort | uniq -c | tr -s ' ' | tr '\n' ' ' || true)"
  diag "controller log from ${LOG_SINCE:-20 min ago}, lines naming ${APP}: initiated-auto-sync=${n_init:-0} backoff-retrying=${n_backoff:-0} failed-no-retry=${n_noretry:-0} operation-already-running=${n_busy:-0}"
  diag "  status lines: ${status_lines:-none}"
  # The last line of each class, so a long run of steady-state status lines cannot push out the sync decisions.
  for pat in 'Initiated automated sync' 'already attempted sync' 'will not retry' 'application status is'; do
    last_line="$(printf '%s\n' "${ctl}" | grep -F "${pat}" | tail -1 || true)"
    if [ -n "${last_line}" ]; then diag "  last of '${pat}': ${last_line:0:180}"; fi
  done

  if [ "${mode}" = "revert" ]; then
    ok_n="$(grep -c '^ok$' "${FLAP_TALLY:-/dev/null}" 2>/dev/null || true)"
    err_n="$(grep -c '^err$' "${FLAP_TALLY:-/dev/null}" 2>/dev/null || true)"
    first_err="$(head -1 "${FLAP_ERR:-/dev/null}" 2>/dev/null | cut -c1-160 || true)"
    diag "flap (45s, one patch every 4s): patches ok=${ok_n:-0} failed=${err_n:-0} first-error=\"${first_err}\""
    diag "limit per sample over the self-heal wait (y = still ${FLAP_MEM}, the flapped value): ${PRESENCE:0:80}"
    diag "series over the self-heal wait: ${SERIES:0:300}"
    diag "memory limit at the end of the wait: ${still_mem:-none} (Git value ${BASE_MEM:-unread})"
  else
    diag "flap and self-heal wait: not part of this step (see the step 1 digest)"
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { printf '\n### s12_l10 diagnostics: %s\n\n' "${where}"; printf '%s' "${DIGEST}" | sed 's/^/    /'; } >> "${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
  fi
}

cleanup() {
  [ -n "${FLAP_PID:-}" ] && kill "${FLAP_PID}" >/dev/null 2>&1 || true
  if [ -n "${FLAP_TALLY:-}" ]; then rm -f "${FLAP_TALLY}" "${FLAP_ERR}" 2>/dev/null || true; fi
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=60s >/dev/null 2>&1 || true
  kubectl delete namespace "${HOOK_NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "a PreSync hook missing its image-pull secret is diagnosable by name, not just stuck"
kubectl create namespace "${HOOK_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n "${HOOK_NS}" -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: stuck-hook
  annotations:
    argocd.argoproj.io/hook: PreSync
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: registry-creds-that-do-not-exist
      containers:
        - name: migrate
          image: ghcr.io/northwind/does-not-matter:1.0
          command: ["true"]
EOF
# The kubelet names the missing secret in the pod's Events once it has tried to pull (about 10 seconds in). Read the
# whole Events section, and poll for it rather than sleeping a fixed time.
pod_events=""
for _ in $(seq 1 30); do
  pod_events="$(kubectl describe pod -n "${HOOK_NS}" -l job-name=stuck-hook 2>/dev/null | sed -n '/^Events:/,$p' || true)"
  printf '%s' "${pod_events}" | grep -qi 'registry-creds-that-do-not-exist' && break
  sleep 2
done
if printf '%s' "${pod_events}" | grep -qi 'registry-creds-that-do-not-exist'; then
  _pass "the hook pod's own Events name the missing image-pull secret: diagnosable, not just hung"
else
  _fail "expected the hook pod's Events to name 'registry-creds-that-do-not-exist':\n${pod_events}"
fi
succ="$(kubectl get job stuck-hook -n "${HOOK_NS}" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
[ "${succ}" = "1" ] && _fail "the hook Job unexpectedly succeeded: it should be unable to complete without the secret" \
  || _pass "the hook Job has not completed: this is what 'stuck' looks like, distinct from 'failed'"

step "wire up a real Application, automated + selfHeal, watching apps/storefront/base"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy:
    automated: {selfHeal: true}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 180

step "a repeatedly re-applied memory limit IS reverted by selfHeal alone: the flap this lesson opens on"
# The lesson's stand-in webhook rewrites this field, so the field is in Git (32Mi in base). Read it before the flap:
# the Application is Synced here, so the live value is the Git value. The flap writes a different value.
BASE_MEM="$(mem_live)"
if [ -n "${BASE_MEM}" ] && [ "${BASE_MEM}" != "${FLAP_MEM}" ]; then
  _pass "the Rollout's memory limit is ${BASE_MEM} before the flap (Synced, so the Git value); the flap sets ${FLAP_MEM}"
else
  _fail "expected a memory limit on the Rollout other than ${FLAP_MEM} before the flap, got '${BASE_MEM:-none}'"
fi
FLAP_TALLY="$(mktemp)"
FLAP_ERR="$(mktemp)"
LOG_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
(
  while true; do
    # Same effect as before: a failed patch still ends this loop (errexit is inherited). The tally only records it.
    kubectl -n "${NS}" patch rollout storefront --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"64Mi"}]' \
      >/dev/null 2>>"${FLAP_ERR}" && echo ok >>"${FLAP_TALLY}" || { echo err >>"${FLAP_TALLY}"; exit 1; }
    sleep 4
  done
) &
FLAP_PID=$!
sleep 45
kill "${FLAP_PID}" >/dev/null 2>&1 || true
FLAP_PID=""
# A pass below must not come from a flap that never wrote. Each successful patch wrote FLAP_MEM, and the flap only
# writes FLAP_MEM, so once one write landed, any later value other than FLAP_MEM can only have come from selfHeal.
flap_writes="$(grep -c '^ok$' "${FLAP_TALLY}" 2>/dev/null || true)"
if [ "${flap_writes:-0}" -lt 1 ]; then
  first_flap_err="$(head -1 "${FLAP_ERR}" 2>/dev/null | cut -c1-160 || true)"
  _fail "the flap wrote ${FLAP_MEM} zero times (first error: ${first_flap_err:-none}): there is nothing for selfHeal to revert"
fi
POLL_T0="$(date +%s)"
# selfHeal reverts on the controller's next reconcile of the Application. Ask for one, then poll for the revert
# rather than trusting a fixed wait, since the Rollout's own rollout after each flap takes a while to settle.
# The refresh does not skip self-heal backoff. After a flap, Argo CD 3.5.3 waits up to the self-heal backoff cap
# (--self-heal-backoff-cap-seconds, default 300) between attempts, so the revert can take ~5 minutes.
# The poll ceiling covers the cap: 66 x 5 s = 330 s.
if kubectl -n argocd annotate application "${APP}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1; then
  ANNOT_RC=0
else
  ANNOT_RC=$?
fi
still_mem="x"
for _ in $(seq 1 66); do
  still_mem="$(mem_live)"
  sample_state "${still_mem}"
  if [ "${still_mem}" = "${FLAP_MEM}" ]; then PRESENCE="${PRESENCE}y"; else PRESENCE="${PRESENCE}n"; fi
  # Leave the loop as soon as the value is no longer the flapped one: selfHeal has written something else.
  if [ "${still_mem}" != "${FLAP_MEM}" ]; then break; fi
  sleep 5
done
if [ "${still_mem}" = "${BASE_MEM}" ]; then
  _pass "with plain selfHeal and no ignoreDifferences, the flapped memory limit was reverted to the Git value: reproduces the lesson's opener"
else
  dump_digest "the revert check (self-heal wait)" revert
  _fail "the memory limit is still ${still_mem:-none} after selfHeal had time to revert it (Git value ${BASE_MEM}): the opener does not reproduce"
fi

step "ignoreDifferences + RespectIgnoreDifferences stops selfHeal from stripping the field back out"
kubectl -n argocd patch application "${APP}" --type merge -p '
spec:
  ignoreDifferences:
  - group: argoproj.io
    kind: Rollout
    jsonPointers:
    - /spec/template/spec/containers/0/resources/limits/memory
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
    - RespectIgnoreDifferences=true
' >/dev/null

LOG_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
kubectl -n "${NS}" patch rollout storefront --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"64Mi"}]' >/dev/null
# The check below judges what a SYNC does to the ignored field, so the sync must really run.
sync_out="$(argocd app sync "${APP}" 2>&1)" || _fail "argocd app sync failed, so step 2 cannot judge the fix: $(printf '%s' "${sync_out}" | tail -3 | tr '\n' ' ' | cut -c1-300)"
sleep 30

survived="$(mem_live)"
if [ "${survived}" = "${FLAP_MEM}" ]; then
  _pass "with ignoreDifferences AND RespectIgnoreDifferences, a sync no longer strips the field back out"
else
  dump_digest "step 2, after ignoreDifferences plus RespectIgnoreDifferences" step2
  _fail "the memory limit was still reverted to ${survived:-none} even with ignoreDifferences + RespectIgnoreDifferences set: the fix this lesson teaches does not hold on this cluster"
fi

smoke_done
