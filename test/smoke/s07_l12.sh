#!/usr/bin/env bash
# lesson: s07_l12 Service Account Impersonation: stopping Argo CD from being a god object
# Service account impersonation: stopping Argo CD being a god object.
#
# The claim: once `application.sync.impersonation.enabled` is on and an AppProject names a scoped
# ServiceAccount via `destinationServiceAccounts`, the controller syncs AS that ServiceAccount,
# so a sync succeeds for whatever its Role grants (Deployments/Services/ConfigMaps here), but
# reading logs or deleting a Pod through Argo CD is refused by underlying KUBERNETES RBAC on the
# impersonated identity, even for an account (here: admin) whose own Argo CD-level RBAC would
# otherwise allow both without question. That last part is the whole point: this is a different,
# lower layer than the policy.csv rules from the earlier RBAC lessons, and it overrides what
# policy.csv would allow.
#
# `application.sync.impersonation.enabled` is a global flag on argocd-cm: snapshotted and
# restored so this is safe to run alongside the rest of this section's scripts on the same cluster.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L12 "impersonation makes the controller sync as a scoped ServiceAccount: its Role's grants succeed, but logs and Pod delete are refused by Kubernetes RBAC underneath, even for an admin Argo CD session"
tier cluster

# ---------------------------------------------------------------------------
# Diagnostics (2026-10-13). They do not change what the test asserts, and they do not change when
# any verdict is reached. The changes from the original, all in this file (lib.sh is untouched):
#   - Every step header carries a UTC time. step, _fail and the EXIT trap are redefined here only.
#     _fail keeps lib.sh's body and records its message for the DIAG SUMMARY.
#   - The verdict commands: the logs read under timeout 20, the Pod delete as the Argo CD API's DELETE
#     under a 60 s curl bound (api_delete_pod). Their output and exit code are captured so the summary can print them.
#   - 2026-10-13 fix (CI run 3): the logs and the Pod delete are judged by their output, not their exit code.
#     argocd app logs exits 0 after streaming the refusal as a log line. argocd app delete-resource cannot address
#     a Pod ("no matching resource found"), so the delete goes through the API, as the UI's Delete button sends it.
#     Before the reads, the grant prepare.sh gives argocd-server (act as this ServiceAccount, nothing more) is applied.
#   - Read-only queries before the verdicts (app state at sync time, the argocd-cm flag read back, the
#     managed resources list) sit outside every wait loop. wait_for_sync is untouched.
#   - On failure only, diagnose_failure runs from the EXIT trap, before cleanup. Each query is bounded
#     (20 s; the probe 30 s), and no group of probes starts after 120 s, so the summary is always reached.
#     A TERM from the runner's timeout stops the probes at once: the TERM handler prints the summary and
#     runs cleanup itself (the runner allows 15 s after the signal, and the probes need more). See on_term.
#   - EXIT-TIME WRITE: when the logs check fails, the Pod delete the verdict would have run is run once
#     more as a probe, after the verdict, with the same request (api_delete_pod). The namespace is disposable
#     and cleanup deletes it anyway. It is skipped when the delete check itself ran.
#   - run_all.sh prints only the LAST 20 lines of a failing script, so DIAG SUMMARY, printed last
#     (about 15 lines), carries the facts that separate the candidate causes. The detail above is for a full run.
# ---------------------------------------------------------------------------
LAST_STEP="(before the first step)"
LAST_FAIL="none"
DIAG_T0=0
step() { LAST_STEP="$1"; printf '\n\033[1m==> [%s] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$1"; }
diag() { printf '  diag [%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
# _fail: lib.sh's _fail body, plus a record of the message for the DIAG SUMMARY.
_fail() {
  LAST_FAIL="$1"
  printf "  \033[31mFAIL\033[0m %b\n" "$1" >&2
  argocd_cli_release 2>/dev/null || true
  exit 1
}
# count_in <text> <ere>: number of matching lines in text. Never fails.
count_in() { printf '%s\n' "$1" | grep -Eic -- "$2" || true; }
# jp <kind> <name> <namespace> <jsonpath-body>: one value, flattened to one line, cut. Bounded. Never fails.
jp() { timeout 20 kubectl get "$1" "$2" -n "$3" -o "jsonpath=$4" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' | cut -c1-200 || true; }
# run_capture <seconds> <command...>: run, leave output in CAP_OUT and the exit code in CAP_RC.
# seconds 0 means no bound (the verdict delete, as in the original). The exit code is taken with ||
# into a file, not inside $( ): lib.sh sets errtrace, and a command substitution would fire its ERR
# trap ("FAIL stopped at line ...") on an expected refusal.
run_capture() {
  local secs="$1" f
  shift
  f="$(mktemp)"
  CAP_RC=0
  if [ "${secs}" -gt 0 ]; then
    timeout "${secs}" "$@" > "${f}" 2>&1 || CAP_RC=$?
  else
    "$@" > "${f}" 2>&1 || CAP_RC=$?
  fi
  CAP_OUT="$(cat "${f}")"
  rm -f "${f}"
}
# late: true once 120 s have passed since the verdict. Diagnostic probes stop starting then.
late() { [ $(( $(date +%s) - DIAG_T0 )) -ge 120 ]; }
# api_delete_pod [seconds]: the Pod delete the Argo CD UI's Delete button sends (DELETE /api/v1/applications/{app}/resource),
# with the session token the argocd CLI stored at login. Prints the response body: "{}" on success (an empty
# ApplicationResponse), a JSON error on refusal. argocd app delete-resource is not used: the CLI looks the Pod up in
# ManagedResources, which holds only objects declared in Git, so it exits "no matching resource found" before any
# request reaches the server (take of 2026-10-07). Same request as test/smoke/s07_l07.sh.
api_delete_pod() {
  local token secs="${1:-60}"
  token="$(awk '/auth-token:/{print $NF; exit}' "${HOME}/.config/argocd/config" 2>/dev/null || true)"
  curl -sS -k --max-time "${secs}" -X DELETE -H "Content-Type: application/json" -H "Authorization: Bearer ${token}" \
    "https://argocd.local/api/v1/applications/${APP}/resource?namespace=${NS}&resourceName=${POD_NAME}&version=v1&kind=Pod&group="
}

REPO="https://github.com/abohmeed/argocd-class-resources.git"
PROJ="s07l12-probe"
NS="s07l12-probe"
APP="s07l12-app"
SA="s07l12-controller"
PF_PID=""
PORT=18212
HAD_IMPERSONATION="no"
ORIG_IMPERSONATION=""
POD_NAME=""
LOGGED_IN="no"
LOGS_RC="not run"; LOGS_SECS="?"; LOGS_OUT=""
DEL_REACHED="no"; DEL_SRC="not run"; DEL_RC="not run"; DEL_OUT=""
CAN_DELETE="?"; CAN_LOGS="?"; CAN_UPDATE="?"
SIGNALED="no"

cleanup() {
  [ -n "${PF_PID}" ] && kill "${PF_PID}" >/dev/null 2>&1 || true
  if [ "${HAD_IMPERSONATION}" = "yes" ]; then
    kubectl patch configmap argocd-cm -n argocd --type merge \
      -p "{\"data\":{\"application.sync.impersonation.enabled\":\"${ORIG_IMPERSONATION}\"}}" >/dev/null 2>&1 || true
  else
    kubectl patch configmap argocd-cm -n argocd --type json \
      -p '[{"op":"remove","path":"/data/application.sync.impersonation.enabled"}]' >/dev/null 2>&1 || true
  fi
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete rolebinding "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete role "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete serviceaccount "${SA}" -n "${NS}" --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}

# The EXIT trap runs after any _fail (exit 1) and after a TERM from the runner's timeout. The runner allows
# 15 s after its TERM before it kills the script, so a TERM during diagnostics stops the probes at once and
# the TERM handler prints the summary and runs cleanup itself. Bash does not run the EXIT trap again for an
# exit taken inside it, so the handler cannot leave it to on_exit. Cleanup runs last, as before.
# STAGE: main (the script body), diag (diagnose_failure runs from on_exit), finish (summary and cleanup).
STAGE="main"
on_term() {
  SIGNALED="yes"
  case "${STAGE}" in
    main) exit 143 ;;
    diag)
      STAGE="finish"
      diag "TERM from the runner's timeout during diagnostics: the remaining probes are skipped"
      summary
      cleanup
      exit 143 ;;
    *) ;;
  esac
}
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  if [ "${STAGE}" = "finish" ]; then exit "${rc}"; fi
  DIAG_T0="$(date +%s)"
  if [ "${SIGNALED}" = "yes" ]; then
    rc=143
    LAST_FAIL="stopped by TERM from the runner's timeout (SMOKE_SCRIPT_TIMEOUT, 600 s by default); no probes were run"
    STAGE="finish"
    summary
  elif [ "${rc}" -ne 0 ]; then
    STAGE="diag"
    diagnose_failure || true
  fi
  STAGE="finish"
  cleanup
  exit "${rc}"
}
trap on_exit EXIT
trap on_term TERM

