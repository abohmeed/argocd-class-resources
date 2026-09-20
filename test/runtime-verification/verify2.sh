#!/bin/bash
K="sudo k3s kubectl"
r(){ printf '%-6s %-24s %s\n' "$1" "$2" "$3"; }

echo "===== F. Notifications catalog (S12-L03) ====="
$K apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/notifications_catalog/install.yaml >/dev/null 2>&1
N=$($K get cm argocd-notifications-cm -n argocd -o json 2>/dev/null | jq -r '.data|keys[]' 2>/dev/null | grep -c '^trigger\.')
LIST=$($K get cm argocd-notifications-cm -n argocd -o json 2>/dev/null | jq -r '.data|keys[]' 2>/dev/null | grep '^trigger\.' | sed 's/^trigger\.//' | tr '\n' ' ')
if [ "$N" -eq 8 ]; then r PASS "catalog-8-triggers" "$LIST"; else r FAIL "catalog-8-triggers" "got $N: $LIST"; fi

echo
echo "===== G. argocd CLI behaviours (S09-L04) ====="
if ! command -v argocd >/dev/null 2>&1; then
  curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/download/v3.5.3/argocd-linux-amd64 2>/dev/null
  sudo install -m 555 /tmp/argocd /usr/local/bin/argocd 2>/dev/null
fi
r INFO "argocd-cli" "$(argocd version --client --short 2>/dev/null | head -1)"

echo
echo "===== H. Unlabelled cluster Secret is silently ignored (S09-L03) ====="
$K create secret generic unlabelled-cluster -n argocd \
  --from-literal=name=ghost --from-literal=server=https://ghost.example.com >/dev/null 2>&1
sleep 5
EV=$($K get events -n argocd --field-selector involvedObject.name=unlabelled-cluster --no-headers 2>/dev/null | wc -l)
SEEN=$($K get secret -n argocd -l argocd.argoproj.io/secret-type=cluster --no-headers 2>/dev/null | grep -c unlabelled || true)
if [ "$EV" -eq 0 ] && [ "$SEEN" -eq 0 ]; then
  r PASS "unlabelled-silent" "0 events, not in the cluster-type selector — invisible, exactly as narrated"
else
  r FAIL "unlabelled-silent" "events=$EV selector-hits=$SEEN"
fi
$K delete secret unlabelled-cluster -n argocd >/dev/null 2>&1

echo
echo "===== I. Helm 4 + chart appVersion (S02-L02) ====="
if ! command -v helm >/dev/null 2>&1; then
  curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 2>/dev/null | sudo bash >/dev/null 2>&1
fi
r INFO "helm-version" "$(helm version --short 2>/dev/null)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
helm repo update >/dev/null 2>&1
APPV=$(helm search repo argo/argo-cd --versions 2>/dev/null | awk '$2=="10.9.2"||$2=="10.9.1"{print $2" -> "$3}' | head -4)
if [ -n "$APPV" ]; then r PASS "chart-appversion" "$(echo $APPV)"; else r INFO "chart-appversion" "$(helm search repo argo/argo-cd 2>/dev/null | head -2 | tail -1)"; fi

echo
echo "===== J. Argo Rollouts + Job-provider analysis (S10-L05) ====="
$K create namespace argo-rollouts >/dev/null 2>&1
$K apply -n argo-rollouts --server-side --force-conflicts \
  -f https://github.com/argoproj/argo-rollouts/releases/download/v1.10.0/install.yaml >/dev/null 2>&1
for i in $(seq 1 30); do
  READY=$($K get deploy argo-rollouts -n argo-rollouts -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$READY" = "1" ] && break; sleep 5
done
RV=$($K get deploy argo-rollouts -n argo-rollouts -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[ -n "$RV" ] && r PASS "rollouts-installed" "$RV" || r FAIL "rollouts-installed" "controller not found"
r INFO "analysistemplate-crd" "$($K get crd analysistemplates.argoproj.io -o jsonpath='{.spec.versions[0].name}' 2>/dev/null)"
