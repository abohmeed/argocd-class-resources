#!/usr/bin/env bash
# lesson: s12_l10 Writing a custom health check for a CRD Argo CD doesn't understand
# Argo CD has no opinion about a k3s HelmChart; the Lua health check gives it one.
#
# The lesson's claim (Do.md and Talk.md, premise approved 2026-10-12): Argo CD v3.5.3 has no health
# rule for helm.cattle.io/HelmChart, so under DEFAULT rules the HelmChart row carries no health value
# at all and the Application does not go Degraded, even while the install job behind the HelmChart
# has failed. With the lesson's Lua check (Failed=True reads Degraded, JobCreated=True reads Healthy)
# the same failing HelmChart reads Degraded with the helm controller's own message, and Healthy once
# it is pinned to a published chart version (6.9.4).
#
# This script used to prove the claim with a cert-manager Certificate. That premise is gone: Argo CD
# v3.5.3 ships a built-in health check for that kind, so a Certificate cannot show the false positive
# the lesson opens on.
#
# argocd-cm is itself GitOps-managed by the argocd self-manage Application with selfHeal:true
# (s02_l11.sh): a live patch of it alone would be reverted within seconds, so this script turns that
# Application's selfHeal off for the duration of the patch, and restores it in cleanup.
#
# Where health is read: Argo CD 3.x does not keep per-resource health in the Application object by
# default. The application controller's --persist-resource-health flag (env
# ARGOCD_APPLICATION_CONTROLLER_PERSIST_RESOURCE_HEALTH, argocd-cmd-params-cm key
# controller.resource.health.persist, default "false") decides it. With it off, the controller writes
# resourceHealthSource "appTree" and no per-resource health into the Application. The server then fills each
# status.resources[].health from the resource tree on every read (inferResourcesStatusHealth), and the
# HEALTH column that argocd app get prints is that same field. So every health read in this script
# goes through argocd app get <app> -o json, the view the lesson reads. A kubectl read of the
# Application's status.resources health always comes back empty and proves nothing.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

APP="s12l10-probe"
NS="s12l10-probe"
ROW="s12l10-podinfo"
HC_KEY="resource.customizations.health.helm.cattle.io_HelmChart"
TMPDIR="$(mktemp -d)"
LUA_PATCH="${TMPDIR}/argocd-cm-patch.yaml"

# ---------------------------------------------------------------------------------------------
# Diagnostics for the CI failure of this script (the "got empty" at the default-rules check).
# Nothing below changes an assertion, a FAIL/PASS message, or a pass/fail condition. Every step
# header carries a UTC time. Every probe is read-only, capped in size, and ends in "|| true", so
# a probe cannot be what fails the run. The argocd calls the verdict depends on keep origin's timing (no
# ceiling); bounded is used only for diagnostic reads.
# Each argocd call that is captured runs with its ERR trap cleared (trap - ERR): lib.sh sets
# errtrace, so a non-zero exit inside a command substitution would otherwise print a
# "FAIL stopped at line" line into the captured output, which reads like a real failure.
# ---------------------------------------------------------------------------------------------
step() { printf '\n\033[1m==> [%s UTC] %s\033[0m\n' "$(date -u +%H:%M:%S)" "$1"; }

# bounded <seconds> <command...>: a ceiling on a command, where timeout exists (it does on CI).
bounded() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "${secs}" "$@"; else "$@"; fi
}

# cli_app_json [app]: the Application as argocd app get <app> -o json returns it, which is the view
# the lesson reads. The server has filled status.resources[].health from the resource tree, the same
# field the HEALTH column prints. Empty output when the CLI call fails, so a failed read judges as empty.
cli_app_json() {
  local name="${1:-${APP}}" out
  out="$(trap - ERR; argocd app get "${name}" -o json 2>/dev/null || true)"
  printf '%s' "${out}"
}

# The last values each step captured, so recap can print them in the last lines of the output.
sync_rc="n/a"; hr_rc="n/a"; good_sync_rc="n/a"; TL_FIRST=""