# app_state: the Application fields that separate "synced by the impersonated SA" from the other readings.
app_state() {
  ST_SYNC="$(jp application "${APP}" argocd '{.status.sync.status}')"
  ST_REV="$(jp application "${APP}" argocd '{.status.sync.revision}')"
  ST_HEALTH="$(jp application "${APP}" argocd '{.status.health.status}')"
  ST_PHASE="$(jp application "${APP}" argocd '{.status.operationState.phase}')"
  ST_MSG="$(jp application "${APP}" argocd '{.status.operationState.message}')"
  ST_INIT="$(jp application "${APP}" argocd '{.status.operationState.operation.initiatedBy}')"
  ST_SYNCREV="$(jp application "${APP}" argocd '{.status.operationState.syncResult.revision}')"
  diag "app sync=${ST_SYNC:-<empty>} health=${ST_HEALTH:-<empty>} status.sync.revision=${ST_REV:-<empty>}"
  diag "app operationState.phase=${ST_PHASE:-<empty>} initiatedBy=${ST_INIT:-<empty>} syncResult.revision=${ST_SYNCREV:-<empty>}"
  diag "app operationState.message=${ST_MSG:-<empty>}"
}

# diagnose_failure: runs only from on_exit, after the verdict, and only for a failed run. Read-only,
# except the Pod delete probe near the end, which is the same command the delete check judges.
diagnose_failure() {
  local ctrl srv pod_logs kinds
  diag "the script stopped before its last check; collecting the state each candidate cause predicts (bounded, 120 s budget)"
  diag "argocd client: $(argocd version --client 2>/dev/null | head -n 1 | cut -c1-80 || true)"
  FLAG_NOW="$(jp configmap argocd-cm argocd '{.data.application\.sync\.impersonation\.enabled}')"
  diag "argocd-cm application.sync.impersonation.enabled now=${FLAG_NOW:-<unset>}"
  diag "AppProject ${PROJ} destinationServiceAccounts=$(jp appproject "${PROJ}" argocd '{.spec.destinationServiceAccounts}')"
  app_state
  EXPECT_REV="$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "${REPO}" refs/heads/baseline/before-rollouts 2>/dev/null | head -n 1 | cut -c1-12 || true)"
  diag "expected revision: the baseline/before-rollouts tip is ${EXPECT_REV:-<unknown>}; syncResult.revision was ${ST_SYNCREV:-<empty>}"

  if [ "${LOGGED_IN}" = "yes" ]; then
    ARGO_CAN_LOGS="$(timeout 20 argocd account can-i get logs "${PROJ}/${APP}" --grpc-web 2>&1 | head -n 1 | cut -c1-120 || true)"
    diag "Argo CD RBAC control (admin's own policy, not Kubernetes): account can-i get logs ${PROJ}/${APP} = ${ARGO_CAN_LOGS:-<empty>}"
  fi

  CAN_IMP="$(timeout 20 kubectl auth can-i impersonate serviceaccounts -n "${NS}" --as="system:serviceaccount:argocd:argocd-server" 2>&1 | head -n 1 || true)"
  diag "kubectl can-i impersonate serviceaccounts in ${NS} as argocd-server: ${CAN_IMP:-<empty>}"
  if timeout 20 kubectl get clusterrole argocd-server >/dev/null 2>&1; then
    CR_IMP_N="$(timeout 20 kubectl get clusterrole argocd-server -o yaml 2>/dev/null | grep -c 'impersonate' || true)"
  else
    CR_IMP_N="absent"
  fi
  diag "ClusterRole argocd-server: lines containing impersonate=${CR_IMP_N:-?}"
  diag "bindings naming argocd-server (first 4): $(timeout 20 kubectl get clusterrolebindings,rolebindings -A --no-headers 2>/dev/null | grep -i 'argocd-server' | head -n 4 | cut -c1-140 | tr '\n' ' ' || true)"
  diag "Role ${SA} in ${NS}, rules (first 14 lines):"
  timeout 20 kubectl get role "${SA}" -n "${NS}" -o yaml 2>/dev/null | sed -n '/^rules:/,$p' | head -n 14 | cut -c1-120 | sed 's/^/    role| /' || true

  if late; then
    diag "time budget spent: the controller, server, event, Pod and status probes were skipped"
  else
    ctrl="$(timeout 20 kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --since=20m --tail=3000 2>/dev/null | grep -Ei -e "${APP}" -e "${SA}" -e 'impersonat' -e 'forbidden' || true)"
    CTRL_N="$(printf '%s\n' "${ctrl}" | grep -c . || true)"
    CTRL_LAST="$(printf '%s\n' "${ctrl}" | grep . | tail -n 1 | cut -c1-160 || true)"
    diag "controller log lines for ${APP} / ${SA} / impersonat / forbidden (last 20m): ${CTRL_N:-0}"
    printf '%s\n' "${ctrl}" | grep . | tail -n 6 | cut -c1-200 | sed 's/^/    ctrl| /' || true

    srv="$(timeout 20 kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --since=20m --tail=3000 2>/dev/null | grep -Ei -e "${APP}" -e 'impersonat' -e 'forbidden' -e 'cannot' -e 'PermissionDenied' || true)"
    diag "argocd-server log lines for ${APP} / impersonat / forbidden / cannot (last 20m): $(printf '%s\n' "${srv}" | grep -c . || true)"
    printf '%s\n' "${srv}" | grep . | tail -n 5 | cut -c1-200 | sed 's/^/    srv| /' || true

    diag "events in ${NS} (last 6):"
    timeout 20 kubectl get events -n "${NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 6 | cut -c1-200 | sed 's/^/    ev| /' || true
    diag "pods in ${NS}:"
    timeout 20 kubectl get pods -n "${NS}" -o wide 2>/dev/null | head -n 4 | cut -c1-160 | sed 's/^/    pod| /' || true

    if [ -n "${POD_NAME}" ]; then
      pod_logs="$(timeout 20 kubectl logs "${POD_NAME}" -n "${NS}" --tail=3 2>/dev/null | head -n 3 || true)"
      POD_LOG_N="$(printf '%s\n' "${pod_logs}" | grep -c . || true)"
      diag "control, admin kubectl logs of ${POD_NAME} (not through Argo CD): ${POD_LOG_N:-0} lines"
    fi

    # Argo CD's status.resources lists the objects its manifests declare. A Pod appears there only if a
    # manifest declares one, so 0 is the expected reading, and the delete output is the decisive marker.
    kinds="$(timeout 20 kubectl get application "${APP}" -n argocd -o jsonpath='{range .status.resources[*]}{.kind}/{.name}{" "}{end}' 2>/dev/null || true)"
    MANAGED_POD="$(printf '%s\n' "${kinds}" | tr ' ' '\n' | grep -c '^Pod/' || true)"
    diag "status.resources kind/name: $(printf '%s' "${kinds:-<none>}" | cut -c1-160); Pods among them: ${MANAGED_POD:-0}"
  fi

  if [ "${DEL_REACHED}" = "no" ] && [ "${LOGGED_IN}" = "yes" ] && [ -n "${POD_NAME}" ]; then
    if late; then
      diag "time budget spent: the exit-time delete probe was skipped"
    else
      diag "Pod delete probe (WRITE, bounded 30 s): the same API request the delete check judges, run after the verdict because the logs check exited first"
      run_capture 0 api_delete_pod 30
      DEL_OUT="${CAP_OUT}"; DEL_RC="${CAP_RC}"; DEL_SRC="exit-time probe"
      diag "Pod delete probe curl exit=${DEL_RC}; first line: $(printf '%s\n' "${DEL_OUT}" | head -n 1 | cut -c1-150 || true)"
    fi
  fi

  summary
}

