#!/usr/bin/env bash
# lesson: s03_l04 Writing a custom health check for a CRD Argo CD doesn't understand
# Argo CD has no opinion about a Certificate; the Lua health check gives it one.
#
# The lesson's claim: a cert-manager Certificate, once created, reads Healthy in Argo CD's
# DEFAULT health computation regardless of whether cert-manager ever actually issues it: Argo
# CD has no built-in rule for a kind it doesn't recognize, so it defaults to Healthy the instant
# the object exists. Only a custom Lua health check
# (resource.customizations.health.cert-manager.io_Certificate) makes the reported status track
# the real `status.conditions[type=Ready]` value. This is proven two ways below: a Certificate
# that can NEVER issue (bad issuerRef, so there is no timing race: it stays Ready:False
# forever) still reads Healthy under the default rules, and reads Progressing once the Lua check
# is active; a real one, with the Lua check active, reads Healthy only once it is genuinely
# Ready.
#
# argocd-cm is itself GitOps-managed by the `argocd` self-manage Application with
# selfHeal:true (from the self-management lesson, s02_l10.sh): a live `kubectl patch` of it alone would be reverted within
# seconds, so this script disables that Application's own selfHeal for the duration of the
# patch, exactly the way the lesson insists this must go through Git in real use, and
# restores it (and argocd-cm) in cleanup regardless of how the script exits.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

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

# The last values each step captured, so recap can print them in the last lines of the output.
sync_rc="n/a"; hr_rc="n/a"; good_sync_rc="n/a"; TL_FIRST=""

# diag_cluster <label>: cluster-wide facts that separate the hypotheses for this failure.
diag_cluster() {
  echo "  [diag cluster $(date -u +%H:%M:%S)] $1"
  echo "    argocd-server image: $(kubectl get deploy argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "    application-controller pod started: $(kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-application-controller -o jsonpath='{.items[0].status.startTime}' 2>/dev/null || true)"
  echo "    self-manage Application argocd: selfHeal=$(kubectl get application argocd -n argocd -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null || true) sync=$(kubectl get application argocd -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true) health=$(kubectl get application argocd -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  echo "    argocd-cm resource.customizations keys (names only): $(kubectl get configmap argocd-cm -n argocd -o json 2>/dev/null | jq -r '(.data // {}) | keys[] | select(startswith("resource.customizations"))' 2>/dev/null | tr '\n' ' ' | cut -c1-600 || true)"
  echo "    cert-manager deployments (ready/desired): $(kubectl get deploy -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}' 2>/dev/null || true)"
  echo "    cert-manager-webhook endpoint IPs: $(kubectl get endpoints cert-manager-webhook -n cert-manager -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  echo "    Certificate CRD: $(kubectl get crd certificates.cert-manager.io -o name 2>/dev/null || echo absent)"
  echo "    ClusterIssuers: $(kubectl get clusterissuer -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
}

