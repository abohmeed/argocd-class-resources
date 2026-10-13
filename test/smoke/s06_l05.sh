#!/usr/bin/env bash
# lesson: s06_l05 hook-delete-policy: cleaning up hook resources instead of accumulating them
# Hook deletion policies and the debris problem.
#
# The claim (lesson as rewritten 2026-10-03, measured on v3.5.3): a hook with NO delete policy is
# NOT left to pile up. Argo CD applies BeforeHookCreation by default, deleting the previous hook
# of the same NAME right before creating the next one, so a dozen syncs leave exactly one Job.
# Debris only accumulates with generateName, which Kustomize (the build tool behind checkout, and
# behind this probe) refuses, so the hook here carries a fixed name exactly as the lesson's
# checkout-migrate does. HookSucceeded sweeps a hook once it succeeds, and leaves a failed one
# standing on purpose (the failure evidence is not supposed to vanish). Driven through a scratch
# Argo CD Application synced with `--local`, so this proves real hook-lifecycle behaviour without
# pushing throwaway commits to the companion repo. Uses a trivial command instead of the lesson's
# real SQL migration: delete-policy timing depends only on Argo CD's own hook bookkeeping.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l05"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
WORKDIR="$(mktemp -d)"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

lesson S06-L05 "no delete policy means BeforeHookCreation: a dozen syncs leave exactly one Job; HookSucceeded sweeps a success and never a failure"
tier cluster

# Diagnostics, added 2026-10-13 after CI run 38442057383 timed out at 600 s, right after the step-2 pass line.
# Nothing here changes what a check asserts or how a check passes or fails.
#   - every step header and every observed action carries a UTC timestamp;
#   - each cleanup is `kubectl delete jobs --all --wait=false`, then clear_hook_finalizers: a bounded
#     grace, and then removal of the hook finalizer from any Job still deleting with it (see below).
#     While the cleanup runs, a sampler prints one poll line every 4 s, at most 15: the Job UIDs,
#     deletionTimestamp and finalizers, and the Application operation. Read together, the poll lines
#     separate a Job that is re-created during the cleanup (UID changes, operation present), a Job stuck
#     deleting (same UID, deletionTimestamp set, finalizers listed) and an API stall (a kubectl-rc in a
#     poll line, or ticks that take long);
#   - the API state after each cleanup, and a Job listing read right after each count, are printed (the
#     count that decides a check is the origin/main read, unbounded, and is not replaced);
#   - on a failed check, the EXIT trap prints a short FINAL REPORT before cleanup deletes anything.
# Every cleanup call is bounded (timeout and --request-timeout), so a stalled API or a finalizer that never
# clears cannot run the script into the run_all.sh ceiling. A Job still present after the bounded wait is
# printed, and the next check reads what is left.

ts() { date -u +%H:%M:%S; }
note() { printf '  diag %s %s\n' "$(ts)" "$*"; }
tstep() { step "[$(ts)] $1"; }
bounded() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "${secs}" "$@"; else "$@"; fi
}

LAST_DELETE_RC=0
LAST_DELETE_SECS=0
LAST_DELETE_OUT=""
API_OK=0

APP_JSONPATH='operationRev={.operation.sync.revision} phase={.status.operationState.phase} initiatedBy={.status.operationState.operation.initiatedBy.username} startedAt={.status.operationState.startedAt} finishedAt={.status.operationState.finishedAt} syncRev={.status.operationState.syncResult.revision} sync={.status.sync.status} health={.status.health.status} deleting={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}msg={.status.operationState.message}'
JOB_COLUMNS='NAME:.metadata.name,UID:.metadata.uid,CREATED:.metadata.creationTimestamp,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers,POLICY:.metadata.annotations.argocd\.argoproj\.io/hook-delete-policy,ACTIVE:.status.active,SUCCEEDED:.status.succeeded,FAILED:.status.failed'
POD_COLUMNS='NAME:.metadata.name,PHASE:.status.phase,OWNER:.metadata.ownerReferences[0].kind,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers'

