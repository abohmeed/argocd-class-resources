#!/usr/bin/env bash
# S05 L02 — Sealed Secrets: cluster-scoped encryption, end to end.
#
# Two claims worth defending here, both behavioural, not textual. First: a SealedSecret really is
# opaque ciphertext that the controller — and only the controller, with its private key — can turn
# back into the exact credential that went in. Second, and the one a demo alone won't show: the
# default `strict` scope ties that ciphertext to ONE namespace and ONE Secret name. The same
# SealedSecret object, copied into a different namespace, must NOT decrypt there — if it ever did,
# `strict` would be theatre, not a real access boundary. Runs entirely in scratch namespaces this
# script owns and tears down; it never touches the shared `checkout` Application.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S05-L02 "a SealedSecret decrypts to the exact credential sealed, and ONLY in the namespace it was scoped to"
tier cluster

LESSON_ID="s05l02"
NS_A="${LESSON_ID}-a"
NS_B="${LESSON_ID}-b"
WORKDIR="$(mktemp -d)"
SECRET_VALUE="probe-${LESSON_ID}-$(date +%s)"

cleanup() {
  kubectl delete sealedsecret probe -n "${NS_A}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete sealedsecret probe -n "${NS_B}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace "${NS_A}" --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS_B}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

step "the Sealed Secrets controller is installed, at the pinned version and the CURRENT bitnami org"
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets >/dev/null 2>&1 \
  || kubectl apply -f "https://github.com/bitnami/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/controller.yaml" >/dev/null
kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s >/dev/null 2>&1 \
  || _fail "sealed-secrets controller did not become ready"
image="$(kubectl get deployment sealed-secrets-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].image}')"
case "${image}" in
  bitnami/sealed-secrets:*) _pass "controller image is ${image} — the current bitnami org, not the retired bitnami-labs" ;;
  *) _fail "controller image is ${image} — expected bitnami/sealed-secrets:*; bitnami-labs is retired and the wrong org would 404 a student's pull" ;;
esac

step "seal a scratch credential, strict-scoped to namespace ${NS_A}, and confirm the cluster decrypts it back"
kubectl create namespace "${NS_A}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubeseal --fetch-cert --controller-namespace kube-system > "${WORKDIR}/pub-cert.pem"
cat > "${WORKDIR}/secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: probe
  namespace: ${NS_A}
type: Opaque
stringData:
  password: "${SECRET_VALUE}"
EOF
kubeseal --cert "${WORKDIR}/pub-cert.pem" --format=yaml < "${WORKDIR}/secret.yaml" > "${WORKDIR}/sealed.yaml"
if grep -qE '^\s*password: [A-Za-z0-9+/=]{20,}$' "${WORKDIR}/sealed.yaml"; then
  _fail "sealed.yaml's password field still looks like plain base64 of the plaintext, not SealedSecrets ciphertext"
fi
kubectl apply -f "${WORKDIR}/sealed.yaml" >/dev/null
decrypted=""
for _ in $(seq 1 20); do
  decrypted="$(kubectl get secret probe -n "${NS_A}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ "${decrypted}" = "${SECRET_VALUE}" ] && break
  sleep 3
done
[ "${decrypted}" = "${SECRET_VALUE}" ] \
  && _pass "controller decrypted the SealedSecret back to the exact value sealed" \
  || _fail "SealedSecret in ${NS_A} never decrypted to '${SECRET_VALUE}' (got '${decrypted}') — Sealed Secrets is broken or mis-scoped"

step "the SAME ciphertext, moved to namespace ${NS_B}, must NOT decrypt there — strict scope is a real boundary"
kubectl create namespace "${NS_B}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
sed "s/namespace: ${NS_A}/namespace: ${NS_B}/" "${WORKDIR}/sealed.yaml" > "${WORKDIR}/sealed-wrong-ns.yaml"
kubectl apply -f "${WORKDIR}/sealed-wrong-ns.yaml" >/dev/null
sleep 15
if kubectl get secret probe -n "${NS_B}" >/dev/null 2>&1; then
  _fail "a SealedSecret sealed for ${NS_A} decrypted in ${NS_B} — strict scope is not actually enforced; this is exactly the silent cross-namespace leak the lesson says cannot happen"
else
  _pass "the SealedSecret does NOT decrypt in ${NS_B} — strict scope really does tie ciphertext to the namespace it was sealed for"
fi

smoke_done