# diag_cluster <label>: cluster-wide facts that separate the hypotheses for this failure.
diag_cluster() {
  echo "  [diag cluster $(date -u +%H:%M:%S)] $1"
  echo "    argocd-server image: $(kubectl get deploy argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "    application-controller pod started: $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].status.startTime}' 2>/dev/null || true)"
  echo "    self-manage Application argocd: selfHeal=$(kubectl get application argocd -n argocd -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null || true) sync=$(kubectl get application argocd -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true) health=$(cli_app_json argocd | jq -r '.status.health.status // empty' 2>/dev/null || true)"
  echo "    argocd-cm resource.customizations keys (names only): $(kubectl get configmap argocd-cm -n argocd -o json 2>/dev/null | jq -r '(.data // {}) | keys[] | select(startswith("resource.customizations"))' 2>/dev/null | tr '\n' ' ' | cut -c1-600 || true)"
  echo "    helmcharts.helm.cattle.io CRD: $(kubectl get crd helmcharts.helm.cattle.io -o name 2>/dev/null || echo absent)"
  echo "    HelmChart objects in ${NS}: $(kubectl get helmchart -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
}

# diag_app <label>: the probe Application as Argo CD holds it right now. Which rows it reports,
# what the last operation was and who started it, when it last reconciled, what the sync result
# says about each s12l10 object, what the live HelmChart looks like, and the controller's own
# log lines for this app. The spec fields (project, source shape, destination) are printed too,
# so a wrong destination or source shows up here.
diag_app() {
  local app_json view_json
  echo "  [diag app ${APP} $(date -u +%H:%M:%S)] $1"
  app_json="$(kubectl get application "${APP}" -n argocd -o json 2>/dev/null || true)"
  if [ -z "${app_json}" ]; then
    echo "    application ${APP}: not readable (absent, or kubectl failed)"
    return 0
  fi
  printf '%s' "${app_json}" | jq -c '{
      project: .spec.project,
      source: {repoURL: .spec.source.repoURL, path: .spec.source.path, targetRevision: .spec.source.targetRevision},
      destination: .spec.destination
    }' 2>/dev/null | cut -c1-800 | sed 's/^/    app identity: /' || echo "    app identity: (jq could not read the Application)"
  printf '%s' "${app_json}" | jq -c '{
      sync: .status.sync.status, resourceHealthSource: .status.resourceHealthSource,
      reconciledAt: .status.reconciledAt, observedAt: .status.observedAt,
      pendingOperation: (.operation != null),
      opPhase: .status.operationState.phase,
      opInitiatedBy: .status.operationState.operation.initiatedBy,
      opStartedAt: .status.operationState.startedAt, opFinishedAt: .status.operationState.finishedAt,
      opRevision: .status.operationState.syncResult.revision,
      opMessage: ((.status.operationState.message // "") | .[0:300])
    }' 2>/dev/null | cut -c1-900 | sed 's/^/    app status: /' || echo "    app status: (jq could not read the Application)"
  echo "    status.resources names: $(printf '%s' "${app_json}" | jq -r '[.status.resources[]? | .name] | join(",")' 2>/dev/null | cut -c1-600 || true)"
  # The health read: the same view the lesson's argocd app get shows (see cli_app_json).
  view_json="$(cli_app_json)"
  printf '%s' "${view_json}" | jq -c '{health: (.status.health.status // null), healthMessage: ((.status.health.message // "") | .[0:160])}' 2>/dev/null | sed 's/^/    cli view application health: /' || echo "    cli view application health: (not readable)"
  printf '%s' "${view_json}" | jq -c '[.status.resources[]? | select((.name // "") | startswith("s12l10")) | {name, kind, status, health: (.health.status // null), healthMessage: ((.health.message // "") | .[0:160])}]' 2>/dev/null | sed 's/^/    cli view rows: /' || true
  printf '%s' "${app_json}" | jq -c '[.status.operationState.syncResult.resources[]? | select((.name // "") | startswith("s12l10")) | {name, kind, status, hookPhase, syncPhase, message: ((.message // "") | .[0:200])}]' 2>/dev/null | sed 's/^/    syncResult: /' || true
  local hc_json hc_view
  hc_json="$(kubectl get helmchart -n "${NS}" -o json 2>/dev/null || true)"
  if [ -z "${hc_json}" ]; then
    echo "    live HelmChart objects: none readable (the CRD is absent, or kubectl failed)"
  else
    hc_view="$(printf '%s' "${hc_json}" | jq -c '[.items[]? | {name: .metadata.name, conditions: [.status.conditions[]? | {type, status, reason, message: ((.message // "") | .[0:200])}]}]' 2>/dev/null || true)"
    if [ "${hc_view}" = "[]" ]; then
      echo "    live HelmChart objects: none (the namespace holds no HelmChart object)"
    else
      echo "    live HelmChart objects: $(printf '%s' "${hc_view:-unparseable}" | cut -c1-600)"
    fi
  fi
  echo "    jobs in ${NS} (the helm controller's install jobs, first 5):"
  kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | head -n 5 | cut -c1-200 | sed 's/^/      /' || true
  echo "    controller log lines naming s12l10 (last 15 min, at most 25):"
  kubectl logs -n argocd statefulset/argocd-application-controller --since=15m 2>/dev/null \
    | grep -E 's12l10' | tail -n 25 | cut -c1-260 | sed 's/^/      /' || true
  echo "    events in ${NS} (last 12):"
  kubectl get events -n "${NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 12 | cut -c1-240 | sed 's/^/      /' || true
  echo "    events on the Application (last 6):"
  kubectl get events -n argocd --field-selector "involvedObject.name=${APP}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 6 | cut -c1-240 | sed 's/^/      /' || true
}