# api_check: one readyz probe. Sets API_OK (1 when it answered) and prints one line.
api_check() {
  local t0 out rc=0
  t0="$(date +%s)"
  out="$(trap - ERR; bounded 10 kubectl get --raw=/readyz --request-timeout=8s 2>&1 | head -1 | cut -c1-120)" || rc=$?
  API_OK=0
  if [ "${rc}" -eq 0 ]; then API_OK=1; fi
  note "api readyz=${out:-no output} rc=${rc} ($(( $(date +%s) - t0 ))s)"
  return 0
}

dump_app() {
  local out
  out="$(bounded 20 kubectl get application "${APP}" -n argocd --request-timeout=15s -o jsonpath="${APP_JSONPATH}" 2>&1 || true)"
  printf '%s\n' "${out:-app: no output (timed out or failed)}" | head -2 | cut -c1-320 | sed 's/^/    app  /' || true
}

# app_summary: one line for the poller. Reports kubectl-rc when the read fails, so a stall is visible.
app_summary() {
  local out rc=0
  out="$(trap - ERR; bounded 10 kubectl get application "${APP}" -n argocd --request-timeout=8s -o jsonpath='op={.operation.sync.revision}/phase={.status.operationState.phase}/startedAt={.status.operationState.startedAt}/del={.metadata.deletionTimestamp}/fin={.metadata.finalizers}' 2>/dev/null)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf 'kubectl-rc=%s' "${rc}"
  else
    printf '%s' "${out:-no-output}" | head -1 | cut -c1-260
  fi
}

dump_jobs() {
  local out
  out="$(bounded 20 kubectl get jobs -n "${NS}" --request-timeout=15s -o custom-columns="${JOB_COLUMNS}" 2>&1 || true)"
  if [ -z "${out}" ]; then
    printf '    job  (no output, timed out or failed)\n'
  else
    printf '%s\n' "${out}" | head -"${1:-6}" | cut -c1-260 | sed 's/^/    job  /'
  fi || true
}

dump_pods() {
  local out
  out="$(bounded 20 kubectl get pods -n "${NS}" --request-timeout=15s -o custom-columns="${POD_COLUMNS}" 2>&1 || true)"
  if [ -z "${out}" ]; then
    printf '    pod  (no output, timed out or failed)\n'
  else
    printf '%s\n' "${out}" | head -"${1:-4}" | cut -c1-200 | sed 's/^/    pod  /'
  fi || true
}

dump_ns() {
  local out
  out="$(bounded 15 kubectl get namespace "${NS}" --request-timeout=10s -o jsonpath='{.status.phase} deleting={.metadata.deletionTimestamp}' 2>&1 || true)"
  printf '    ns   %s\n' "${out:-no output}" | head -1 | cut -c1-200 || true
}

dump_events() {
  local out
  out="$(bounded 20 kubectl get events -n "${NS}" --sort-by=.lastTimestamp --request-timeout=15s 2>&1 || true)"
  printf '%s\n' "${out:-no events}" | tail -4 | cut -c1-220 | sed 's/^/    evt  /' || true
  out="$(bounded 20 kubectl get events -n argocd --field-selector "involvedObject.name=${APP}" --sort-by=.lastTimestamp --request-timeout=15s 2>&1 || true)"
  printf '%s\n' "${out:-no events on the Application}" | tail -3 | cut -c1-220 | sed 's/^/    aevt /' || true
}

dump_ctrl() {
  local out
  out="$(bounded 25 kubectl -n argocd logs statefulset/argocd-application-controller --since=15m --request-timeout=20s 2>/dev/null | grep -F "\"${APP}\"" | tail -5 || true)"
  if [ -z "${out}" ]; then
    printf '    ctrl (no controller lines naming %s in the last 15m)\n' "${APP}"
  else
    printf '%s\n' "${out}" | cut -c1-260 | sed 's/^/    ctrl /'
  fi || true
}