# diag_app <label>: the probe Application as Argo CD holds it right now. Which rows it reports,
# what the last operation was and who started it, when it last reconciled, what the sync result
# says about each s03l04 object, what the live Certificate looks like, and the controller's own
# log lines for this app. The spec fields (project, source shape, destination) are printed too,
# so a wrong destination or source shows up here.
diag_app() {
  local app_json
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
      sync: .status.sync.status, health: .status.health.status,
      reconciledAt: .status.reconciledAt, observedAt: .status.observedAt,
      pendingOperation: (.operation != null),
      opPhase: .status.operationState.phase,
      opInitiatedBy: .status.operationState.operation.initiatedBy,
      opStartedAt: .status.operationState.startedAt, opFinishedAt: .status.operationState.finishedAt,
      opRevision: .status.operationState.syncResult.revision,
      opMessage: ((.status.operationState.message // "") | .[0:300])
    }' 2>/dev/null | cut -c1-900 | sed 's/^/    app status: /' || echo "    app status: (jq could not read the Application)"
  echo "    status.resources names: $(printf '%s' "${app_json}" | jq -r '[.status.resources[]? | .name] | join(",")' 2>/dev/null | cut -c1-600 || true)"
  printf '%s' "${app_json}" | jq -c '[.status.resources[]? | select((.name // "") | startswith("s03l04")) | {name, kind, status, health: (.health.status // null), healthMessage: ((.health.message // "") | .[0:160])}]' 2>/dev/null | sed 's/^/    rows: /' || true
  printf '%s' "${app_json}" | jq -c '[.status.operationState.syncResult.resources[]? | select((.name // "") | startswith("s03l04")) | {name, kind, status, hookPhase, syncPhase, message: ((.message // "") | .[0:200])}]' 2>/dev/null | sed 's/^/    syncResult: /' || true
  local certs_json certs_view
  certs_json="$(kubectl get certificate -n "${NS}" -o json 2>/dev/null || true)"
  if [ -z "${certs_json}" ]; then
    echo "    live Certificates: none readable (no Certificate object, or the CRD is absent)"
  else
    certs_view="$(printf '%s' "${certs_json}" | jq -c '[.items[]? | {name: .metadata.name, conditions: [.status.conditions[]? | {type, status, reason, message: ((.message // "") | .[0:200])}]}]' 2>/dev/null || true)"
    if [ "${certs_view}" = "[]" ]; then
      echo "    live Certificates: none (the namespace holds no Certificate object)"
    else
      echo "    live Certificates: $(printf '%s' "${certs_view:-unparseable}" | cut -c1-600)"
    fi
  fi
  echo "    controller log lines naming s03l04 (last 15 min, at most 25):"
  kubectl logs -n argocd statefulset/argocd-application-controller --since=15m 2>/dev/null \
    | grep -E 's03l04' | tail -n 25 | cut -c1-260 | sed 's/^/      /' || true
  echo "    events in ${NS} (last 12):"
  kubectl get events -n "${NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 12 | cut -c1-240 | sed 's/^/      /' || true
  echo "    events on the Application (last 6):"
  kubectl get events -n argocd --field-selector "involvedObject.name=${APP}" --sort-by=.lastTimestamp 2>/dev/null | tail -n 6 | cut -c1-240 | sed 's/^/      /' || true
}

# observe_timeline <resource name>: read-only, 12 samples over 60 s. It runs only AFTER the
# 15 s read has already been judged, so it cannot change that verdict. It shows whether the row
# ever gains a health value, and when, which separates "not yet reconciled" from "never computed".
# It sets TL_FIRST to the first sample that carried a health value (or to "none in 60 s").
observe_timeline() {
  local name="$1" i row h
  TL_FIRST=""
  for i in $(seq 1 12); do
    sleep 5
    row="$(kubectl get application "${APP}" -n argocd -o json 2>/dev/null \
      | jq -c --arg n "${name}" '[.status.resources[]? | select(.name == $n) | {sync: .status, health: (.health.status // null)}]' 2>/dev/null || true)"
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
  j="$(kubectl get application "${APP}" -n argocd -o json 2>/dev/null || true)"
  echo "  [RECAP s03_l04] $1 judged value: [${2:-empty}]"
  echo "  [RECAP s03_l04] exits: broken sync ${sync_rc}, hard-refresh ${hr_rc}, good sync ${good_sync_rc} (124 = the bound fired); timeline first health: ${TL_FIRST:-not read}"
  printf '%s' "${j}" | jq -r '"  [RECAP s03_l04] app sync=\(.status.sync.status // "unknown") health=\(.status.health.status // "unknown") opPhase=\(.status.operationState.phase // "none") initiatedBy=\(.status.operationState.operation.initiatedBy // "none") reconciledAt=\(.status.reconciledAt // "none") opFinishedAt=\(.status.operationState.finishedAt // "none")"' 2>/dev/null \
    || echo "  [RECAP s03_l04] app: not readable"
  printf '%s' "${j}" | jq -r '"  [RECAP s03_l04] rows: " + ([.status.resources[]? | select((.name // "") | startswith("s03l04")) | "\(.name)=\(.health.status // "null")"] | join(", "))' 2>/dev/null \
    || true
}

lesson S03-L04 "a Certificate reads Healthy by default before issuance; only the Lua health check reports the real Ready condition"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "preconditions from the TLS lesson (s02_l08.sh): cert-manager and selfsigned-issuer must already be on the cluster"
kubectl get deploy -n cert-manager >/dev/null 2>&1 \
  || _fail "no cert-manager deployment found: it comes from the TLS lesson (s02_l08.sh), not this one; run that lesson's setup before this script"
kubectl get clusterissuer selfsigned-issuer >/dev/null 2>&1 \
  || _fail "ClusterIssuer selfsigned-issuer not found: the TLS lesson's setup (s02_l08.sh) is missing; run it first"
_pass "cert-manager and selfsigned-issuer are present"
diag_cluster "after the TLS preconditions, before this script changes anything"

step "confirm the argocd Application (self-management) exists, name and shape from the self-management lesson (s02_l10.sh)"
kubectl get application argocd -n argocd >/dev/null 2>&1 \
  || _fail "no Application named 'argocd' in the argocd namespace: the self-management from s02_l10.sh is missing; this script cannot safely test the Lua-through-Git claim without it"

APP="s03l04-probe"
NS="s03l04-probe"
TMPDIR="$(mktemp -d)"
LUA_PATCH="${TMPDIR}/argocd-cm-patch.yaml"

cleanup() {
  # Restore argocd-cm to its committed (vanilla) shape...
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p '[{"op":"remove","path":"/data"}]' >/dev/null 2>&1 || true
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
cat <<EOF | kubectl apply -f - >/dev/null
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
EOF
diag_app "probe Application created, nothing synced yet (does it exist, what is its shape)"

step "sync a Certificate that can NEVER issue (bad issuerRef): no timing race, it stays Ready:False forever"
mkdir -p "${TMPDIR}/broken"
cat > "${TMPDIR}/broken/certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: s03l04-broken
spec:
  secretName: s03l04-broken-tls
  dnsNames: ["storefront.northwind.local"]
  issuerRef:
    name: s03l04-nonexistent-issuer
    kind: ClusterIssuer
EOF
t_sync="$(date -u +%H:%M:%S)"
sync_rc=0
sync_out="$(trap - ERR; argocd app sync "${APP}" --local "${TMPDIR}/broken" 2>&1)" || sync_rc=$?
echo "  [diag sync] broken Certificate: started ${t_sync}, returned $(date -u +%H:%M:%S), exit ${sync_rc} (124 means the 120 s bound fired; the exit code is still not judged)"
printf '%s\n' "${sync_out}" | head -n 25 | cut -c1-300 | sed 's/^/    sync output: /' || true
sleep 15

step "under DEFAULT (uncustomized) health rules, Argo CD reports it Healthy anyway"
health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-broken")].health.status}' 2>/dev/null || true)"
printf '  [diag check] judged value, raw jsonpath output: [%s]\n' "${health}"
diag_app "the default-rules read, same moment as the judged value"
diag_cluster "same moment as the default-rules read"
if [ "${health}" = "Healthy" ]; then
  _pass "a Certificate that will NEVER issue still reads Healthy under Argo CD's default rules: the false positive the lesson opens on"
else
  observe_timeline "s03l04-broken"
  recap "default-rules read" "${health}"
  _fail "expected the default rules to report Healthy for an unrecognized kind, got '${health:-empty}': either Argo CD gained a built-in cert-manager health check or this repo's default health behaviour has changed; the problem the lesson opens on no longer reproduces"
fi

step "write the Lua health check through a (temporary, self-cleaning) argocd-cm patch, not a live one-off edit"
kubectl patch application argocd -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null
cat > "${LUA_PATCH}" <<'EOF'
data:
  resource.customizations.health.cert-manager.io_Certificate: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" then
          if condition.status == "False" then
            hs.status = "Progressing"
            hs.message = condition.message
            return hs
          end
          if condition.status == "True" then
            hs.status = "Healthy"
            hs.message = condition.message
            return hs
          end
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate status"
    return hs
EOF
kubectl patch configmap argocd-cm -n argocd --type merge --patch-file "${LUA_PATCH}" >/dev/null
diag_cluster "after the Lua override was written (the cert-manager Certificate key should now be listed; selfHeal should read false)"

step "same never-issuing Certificate, now reads honest: Progressing, not Healthy"
hr_rc=0
hr_out="$(trap - ERR; argocd app get "${APP}" --hard-refresh 2>&1)" || hr_rc=$?
echo "  [diag] argocd app get --hard-refresh: exit ${hr_rc} (124 means the 30 s bound fired), first line: $(printf '%s' "${hr_out}" | head -n 1 | cut -c1-200 || true)"
deadline=$(( $(date +%s) + 60 ))
health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-broken")].health.status}' 2>/dev/null || true)"
  [ "${health}" = "Progressing" ] && break
  sleep 5
done
if [ "${health}" = "Progressing" ]; then
  _pass "with the Lua check active, the same never-issuing Certificate now reads Progressing: health tracks the real Ready condition"
else
  diag_app "the Lua-active read, after the 60 s poll (the Certificate row should read Progressing)"
  recap "Lua-active read" "${health}"
  _fail "expected Progressing once the Lua health check was active, got '${health:-empty}': the Lua customization did not take effect, or its condition-reading logic is broken"
fi

step "a Certificate that CAN issue reads Healthy only once it genuinely is"
mkdir -p "${TMPDIR}/good"
cat > "${TMPDIR}/good/certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: s03l04-good
spec:
  secretName: s03l04-good-tls
  dnsNames: ["storefront.northwind.local"]
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
EOF
t_good="$(date -u +%H:%M:%S)"
good_sync_rc=0
good_sync_out="$(trap - ERR; argocd app sync "${APP}" --local "${TMPDIR}/good" 2>&1)" || good_sync_rc=$?
echo "  [diag sync] good Certificate: started ${t_good}, returned $(date -u +%H:%M:%S), exit ${good_sync_rc} (124 means the 120 s bound fired; the exit code is still not judged)"
printf '%s\n' "${good_sync_out}" | head -n 25 | cut -c1-300 | sed 's/^/    sync output: /' || true
deadline=$(( $(date +%s) + 90 ))
good_health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
  good_health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-good")].health.status}' 2>/dev/null || true)"
  [ "${good_health}" = "Healthy" ] && break
  sleep 5
done
if [ "${good_health}" = "Healthy" ]; then
  _pass "the real Certificate reached Ready and the Lua check reported Healthy: the honest positive case, not just an always-Progressing stub"
else
  diag_app "the real Certificate, after the 90 s poll (the good row should read Healthy)"
  recap "good Certificate read" "${good_health}"
  _fail "the real Certificate never read Healthy under the Lua check (got '${good_health:-empty}'): either issuance failed or the check's True-condition branch is broken"
fi

smoke_done