# observe_timeline <resource name>: read-only, 12 samples over 60 s. It runs only AFTER the
# read has already been judged, so it cannot change that verdict. It shows whether the row
# ever gains a health value, and when, which separates "not yet reconciled" from "never computed".
# It sets TL_FIRST to the first sample that carried a health value (or to "none in 60 s").
observe_timeline() {
  local name="$1" i row h
  TL_FIRST=""
  for i in $(seq 1 12); do
    sleep 5
    row="$(cli_app_json | jq -c --arg n "${name}" '[.status.resources[]? | select(.name == $n) | {sync: .status, health: (.health.status // null)}]' 2>/dev/null || true)"
    echo "  [diag timeline +$((15 + i * 5))s $(date -u +%H:%M:%S)] ${name}: ${row:-unreadable}"
    h="$(printf '%s' "${row}" | jq -r '.[0].health // empty' 2>/dev/null || true)"
    if [ -n "${h}" ] && [ "${h}" != "null" ]; then
      TL_FIRST="+$((15 + i * 5))s health=${h}"
      break
    fi
  done
  [ -n "${TL_FIRST}" ] || TL_FIRST="none in 60 s"
}

# recap <judged label> <judged value>: four short lines printed right before a FAIL. CI prints
# only the last 20 lines of a failing script, and the timeline alone can fill that tail, so the
# decisive facts are repeated here, last. Read-only; it runs after the verdict has been judged.
recap() {
  local j
  j="$(cli_app_json)"
  echo "  [RECAP s12_l10] $1 judged value: [${2:-empty}]"
  echo "  [RECAP s12_l10] exits: broken sync ${sync_rc}, hard-refresh ${hr_rc}, good sync ${good_sync_rc} (not judged); timeline first health: ${TL_FIRST:-not read}"
  printf '%s' "${j}" | jq -r '"  [RECAP s12_l10] app sync=\(.status.sync.status // "unknown") health=\(.status.health.status // "unknown") opPhase=\(.status.operationState.phase // "none") initiatedBy=\(.status.operationState.operation.initiatedBy // "none") reconciledAt=\(.status.reconciledAt // "none") opFinishedAt=\(.status.operationState.finishedAt // "none")"' 2>/dev/null \
    || echo "  [RECAP s12_l10] app: not readable"
  printf '%s' "${j}" | jq -r '"  [RECAP s12_l10] rows: " + ([.status.resources[]? | select((.name // "") | startswith("s12l10")) | "\(.name)=\(.health.status // "null")"] | join(", "))' 2>/dev/null \
    || true
}

# row_view: the HelmChart row as the CLI view lists it (one JSON object), empty when the row is not listed.
row_view() {
  cli_app_json | jq -c --arg n "${ROW}" \
    '[.status.resources[]? | select(.name == $n and .kind == "HelmChart")] | .[0] // empty' 2>/dev/null || true
}

# row_listed: the HelmChart row is in the CLI view at all. An empty health only means "no health"
# when the row itself is there to carry it.
row_listed() {
  [ -n "$(row_view)" ]
}

# row_health: the health value the CLI view reports for the HelmChart row (empty when it reports none).
row_health() {
  row_view | jq -r '.health.status // empty' 2>/dev/null || true
}

# row_message: the health message the CLI view reports for the HelmChart row (empty when none).
row_message() {
  row_view | jq -r '.health.message // empty' 2>/dev/null || true
}

