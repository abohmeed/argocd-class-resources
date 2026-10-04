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

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

cleanup() {
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

step "no delete policy at all: the default BeforeHookCreation leaves exactly one Job"
write_manifests "true" ""
for _ in 1 2 3; do
  argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
  sleep 3
done
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${count}" -eq 1 ]; then
  _pass "3 syncs with no delete policy left exactly one hook Job: the implicit BeforeHookCreation replaced each earlier run, as the lesson now opens on"
else
  _fail "expected exactly 1 hook Job after 3 syncs with no delete policy (default BeforeHookCreation), found ${count}"
fi
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true

step "BeforeHookCreation: never more than one hook Job standing, no matter how many syncs"
write_manifests "true" "BeforeHookCreation"
for _ in 1 2 3; do
  argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
  sleep 3
done
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${count}" -eq 1 ] \
  && _pass "exactly one hook Job present after 3 syncs under BeforeHookCreation" \
  || _fail "expected exactly 1 Job under BeforeHookCreation, found ${count}: the previous hook is not being deleted before the new one is created"
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true

step "HookSucceeded: a successful hook is swept once it succeeds"
write_manifests "true" "HookSucceeded"
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
count=1
for _ in $(seq 1 15); do
  count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [ "${count}" -eq 0 ] && break
  sleep 2
done
[ "${count}" -eq 0 ] \
  && _pass "no Job left after a successful sync under HookSucceeded: the success was swept" \
  || _fail "expected 0 Jobs after a successful HookSucceeded sync, found ${count}"

step "HookSucceeded: a FAILED hook is left standing, on purpose"
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true
write_manifests "exit 1" "HookSucceeded"
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
sleep 10
failed_count="$(kubectl get jobs -n "${NS}" -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
[ "${failed_count}" -ge 1 ] \
  && _pass "the failed hook Job is still present (HookSucceeded only sweeps successes): the failure evidence isn't erased" \
  || _fail "no failed hook Job found standing: either the hook didn't actually fail, or HookSucceeded swept a failure it should have left alone"

smoke_done
