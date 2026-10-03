#!/usr/bin/env bash
# S06 L03 — why a plain Job isn't enough.
#
# The claim is a Kubernetes API-server fact, not an Argo CD one: a live Job's `spec.template` is
# immutable, so editing a tracked Job's command and re-applying is REJECTED at the API level — the
# object on the cluster never changes. That is the mechanism the lesson explains ("argocd app diff
# sees nothing" is a direct consequence of the live spec never moving); it is proven here with
# plain kubectl against a scratch Job, without pushing a commit to the companion repo just to drive
# an `argocd app diff` for a corollary that follows automatically once the API-level fact holds.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S06-L03 "a live Job's spec.template is immutable — the API server rejects the edit, so nothing ever runs a second time"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

LESSON_ID="s06l03"
NS="${LESSON_ID}-probe"

cleanup() {
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "create the scratch Job, and let it complete"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: probe
  namespace: ${NS}
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: busybox:1.37
          command: ["sh", "-c", "echo original-command"]
EOF
kubectl wait --for=condition=complete job/probe -n "${NS}" --timeout=90s >/dev/null 2>&1 \
  || _fail "scratch Job never completed — cannot test immutability against a Job that isn't even running"
first_completion="$(kubectl get job probe -n "${NS}" -o jsonpath='{.status.completionTime}')"
_pass "Job completed at ${first_completion}"

step "edit the Job's command and try to apply the change to the LIVE object"
out="$(kubectl apply --dry-run=server -f - 2>&1 <<EOF || true
apiVersion: batch/v1
kind: Job
metadata:
  name: probe
  namespace: ${NS}
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: busybox:1.37
          command: ["sh", "-c", "echo EDITED-command"]
EOF
)"
if printf '%s' "${out}" | grep -qiE 'immutable|field is immutable|may not be updated'; then
  _pass "the API server rejected the edit as immutable — exactly what the lesson says happens"
else
  _fail "editing spec.template did NOT get rejected as immutable (server said: ${out}) — this lesson's central claim does not reproduce against the current Kubernetes API; RESTAGE before recording"
fi

step "confirm the live Job genuinely never re-ran — same completion time, no second attempt"
kubectl apply -f - >/dev/null 2>&1 <<EOF || true
apiVersion: batch/v1
kind: Job
metadata:
  name: probe
  namespace: ${NS}
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: busybox:1.37
          command: ["sh", "-c", "echo EDITED-command"]
EOF
second_completion="$(kubectl get job probe -n "${NS}" -o jsonpath='{.status.completionTime}')"
[ "${first_completion}" = "${second_completion}" ] \
  && _pass "completion time is unchanged (${second_completion}) — the edited logic never ran" \
  || _fail "completion time changed from ${first_completion} to ${second_completion} — something re-ran the Job, which should be impossible for an unrecreated live Job"

smoke_done
