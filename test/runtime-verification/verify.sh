#!/bin/bash
# RUNTIME verification for the Argo CD course. Reports PASS/FAIL/INFO per claim.
# Never exits early: every check runs so one failure does not hide the rest.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
K="sudo k3s kubectl"
r(){ printf '%-6s %-22s %s\n' "$1" "$2" "$3"; }

echo "===== A. k3s baseline (S02-L01, S09-L02) ====="
SRV=$(sudo grep -m1 'server:' /etc/rancher/k3s/k3s.yaml | awk '{print $2}')
[ "$SRV" = "https://127.0.0.1:6443" ] && r PASS "kubeconfig-server" "$SRV" || r FAIL "kubeconfig-server" "got $SRV, expected https://127.0.0.1:6443"
MODE=$(sudo stat -c '%a %U' /etc/rancher/k3s/k3s.yaml)
r INFO "kubeconfig-mode" "$MODE"
VER=$(sudo k3s --version | head -1)
r INFO "k3s-version" "$VER"
$K get ds -n kube-system 2>/dev/null | grep -qi svclb && r INFO "servicelb" "svclb daemonset present" || r INFO "servicelb" "no svclb ds yet (appears with a LoadBalancer svc)"
$K get deploy -n kube-system traefik >/dev/null 2>&1 && r PASS "traefik-bundled" "traefik deployment present" || r FAIL "traefik-bundled" "absent"
sudo test -f /var/lib/rancher/k3s/server/db/state.db && r PASS "sqlite-datastore" "state.db present (embedded SQLite, not etcd)" || r FAIL "sqlite-datastore" "state.db absent"

echo
echo "===== B. Gateway API (S02-L06) ====="
CRD=$($K get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null)
if [ -n "$CRD" ]; then r PASS "gwapi-crds-bundled" "bundle-version=$CRD"; else r FAIL "gwapi-crds-bundled" "gateways CRD not found"; fi
GC=$($K get gatewayclass --no-headers 2>/dev/null | wc -l)
GW=$($K get gateway -A --no-headers 2>/dev/null | wc -l)
if [ "$GC" -eq 0 ] && [ "$GW" -eq 0 ]; then
  r PASS "gw-provider-off" "0 GatewayClass, 0 Gateway by default — provider is OFF"
else
  r FAIL "gw-provider-off" "found $GC GatewayClass / $GW Gateway — provider appears ON by default"
fi

echo
echo "===== C. The 262144-byte wall (S02-L03) ====="
curl -sSL -o /tmp/argocd-install.yaml https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml
r INFO "manifest-size" "$(wc -c < /tmp/argocd-install.yaml) bytes"
$K create namespace argocd >/dev/null 2>&1
OUT=$($K apply -n argocd -f /tmp/argocd-install.yaml 2>&1)
if echo "$OUT" | grep -qi 'Too long\|annotations.*too long\|metadata.annotations'; then
  r PASS "ssa-wall-fires" "client-side apply FAILED as the lesson teaches"
  echo "$OUT" | grep -i 'too long' | head -2 | sed 's/^/       /'
else
  r FAIL "ssa-wall-fires" "client-side apply did NOT hit the annotation limit"
  echo "$OUT" | tail -3 | sed 's/^/       /'
fi
r INFO "ssa-fix" "applying with --server-side --force-conflicts"
$K apply -n argocd --server-side --force-conflicts -f /tmp/argocd-install.yaml >/tmp/ssa.log 2>&1 \
  && r PASS "ssa-fix-works" "server-side apply succeeded" || { r FAIL "ssa-fix-works" "see /tmp/ssa.log"; tail -3 /tmp/ssa.log | sed 's/^/       /'; }

echo
echo "===== D. Notifications ConfigMap (S12-L03) ====="
DATA=$($K get cm argocd-notifications-cm -n argocd -o jsonpath='{.data}' 2>/dev/null)
TRIG=$($K get cm argocd-notifications-cm -n argocd -o yaml 2>/dev/null | grep -c 'trigger\.')
if [ -z "$DATA" ] || [ "$DATA" = "{}" ] || [ "$TRIG" -eq 0 ]; then
  r PASS "notif-cm-empty" "ships with NO triggers (data=${DATA:-<none>}) — catalog is a separate apply"
else
  r FAIL "notif-cm-empty" "found $TRIG trigger keys already present"
fi

echo
echo "===== E. Metrics ports (S12-L01) ====="
for pair in "argocd-metrics 8082" "argocd-server-metrics 8083" "argocd-repo-server 8084" "argocd-notifications-controller-metrics 9001" "argocd-applicationset-controller 8080"; do
  svc=${pair%% *}; want=${pair##* }
  got=$($K get svc "$svc" -n argocd -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)
  if echo " $got " | grep -q " $want "; then r PASS "port:$svc" "$want present (ports: $got)"; else r FAIL "port:$svc" "expected $want, ports are: ${got:-<svc missing>}"; fi
done
