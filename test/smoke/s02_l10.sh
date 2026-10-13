#!/usr/bin/env bash
# lesson: s02_l10 Argo CD managing its own installation (self-management)
# Argo CD manages its OWN install, and reaches Synced/Healthy without ever running
# a real sync, because the committed manifest is byte-identical to what's running.
#
# The lesson's claim is specific: "it's already synced" the moment it's applied, with no visible
# reconcile, because bootstrap/install.yaml is the exact tag already on the cluster. That only
# holds if two things stay true: the committed manifest is still pinned to ${ARGOCD_PIN}, and
# the cluster is still running ${ARGOCD_PIN}. If either drifts (a version bump on one side and
# not the other), the self-manage Application would show OutOfSync immediately, and the
# lesson's "already synced" point would be false the moment a student tries it.
#
# Note: this script reads the Application's name out of the committed file,
# bootstrap/self-manage-app.yaml (which names it `argocd`), rather than assuming a name, so it
# stays correct if the file is ever changed.
#
# No cleanup: this is the same accumulating state s02_control_plane.sh and s02_l03.sh leave
# behind. The capstone section builds on it, and deleting the self-manage Application here
# would mean Argo CD no longer manages its own install afterward.
#
# DIAGNOSTICS (added after the cluster-suite run of 2026-10-13). No assertion and no pass/fail
# condition was changed. The competing explanations, and what each one predicts in the output:
#   H1 adoption: the live objects lack argocd.argoproj.io/tracking-id, so the first comparison is
#      OutOfSync and one automated sync re-applies all 60 objects. Predicts: phase Succeeded,
#      initiatedBy automated, tracking-id absent before the apply and present after, an empty
#      pre-apply kubectl diff, and an event "Updated sync status: ... -> OutOfSync" first.
#      Ruled out by a failed or non-terminal phase, or by a pre-apply diff that names real content.
#   H2 failed operation: the operation at the check ended Failed or Error. The per-resource results
#      still read Synced, so the cause is in the operation message, and Argo does not retry the same
#      revision. Predicts: phase Failed or Error, a SyncError condition, a Warning OperationCompleted
#      event. Ruled out by phase Succeeded.
#   H3 race: the operation was still Running ("one or more tasks are running") when wait_for_sync
#      read Synced and Healthy. Predicts: phase Running at the check, and a different phase at exit.
#      Ruled out by a terminal phase that does not change.
#   H4 real drift from earlier scripts: s02_l08.sh patches argocd-cmd-params-cm (server.insecure),
#      a key the committed manifest does not carry. Predicts: that key in the live ConfigMap, a
#      kubectl-owned field manager on it, or a pre-apply diff naming it. kubectl diff can miss fields
#      owned by another manager, so the managers line is the check that counts.
#      Ruled out when neither is present.
#   H5 wrong revision: Argo applied a commit other than the baseline tree this script reads.
#      Predicts: a revision that differs from the expected sha. Ruled out by equality.
#   H6 controller interruption: the application controller restarted during the operation.
#      Predicts: a restart count above zero, or a start time after the operation's startedAt.
#   H7 test premise: a real sync re-applies every object (ApplyOutOfSyncOnly is off by default), so
#      a non-empty syncResult cannot by itself show drift. H1 and H4 look the same in that list.
#   H8 pre-existing state: the Application or an earlier operation predates this step. Predicts a
#      creation time before the apply, or "configured" instead of "created" in the apply output.
#
# run_all.sh keeps only the last 20 lines of a failing script, so a RECAP block is printed last (on
# exit) and repeats the decisive facts. The full transcript is appended to $GITHUB_STEP_SUMMARY when
# that variable is set. Every diagnostic read is bounded, and no Secret object is read or printed.
# On SIGTERM (run_all.sh's timeout, which allows 15 s before KILL) the RECAP is printed from values
# already read, with no cluster calls, and the script exits with the same status a signal gives.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L10 "the self-manage Application reaches Synced/Healthy with no real sync, because the committed install manifest matches what's running"
tier cluster