# summary: printed LAST, so it is inside the 20 lines run_all.sh keeps from a failing script.
summary() {
  local m_cimp m_pl m_fb m_pd m_np m_sa m_dcimp m_dimp m_dfb m_dnm m_dq
  m_cimp="$(count_in "${LOGS_OUT}" 'cannot impersonate')"
  m_pl="$(count_in "${LOGS_OUT}" 'pods/log')"
  m_fb="$(count_in "${LOGS_OUT}" 'forbidden')"
  m_pd="$(count_in "${LOGS_OUT}" 'permission denied|PermissionDenied')"
  m_np="$(count_in "${LOGS_OUT}" 'no pods|no matching|not found')"
  m_sa="$(count_in "${LOGS_OUT}" "${SA}")"
  m_dcimp="$(count_in "${DEL_OUT}" 'cannot impersonate')"
  m_dimp="$(count_in "${DEL_OUT}" 'impersonate-on')"
  m_dfb="$(count_in "${DEL_OUT}" 'forbidden|cannot delete')"
  m_dnm="$(count_in "${DEL_OUT}" 'no matching resource found')"
  m_dq="$(count_in "${DEL_OUT}" 'Are you sure|EOF|cancelled')"
  printf '\n  ----- DIAG SUMMARY s07_l12 at %s UTC; last step: %s -----\n' "$(date -u +%H:%M:%S)" "${LAST_STEP}"
  printf '  verdict: %s\n' "$(printf '%s' "${LAST_FAIL}" | cut -c1-230)"
  printf '  logs: exit=%s after %ss; markers cannot-impersonate=%s pods/log=%s forbidden=%s perm-denied=%s no-pods=%s SA-name=%s\n' \
    "${LOGS_RC}" "${LOGS_SECS}" "${m_cimp}" "${m_pl}" "${m_fb}" "${m_pd}" "${m_np}" "${m_sa}"
  printf '%s\n' "${LOGS_OUT}" | head -n 2 | cut -c1-170 | sed 's/^/  logs out| /' || true
  printf '  delete (%s): exit=%s; markers cannot-impersonate=%s impersonate-on=%s forbidden=%s no-matching=%s prompt-or-EOF=%s\n' \
    "${DEL_SRC}" "${DEL_RC}" "${m_dcimp}" "${m_dimp}" "${m_dfb}" "${m_dnm}" "${m_dq}"
  printf '  delete out| %s\n' "$(printf '%s\n' "${DEL_OUT}" | head -n 1 | cut -c1-150)"
  printf '  kubectl can-i impersonate SAs as argocd-server: %s; ClusterRole argocd-server impersonate lines: %s\n' \
    "${CAN_IMP:-?}" "${CR_IMP_N:-?}"
  printf '  Argo CD RBAC (admin) can get logs: %s; argocd-cm flag now: %s; expected revision: %s, syncResult.revision: %s\n' \
    "${ARGO_CAN_LOGS:-?}" "${FLAG_NOW:-?}" "${EXPECT_REV:-?}" "${ST_SYNCREV:-?}"
  printf '  app sync=%s health=%s operationState.phase=%s initiatedBy=%s\n' \
    "${ST_SYNC:-?}" "${ST_HEALTH:-?}" "${ST_PHASE:-?}" "${ST_INIT:-?}"
  printf '  app operationState.message: %s\n' "$(printf '%s' "${ST_MSG:-}" | cut -c1-150)"
  printf '  controller lines (app/SA/impersonat/forbidden): %s; last: %s\n' "${CTRL_N:-?}" "${CTRL_LAST:-none}"
  printf '  Pods in status.resources: %s; SA can-i: delete=%s logs=%s update=%s; control logs of Pod: %s\n' \
    "${MANAGED_POD:-?}" "${CAN_DELETE}" "${CAN_LOGS}" "${CAN_UPDATE}" "${POD_LOG_N:-?}"
  printf '  ----- end DIAG SUMMARY -----\n'
}