# dump_state <label>: the API is probed first. If it does not answer, the reads that depend on it are
# skipped, so a stalled API cannot push the script past its ceiling before the failure is printed.
dump_state() {
  note "state [$1]"
  api_check
  if [ "${API_OK}" -ne 1 ]; then
    note "    app, jobs and pods not read: the API did not answer"
    return 0
  fi
  dump_app
  dump_jobs
  dump_pods
  dump_ns
}

job_summary() {
  local out rc=0
  out="$(trap - ERR; bounded 10 kubectl get jobs -n "${NS}" --request-timeout=8s -o jsonpath='{range .items[*]}{.metadata.name}/{.metadata.uid}/del={.metadata.deletionTimestamp}/fin={.metadata.finalizers};{end}' 2>/dev/null)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    printf 'kubectl-rc=%s' "${rc}"
  else
    printf '%s' "${out:-none}" | cut -c1-240
  fi
}

# poll_during_delete <stop-file>: a read-only sample every 4 s while a delete runs, at most 15.
# It returns as soon as the stop file exists. The caller kills it and does not wait for it.
poll_during_delete() {
  local stop="$1" i t0 jobs app s
  trap - ERR
  for i in $(seq 1 15); do
    t0="$(date +%s)"
    jobs="$(job_summary)"
    app="$(app_summary)"
    printf '    poll %s took=%ss jobs=%s app=%s\n' "$(ts)" "$(( $(date +%s) - t0 ))" "${jobs}" "${app}" || true
    for s in 1 2 3 4; do
      [ -e "${stop}" ] && return 0
      sleep 1
    done
  done
  [ -e "${stop}" ] || printf '    poll %s cap: 15 samples (about 60 s) taken and the delete is still running\n' "$(ts)" || true
}