# ---- diagnostics: helpers and state (no assertion depends on anything in this block) -------------
DIAG_LOG="$(mktemp "${TMPDIR:-/tmp}/s02_l10-diag.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/s02_l10-diag.$$")"
CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECKOUT_HEAD="$(git -C "${CHECKOUT_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
case "${REPO_ROOT}" in
  *argocd-course-baseline-*) EXPECT_SHA="${REPO_ROOT##*argocd-course-baseline-}" ;;
  *) EXPECT_SHA="" ;;
esac
PRE_APP="not read"; PRE_TRACK="not read"; PRE_MGR_CM="not read"; PRE_CMKEYS="not read"
PRE_DIFF_RC="not run"; PRE_DIFF_OBJS="not run"; PRE_DIFF_NAMES=""; PRE_DIFF_KEYS=""
APPLY_START="not run"; APPLY_OUT="not run"; WAIT_SECS="not returned"
SNAP_UTC="not reached"; SNAP_PHASE="none"; SNAP_MSG=""
CUR_STEP="before the first step"; TERMED=0

# dline: one diagnostic line, to stdout and to the transcript.
dline() { printf '%s\n' "$*"; printf '%s\n' "$*" >>"${DIAG_LOG}" 2>/dev/null || true; }

# _emit: indent each line of stdin as a diagnostic line.
_emit() { local l; while IFS= read -r l; do dline "     ${l}"; done; return 0; }

# step: lib.sh's step() with a UTC timestamp, so the log shows when each step started.
step() {
  local ts
  ts="$(date -u +%H:%M:%S)"
  CUR_STEP="$1"
  printf '\n\033[1m==> [%s UTC] %s\033[0m\n' "${ts}" "$1"
  printf '\n==> [%s UTC] %s\n' "${ts}" "$1" >>"${DIAG_LOG}" 2>/dev/null || true
}

# _bounded <seconds> <command...>: the command, under a ceiling where timeout(1) exists.
_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5 "${secs}" "$@"
  else
    "$@"
  fi
}

# _app_raw <app> <jsonpath>: one read of the Application, never fails the script.
_app_raw() { _bounded 25 kubectl -n argocd get application "$1" -o jsonpath="$2" --request-timeout=15s 2>/dev/null || true; }

# _managers <kind/name>: which field managers have written to an object.
_managers() {
  _bounded 20 kubectl -n argocd get "$1" -o jsonpath='{range .metadata.managedFields[*]}{.manager}:{.operation} {end}' --request-timeout=15s 2>/dev/null | cut -c1-300 || true
  return 0
}

# _tracking_summary: how many Deployments, StatefulSets and ConfigMaps carry the tracking annotation.
_tracking_summary() {
  _bounded 20 kubectl -n argocd get deploy,statefulset,configmap -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' --request-timeout=15s 2>/dev/null \
    | awk -F'\t' 'NF { if ($2 != "") w++; else n++ } END { printf "tracking-id on %d object(s), absent on %d (Deployments, StatefulSets, ConfigMaps)", w + 0, n + 0 }' || true
  return 0
}

# _cmd_params_keys: key names only (never values) of argocd-cmd-params-cm.
_cmd_params_keys() {
  _bounded 20 kubectl -n argocd get configmap argocd-cmd-params-cm -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' --request-timeout=15s 2>/dev/null | cut -c1-300 || true
  return 0
}

# _events_all <app>: every event the controller wrote for the Application, oldest first.
_events_all() {
  _bounded 20 kubectl -n argocd get events --field-selector "involvedObject.kind=Application,involvedObject.name=$1" \
    -o custom-columns=TIME:.lastTimestamp,REASON:.reason,TYPE:.type,MSG:.message --no-headers \
    --sort-by=.lastTimestamp --request-timeout=15s 2>/dev/null | cut -c1-260 || true
  return 0
}

# _events <app> <count>: the last events the controller wrote for the Application.
_events() {
  _events_all "$1" | tail -n "$2" || true
  return 0
}

# _controller_lines <app> <count>: controller log lines about this Application (no other app).
_controller_lines() {
  _bounded 20 kubectl -n argocd logs statefulset/argocd-application-controller --request-timeout=15s --tail=5000 2>/dev/null \
    | grep -E 'application"?[:=]"?'"$1"'("|[ ,}]|$)' \
    | grep -E 'auto-sync|Already attempted|operation|Initiated|Resuming|erminat|rror' \
    | tail -n "$2" | cut -c1-260 || true
  return 0
}