if ! command -v argocd >/dev/null 2>&1; then
  _fail "argocd CLI not on PATH: argocd app logs / delete-resource are only reachable behind the real API"
fi

step "the scoped ServiceAccount: full control of Deployments/Services/ConfigMaps, read-only on Pods, no logs subresource"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: {name: ${SA}, namespace: ${NS}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: ${SA}, namespace: ${NS}}
rules:
  - apiGroups: ["", "apps"]
    resources: ["deployments", "services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: ${SA}, namespace: ${NS}}
subjects:
  - {kind: ServiceAccount, name: ${SA}, namespace: ${NS}}
roleRef: {kind: Role, name: ${SA}, apiGroup: rbac.authorization.k8s.io}
EOF

# can-i exits 1 for "no", which is an answer here, not an error: the answer is read from its output.
can_delete="$(kubectl auth can-i delete pods --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}" || true)"
can_logs="$(kubectl auth can-i get pods --subresource=log --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}" || true)"
can_update="$(kubectl auth can-i update deployments --namespace "${NS}" --as="system:serviceaccount:${NS}:${SA}" || true)"
CAN_DELETE="${can_delete:-<empty>}"; CAN_LOGS="${can_logs:-<empty>}"; CAN_UPDATE="${can_update:-<empty>}"
diag "can-i judged: delete=${CAN_DELETE} logs=${CAN_LOGS} update=${CAN_UPDATE}"
if [ "${can_delete}" = "no" ] && [ "${can_logs}" = "no" ] && [ "${can_update}" = "yes" ]; then
  _pass "ServiceAccount's Kubernetes RBAC is exactly as scoped: no pod delete, no pod logs, yes deployment update"
