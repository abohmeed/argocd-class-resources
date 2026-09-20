#!/bin/bash
K="sudo k3s kubectl"
r(){ printf '%-6s %-26s %s\n' "$1" "$2" "$3"; }

echo "===== N. Enable Gateway provider + TLS listener via HelmChartConfig (S02-L06) ====="
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
r INFO "helmchartconfig" "written to /var/lib/rancher/k3s/server/manifests/"

echo "       installing cert-manager first (the listener needs its Secret to exist)"
$K apply --server-side --force-conflicts -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml >/dev/null 2>&1
$K wait --for=condition=Available deploy/cert-manager-webhook -n cert-manager --timeout=180s >/dev/null 2>&1
r INFO "cert-manager" "$($K get deploy cert-manager -n cert-manager -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null) ready"

cat <<'YAML' | $K apply -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: {name: selfsigned-issuer}
spec: {selfSigned: {}}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: argocd-gateway-tls, namespace: kube-system}
spec:
  secretName: argocd-gateway-tls
  dnsNames: [argocd.local]
  issuerRef: {name: selfsigned-issuer, kind: ClusterIssuer}
YAML
for i in $(seq 1 30); do $K get secret argocd-gateway-tls -n kube-system >/dev/null 2>&1 && break; sleep 4; done
$K get secret argocd-gateway-tls -n kube-system >/dev/null 2>&1 \
  && r PASS "cert-issued" "Secret argocd-gateway-tls present in kube-system (no ReferenceGrant needed)" \
  || r FAIL "cert-issued" "certificate never issued"

echo "       waiting for helm-controller to re-run the traefik chart"
for i in $(seq 1 45); do
  $K get gateway traefik-gateway -n kube-system >/dev/null 2>&1 && break; sleep 5
done
GC=$($K get gatewayclass --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
[ -n "$GC" ] && r PASS "gatewayclass-created" "$GC" || r FAIL "gatewayclass-created" "none"
if $K get gateway traefik-gateway -n kube-system >/dev/null 2>&1; then
  L=$($K get gateway traefik-gateway -n kube-system -o jsonpath='{range .spec.listeners[*]}{.name}:{.port}/{.protocol} {end}' 2>/dev/null)
  r PASS "gateway-created" "traefik-gateway in kube-system"
  echo "$L" | grep -q 'websecure:8443/HTTPS' && r PASS "tls-listener" "$L" || r FAIL "tls-listener" "$L"
else
  r FAIL "gateway-created" "traefik-gateway not found"
fi

echo
echo "===== O. HTTPRoute with sectionName, and real HTTPS (S02-L06) ====="
$K patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}' >/dev/null 2>&1
$K rollout restart deploy argocd-server -n argocd >/dev/null 2>&1
$K rollout status deploy argocd-server -n argocd --timeout=180s >/dev/null 2>&1
cat <<'YAML' | $K apply -f - >/dev/null 2>&1
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: argocd-server, namespace: argocd}
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system
      sectionName: websecure
  hostnames: ["argocd.local"]
  rules:
    - backendRefs:
        - name: argocd-server
          port: 80
YAML
sleep 10
COND=$($K get httproute argocd-server -n argocd -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$COND" = "True" ] && r PASS "httproute-accepted" "Accepted=True against listener websecure" || r FAIL "httproute-accepted" "Accepted=$COND"
CODE=$(curl -sk -o /dev/null -w '%{http_code}' --resolve argocd.local:443:127.0.0.1 https://argocd.local/ --max-time 20 2>/dev/null)
[ "$CODE" = "200" ] && r PASS "https-works" "HTTP $CODE over TLS at https://argocd.local" || r FAIL "https-works" "HTTP $CODE"
ISS=$(echo | openssl s_client -connect 127.0.0.1:443 -servername argocd.local 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null | tr '\n' ' ')
r INFO "tls-cert" "${ISS:-<none>}"