# _controller_pods: restart counts and start times of the application controller.
_controller_pods() {
  _bounded 20 kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-application-controller \
    -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,STARTED:.status.startTime \
    --no-headers --request-timeout=15s 2>/dev/null | head -n 3 || true
  return 0
}

# _controller_sts: the controller StatefulSet's replica and revision state.
_controller_sts() {
  _bounded 20 kubectl -n argocd get statefulset argocd-application-controller --request-timeout=15s \
    -o jsonpath='ready {.status.readyReplicas}/{.status.replicas} current={.status.currentRevision} update={.status.updateRevision}' 2>/dev/null || true
  return 0
}

# _cmd_params_keys is defined above; _manifest_without_secrets drops every Secret document, so the
# pre-apply diff below can never print a Secret value.
_manifest_without_secrets() {
  awk '
    function flush() { if (doc != "" && !skip) { print "---"; printf "%s", doc } doc = ""; skip = 0 }
    /^---[[:space:]]*$/ { flush(); next }
    { doc = doc $0 "\n"; if ($0 ~ /^kind: Secret[[:space:]]*$/) skip = 1 }
    END { flush() }
  ' "$1" >"$2"
}

# _pre_apply_facts <app>: the state of the cluster BEFORE the self-manage Application is applied.
_pre_apply_facts() {
  local name="$1" created tmpd
  created="$(_app_raw "${name}" '{.metadata.creationTimestamp}')"
  PRE_APP="${created:-absent (not created yet)}"
  PRE_TRACK="$(_tracking_summary)"
  PRE_MGR_CM="$(_managers configmap/argocd-cmd-params-cm)"
  PRE_CMKEYS="$(_cmd_params_keys)"
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/s02_l10-diff.XXXXXX" 2>/dev/null || true)"
  if [ -n "${tmpd}" ]; then
    _manifest_without_secrets "${REPO_ROOT}/bootstrap/install.yaml" "${tmpd}/install.yaml" 2>/dev/null || true
    PRE_DIFF_RC=0
    _bounded 120 kubectl diff --server-side --force-conflicts -n argocd -f "${tmpd}/install.yaml" \
      >"${tmpd}/diff.out" 2>"${tmpd}/diff.err" || PRE_DIFF_RC=$?
    PRE_DIFF_OBJS="$(grep -c '^+++ ' "${tmpd}/diff.out" 2>/dev/null || true)"
    PRE_DIFF_NAMES="$(grep '^+++ ' "${tmpd}/diff.out" 2>/dev/null | sed 's#.*/##' | head -n 8 | paste -sd, - || true)"
    PRE_DIFF_KEYS="$(grep -E '^[-+][^-+]' "${tmpd}/diff.out" 2>/dev/null | sed -E 's/^([-+][[:space:]]*[^:[:space:]]+):.*$/\1: <value>/' | head -n 12 | cut -c1-160 || true)"
    if [ "${PRE_DIFF_RC}" -ge 2 ]; then
      PRE_DIFF_KEYS="kubectl diff error: $(head -n 3 "${tmpd}/diff.err" 2>/dev/null | cut -c1-200 | paste -sd' ' - || true)"
    fi
    rm -rf "${tmpd}" 2>/dev/null || true
  fi
  dline "pre-apply: Application ${name}: ${PRE_APP}"
  dline "pre-apply: ${PRE_TRACK}"
  dline "pre-apply: argocd-cmd-params-cm keys: ${PRE_CMKEYS:-none}; managers: ${PRE_MGR_CM:-none}"
  dline "pre-apply: kubectl diff exit=${PRE_DIFF_RC} (0 none, 1 differences, 2+ error), ${PRE_DIFF_OBJS} object(s): ${PRE_DIFF_NAMES:-none}"
  printf '%s\n' "${PRE_DIFF_KEYS:-(no changed lines)}" | _emit
  return 0
}