else
  _fail "ServiceAccount's Role does not have the expected shape (delete=${can_delete} logs=${can_logs} update=${can_update}): the rest of this test cannot isolate impersonation's effect from a Role that is wrong to begin with"
fi

step "wire it in: destinationServiceAccounts on the project, impersonation enabled instance-wide"
present="$(kubectl get configmap argocd-cm -n argocd -o jsonpath='{.data.application\.sync\.impersonation\.enabled}' 2>/dev/null || true)"
if [ -n "${present}" ]; then HAD_IMPERSONATION="yes"; ORIG_IMPERSONATION="${present}"; fi
diag "argocd-cm impersonation flag before the patch=${present:-<unset>}"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "Smoke-test probe: not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  destinationServiceAccounts:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}", defaultServiceAccount: "${SA}"}
EOF
kubectl patch configmap argocd-cm -n argocd --type merge -p \
  '{"data":{"application.sync.impersonation.enabled":"true"}}' >/dev/null
diag "argocd-cm impersonation flag read back after the patch=$(jp configmap argocd-cm argocd '{.data.application\.sync\.impersonation\.enabled}')"

step "sync succeeds: the SA's Role covers everything a plain Deployment+Service sync touches"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: baseline/before-rollouts, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy: {automated: {}, syncOptions: []}
EOF
wait_for_sync "${APP}" 180
diag "state at the moment the sync reported Synced and Healthy:"
app_state
POD_NAME="$(kubectl get pods -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
diag "target Pod=${POD_NAME:-<none>}"
[ -n "${POD_NAME}" ] || _fail "no Pod found in ${NS} after a reported sync"

