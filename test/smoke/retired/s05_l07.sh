#!/usr/bin/env bash
# S05 L07 — securing Argo CD's own secrets: the chicken-and-egg problem.
#
# The claim is mechanical and doesn't need a real GitHub PAT to prove: Argo CD recognises a
# repository credential SOLELY by the label `argocd.argoproj.io/secret-type: repository` in the
# `argocd` namespace, and a SealedSecret can materialise that exact shape just as well as a
# manually-applied one — so rotating from "typed in by hand once" to "GitOps-managed" changes
# nothing about how Argo CD sees the credential. This script proves the label-driven recognition
# and the seal/decrypt chain with a throwaway scratch credential; it never touches Argo CD's real
# `argocd-class-resources-creds` Secret or any live GitHub token.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S05-L07 "a SealedSecret can materialise Argo CD's own repo-credential shape — the label is what makes it count, not how it got there"
tier cluster

LESSON_ID="s05l07"
SECRET_NAME="${LESSON_ID}-repo-creds-probe"
WORKDIR="$(mktemp -d)"
PROBE_VALUE="probe-${LESSON_ID}-$(date +%s)"

cleanup() {
  kubectl delete sealedsecret "${SECRET_NAME}" -n argocd --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${SECRET_NAME}" -n argocd --ignore-not-found >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

step "Sealed Secrets controller (S05 L02) is available to seal against"
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=60s >/dev/null 2>&1 \
  || _fail "sealed-secrets controller is not running — S05 L02 must land before this lesson"

step "build a SCRATCH repo-credential Secret with the exact shape Argo CD looks for, and seal it"
kubeseal --fetch-cert --controller-namespace kube-system > "${WORKDIR}/pub-cert.pem"
cat > "${WORKDIR}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://example.invalid/${LESSON_ID}.git
  username: probe-user
  password: "${PROBE_VALUE}"
EOF
kubeseal --cert "${WORKDIR}/pub-cert.pem" --format=yaml < "${WORKDIR}/secret.yaml" > "${WORKDIR}/sealed.yaml"
kubectl apply -f "${WORKDIR}/sealed.yaml" >/dev/null

step "confirm the controller decrypted it, with the label intact"
password=""
for _ in $(seq 1 20); do
  password="$(kubectl get secret "${SECRET_NAME}" -n argocd -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ "${password}" = "${PROBE_VALUE}" ] && break
  sleep 3
done
[ "${password}" = "${PROBE_VALUE}" ] \
  && _pass "the SealedSecret decrypted to the exact scratch credential sealed" \
  || _fail "the SealedSecret never decrypted to '${PROBE_VALUE}' (got '${password}')"

label="$(kubectl get secret "${SECRET_NAME}" -n argocd -o jsonpath='{.metadata.labels.argocd\.argoproj\.io/secret-type}' 2>/dev/null || true)"
[ "${label}" = "repository" ] \
  && _pass "the materialised Secret carries argocd.argoproj.io/secret-type: repository — the exact label Argo CD scans for" \
  || _fail "the materialised Secret's label is '${label}', not 'repository' — Argo CD's repo-credential scan would skip it silently, which is the failure mode this lesson warns about"

smoke_done