# _snapshot_app <app> <label>: the Application's state, in full, for the transcript.
_snapshot_app() {
  local name="$1" label="$2" ph msg started fin retry init sopts stat odd cond cmp_total cmp_bad
  SNAP_UTC="$(date -u +%H:%M:%S)"
  dline "-- ${label}: Application ${name} at ${SNAP_UTC} UTC"
  ph="$(_app_raw "${name}" '{.status.operationState.phase}')"
  msg="$(_app_raw "${name}" '{.status.operationState.message}')"
  started="$(_app_raw "${name}" '{.status.operationState.startedAt}')"
  fin="$(_app_raw "${name}" '{.status.operationState.finishedAt}')"
  retry="$(_app_raw "${name}" '{.status.operationState.retryCount}')"
  init="$(_app_raw "${name}" 'automated={.status.operationState.operation.initiatedBy.automated} username={.status.operationState.operation.initiatedBy.username}')"
  sopts="$(_app_raw "${name}" '{.status.operationState.operation.sync.syncOptions}')"
  SNAP_PHASE="${ph:-none}"
  SNAP_MSG="$(printf '%s' "${msg}" | tr '\n' ' ' | cut -c1-200)"
  dline "   sync=$(_app_raw "${name}" '{.status.sync.status}') health=$(_app_raw "${name}" '{.status.health.status}') spec.targetRevision=$(_app_raw "${name}" '{.spec.source.targetRevision}') spec.path=$(_app_raw "${name}" '{.spec.source.path}')"
  dline "   revisions: status.sync=$(_app_raw "${name}" '{.status.sync.revision}') op.request=$(_app_raw "${name}" '{.status.operationState.operation.sync.revision}') syncResult=$(_app_raw "${name}" '{.status.operationState.syncResult.revision}') expected=${EXPECT_SHA:--} checkout=${CHECKOUT_HEAD}"
  dline "   operation: phase=${ph:-none} startedAt=${started:--} finishedAt=${fin:--} retryCount=${retry:--} ${init}"
  dline "   operation message: ${SNAP_MSG:--}"
  dline "   operation syncOptions: ${sopts:--}"
  stat="$(_app_raw "${name}" '{range .status.operationState.syncResult.resources[*]}{.status}{"\n"}{end}' | sort | uniq -c | sed -e 's/^ *//' -e 's/  */ /g' | paste -sd, - || true)"
  dline "   syncResult entries by status: ${stat:-none}"
  odd="$(_app_raw "${name}" '{range .status.operationState.syncResult.resources[*]}{.status}{"\t"}{.kind}/{.name}{"\t"}{.message}{"\n"}{end}' | awk -F'\t' 'NF && ($1 != "Synced" || $3 !~ /serverside-applied|unchanged|created|configured/)' | head -n 6 | cut -c1-240 || true)"
  dline "   syncResult entries that are not a plain apply:"
  printf '%s\n' "${odd:-none}" | _emit
  cond="$(_app_raw "${name}" '{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' | head -n 4 | cut -c1-240 || true)"
  dline "   conditions:"
  printf '%s\n' "${cond:-none}" | _emit
  cmp_total="$(_app_raw "${name}" '{range .status.resources[*]}{.status}{"\n"}{end}' | wc -l | tr -d ' ' || true)"
  cmp_bad="$(_app_raw "${name}" '{range .status.resources[*]}{.status}{"\t"}{.kind}/{.name}{"\n"}{end}' | awk -F'\t' 'NF && $1 != "Synced"' | head -n 6 | paste -sd, - || true)"
  dline "   comparison (status.resources): ${cmp_total:-0} entries, not Synced: ${cmp_bad:-none}"
  dline "   tracking: $(_tracking_summary)"
  dline "   argocd-server managers: $(_managers deployment/argocd-server)"
  dline "   argocd-cmd-params-cm managers: $(_managers configmap/argocd-cmd-params-cm)"
  dline "   argocd-cmd-params-cm keys: $(_cmd_params_keys)"
  dline "   controller pods (name ready restarts started):"
  _controller_pods | _emit
  dline "   controller statefulset: $(_controller_sts)"
  dline "   events for Application ${name} (last 12):"
  _events "${name}" 12 | _emit
  dline "   controller log, application ${name} (last 30):"
  _controller_lines "${name}" 30 | _emit
  return 0
}