step "argocd-server may act as the scoped ServiceAccount, for get on pods/log and delete on pods, and nothing else"
# Stock argocd-server has no impersonate-on verb, so without this grant its impersonated requests are refused by
# Kubernetes before the ServiceAccount's own Role is checked ("cannot impersonate-on:serviceaccount:get resource
# pods/log", take of 2026-10-08). This is the grant prepare.sh adds (ACD-163 retake fix, 2026-10-11): this
# ServiceAccount, in this namespace, and no other. The delete rule is the same kind of grant for the delete verb:
# the impersonation check is keyed on the request's verb, so a DELETE needs its own rule. prepare.sh grants only
# the get rule; without the delete rule the Pod delete would be refused by argocd-server, not by the ServiceAccount.
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: argocd-server-impersonate-${SA}, namespace: ${NS}}
rules:
  - apiGroups: [""]
    resources: ["serviceaccounts"]
    resourceNames: ["${SA}"]
    verbs: ["impersonate"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["impersonate-on:serviceaccount:get"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["impersonate-on:serviceaccount:delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: argocd-server-impersonate-${SA}, namespace: ${NS}}
subjects:
  - {kind: ServiceAccount, name: argocd-server, namespace: argocd}
roleRef: {kind: Role, name: argocd-server-impersonate-${SA}, apiGroup: rbac.authorization.k8s.io}
EOF
[ "$(kubectl auth can-i 'impersonate-on:serviceaccount:get' pods --subresource=log --namespace "${NS}" --as=system:serviceaccount:argocd:argocd-server 2>/dev/null || true)" = "yes" ] \
  || _fail "argocd-server cannot act as ${SA} for get on pods/log: the grant above did not take"
[ "$(kubectl auth can-i 'impersonate-on:serviceaccount:delete' pods --namespace "${NS}" --as=system:serviceaccount:argocd:argocd-server 2>/dev/null || true)" = "yes" ] \
  || _fail "argocd-server cannot act as ${SA} for delete on pods: the grant above did not take"
diag "argocd-server may act as ${SA} for get on pods/log and delete on pods (scoped grant applied)"

step "reach argocd-server as admin: an account whose OWN Argo CD RBAC has no reason to be denied logs or delete"
up="no"
# The lesson logs in through argocd.local (Do.md, S02-L08 step 12): Traefik terminates TLS on 443 with a
# self-signed certificate, and argocd-server behind it runs insecure.
SCHEME=https; LOGIN_TLS="--insecure"
for _ in $(seq 1 20); do curl -sk "${SCHEME}://argocd.local/healthz" >/dev/null 2>&1 && { up="yes"; break; }; sleep 1; done
[ "${up}" = "yes" ] || _fail "argocd-server never answered through argocd.local"
ADMIN_PW="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode)"
[ -n "${ADMIN_PW}" ] || _fail "no argocd-initial-admin-secret on this cluster"
argocd login argocd.local ${LOGIN_TLS} --grpc-web --username admin --password "${ADMIN_PW}" >/dev/null
LOGGED_IN="yes"
diag "argocd login ok; argocd client: $(argocd version --client 2>/dev/null | head -n 1 | cut -c1-80 || true)"

step "admin's own logs read is refused: blocked underneath by the impersonated SA's Kubernetes RBAC, not by policy.csv"
t0="$(date +%s)"
run_capture 20 argocd app logs "${APP}" --grpc-web
rc="${CAP_RC}"; out="${CAP_OUT}"
LOGS_RC="${rc}"; LOGS_OUT="${out}"; LOGS_SECS=$(( $(date +%s) - t0 ))
diag "argocd app logs exit=${rc} after ${LOGS_SECS}s (exit 124 = the 20s bound was hit); output lines: $(printf '%s\n' "${out}" | wc -l | tr -d ' ')"
diag "output markers: cannot-impersonate=$(count_in "${out}" 'cannot impersonate') pods/log=$(count_in "${out}" 'pods/log') forbidden=$(count_in "${out}" 'forbidden') perm-denied=$(count_in "${out}" 'permission denied|PermissionDenied') no-pods=$(count_in "${out}" 'no pods|no matching|not found') SA-name=$(count_in "${out}" "${SA}")"
printf '%s\n' "${out}" | head -n 8 | cut -c1-220 | sed 's/^/    logs| /' || true
# Argo CD streams a per-pod Kubernetes error back as a log line and the CLI exits 0 after it, so the exit code says
# nothing here. The refusal is read from the text: it must come from the scoped ServiceAccount's own RBAC.
if grep -q 'cannot impersonate' <<<"${out}"; then
  _fail "argocd-server was refused the impersonation itself (the grant above did not reach it), so the SA's RBAC never decided this read (exit ${rc}): ${out}"
elif grep -qF "User \"system:serviceaccount:${NS}:${SA}\" cannot get resource \"pods/log\"" <<<"${out}"; then
  _pass "admin's logs read refused (exit ${rc}) by Kubernetes RBAC on the impersonated ServiceAccount (no pods/log): policy.csv was not the layer that said no"
else
  _fail "admin's logs read was not refused by the impersonated ServiceAccount's RBAC (exit ${rc}): ${out}"
fi

step "admin's own Pod delete is refused the same way"
DEL_REACHED="yes"
diag "managed resources as the CLI lists them (a Pod is not one of them; the delete uses api_delete_pod), first 12 lines:"
timeout 20 argocd app resources "${APP}" --grpc-web 2>&1 | head -n 12 | cut -c1-160 | sed 's/^/    res| /' || true
# The UI's own request, with admin's session token (api_delete_pod). The CLI cannot address a Pod.
run_capture 0 api_delete_pod 60
DEL_OUT="${CAP_OUT}"; DEL_RC="${CAP_RC}"; DEL_SRC="verdict"
diag "DELETE /api/v1/applications/${APP}/resource for Pod ${POD_NAME}: curl exit=${DEL_RC}; response first line: $(printf '%s\n' "${DEL_OUT}" | head -n 1 | cut -c1-150 || true)"
printf '%s\n' "${DEL_OUT}" | head -n 3 | cut -c1-220 | sed 's/^/    delete| /' || true
if [ "$(printf '%s' "${DEL_OUT}" | tr -d '[:space:]')" = "{}" ]; then
  _fail "admin deleted the Pod through the impersonated app: the SA's Role only grants get/list/watch on Pods, delete should have been refused"
elif grep -q 'cannot impersonate' <<<"${DEL_OUT}"; then
  _fail "argocd-server was refused the impersonation itself for delete, so the SA's RBAC never decided this request: ${DEL_OUT}"
elif grep -q 'cannot delete resource' <<<"${DEL_OUT}" && grep -qF "system:serviceaccount:${NS}:${SA}" <<<"${DEL_OUT}"; then
  _pass "Pod delete refused by Kubernetes RBAC on the impersonated ServiceAccount: its Role has no delete on pods, whatever admin's own reach"
else
  _fail "admin's Pod delete was not refused by the impersonated ServiceAccount's RBAC (curl exit ${DEL_RC}): ${DEL_OUT}"
fi

smoke_done