# write_chart <dir> <version>: the HelmChart from the lesson, pinned to <version>.
write_chart() {
  mkdir -p "$1"
  cat > "$1/helmchart.yaml" <<CHART
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: ${ROW}
spec:
  repo: https://stefanprodan.github.io/podinfo
  chart: podinfo
  version: $2
  targetNamespace: ${NS}
  backOffLimit: 1
CHART
}

# wait_for_row <seconds>: the HelmChart row is listed in the probe Application's status.
wait_for_row() {
  local deadline name
  deadline=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
    name="$(kubectl get application "${APP}" -n argocd \
      -o jsonpath="{.status.resources[?(@.name==\"${ROW}\")].name}" 2>/dev/null || true)"
    [ "${name}" = "${ROW}" ] && return 0
    sleep 5
  done
  return 1
}

lesson S12-L10 "a HelmChart carries no health under default rules, so the Application does not go Degraded while the install fails; the Lua health check reads Degraded, then Healthy"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "preconditions: k3s's helm controller serves the HelmChart kind this lesson uses"
kubectl get crd helmcharts.helm.cattle.io >/dev/null 2>&1 \
  || _fail "CRD helmcharts.helm.cattle.io is not served: k3s's helm controller is missing, so the lesson's HelmChart cannot run on this cluster (environment fault)"
_pass "helmcharts.helm.cattle.io is served"
diag_cluster "after the precondition check, before this script changes anything"

step "confirm the argocd Application (self-management) exists, from s02_l11.sh"
kubectl get application argocd -n argocd >/dev/null 2>&1 \
  || _fail "no Application named 'argocd' in the argocd namespace: the self-management from s02_l11.sh is missing; this script cannot safely test the Lua-through-Git claim without it"
_pass "argocd (self-management) Application is present"

cleanup() {
  # Remove only the key this script added. The committed argocd-cm carries other data (for example
  # application.resourceTrackingMethod), which a whole-/data removal would take out with it.
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p "[{\"op\":\"remove\",\"path\":\"/data/${HC_KEY}\"}]" >/dev/null 2>&1 || true
  # ...and put the argocd Application's own selfHeal back on, exactly as bootstrap/self-manage-app.yaml commits it.
  kubectl patch application argocd -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}' >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

kubectl create namespace "${NS}" >/dev/null 2>&1 || true

step "create the probe Application: its own namespace, manual sync, nothing pruned"
cat <<PROBE | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # source is a placeholder, never synced without --local below (base, so it carries no
  # namespace opinion of its own even inert: overlays pin their own namespace).
  source: {repoURL: "https://github.com/abohmeed/argocd-class-resources.git", targetRevision: baseline/before-rollouts, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy: {}
PROBE
diag_app "probe Application created, nothing synced yet (does it exist, what is its shape)"

step "sync a HelmChart pinned to a chart version that does not exist (6.99.0)"
write_chart "${TMPDIR}/broken" 6.99.0
t_sync="$(date -u +%H:%M:%S)"
sync_rc=0
sync_out="$(trap - ERR; argocd app sync "${APP}" --local "${TMPDIR}/broken" 2>&1)" || sync_rc=$?
echo "  [diag sync] broken HelmChart: started ${t_sync}, returned $(date -u +%H:%M:%S), exit ${sync_rc} (not judged here; the row check below judges the outcome)"
printf '%s\n' "${sync_out}" | head -n 25 | cut -c1-300 | sed 's/^/    sync output: /' || true
if ! wait_for_row 120; then
  diag_app "the HelmChart row was never listed in the probe Application's status"
  recap "row listing" "absent"
  _fail "the HelmChart ${ROW} never appeared in the probe Application's status within 120 s (see the sync output above, if the CLI sync failed)"
fi

step "its install job really fails: the helm controller marks the HelmChart Failed=True"
failed=""
deadline=$(( $(date +%s) + 240 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  failed="$(kubectl get helmchart "${ROW}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
  [ "${failed}" = "True" ] && break
  sleep 5
done
if [ "${failed}" = "True" ]; then
  _pass "the HelmChart reports Failed=True: the install behind it has failed"
else
  diag_app "the HelmChart never reported Failed=True (the install job did not run, or did not fail)"
  recap "install failure" "${failed:-empty}"
  _fail "expected the HelmChart to report Failed=True within 240s, got '${failed:-empty}': the helm controller did not run the install job to failure, so the lesson's failure does not reproduce on this cluster"
fi

step "under DEFAULT (uncustomized) health rules, the HelmChart carries no health and the Application does not go Degraded"
health="$(row_health)"
app_health="$(cli_app_json | jq -r '.status.health.status // empty' 2>/dev/null || true)"
listed=no
row_listed && listed=yes
printf '  [diag check] judged values, argocd app get -o json: row=[%s] row listed=[%s] application=[%s]\n' "${health}" "${listed}" "${app_health}"
diag_app "the default-rules read, same moment as the judged value"
diag_cluster "same moment as the default-rules read"
if [ "${listed}" = yes ] && [ -z "${health}" ] && [ -n "${app_health}" ] && [ "${app_health}" != "Degraded" ]; then
  _pass "no health value on the HelmChart, and the Application reads ${app_health} while its install has failed: the false positive the lesson opens on"
else
  observe_timeline "${ROW}"
  recap "default-rules read" "row=${health:-empty} listed=${listed} application=${app_health:-empty}"
  _fail "expected no health value on the HelmChart and an Application that is not Degraded under default rules, got row health '${health:-empty}' (row listed: ${listed}) and Application health '${app_health:-empty}': either Argo CD gained a built-in helm.cattle.io check, or the Application now rolls up the failed install"
fi

step "write the Lua health check through a temporary argocd-cm patch, not a live one-off edit"
kubectl patch application argocd -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null
cat > "${LUA_PATCH}" <<'LUA'
data:
  resource.customizations.health.helm.cattle.io_HelmChart: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Failed" and condition.status == "True" then
          hs.status = "Degraded"
          hs.message = condition.message
          return hs
        end
      end
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "JobCreated" and condition.status == "True" then
          hs.status = "Healthy"
          hs.message = condition.message
          return hs
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for the helm controller"
    return hs
LUA
kubectl patch configmap argocd-cm -n argocd --type merge --patch-file "${LUA_PATCH}" >/dev/null
diag_cluster "after the Lua override was written (the HelmChart key should now be listed; selfHeal should read false)"

step "same failing HelmChart, now reads honest: Degraded, with the helm controller's own message"
hr_rc=0
hr_out="$(trap - ERR; argocd app get "${APP}" --hard-refresh 2>&1)" || hr_rc=$?
echo "  [diag] argocd app get --hard-refresh: exit ${hr_rc} (not judged), first line: $(printf '%s' "${hr_out}" | head -n 1 | cut -c1-200 || true)"
deadline=$(( $(date +%s) + 120 ))
health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
  health="$(row_health)"
  [ "${health}" = "Degraded" ] && break
  sleep 5
done
if [ "${health}" = "Degraded" ]; then
  _pass "with the Lua check active the HelmChart reads Degraded (controller message: $(row_message | cut -c1-160)): health now tracks the install's real failure"
else
  diag_app "the Lua-active read, after the 120 s poll (the HelmChart row should read Degraded)"
  recap "Lua-active read" "${health:-empty}"
  _fail "expected Degraded once the Lua check sees Failed=True, got '${health:-empty}': the customization did not take effect, or its condition logic is broken"
fi

step "pin the HelmChart to a published chart version (6.9.4): a fresh install job runs and the HelmChart reads Healthy"
write_chart "${TMPDIR}/good" 6.9.4
t_good="$(date -u +%H:%M:%S)"
good_sync_rc=0
good_sync_out="$(trap - ERR; argocd app sync "${APP}" --local "${TMPDIR}/good" 2>&1)" || good_sync_rc=$?
echo "  [diag sync] corrected HelmChart: started ${t_good}, returned $(date -u +%H:%M:%S), exit ${good_sync_rc} (not judged here; the row check below judges the outcome)"
printf '%s\n' "${good_sync_out}" | head -n 25 | cut -c1-300 | sed 's/^/    sync output: /' || true
deadline=$(( $(date +%s) + 180 ))
good_health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
  good_health="$(row_health)"
  [ "${good_health}" = "Healthy" ] && break
  sleep 5
done
if [ "${good_health}" = "Healthy" ]; then
  _pass "the corrected HelmChart reads Healthy under the Lua check: the honest positive case, not just an always-Degraded stub"
else
  diag_app "the corrected HelmChart, after the 180 s poll (the row should read Healthy)"
  recap "corrected HelmChart read" "${good_health:-empty}"
  _fail "the corrected HelmChart never read Healthy under the Lua check (got '${good_health:-empty}'): either the 6.9.4 install failed or the JobCreated branch of the check is broken"
fi

smoke_done