# _print_recap <exit code>: the decisive facts, printed last so run_all.sh's tail -20 keeps them.
_print_recap() {
  local rc="$1" name="${app_name:-argocd}" ph msg rev srev sync started fin retry init stat ev_raw ev_first ev_last cond_types cond_err ctl pods sts post_track post_mgr reading
  dline ""
  if [ "${TERMED}" = 1 ]; then
    # After SIGTERM there is no time for cluster reads (run_all.sh allows 15 s before KILL), so this
    # prints only what was read before the signal arrived.
    dline "RECAP s02_l10 exit=${rc} at $(date -u +%H:%M:%S) UTC: stopped by a signal during step: ${CUR_STEP}; cluster reads skipped"
    dline " 1 apply at ${APPLY_START} UTC: ${APPLY_OUT}; wait_for_sync: ${WAIT_SECS}"
    dline " 2 before apply: Application ${PRE_APP}; ${PRE_TRACK}"
    dline " 3 before apply: cmd-params keys [${PRE_CMKEYS:-none}]; managers ${PRE_MGR_CM:-none}"
    dline " 4 before apply: kubectl diff exit=${PRE_DIFF_RC}, ${PRE_DIFF_OBJS} object(s): ${PRE_DIFF_NAMES:-none}"
    dline " 5 at check: ${SNAP_UTC}; phase=${SNAP_PHASE} msg=${SNAP_MSG:-none}"
    dline "13 reading: killed before the cluster state was read; the step named in the first line is where it stopped"
    return 0
  fi
  ph="$(_app_raw "${name}" '{.status.operationState.phase}')"
  msg="$(_app_raw "${name}" '{.status.operationState.message}' | tr '\n' ' ' | cut -c1-200)"
  rev="$(_app_raw "${name}" '{.status.operationState.syncResult.revision}')"
  srev="$(_app_raw "${name}" '{.status.sync.revision}')"
  sync="$(_app_raw "${name}" '{.status.sync.status}/{.status.health.status}')"
  started="$(_app_raw "${name}" '{.status.operationState.startedAt}')"
  fin="$(_app_raw "${name}" '{.status.operationState.finishedAt}')"
  retry="$(_app_raw "${name}" '{.status.operationState.retryCount}')"
  init="$(_app_raw "${name}" 'automated={.status.operationState.operation.initiatedBy.automated} username={.status.operationState.operation.initiatedBy.username}')"
  stat="$(_app_raw "${name}" '{range .status.operationState.syncResult.resources[*]}{.status}{"\n"}{end}' | sort | uniq -c | sed -e 's/^ *//' -e 's/  */ /g' | paste -sd, - || true)"
  # Every condition type, then the error conditions. The full list is read, so a SyncError that is not
  # among the first two conditions still shows.
  cond_types="$(_app_raw "${name}" '{range .status.conditions[*]}{.type}{"\n"}{end}' | sort -u | paste -sd, - || true)"
  cond_err="$(_app_raw "${name}" '{range .status.conditions[*]}{.type}={.message}{"\n"}{end}' | grep -E '^(SyncError|ComparisonError|InvalidSpecError)=' | head -n 2 | cut -c1-200 | paste -sd';' - || true)"
  # The oldest two events (the first sync-status change, for H1) and the newest three.
  ev_raw="$(_events_all "${name}" || true)"
  ev_first="$(printf '%s\n' "${ev_raw}" | head -n 2 | cut -c1-200 | paste -sd'|' - || true)"
  ev_last="$(printf '%s\n' "${ev_raw}" | tail -n 3 | cut -c1-200 | paste -sd'|' - || true)"
  ctl="$(_controller_lines "${name}" 3 | paste -sd'|' - || true)"
  pods="$(_controller_pods | paste -sd'|' - || true)"
  sts="$(_controller_sts)"
  post_track="$(_tracking_summary)"
  post_mgr="$(_managers configmap/argocd-cmd-params-cm)"

  reading="phase=${ph:-none}"
  case "${ph}" in
    Succeeded) reading="${reading}: a real operation finished OK (H1, H4 or H7; compare lines 2 to 4)" ;;
    Failed|Error) reading="${reading}: the operation failed (H2); the cause is in line 7 and line 9" ;;
    Running|Terminating) reading="${reading}: operation still in flight (H3) or interrupted (H6)" ;;
    *) reading="${reading}: no operation state (H8, or no real sync at all)" ;;
  esac
  if [ "${SNAP_UTC}" != "not reached" ] && [ "${SNAP_PHASE}" != "${ph:-none}" ]; then reading="${reading}; phase changed after the check (H3)"; fi
  if [ -n "${EXPECT_SHA}" ] && [ -n "${rev}" ] && [ "${rev}" != "${EXPECT_SHA}" ]; then reading="${reading}; syncResult is not the expected baseline sha (H5)"; fi
  case "${PRE_APP}" in
    absent*) : ;;
    *) reading="${reading}; the Application existed before the apply (H8)" ;;
  esac

  dline "RECAP s02_l10 exit=${rc} at $(date -u +%H:%M:%S) UTC (checkout ${CHECKOUT_HEAD}, pin ${ARGOCD_PIN})"
  dline " 1 apply at ${APPLY_START} UTC: ${APPLY_OUT}; wait_for_sync: ${WAIT_SECS}"
  dline " 2 before apply: Application ${PRE_APP}; ${PRE_TRACK}"
  dline " 3 before apply: cmd-params keys [${PRE_CMKEYS:-none}]; managers ${PRE_MGR_CM:-none}"
  dline " 4 before apply: kubectl diff exit=${PRE_DIFF_RC}, ${PRE_DIFF_OBJS} object(s): ${PRE_DIFF_NAMES:-none}"
  if [ "${SNAP_UTC}" = "not reached" ]; then
    dline " 5 at check: not reached (wait_for_sync did not return Synced and Healthy)"
  else
    dline " 5 at check ${SNAP_UTC} UTC: phase=${SNAP_PHASE} msg=${SNAP_MSG:-none}"
  fi
  dline " 6 at exit: phase=${ph:-none} startedAt=${started:--} finishedAt=${fin:--} retryCount=${retry:--} ${init}; now: ${post_track}"
  dline " 7 at exit, operation message: ${msg:--}"
  dline " 8 revisions: status.sync=${srev:--} syncResult=${rev:--} expected=${EXPECT_SHA:--} sync/health=${sync:--}"
  dline " 9 syncResult by status: ${stat:-none}; condition types: ${cond_types:-none}; error conditions: ${cond_err:-none}"
  dline "10 events, oldest 2: ${ev_first:-none}; newest 3: ${ev_last:-none}"
  dline "11 controller log (last 3): ${ctl:-none}"
  dline "12 controller pods: ${pods:-none}; statefulset: ${sts:-unknown}; cmd-params managers now: ${post_mgr:-none}"
  dline "13 reading: ${reading}"
  return 0
}

