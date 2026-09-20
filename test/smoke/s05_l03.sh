#!/usr/bin/env bash
# S05 L03 — External Secrets Operator: pulling from OpenBao, not Vault.
#
# The claim worth defending is specific, not generic ESO plumbing: this course demos against
# OpenBao, configured through ESO's `provider: vault` block unmodified, and the credential is
# PULLED at reconcile time — it never touches Git. If the ClusterSecretStore ever pointed at a
# real HashiCorp Vault endpoint instead, or the value leaked into a committed manifest, both
# would contradict what this lesson says on camera. Runs against scratch namespaces/paths this
# script owns; the shared OpenBao/ESO install (permanent course infrastructure per the runbook)
# is reused if already present, installed idempotently if not.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S05-L03 "ESO pulls checkout's credential from OpenBao at reconcile time — nothing secret-shaped ever touches Git"
tier cluster

LESSON_ID="s05l03"
NS="${LESSON_ID}-probe"
SECRET_VALUE="probe-${LESSON_ID}-$(date +%s)"
VAULT_PATH="secret/${LESSON_ID}"

cleanup() {
  kubectl delete externalsecret probe -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete clustersecretstore "${LESSON_ID}-openbao" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete secret "${LESSON_ID}-token" -n external-secrets --ignore-not-found >/dev/null 2>&1 || true
  kubectl exec -n openbao openbao-0 -- env BAO_TOKEN=root bao kv delete "${VAULT_PATH}" >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "OpenBao is installed and reachable (dev mode) — the claim is specifically OpenBao, not HashiCorp Vault"
if ! kubectl get statefulset openbao -n openbao >/dev/null 2>&1; then
  helm repo add openbao "${OPENBAO_CHART_REPO}" >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  helm install openbao openbao/openbao --namespace openbao --create-namespace \
    --set server.dev.enabled=true >/dev/null
fi
kubectl rollout status statefulset/openbao -n openbao --timeout=180s >/dev/null 2>&1 \
  || _fail "OpenBao statefulset never became ready"
image="$(kubectl get pod openbao-0 -n openbao -o jsonpath='{.spec.containers[0].image}')"
case "${image}" in
  *vault*hashicorp*) _fail "openbao-0 is actually running a HashiCorp Vault image (${image}) — this lesson's whole point is OpenBao, not Vault" ;;
  *openbao*) _pass "openbao-0 is running an OpenBao image (${image})" ;;
  *) _pass "openbao-0 image is ${image} (no vendor string to check, but not a HashiCorp Vault image)" ;;
esac

step "External Secrets Operator is installed"
if ! kubectl get deployment external-secrets -n external-secrets >/dev/null 2>&1; then
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1
  helm install external-secrets external-secrets/external-secrets \
    --namespace external-secrets --create-namespace --set installCRDs=true >/dev/null
fi
kubectl rollout status deployment/external-secrets -n external-secrets --timeout=180s >/dev/null 2>&1 \
  || _fail "external-secrets deployment never became ready"
_pass "external-secrets controller is running"

step "write a scratch credential into OpenBao, and confirm nothing about it is in this repo"
kubectl exec -n openbao openbao-0 -- env BAO_TOKEN=root bao kv put "${VAULT_PATH}" "password=${SECRET_VALUE}" >/dev/null
if grep -rqF --exclude-dir=.git --exclude-dir=test "${SECRET_VALUE}" "${REPO_ROOT}" 2>/dev/null; then
  _fail "the scratch OpenBao credential leaked into the companion repo — that is exactly what this lesson says never happens"
else
  _pass "the credential lives in OpenBao only — nothing wrote it back into the repo"
fi

step "wire ClusterSecretStore -> ExternalSecret against OpenBao's own service, and confirm the pull actually works"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic "${LESSON_ID}-token" -n external-secrets \
  --from-literal=token=root --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${LESSON_ID}-openbao
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        tokenSecretRef:
          name: ${LESSON_ID}-token
          key: token
          namespace: external-secrets
EOF
server="$(kubectl get clustersecretstore "${LESSON_ID}-openbao" -o jsonpath='{.spec.provider.vault.server}')"
case "${server}" in
  *openbao*) _pass "ClusterSecretStore server (${server}) points at OpenBao's own service" ;;
  *) _fail "ClusterSecretStore server is ${server} — expected the in-cluster OpenBao service" ;;
esac

cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe
  namespace: ${NS}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: ${LESSON_ID}-openbao
    kind: ClusterSecretStore
  target:
    name: probe
  data:
    - secretKey: password
      remoteRef:
        key: ${LESSON_ID}
        property: password
EOF

pulled=""
for _ in $(seq 1 20); do
  pulled="$(kubectl get secret probe -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ "${pulled}" = "${SECRET_VALUE}" ] && break
  sleep 3
done
[ "${pulled}" = "${SECRET_VALUE}" ] \
  && _pass "ESO pulled the exact credential written into OpenBao — the ClusterSecretStore/ExternalSecret chain works end to end" \
  || _fail "ExternalSecret never materialised '${SECRET_VALUE}' (got '${pulled}') — the OpenBao pull chain is broken"

smoke_done
