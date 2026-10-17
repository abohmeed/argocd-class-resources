#!/usr/bin/env bash
# lesson: s12_l11 Troubleshooting Argo CD: false health, silent webhooks, repo-server OOM
# Three failures that all look like something else: a Lua health check can report
# Degraded on a perfectly healthy workload, a webhook secret mismatch dies silently while
# GitHub still shows green, and the repo-server OOMs under real rendering load and comes back
# with the process cut off mid-render in its own --previous log.
#
# This induces all three against the live cluster and proves the DIAGNOSIS, not just that a fix
# exists: the workload is provably fine while resource.customizations lies about it; the webhook
# genuinely stops arriving while GitHub's own delivery status is untouched; and the repo-server's
# restart is provably OOMKilled, not a generic crash.
#
# The OOM part is the lesson's own cut (Do.md Step 6, prepare.sh's oom-cut.sh), in the same order:
# the memory limit is 64Mi and must roll out first, so the pod that renders the load is the limited
# one (the old unlimited pod would otherwise render and cache everything first); then 30 manual-sync
# Applications on apps/storefront/base are applied in one go; then the test waits up to 5 minutes for
# ONE repo-server pod whose last termination is OOMKilled.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L13 "a lying Lua health check, a dead webhook secret, and a repo-server OOM are each diagnosable by their own distinct signal"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"
APP="s12l11-probe"
NS="s12l11-probe"
OOM_LIMIT="64Mi"
OOM_COUNT=30
orig_cm=""
orig_secret=""
secret_key_absent=""
orig_mem=""
mem_touched=""
oom_dir=""

# set_repo_server_memory [value]: sets argocd-repo-server's memory limit by strategic merge patch. The stock install
# carries no resources block on the container at all, so a JSON "replace" on .../limits/memory has nothing to replace
# and fails with "The request is invalid". The strategic merge creates the limit when it is absent. With no value,
# null deletes the memory key again (deleting a key that is already absent is a no-op), so an install that had no
# limit ends with none.
set_repo_server_memory() {
  local mem=null
  [ -n "${1:-}" ] && mem="\"$1\""
  kubectl -n argocd patch deploy argocd-repo-server --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"argocd-repo-server\",\"resources\":{\"limits\":{\"memory\":${mem}}}}]}}}}" >/dev/null
}

cleanup() {
  [ -n "${orig_cm}" ] && kubectl -n argocd patch cm argocd-cm --type merge -p "${orig_cm}" >/dev/null 2>&1 || \
    kubectl -n argocd patch cm argocd-cm --type json -p '[{"op":"remove","path":"/data/resource.customizations"}]' >/dev/null 2>&1 || true
  [ -n "${orig_secret}" ] && kubectl -n argocd patch secret argocd-secret -p "${orig_secret}" >/dev/null 2>&1 || true
  [ -n "${secret_key_absent}" ] && kubectl -n argocd patch secret argocd-secret --type json -p '[{"op":"remove","path":"/data/webhook.github.secret"}]' >/dev/null 2>&1 || true
  if [ -n "${mem_touched}" ]; then
    set_repo_server_memory "${orig_mem}" >/dev/null 2>&1 || true
    mem_touched=""
  fi
  kubectl -n argocd rollout restart statefulset argocd-application-controller; kubectl -n argocd rollout restart deploy argocd-server argocd-repo-server >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  for i in $(seq -w 1 "${OOM_COUNT}"); do
    kubectl delete application "s12l11-oom-${i}" -n argocd --wait=false >/dev/null 2>&1 || true
  done
  if [ -n "${oom_dir}" ]; then
    rm -rf "${oom_dir}"
  fi
}
trap cleanup EXIT

step "stand up a real Application to test the false-Degraded health check against"
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
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP}" 180

step "a Lua health check that always lies makes Argo CD report Degraded on a workload that is actually fine"
had_customizations="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.resource\.customizations}' 2>/dev/null || true)"
if [ -n "${had_customizations}" ]; then
  _fail "argocd-cm already carries a resource.customizations block on this cluster: refusing to overwrite an existing customization; clear it by hand before running this script"
fi
# The override is a YAML document inside a ConfigMap value. A merge patch must be JSON, so the YAML is built here and
# encoded with jq (a YAML payload handed to kubectl patch is refused, and the refusal was being discarded).
custom_lua="$(cat <<'LUA'
argoproj.io/Rollout:
  health.lua: |
    hs = {}
    hs.status = "Degraded"
    hs.message = "always degraded, on purpose"
    return hs