# hook_jobs_deleting: the names of the Jobs in the namespace that have a deletionTimestamp, one per line.
hook_jobs_deleting() {
  bounded 15 kubectl get jobs -n "${NS}" --request-timeout=10s \
    -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# clear_hook_finalizers <label>: a Job that is being deleted and still lists argocd.argoproj.io/hook-finalizer
# waits for Argo CD to drop that finalizer. Argo CD drops hook finalizers only inside a sync pass, and this
# operation has already finished, so nothing else will drop it. The order is: a short grace first (the
# controller may still drop it on its own), then removal of only the hook finalizer from each Job still
# holding it (any other finalizer is kept), then a bounded wait until the namespace has no Jobs left.
clear_hook_finalizers() {
  local label="$1" i name job_json had keep left
  for i in $(seq 1 8); do
    [ -z "$(hook_jobs_deleting)" ] && break
    sleep 2
  done
  for name in $(hook_jobs_deleting); do
    job_json="$(bounded 15 kubectl get job "${name}" -n "${NS}" --request-timeout=10s -o json 2>/dev/null || true)"
    had="$(printf '%s' "${job_json}" | jq -r '[(.metadata.finalizers // [])[] | select(. == "argocd.argoproj.io/hook-finalizer")] | length > 0' 2>/dev/null || true)"
    if [ "${had}" = "true" ]; then
      keep="$(printf '%s' "${job_json}" | jq -c '[(.metadata.finalizers // [])[] | select(. != "argocd.argoproj.io/hook-finalizer")] | if length == 0 then null else . end' 2>/dev/null || true)"
      if [ -z "${keep}" ]; then
        note "cleanup [${label}]: could not read the finalizer list of ${name}; left alone"
        continue
      fi
      note "cleanup [${label}]: ${name} is still deleting with the hook finalizer after the grace; removing that finalizer"
      bounded 15 kubectl patch job "${name}" -n "${NS}" --request-timeout=10s --type=merge \
        -p "{\"metadata\":{\"finalizers\":${keep}}}" >/dev/null 2>&1 \
        || note "cleanup [${label}]: the finalizer patch on ${name} failed or timed out"
    fi
  done
  left=0
  for i in $(seq 1 15); do
    left="$(bounded 15 kubectl get jobs -n "${NS}" --no-headers --request-timeout=10s 2>/dev/null | wc -l | tr -d ' ' || true)"
    [ "${left:-1}" -eq 0 ] && return 0
    sleep 2
  done
  note "cleanup [${label}]: Jobs left after the bounded wait: ${left:-unreadable}; the next check reads what is left"
}

# delete_hook_jobs <label>: the cleanup of every Job in the namespace: a delete that does not wait
# (--wait=false), then clear_hook_finalizers. The sampler runs alongside both. The delete's output goes to
# a file, so no pipe is held open by anything that is still running.
delete_hook_jobs() {
  local label="$1" stop pid t0 rc=0
  stop="${WORKDIR}/poll-stop"
  rm -f "${stop}"
  poll_during_delete "${stop}" &
  pid=$!
  t0="$(date +%s)"
  note "delete start [${label}]: kubectl delete jobs --all --wait=false"
  bounded 60 kubectl delete jobs -n "${NS}" --all --wait=false --request-timeout=30s >"${WORKDIR}/delete.out" 2>&1 || rc=$?
  clear_hook_finalizers "${label}"
  touch "${stop}"
  { kill "${pid}"; wait "${pid}"; } 2>/dev/null || true
  LAST_DELETE_RC="${rc}"
  LAST_DELETE_SECS="$(( $(date +%s) - t0 ))"
  LAST_DELETE_OUT="$(head -1 "${WORKDIR}/delete.out" 2>/dev/null | cut -c1-200 || true)"
  note "delete end [${label}]: rc=${rc} took=${LAST_DELETE_SECS}s"
  head -4 "${WORKDIR}/delete.out" 2>/dev/null | cut -c1-200 | sed 's/^/    kubectl /' || true
  dump_state "after delete [${label}]"
  if [ "${rc}" -ne 0 ]; then
    dump_events
    dump_ctrl
  fi
}

# sync_observed <label>: argocd_sync_local, with its start, end, rc and the Application operation after it.
sync_observed() {
  local label="$1" t0 rc=0
  t0="$(date +%s)"
  note "sync start [${label}]"
  argocd_sync_local "${APP}" "${WORKDIR}" 120 || rc=$?
  note "sync end [${label}]: rc=${rc} took=$(( $(date +%s) - t0 ))s (rc 1 means the operation was still running at 120 s and was terminated)"
  dump_app
  return 0
}

# print_judged <count>: logs the count a check just took, then a Job listing read right after it. The
# listing read is diagnostic only: bounded, and it never decides anything. The count is the origin/main read.
print_judged() {
  local out
  out="$(bounded 20 kubectl get jobs -n "${NS}" --no-headers --request-timeout=15s 2>/dev/null || true)"
  note "Job count judged: $1; listing read after the count:"
  printf '%s\n' "${out:-(empty listing)}" | sed '/^$/d' | head -5 | cut -c1-200 | sed 's/^/    judged /' || true
}

# print_failed <count>: logs the failed-Job count a check just took, then the names read right after it.
print_failed() {
  local out
  out="$(bounded 20 kubectl get jobs -n "${NS}" --request-timeout=15s -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  note "failed Job count judged: $1; names read after the count:"
  printf '%s\n' "${out:-(none)}" | sed '/^$/d' | head -5 | cut -c1-200 | sed 's/^/    judged /' || true
}

# final_report: printed by the EXIT trap, only when a check failed. About 16 lines, all reads guarded.
final_report() {
  note "FINAL REPORT (the script failed; read these lines first, cleanup runs after them)"
  note "last Job delete: rc=${LAST_DELETE_RC} took=${LAST_DELETE_SECS}s first line: ${LAST_DELETE_OUT:-(none)}"
  api_check
  if [ "${API_OK}" -ne 1 ]; then
    note "    app, jobs and pods not read: the API did not answer"
    return 0
  fi
  dump_app
  dump_jobs 3
  dump_pods 3
  dump_ctrl
}

note "start"
# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready
note "CLI ready"
api_check
pre_app="$(bounded 15 kubectl get application "${APP}" -n argocd --ignore-not-found -o name --request-timeout=10s 2>/dev/null | head -1 || true)"
pre_ns="$(bounded 15 kubectl get namespace "${NS}" --ignore-not-found -o name --request-timeout=10s 2>/dev/null | head -1 || true)"
note "preexisting before this script creates anything (a fresh cluster has none): application=${pre_app:-none} namespace=${pre_ns:-none}"

cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then final_report; fi
  argocd app delete "${APP}" --cascade --yes >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

write_manifests() {
  # $1 = command that decides pass/fail, $2 = delete-policy annotation line (or empty)
  mkdir -p "${WORKDIR}"
  cat > "${WORKDIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - job.yaml
EOF
  cat > "${WORKDIR}/job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: probe-hook
  namespace: ${NS}
  annotations:
    argocd.argoproj.io/hook: PreSync
$( [ -n "$2" ] && printf '    argocd.argoproj.io/hook-delete-policy: %s\n' "$2" )
spec:
  # A failing hook fails at once. The default backoffLimit (6) retries it with growing delays first,
  # which keeps the sync Running for about ten minutes before the failure this script checks exists.
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: busybox:1.37
          command: ["sh", "-c", "$1"]
EOF
}

argocd app create "${APP}" --repo "${REPO}" --path apps/checkout/base \
  --dest-namespace "${NS}" --dest-server https://kubernetes.default.svc \
  --sync-policy none >/dev/null

tstep "no delete policy at all: the default BeforeHookCreation leaves exactly one Job"
write_manifests "true" ""
for _ in 1 2 3; do
  sync_observed "step 1 sync"
  sleep 3
done
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
print_judged "${count}"
if [ "${count}" -eq 1 ]; then
  _pass "3 syncs with no delete policy left exactly one hook Job: the implicit BeforeHookCreation replaced each earlier run, as the lesson now opens on"
else
  _fail "expected exactly 1 hook Job after 3 syncs with no delete policy (default BeforeHookCreation), found ${count}"
fi
delete_hook_jobs "after step 1"

tstep "BeforeHookCreation: never more than one hook Job standing, no matter how many syncs"
write_manifests "true" "BeforeHookCreation"
for _ in 1 2 3; do
  sync_observed "step 2 sync"
  sleep 3
done
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
print_judged "${count}"
[ "${count}" -eq 1 ] \
  && _pass "exactly one hook Job present after 3 syncs under BeforeHookCreation" \
  || _fail "expected exactly 1 Job under BeforeHookCreation, found ${count}: the previous hook is not being deleted before the new one is created"
delete_hook_jobs "after step 2"

tstep "HookSucceeded: a successful hook is swept once it succeeds"
write_manifests "true" "HookSucceeded"
sync_observed "step 3 sync"
count=1
for _ in $(seq 1 15); do
  count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${count}" -eq 0 ] && break
  sleep 2
done
print_judged "${count}"
[ "${count}" -eq 0 ] \
  && _pass "no Job left after a successful sync under HookSucceeded: the success was swept" \
  || _fail "expected 0 Jobs after a successful HookSucceeded sync, found ${count}"

tstep "HookSucceeded: a FAILED hook is left standing, on purpose"
delete_hook_jobs "before step 4 (clears the step 3 Job)"
write_manifests "exit 1" "HookSucceeded"
sync_observed "step 4 sync"
sleep 10
failed_count="$(kubectl get jobs -n "${NS}" -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
print_failed "${failed_count}"
dump_jobs
[ "${failed_count}" -ge 1 ] \
  && _pass "the failed hook Job is still present (HookSucceeded only sweeps successes): the failure evidence isn't erased" \
  || _fail "no failed hook Job found standing: either the hook didn't actually fail, or HookSucceeded swept a failure it should have left alone"

smoke_done
