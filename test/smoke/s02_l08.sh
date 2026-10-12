#!/usr/bin/env bash
# lesson: s02_l08 Exposing Argo CD over TLS with the Kubernetes Gateway API
# Exposing Argo CD over real TLS, and the `sectionName` trap.
#
# The lesson's whole troubleshooting table points at one silent failure mode: an HTTPRoute
# with no `sectionName` in `parentRefs` attaches to EVERY listener on the Gateway, not just
# `websecure`, so a visitor would reach Argo CD over PLAIN HTTP on port 8000, defeating the
# entire point of the lesson, while `kubectl get httproute` still reports `Accepted: True` and
# nothing on screen looks wrong. That is the one thing that actually matters here: not "does an
# HTTPRoute exist" but "does leaving out sectionName really cause the failure this lesson warns
# about, and does the lesson's own httproute.yaml avoid it."
#
# This builds the real, shared Gateway/TLS chain the lesson builds (Traefik's Gateway provider,
# cert-manager, the ClusterIssuer/Certificate): applying the SAME manifests the lesson shows
# is idempotent, and later lessons (the custom health check in s03_l04.sh and the canary
# lesson in s10_l04.sh) depend on that chain, so this script deliberately does NOT tear that
# shared state down. Only the two probe HTTPRoutes it adds to prove the trap are cleaned up.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L08 "an HTTPRoute needs sectionName: websecure, or it silently attaches to the plain-HTTP listener too"
tier cluster

PROBE_BAD="s02l08-probe-bad"

cleanup() {
  kubectl delete httproute "${PROBE_BAD}" -n argocd --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "Gateway API CRDs are present (k3s ships them; nothing to install)"
kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1 \
  && _pass "GatewayClass CRD present" \
  || _fail "no gatewayclasses CRD: this k3s build does not ship Gateway API; the whole lesson's premise breaks"

step "Traefik's Gateway provider and TLS listener (idempotent: same manifest the lesson types)"
sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml >/dev/null <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    providers:
      kubernetesGateway:
        enabled: true
    gateway:
      listeners:
        websecure:
          port: 8443
          protocol: HTTPS
          mode: Terminate
          certificateRefs:
            - name: argocd-gateway-tls
          namespacePolicy:
            from: All
YAML

listeners=""
for _ in $(seq 1 24); do
  # The Gateway does not exist until k3s's helm-controller has re-run Traefik's chart, so the very first
  # read finds nothing. That is the normal wait, not an error: `|| true` keeps set -e from ending the loop.
  listeners="$(kubectl get gateway traefik-gateway -n kube-system -o jsonpath='{range .spec.listeners[*]}{.name}:{.port}/{.protocol} {end}' 2>/dev/null || true)"
  case "${listeners}" in *websecure:8443/HTTPS*) break ;; esac
  sleep 5
done
case "${listeners}" in
  *web:8000/HTTP*websecure:8443/HTTPS*|*websecure:8443/HTTPS*web:8000/HTTP*)
    _pass "Gateway has both listeners: ${listeners}"
    ;;
  *)
    _fail "Gateway is missing a listener (got: '${listeners:-none}'): the HelmChartConfig was not picked up by k3s's helm-controller"
    ;;
esac

step "cert-manager, and a real (self-signed) certificate for the websecure listener"
kubectl apply --server-side --force-conflicts -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" >/dev/null
kubectl wait --for=condition=Available deploy/cert-manager-webhook -n cert-manager --timeout=180s >/dev/null 2>&1 \
  && _pass "cert-manager webhook Available" \
  || _fail "cert-manager webhook never became Available"

kubectl apply -f - >/dev/null <<'YAML'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-gateway-tls
  namespace: kube-system
spec:
  secretName: argocd-gateway-tls
  dnsNames:
    - argocd.local
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
YAML

secret_ok=no
for _ in $(seq 1 24); do
  kubectl get secret argocd-gateway-tls -n kube-system >/dev/null 2>&1 && { secret_ok=yes; break; }
  sleep 5