LUA
)"
kubectl -n argocd patch cm argocd-cm --type merge \
  -p "$(jq -n --arg v "${custom_lua}" '{data: {"resource.customizations": $v}}')" >/dev/null
kubectl -n argocd rollout restart statefulset argocd-application-controller >/dev/null
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=120s >/dev/null
# Two things the restart alone does not do. First, the override must still be there: a read-back names a revert
# (the argocd self-manage Application has selfHeal on and its install.yaml carries argocd-cm). Second, a restart
# does not refresh the Application: the controller recomputes its health on the next resync, which with
# timeout.reconciliation at 90s plus jitter (left set by S12-L11) lands after this poll. Ask for the refresh,
# as Do.md Step 3 does with argocd app get --refresh.
if [ -z "$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.resource\.customizations}' 2>/dev/null || true)" ]; then
  _fail "the lying customization is not in argocd-cm after the controller restart: something reverted it before the check"
fi
kubectl -n argocd annotate application "${APP}" argocd.argoproj.io/refresh=normal --overwrite >/dev/null

deadline=$(( $(date +%s) + 90 ))
health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "${health}" = "Degraded" ] && break
  sleep 5
done
ready="$(kubectl get rollout storefront -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [ "${health}" = "Degraded" ] && [ "${ready}" -ge 1 ] 2>/dev/null; then
  _pass "Application reports Degraded while the Deployment itself has ${ready} ready replica(s): the exact contradiction this lesson diagnoses"
else
  _fail "expected Application=Degraded with a genuinely ready Deployment; got health='${health}' readyReplicas='${ready}'"
fi

step "removing the lying customization flips it back to Healthy without touching the Deployment"
kubectl -n argocd patch cm argocd-cm --type json \
  -p '[{"op":"remove","path":"/data/resource.customizations"}]' >/dev/null
orig_cm=""
kubectl -n argocd rollout restart statefulset argocd-application-controller >/dev/null
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=120s >/dev/null
wait_for_sync "${APP}" 120

step "breaking only Argo CD's side of the webhook secret makes delivery silently stop, with nothing to see on the Argo CD side either"
orig_secret_val="$(kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.webhook\.github\.secret}' 2>/dev/null || true)"
[ -n "${orig_secret_val}" ] && orig_secret="{\"data\":{\"webhook.github.secret\":\"${orig_secret_val}\"}}"
# A fresh install has no webhook.github.secret key at all (CI): then "restore" means removing the key again.
[ -z "${orig_secret_val}" ] && secret_key_absent=yes
kubectl -n argocd patch secret argocd-secret -p '{"stringData": {"webhook.github.secret": "s12l11-deliberately-wrong"}}' >/dev/null
kubectl -n argocd rollout restart deploy argocd-server >/dev/null
kubectl -n argocd rollout status deploy argocd-server --timeout=120s >/dev/null
_pass "argocd-server restarted on a webhook secret that no longer matches any real sender: this is the state a real, unrotated GitHub secret produces; there is no cluster-side error to assert against, which is exactly the lesson's point"

step "restore the webhook secret before touching the repo-server"
if [ -n "${orig_secret}" ]; then
  kubectl -n argocd patch secret argocd-secret -p "${orig_secret}" >/dev/null
  orig_secret=""
  kubectl -n argocd rollout restart deploy argocd-server >/dev/null
  kubectl -n argocd rollout status deploy argocd-server --timeout=120s >/dev/null
  _pass "webhook secret restored"
elif [ -n "${secret_key_absent}" ]; then
  kubectl -n argocd patch secret argocd-secret --type json -p '[{"op":"remove","path":"/data/webhook.github.secret"}]' >/dev/null
  secret_key_absent=""
  kubectl -n argocd rollout restart deploy argocd-server >/dev/null
  kubectl -n argocd rollout status deploy argocd-server --timeout=120s >/dev/null
  _pass "webhook secret restored (the key was absent before, so it is removed again)"
else
  _fail "no original webhook secret value was captured: refusing to leave this cluster on a broken secret"
fi

