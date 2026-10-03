#!/usr/bin/env bash
# S03 L04 — Argo CD has no opinion about a Certificate; the Lua health check gives it one.
#
# The lesson's claim: a cert-manager Certificate, once created, reads Healthy in Argo CD's
# DEFAULT health computation regardless of whether cert-manager ever actually issues it — Argo
# CD has no built-in rule for a kind it doesn't recognize, so it defaults to Healthy the instant
# the object exists. Only a custom Lua health check
# (resource.customizations.health.cert-manager.io_Certificate) makes the reported status track
# the real `status.conditions[type=Ready]` value. This is proven two ways below: a Certificate
# that can NEVER issue (bad issuerRef, so there is no timing race — it stays Ready:False
# forever) still reads Healthy under the default rules, and reads Progressing once the Lua check
# is active; a real one, with the Lua check active, reads Healthy only once it is genuinely
# Ready.
#
# argocd-cm is itself GitOps-managed by the `argocd` self-manage Application with
# selfHeal:true (S02 L08) — a live `kubectl patch` of it alone would be reverted within
# seconds, so this script disables that Application's own selfHeal for the duration of the
# patch, exactly the way the lesson insists this must go through Git in a real take, and
# restores it (and argocd-cm) in cleanup regardless of how the script exits.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L04 "a Certificate reads Healthy by default before issuance; only the Lua health check reports the real Ready condition"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "preconditions from S02 L06: cert-manager and selfsigned-issuer must already be on the cluster"
kubectl get deploy -n cert-manager >/dev/null 2>&1 \
  || _fail "no cert-manager deployment found — this is S02 L06's own setup, not S03 L04's; restage S02 L06 before this script can run"
kubectl get clusterissuer selfsigned-issuer >/dev/null 2>&1 \
  || _fail "ClusterIssuer selfsigned-issuer not found — S02 L06's setup is missing; restage it first"
_pass "cert-manager and selfsigned-issuer are present"

step "confirm the argocd Application (self-management) exists, name and shape from S02 L08"
kubectl get application argocd -n argocd >/dev/null 2>&1 \
  || _fail "no Application named 'argocd' in the argocd namespace — S02 L08's self-management is missing; this script cannot safely test the Lua-through-Git claim without it"

APP="s03l04-probe"
NS="s03l04-probe"
TMPDIR="$(mktemp -d)"
LUA_PATCH="${TMPDIR}/argocd-cm-patch.yaml"

cleanup() {
  # Restore argocd-cm to its committed (vanilla) shape...
  kubectl patch configmap argocd-cm -n argocd --type json \
    -p '[{"op":"remove","path":"/data"}]' >/dev/null 2>&1 || true
  # ...and put the argocd Application's own selfHeal back on, exactly as bootstrap/self-manage-app.yaml commits it.
  kubectl patch application argocd -n argocd --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":true,"prune":false}}}}' >/dev/null 2>&1 || true
  kubectl delete application "${APP}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

kubectl create namespace "${NS}" >/dev/null 2>&1 || true

step "create the probe Application — its own namespace, manual sync, nothing pruned"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP}, namespace: argocd}
spec:
  project: default
  # source is a placeholder, never synced without --local below (base, so it carries no
  # namespace opinion of its own even inert — overlays pin their own namespace).
  source: {repoURL: "https://github.com/abohmeed/argocd-class-resources.git", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS}}
  syncPolicy: {}
EOF

step "sync a Certificate that can NEVER issue (bad issuerRef) — no timing race, it stays Ready:False forever"
mkdir -p "${TMPDIR}/broken"
cat > "${TMPDIR}/broken/certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: s03l04-broken
spec:
  secretName: s03l04-broken-tls
  dnsNames: ["storefront.northwind.local"]
  issuerRef:
    name: s03l04-nonexistent-issuer
    kind: ClusterIssuer
EOF
argocd app sync "${APP}" --local "${TMPDIR}/broken" >/dev/null 2>&1 || true
sleep 15

step "under DEFAULT (uncustomized) health rules, Argo CD reports it Healthy anyway"
health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-broken")].health.status}' 2>/dev/null || true)"
if [ "${health}" = "Healthy" ]; then
  _pass "a Certificate that will NEVER issue still reads Healthy under Argo CD's default rules — the false-positive the lecture opens on"
else
  _fail "expected the default rules to report Healthy for an unrecognized kind, got '${health:-empty}' — either Argo CD gained a built-in cert-manager health check or this repo's default health behaviour has changed; the lecture's cold open no longer reproduces"
fi

step "write the Lua health check through a (temporary, self-cleaning) argocd-cm patch, not a live one-off edit"
kubectl patch application argocd -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"selfHeal":false,"prune":false}}}}' >/dev/null
cat > "${LUA_PATCH}" <<'EOF'
data:
  resource.customizations.health.cert-manager.io_Certificate: |
    hs = {}
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for i, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" then
          if condition.status == "False" then
            hs.status = "Progressing"
            hs.message = condition.message
            return hs
          end
          if condition.status == "True" then
            hs.status = "Healthy"
            hs.message = condition.message
            return hs
          end
        end
      end
    end
    hs.status = "Progressing"
    hs.message = "Waiting for certificate status"
    return hs
EOF
kubectl patch configmap argocd-cm -n argocd --type merge --patch-file "${LUA_PATCH}" >/dev/null

step "same never-issuing Certificate, now reads honest: Progressing, not Healthy"
argocd app get "${APP}" --hard-refresh >/dev/null 2>&1 || true
deadline=$(( $(date +%s) + 60 ))
health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-broken")].health.status}' 2>/dev/null || true)"
  [ "${health}" = "Progressing" ] && break
  sleep 5
done
if [ "${health}" = "Progressing" ]; then
  _pass "with the Lua check active, the same never-issuing Certificate now reads Progressing — health tracks the real Ready condition"
else
  _fail "expected Progressing once the Lua health check was active, got '${health:-empty}' — the Lua customization did not take effect, or its condition-reading logic is broken"
fi

step "a Certificate that CAN issue reads Healthy only once it genuinely is"
mkdir -p "${TMPDIR}/good"
cat > "${TMPDIR}/good/certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: s03l04-good
spec:
  secretName: s03l04-good-tls
  dnsNames: ["storefront.northwind.local"]
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
EOF
argocd app sync "${APP}" --local "${TMPDIR}/good" >/dev/null 2>&1 || true
deadline=$(( $(date +%s) + 90 ))
good_health=""
while [ "$(date +%s)" -lt "${deadline}" ]; do
  argocd app get "${APP}" --refresh >/dev/null 2>&1 || true
  good_health="$(kubectl get application "${APP}" -n argocd -o jsonpath='{.status.resources[?(@.name=="s03l04-good")].health.status}' 2>/dev/null || true)"
  [ "${good_health}" = "Healthy" ] && break
  sleep 5
done
if [ "${good_health}" = "Healthy" ]; then
  _pass "the real Certificate reached Ready and the Lua check reported Healthy — the honest positive case, not just an always-Progressing stub"
else
  _fail "the real Certificate never read Healthy under the Lua check (got '${good_health:-empty}') — either issuance failed or the check's True-condition branch is broken"
fi

smoke_done
