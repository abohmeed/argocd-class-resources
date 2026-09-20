#!/usr/bin/env bash
# S06 L05 — hook deletion policies and the debris problem.
#
# The claim: a hook with NO delete policy is created fresh on every sync and never cleaned up, so
# repeated syncs pile up completed Jobs forever; `BeforeHookCreation` caps that at exactly one;
# and `HookSucceeded` only sweeps a hook that actually succeeded, so a hook that fails is left
# standing on purpose (the failure evidence isn't supposed to vanish). Driven through a scratch
# Argo CD Application synced with `--local`, so this proves real hook-lifecycle behaviour without
# pushing throwaway commits to the companion repo. Uses a trivial command instead of the lesson's
# real SQL migration — debris counting and delete-policy timing don't depend on what the hook's
# command actually does, only on Argo CD's own hook bookkeeping.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l05"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
WORKDIR="$(mktemp -d)"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

lesson S06-L05 "no delete policy piles up hook Jobs forever; BeforeHookCreation caps it at one; HookSucceeded never sweeps a failure"
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
  generateName: probe-hook-
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

step "no delete policy at all — repeated syncs pile up debris"
write_manifests "true" ""
for _ in 1 2 3; do
  argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
  sleep 2
done
count="$(kubectl get jobs -n "${NS}" -l 'argocd.argoproj.io/instance' --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ -n "${count}" ] || count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [ "${count}" -ge 3 ]; then
  _pass "3 syncs with no delete policy left ${count} hook Jobs behind — this is the debris the lesson names"
else
  _fail "expected at least 3 accumulated hook Jobs with no delete policy, found ${count} — hooks may be getting swept when the lesson says they should not be"
fi
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true

step "BeforeHookCreation — never more than one hook Job standing, no matter how many syncs"
write_manifests "true" "BeforeHookCreation"
for _ in 1 2 3; do
  argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
  sleep 3
done
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${count}" -eq 1 ] \
  && _pass "exactly one hook Job present after 3 syncs under BeforeHookCreation" \
  || _fail "expected exactly 1 Job under BeforeHookCreation, found ${count} — the previous hook is not being deleted before the new one is created"
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true

step "HookSucceeded — a successful hook is swept on the NEXT successful sync"
write_manifests "true" "HookSucceeded"
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
sleep 5
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
sleep 5
count="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${count}" -eq 1 ] \
  && _pass "exactly one Job present after two successful syncs under HookSucceeded — the earlier success was swept" \
  || _fail "expected exactly 1 Job after two successful HookSucceeded syncs, found ${count}"

step "HookSucceeded — a FAILED hook is left standing, on purpose"
kubectl delete jobs -n "${NS}" --all >/dev/null 2>&1 || true
write_manifests "exit 1" "HookSucceeded"
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
sleep 10
failed_count="$(kubectl get jobs -n "${NS}" -o jsonpath='{range .items[?(@.status.failed>=1)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')"
[ "${failed_count}" -ge 1 ] \
  && _pass "the failed hook Job is still present (HookSucceeded only sweeps successes) — the failure evidence isn't erased" \
  || _fail "no failed hook Job found standing — either the hook didn't actually fail, or HookSucceeded swept a failure it should have left alone"

smoke_done