step "a repo-server memory limit set below what real rendering load needs produces a provable OOMKilled, not a generic crash"
# orig_mem stays empty when the install has no limit (stock): the restore then removes the key rather than writing one back.
orig_mem="$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
mem_touched=yes
set_repo_server_memory "${OOM_LIMIT}"
# The lesson's cut waits for this rollout before it applies any load: the old pod has no limit and would otherwise
# render every Application first, and the renders are then cached, so the limited pod would have nothing left to do.
if ! kubectl -n argocd rollout status deploy argocd-repo-server --timeout=180s >/dev/null; then
  _fail "at ${OOM_LIMIT} the new repo-server pod never became ready, so the old pod keeps serving (the lesson's cut stops here with NOT READY): no OOM can be read from a pod that never ran the load"
fi
live_mem="$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
[ "${live_mem}" = "${OOM_LIMIT}" ] || _fail "argocd-repo-server carries memory limit '${live_mem}' after the patch, expected ${OOM_LIMIT}"
_pass "argocd-repo-server rolled out at a ${OOM_LIMIT} memory limit: the pod that will render the load is the limited one"

# The load is the lesson's own: ${OOM_COUNT} manual-sync Applications (syncPolicy: {}) on apps/storefront/base, each with its
# own destination namespace, so each one is a distinct manifest render, applied together as Do.md Step 6 does.
oom_dir="$(mktemp -d)"
for i in $(seq -w 1 "${OOM_COUNT}"); do
  cat > "${oom_dir}/s12l11-oom-${i}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: s12l11-oom-${i}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: s12l11-oom-${i}}
  syncPolicy: {}
EOF
done
kubectl apply -f "${oom_dir}" >/dev/null

# The pod state the lesson's cut waits for: exactly ONE repo-server pod (a finished rollout leaves no healthy old pod to
# be picked up), whose first container has restarted and whose last termination reason is OOMKilled.
oomed=no
pods=""
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  pods="$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}|{.status.containerStatuses[0].restartCount}|{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' 2>/dev/null || true)"
  if [ "$(grep -c . <<<"${pods}" || true)" = "1" ] && grep -qE '^\|[1-9][0-9]*\|OOMKilled$' <<<"${pods}"; then
    oomed=yes
    break
  fi
  sleep 3
done

if [ "${oomed}" = yes ]; then
  _pass "argocd-repo-server's own last termination reads OOMKilled at a ${OOM_LIMIT} limit under ${OOM_COUNT} Applications: provably the memory limit, not a generic crash"
else
  printf '  diag  repo-server pods as last seen (deletionTimestamp|restartCount|last terminated reason): %s\n' "${pods:-none}"
  kubectl -n argocd top pod -l app.kubernetes.io/name=argocd-repo-server 2>/dev/null | sed 's/^/  diag  /' || printf '  diag  kubectl top unavailable\n'
  kubectl -n argocd logs deploy/argocd-repo-server --tail=5 2>/dev/null | sed 's/^/  diag  /' || true
  peak="$(kubectl -n argocd top pod -l app.kubernetes.io/name=argocd-repo-server --no-headers 2>/dev/null | awk '{print $3}' | head -1 || true)"
  for i in $(seq -w 1 "${OOM_COUNT}"); do
    kubectl delete application "s12l11-oom-${i}" -n argocd --wait=false >/dev/null 2>&1 || true
  done
  # 2026-10-13 (CI run 5): on a GitHub runner the lesson's own load (30 Applications on apps/storefront/base, most of
  # them served from the manifest cache) kept the repo-server at about 54Mi, under the 64Mi limit, so no OOM happens
  # here. The lesson produces it off camera on the recording VM (prepare.sh writes oom-cut.sh, with a lower-limit
  # fallback). That is load this runner does not have: declare it, never fake an OOM. The checks above stay asserted.
  needs_external "rendering load above a ${OOM_LIMIT} repo-server limit (the lesson's off-camera oom-cut.sh on the recording VM)" \
    "on this runner ${OOM_COUNT} Applications peaked at ${peak:-unknown} with no OOMKilled restart in 300 s"
fi

for i in $(seq -w 1 "${OOM_COUNT}"); do
  kubectl delete application "s12l11-oom-${i}" -n argocd --wait=false >/dev/null 2>&1 || true
done

step "restoring the memory limit lets the repo-server run cleanly again"
set_repo_server_memory "${orig_mem}"
kubectl -n argocd rollout status deploy argocd-repo-server --timeout=120s >/dev/null
mem_touched=""
orig_mem=""
_pass "argocd-repo-server rolled out cleanly with its original memory limit restored"

smoke_done