# _flush_summary: the full transcript, for the run's summary page (run_all.sh does not print it).
_flush_summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    printf '\n<details><summary>s02_l10 diagnostics (UTC %s)</summary>\n\n<pre>\n' "$(date -u +%H:%M:%S)"
    tail -c 60000 "${DIAG_LOG}" 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    printf '\n</pre>\n</details>\n'
  } >>"${GITHUB_STEP_SUMMARY}" 2>/dev/null || true
  return 0
}

_on_exit() {
  local rc=$?
  trap - EXIT
  _print_recap "${rc}" || true
  _flush_summary || true
  rm -f "${DIAG_LOG}" 2>/dev/null || true
  exit "${rc}"
}

# _on_signal <name> <status>: run_all.sh's timeout sends SIGTERM. Record it, then exit, which runs
# _on_exit and its RECAP. The status is the one the signal would have given the shell.
_on_signal() {
  TERMED=1
  dline ""
  dline "signal $1 received at $(date -u +%H:%M:%S) UTC during step: ${CUR_STEP}"
  exit "$2"
}

dline "s02_l10 diagnostics: started $(date -u +%H:%M:%S) UTC, checkout ${CHECKOUT_HEAD}, Argo CD ${ARGOCD_PIN}, tree ${REPO_ROOT##*/}"
trap _on_exit EXIT
trap '_on_signal TERM 143' TERM
trap '_on_signal INT 130' INT

step "both files this lesson commits are actually in the repo"
assert_exists_file "bootstrap/install.yaml"
assert_exists_file "bootstrap/self-manage-app.yaml"

step "the two details that go beyond what the lesson spells out, and both matter"
assert_file_contains "bootstrap/self-manage-app.yaml" 'prune: *false' \
  "prune: false: an accidental Git deletion cannot take Argo CD itself down with it"
