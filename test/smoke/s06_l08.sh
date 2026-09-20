#!/usr/bin/env bash
# S06 L08 — PostDelete: cleaning up what Kubernetes never owned.
#
# The claim: the `resources-finalizer.argocd.argoproj.io` finalizer holds an Application object in
# place long enough for its PostDelete hook to run BEFORE the workload it backs up is gone, and a
# PostDelete backup written to a hostPath survives the namespace deletion that follows it — it has
# to, since the whole point of a PostDelete backup is outliving the thing being torn down. Proven
# against a scratch Application/namespace this script owns; it never touches the shared `checkout`
# Application the real lesson deletes and recreates.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

LESSON_ID="s06l08"
APP="${LESSON_ID}-probe"
NS="${LESSON_ID}-probe"
BACKUP_DIR="/tmp/${LESSON_ID}-backup"
REPO="https://github.com/abohmeed/argocd-class-resources.git"

lesson S06-L08 "a PostDelete hook backs up before teardown, and the finalizer holds the Application open long enough to let it"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

cleanup() {
  kubectl delete pod "${LESSON_ID}-checker" -n default --ignore-not-found >/dev/null 2>&1 || true
  kubectl run "${LESSON_ID}-cleaner" --image=busybox:1.37 --restart=Never -n default \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"cleaner\",\"image\":\"busybox:1.37\",\"command\":[\"rm\",\"-rf\",\"/backup\"],\"volumeMounts\":[{\"name\":\"backup\",\"mountPath\":\"/backup\"}]}],\"volumes\":[{\"name\":\"backup\",\"hostPath\":{\"path\":\"${BACKUP_DIR}\",\"type\":\"DirectoryOrCreate\"}}]}}" \
    >/dev/null 2>&1 || true
  sleep 3
  kubectl delete pod "${LESSON_ID}-cleaner" -n default --ignore-not-found --wait=false >/dev/null 2>&1 || true
  argocd app delete "${APP}" --cascade --yes >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

argocd app create "${APP}" --repo "${REPO}" --path apps/checkout/base \
  --dest-namespace "${NS}" --dest-server https://kubernetes.default.svc \
  --sync-policy none >/dev/null

step "the Application carries the finalizer that makes a controlled deletion possible"
kubectl patch application "${APP}" -n argocd --type merge \
  -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null
fin="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.metadata.finalizers}')"
case "${fin}" in
  *resources-finalizer.argocd.argoproj.io*) _pass "resources-finalizer.argocd.argoproj.io present on ${APP}" ;;
  *) _fail "resources-finalizer.argocd.argoproj.io is missing from ${APP} — deletion would remove the Application immediately, with no chance for a PostDelete hook to run" ;;
esac

step "sync a scratch workload plus a PostDelete backup hook"
WORKDIR="$(mktemp -d)"
cat > "${WORKDIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - backup-job.yaml
EOF
cat > "${WORKDIR}/deployment.yaml" <<EOF
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
EOF
cat > "${WORKDIR}/backup-job.yaml" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: probe-postdelete-backup
  namespace: ${NS}
  annotations:
    argocd.argoproj.io/hook: PostDelete
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: backup
          image: busybox:1.37
          command: ["sh", "-c", "mkdir -p /backup && echo backed-up-$(date +%s) > /backup/marker.txt"]
          volumeMounts:
            - name: backup
              mountPath: /backup
      volumes:
        - name: backup
          hostPath:
            path: ${BACKUP_DIR}
            type: DirectoryOrCreate
EOF
argocd app sync "${APP}" --local "${WORKDIR}" >/dev/null 2>&1 || true
kubectl rollout status deployment/probe -n "${NS}" --timeout=90s >/dev/null 2>&1 \
  || _fail "scratch workload never became Ready — cannot test PostDelete teardown against it"
rm -rf "${WORKDIR}"

step "delete the Application for real, and confirm the PostDelete hook runs before it's gone"
argocd app delete "${APP}" --cascade --yes >/dev/null 2>&1 || true
gone=no
for _ in $(seq 1 30); do
  kubectl get application "${APP}" -n argocd >/dev/null 2>&1 || { gone=yes; break; }
  sleep 3
done
[ "${gone}" = yes ] \
  && _pass "Application ${APP} fully deleted" \
  || _fail "Application ${APP} did not finish deleting within 90s — check whether the PostDelete hook is stuck"

step "the backup landed on the node BEFORE the namespace it protected disappeared"
kubectl delete pod "${LESSON_ID}-checker" -n default --ignore-not-found >/dev/null 2>&1 || true
kubectl run "${LESSON_ID}-checker" --image=busybox:1.37 --restart=Never -n default \
  --overrides="{\"spec\":{\"containers\":[{\"name\":\"checker\",\"image\":\"busybox:1.37\",\"command\":[\"cat\",\"/backup/marker.txt\"],\"volumeMounts\":[{\"name\":\"backup\",\"mountPath\":\"/backup\"}]}],\"volumes\":[{\"name\":\"backup\",\"hostPath\":{\"path\":\"${BACKUP_DIR}\",\"type\":\"DirectoryOrCreate\"}}]}}" \
  >/dev/null
kubectl wait --for=condition=Ready=false pod/"${LESSON_ID}-checker" -n default --timeout=30s >/dev/null 2>&1 || true
marker="$(kubectl logs "${LESSON_ID}-checker" -n default 2>/dev/null || true)"
kubectl delete pod "${LESSON_ID}-checker" -n default --ignore-not-found >/dev/null 2>&1 || true
case "${marker}" in
  backed-up-*) _pass "PostDelete backup file is present on the node: '${marker}' — it ran and survived the namespace it protected" ;;
  *) _fail "no backup marker found on the node (got '${marker}') — the PostDelete hook either did not run or did not complete before teardown" ;;
esac

smoke_done