done
[ "${secret_ok}" = yes ] && _pass "TLS Secret issued for the websecure listener" \
  || _fail "argocd-gateway-tls Secret never appeared: the websecure listener has no certificate to terminate with"

step "point argocd-server at plain HTTP behind the Gateway (TLS terminates once, at the edge)"
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null
kubectl rollout restart deploy/argocd-server -n argocd >/dev/null 2>&1 || true
kubectl rollout status deploy/argocd-server -n argocd --timeout=120s >/dev/null 2>&1 \
  && _pass "argocd-server restarted in insecure (plain-HTTP-behind-TLS) mode" \
  || _fail "argocd-server did not roll out after the insecure patch"

step "the lesson's own httproute.yaml attaches ONLY to websecure: the correct, non-trap form"
# The lesson has the student WRITE this file (Do.md step 9) and apply it (step 10). It is not a file the
# companion repo carries, so the script writes the same block the lesson shows, to a scratch file, and applies that.
route_file="$(mktemp)"
cat > "${route_file}" <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
      sectionName: websecure
  hostnames:
    - argocd.local
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
YAML
kubectl apply -f "${route_file}" >/dev/null 2>&1 || { rm -f "${route_file}"; _fail "could not apply the HTTPRoute from the lesson's step 9 block"; }
rm -f "${route_file}"
accepted=""
for _ in $(seq 1 12); do
  accepted="$(kubectl get httproute argocd-server -n argocd -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)"
  [ "${accepted}" = "True" ] && break
  sleep 5
done
[ "${accepted}" = "True" ] && _pass "the lesson's HTTPRoute is Accepted" || _fail "the lesson's HTTPRoute never reached Accepted=True"

parent_count="$(kubectl get httproute argocd-server -n argocd -o jsonpath='{.status.parents}' 2>/dev/null | grep -o 'sectionName' | wc -l | tr -d ' ')"
if [ "${parent_count}" = "1" ]; then
  _pass "the lesson's HTTPRoute attached to exactly one listener (websecure): TLS-only, as the lesson intends"
else
  _fail "the lesson's HTTPRoute attached to ${parent_count} listeners, not 1: it is reachable over plain HTTP too, exactly the silent trap the lesson warns about; check sectionName in parentRefs"
fi

step "what leaving out sectionName does on this Gateway: the route is tried on every listener, and web refuses it"
# Measured on this Gateway (k3s, Traefik, 2026-10-12): without sectionName the route is Accepted by
# websecure, and the web listener keeps 0 attached routes, because web admits routes from the SAME
# namespace only (allowedRoutes from: Same) and this route lives in argocd. The lesson says this too
# (Do.md: "web showed 0 attached routes"; on a stock k3s the plain-HTTP exposure does not happen). The
# trap is latent: it opens the day web is widened to from: All. So the probe asserts the observed
# attachment, and does not widen the shared listener to prove the latent case.
kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ${PROBE_BAD}
  namespace: argocd
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
  hostnames:
    - argocd-l06-probe.local
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
YAML
probe_accepted=""
for _ in $(seq 1 12); do
  probe_accepted="$(kubectl get httproute "${PROBE_BAD}" -n argocd -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  [ "${probe_accepted}" = "True" ] && break
  sleep 5
done
web_attached="$(kubectl get gateway traefik-gateway -n kube-system -o jsonpath='{.status.listeners[?(@.name=="web")].attachedRoutes}' 2>/dev/null || true)"
web_from="$(kubectl get gateway traefik-gateway -n kube-system -o jsonpath='{.spec.listeners[?(@.name=="web")].allowedRoutes.namespaces.from}' 2>/dev/null || true)"
if [ "${probe_accepted}" = "True" ] && [ "${web_attached:-x}" = "0" ] && [ "${web_from}" = "Same" ]; then
  _pass "without sectionName the route is Accepted, and the web listener (from: ${web_from}) keeps ${web_attached} attached routes: plain HTTP stays closed, as the lesson records"
else
  _fail "expected the sectionName-less route Accepted and web at 0 attached routes with from: Same; got accepted='${probe_accepted:-none}', web attachedRoutes='${web_attached:-none}', web from='${web_from:-none}'"
fi

smoke_done