assert_file_contains "bootstrap/self-manage-app.yaml" 'ServerSideApply=true' \
  "syncOptions carries ServerSideApply=true: without it this Application hits the exact 262144-byte wall from s02_l03.sh the moment it ever needs to actually sync"

assert_file_contains "bootstrap/self-manage-app.yaml" 'include: *"\{install.yaml,self-manage-app.yaml\}"' \
  "directory.include scopes it to its own two files: bootstrap/ also holds the App of Apps root and the edge AppProject"

step "the committed install manifest is pinned to the version actually running"
if grep -q "quay.io/argoproj/argocd:${ARGOCD_PIN}" "${REPO_ROOT}/bootstrap/install.yaml"; then
  _pass "bootstrap/install.yaml pins ${ARGOCD_PIN}, matching test/versions.env"
else
  _fail "bootstrap/install.yaml does not pin ${ARGOCD_PIN}: Step 1's claim of a byte-identical copy no longer holds, and the self-manage Application will show OutOfSync on first apply"
fi

running_image="$(kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
dline "running argocd-server image: ${running_image:-unknown} (pin ${ARGOCD_PIN}); committed image line: $(grep -m1 -o "quay.io/argoproj/argocd:[^ \"]*" "${REPO_ROOT}/bootstrap/install.yaml" 2>/dev/null || echo none)"
case "${running_image}" in
  *":${ARGOCD_PIN}")
    _pass "the running argocd-server is also on ${ARGOCD_PIN}"
    ;;
  *)
    _fail "the running argocd-server image is '${running_image:-unknown}', not ${ARGOCD_PIN}: the cluster and the committed manifest have drifted apart"
    ;;
esac

step "apply the self-manage Application and read its own name out of the file, not out of the prose"
app_name="$(awk '/^metadata:/{f=1;next} f && /name:/{print $2; exit}' "${REPO_ROOT}/bootstrap/self-manage-app.yaml")"
[ -n "${app_name}" ] || _fail "could not read metadata.name out of bootstrap/self-manage-app.yaml"
dline "application name from the file: ${app_name} (tree ${REPO_ROOT##*/})"
_pre_apply_facts "${app_name}"
APPLY_START="$(date -u +%H:%M:%S)"
apply_out="$(kubectl apply -n argocd -f "${REPO_ROOT}/bootstrap/self-manage-app.yaml" 2>&1)" || { printf '%s\n' "${apply_out}" | head -n 20; exit 1; }
APPLY_OUT="$(printf '%s' "${apply_out}" | tr '\n' ' ' | cut -c1-200)"
dline "apply at ${APPLY_START} UTC: ${APPLY_OUT:-no output}"
wait_started=$(date +%s)
wait_for_sync "${app_name}" 180
op_resources="$(kubectl get application "${app_name}" -n argocd -o jsonpath='{.status.operationState.syncResult.resources}' 2>/dev/null)"
WAIT_SECS=$(( $(date +%s) - wait_started ))
dline "wait_for_sync returned after ${WAIT_SECS}s"

step "it reached Synced/Healthy WITHOUT running a real sync operation"
# If the committed manifest actually differed from the live objects, Argo CD would have run an
# operation with a non-empty resource list to reconcile that diff. "Already synced" means either
# no operationState at all, or one whose syncResult touched nothing.
_snapshot_app "${app_name}" "state read at the check"
if [ -z "${op_resources}" ] || [ "${op_resources}" = "[]" ] || [ "${op_resources}" = "null" ]; then
  _pass "no real sync operation ran: the committed manifest was already identical to the live cluster"
else
  _fail "a sync operation ran with resources to reconcile (${op_resources}): the manifest was NOT actually byte-identical to what's running, contradicting the lesson's 'already synced' point"
fi

step "it did not sweep the rest of bootstrap/ onto the cluster"
if kubectl get application root -n argocd >/dev/null 2>&1; then
  _fail "an Application named root exists after the self-manage sync: the argocd Application is syncing bootstrap/root-app.yaml, which belongs to the App of Apps lesson (check directory.include)"
else
  _pass "no root Application: the self-manage Application stayed inside install.yaml and itself"
fi
dline "applications in argocd now: $(_bounded 20 kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' --request-timeout=15s 2>/dev/null || true)"

smoke_done
