#!/usr/bin/env bash
# S14 L04 — the capstone's staged live failure: a SealedSecret sealed under strict scope for one
# namespace does not decrypt when Kustomize's namespace transformer lands the same rendered
# object in a DIFFERENT namespace. This is the failure that must actually fire, not a
# configuration check that would read the same whether or not the mismatch is real.
#
# PRECONDITION GAP, found while writing this script, not invented by it: this lesson's own
# runbook (_runbooks/S14-L04.runbook.md) states "apps/checkout/base/sealedsecret.yaml already
# exists — committed since S05 L02" and treats that as a given precondition to confirm. It does
# not exist in this checkout, and apps/checkout/base/kustomization.yaml's resources list does not
# reference it either — grep both and see. Until that gap is closed, the capstone's proof lesson
# has no ciphertext to reproduce the mismatch against, so the checks below correctly FAIL rather
# than passing on a demo that cannot currently run. Once the file lands, this script proves the
# mismatch fires for real: sealed for "checkout", it must fail to decrypt in BOTH checkout-dev
# and checkout-staging, and a namespace-wide reseal targeted at checkout-staging must fix that
# ONE namespace without making checkout-dev's copy decrypt too — the exact scope the runbook's
# own correction insists on saying plainly.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S14-L04 "a SealedSecret sealed for one namespace fails to decrypt in another — and a namespace-wide reseal fixes only the namespace it targeted"
tier cluster

step "repo-tier precondition: apps/checkout/base/sealedsecret.yaml exists and is wired into the base"
assert_exists_file "apps/checkout/base/sealedsecret.yaml"
assert_file_contains "apps/checkout/base/kustomization.yaml" 'sealedsecret\.yaml' \
  "apps/checkout/base/kustomization.yaml lists sealedsecret.yaml as a resource"

step "it renders into both checkout-dev and checkout-staging via each overlay's namespace transformer"
dev_rendered="$(kubectl kustomize "${REPO_ROOT}/apps/checkout/overlays/dev" 2>&1 | grep -A2 'kind: SealedSecret' || true)"
staging_rendered="$(kubectl kustomize "${REPO_ROOT}/apps/checkout/overlays/staging" 2>&1 | grep -A2 'kind: SealedSecret' || true)"
printf '%s' "${dev_rendered}" | grep -q 'namespace: checkout-dev' \
  && _pass "checkout/overlays/dev renders the SealedSecret stamped checkout-dev" \
  || _fail "checkout/overlays/dev did not render a SealedSecret stamped checkout-dev"
printf '%s' "${staging_rendered}" | grep -q 'namespace: checkout-staging' \
  && _pass "checkout/overlays/staging renders the SealedSecret stamped checkout-staging" \
  || _fail "checkout/overlays/staging did not render a SealedSecret stamped checkout-staging"

step "confirm the Sealed Secrets controller this test depends on is actually running"
kubectl get pods -n kube-system -l name=sealed-secrets-controller --no-headers 2>/dev/null | grep -q Running \
  || _fail "no Running sealed-secrets-controller pod in kube-system — this is this lesson's own precondition (S05 L02), not something this script stands up"

NS_A="s14l04-checkout-dev"
NS_B="s14l04-checkout-staging"
cleanup() {
  kubectl delete namespace "${NS_A}" --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS_B}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "the ciphertext, applied as-is, fails to decrypt in EITHER capstone namespace — the mismatch this lesson stages"
kubectl create namespace "${NS_A}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "${NS_B}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

sealed_name="$(grep -m1 '^  name:' "${REPO_ROOT}/apps/checkout/base/sealedsecret.yaml" | awk '{print $2}')"
[ -n "${sealed_name}" ] || _fail "could not read the SealedSecret's own metadata.name from apps/checkout/base/sealedsecret.yaml"

sed "s/namespace: checkout\$/namespace: ${NS_A}/" "${REPO_ROOT}/apps/checkout/base/sealedsecret.yaml" | kubectl apply -f - >/dev/null 2>&1 || true
sed "s/namespace: checkout\$/namespace: ${NS_B}/" "${REPO_ROOT}/apps/checkout/base/sealedsecret.yaml" | kubectl apply -f - >/dev/null 2>&1 || true
sleep 15

for ns in "${NS_A}" "${NS_B}"; do
  if kubectl get secret "${sealed_name}" -n "${ns}" >/dev/null 2>&1; then
    _fail "the plain Secret DID materialize in ${ns} from the original ciphertext — the scope mismatch this lesson stages did not fire; the demo's live failure would not reproduce on camera"
  else
    _pass "${ns}: the original ciphertext did NOT decrypt — the scope mismatch fired, as this lesson's failure requires"
  fi
done

step "a namespace-wide reseal targeted at ONE namespace fixes that namespace and no other"
cert="$(mktemp)"
kubeseal --fetch-cert --controller-namespace kube-system > "${cert}" 2>/dev/null \
  || _fail "kubeseal --fetch-cert failed — cannot fetch the controller's public certificate"

secret_yaml="$(mktemp)"
cat > "${secret_yaml}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${sealed_name}
  namespace: ${NS_B}
type: Opaque
stringData:
  password: "s14l04-probe-password"
EOF
kubeseal --cert "${cert}" --scope namespace-wide --format yaml < "${secret_yaml}" | kubectl apply -f - >/dev/null
rm -f "${cert}" "${secret_yaml}"

sleep 15
b_ok=no
kubectl get secret "${sealed_name}" -n "${NS_B}" >/dev/null 2>&1 && b_ok=yes
a_ok=no
kubectl get secret "${sealed_name}" -n "${NS_A}" >/dev/null 2>&1 && a_ok=yes

if [ "${b_ok}" = yes ]; then
  _pass "the namespace-wide reseal targeted at ${NS_B} decrypts there"
else
  _fail "the namespace-wide reseal targeted at ${NS_B} STILL did not decrypt there — the fix this lesson teaches did not hold"
fi
if [ "${a_ok}" = no ]; then
  _pass "${NS_A} still does not decrypt — confirming namespace-wide scope is NOT portable to a namespace it wasn't sealed for, exactly the correction this runbook insists on"
else
  _fail "${NS_A} unexpectedly decrypted too — either a stale Secret from a previous run, or namespace-wide scope is more portable than this lesson claims"
fi

smoke_done
