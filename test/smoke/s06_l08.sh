#!/usr/bin/env bash
# lesson: s06_l08 PreDelete and PostDelete hooks: cleaning up what Kubernetes never owned
# A PreDelete hook is what makes Argo CD hold an Application open to back up what it is about to delete.
#
# Two claims, checked two ways.
#
# 1. Cluster-tier, and it runs here: a PreDelete hook in the Application's manifests makes Argo CD add
#    `pre-delete-finalizer.argocd.argoproj.io` (and its /cleanup companion) to the Application. Do.md step 3
#    expects exactly that pair on screen, so the script checks the same two strings. Driven through a scratch
#    Application synced from local manifests, which is how this suite proves hook behaviour without
#    pushing to the companion repo.
#
# 2. The runtime part is declared external below. The lesson's backup runs when the checkout Application is
#    DELETED, and Argo CD runs a PreDelete hook from the Application's source. The lesson gets that hook into
#    the source by committing predelete-backup-job.yaml to apps/checkout/base and pushing it (Do.md step 2).
#    A --local sync does not put the hook where a deletion looks, so the backup cannot be observed here
#    without that push, and the CI token is read-only by design (smoke.yml: contents: read).
#
# The earlier version of this script drove a PostDelete hook. The lesson was restored to PreDelete on
# 2026-10-03 (Do.md header), so this script follows the lesson.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l08"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
WORKDIR="$(mktemp -d)"

lesson S06-L08 "a PreDelete hook makes Argo CD add pre-delete-finalizer to the Application, which holds it open for the backup"
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

cat > "${WORKDIR}/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - predelete-backup-job.yaml
YAML
cat > "${WORKDIR}/deployment.yaml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: probe}
  template:
    metadata:
      labels: {app: probe}
    spec:
      containers:
        - name: probe
          image: ${HTTP_ECHO_IMAGE}
          args: ["-listen=:5678", "-text=probe"]
YAML
# The lesson's Step 1 manifest, with the probe's namespace in place of checkout's.
cat > "${WORKDIR}/predelete-backup-job.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: probe-predelete-backup
  namespace: ${NS}
  annotations:
    argocd.argoproj.io/hook: PreDelete
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: backup
          image: busybox:1.37
          command: ["sh", "-c", "echo backed-up > /dev/null"]
YAML

argocd app create "${APP}" --repo "${REPO}" --path apps/checkout/base \
  --dest-namespace "${NS}" --dest-server https://kubernetes.default.svc \
  --sync-policy none >/dev/null

step "sync the workload and the PreDelete hook from local manifests (the hook is not run by a sync)"
argocd_sync_local "${APP}" "${WORKDIR}" 120 || _fail "the scratch Application did not finish its sync within 120s"
rollout_ok=no
kubectl rollout status deployment/probe -n "${NS}" --timeout=120s >/dev/null 2>&1 && rollout_ok=yes
[ "${rollout_ok}" = yes ] && _pass "the scratch workload is Ready" || _fail "the scratch workload never became Ready"
backup_jobs="$(kubectl get jobs -n "${NS}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
[ "${backup_jobs}" -eq 0 ] && _pass "no backup Job ran during the sync: a PreDelete hook waits for the deletion" \
  || _fail "a backup Job exists after a plain sync (${backup_jobs}): a PreDelete hook should not run on sync"

step "the Application carries the PreDelete finalizers Argo CD adds when it sees the hook (Do.md step 3)"
fin="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.metadata.finalizers}' 2>/dev/null || true)"
case "${fin}" in
  *'pre-delete-finalizer.argocd.argoproj.io'*'pre-delete-finalizer.argocd.argoproj.io/cleanup'*)
    _pass "Argo CD added pre-delete-finalizer.argocd.argoproj.io and its /cleanup companion: the Application will be held for the hook" ;;
  *) _fail "expected the pre-delete finalizer pair on ${APP}, got '${fin:-none}': without it the deletion would not wait for the backup" ;;
esac

needs_external "a Git push of the PreDelete hook into the companion repo, then a real deletion of an Application sourced from it" \
  "the runtime proof needs the hook in the Application's Git source, and the lesson's own step 2 gets it there with a commit and push; this CI token is read-only by design (smoke.yml permissions: contents: read), so the backup cannot be observed on a CI cluster"

smoke_done
