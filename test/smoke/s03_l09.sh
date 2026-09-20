#!/usr/bin/env bash
# S03 L09 — App of Apps: the parent's managed resources are Application objects, not Deployments.
#
# The lesson's claim is about what KIND of thing the parent manages: `bootstrap/root-app.yaml`
# (name `root`, source.path `bootstrap/apps`) points Argo CD at a directory of Application
# manifests, so the parent's own managed-resources list is a set of `Application` objects — the
# parent never touches a Deployment or Service directly, and a child it has never seen before
# gets created from nothing but a commit under that directory. If a future change made the
# parent's managed resources look like ordinary workloads instead, or made a new child require a
# manual kubectl apply to appear, this lesson's whole "compose many Applications from one" claim
# collapses. This proves it with two throwaway children, isolated by name and namespace so this
# script cannot collide with the real `root`/`storefront-dev` Applications any other lesson or
# session may have live. It never touches the real bootstrap/apps/ directory or pushes to the
# companion repo — the parent's child list comes from a local directory via `--local`, standing
# in for "a commit landed under bootstrap/apps/".
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S03-L09 "the App-of-Apps parent's managed resources are Application objects, and a new child appears from a commit alone, no kubectl apply against it"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

PARENT="s03l09-root"
CHILD_DEV="s03l09-child-dev"
CHILD_PAY="s03l09-child-payments"
NS_DEV="s03l09-dev"
NS_PAY="s03l09-payments"
REPO="https://github.com/abohmeed/argocd-class-resources.git"
TMPDIR="$(mktemp -d)"

cleanup() {
  kubectl delete application "${CHILD_DEV}" "${CHILD_PAY}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete application "${PARENT}" -n argocd --wait=true --timeout=90s >/dev/null 2>&1 || true
  kubectl delete namespace "${NS_DEV}" "${NS_PAY}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${TMPDIR}"
}
trap cleanup EXIT

step "repo-side invariant: apps/payments/overlays/dev exists — this is L09's real 'onboard a fourth child' content"
# The real lesson's children point at the overlays (bootstrap/apps/storefront-dev.yaml does);
# this script's own probe children point at base instead (see below) purely for CI isolation —
# the overlays pin their own namespace, which would collide with the real, shared one. This
# assertion still checks the real content the lesson itself onboards.
assert_exists_dir "apps/payments/overlays/dev"
assert_kustomize_builds "apps/payments/overlays/dev"

step "the parent Application — its own namespace-scoped probe, standing in for bootstrap/root-app.yaml's shape"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${PARENT}, namespace: argocd}
spec:
  project: default
  # source is a placeholder never synced without --local below (base, so it carries no
  # namespace opinion even inert).
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: argocd}
  syncPolicy: {}
EOF

step "the child list the parent will create — TWO Applications it has never seen before, pointed at real, already-committed paths"
mkdir -p "${TMPDIR}/apps"
cat > "${TMPDIR}/apps/${CHILD_DEV}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${CHILD_DEV}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev — the dev overlay pins its own namespace, and a manifest's own
  # namespace wins over destination.namespace, so this child would silently land in the real
  # storefront-dev namespace other lessons own. base pins none, so destination.namespace applies.
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS_DEV}}
  syncPolicy:
    automated: {selfHeal: true, prune: true}
    syncOptions: ["CreateNamespace=true"]
EOF
cat > "${TMPDIR}/apps/${CHILD_PAY}.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${CHILD_PAY}, namespace: argocd}
spec:
  project: default
  # base, NOT overlays/dev — the dev overlay pins its own namespace, and a manifest's own
  # namespace wins over destination.namespace, so this child would silently land in the real
  # payments-dev namespace. base pins none, so destination.namespace applies cleanly.
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/payments/base}
  destination: {server: "https://kubernetes.default.svc", namespace: ${NS_PAY}}
  syncPolicy:
    automated: {selfHeal: true, prune: true}
    syncOptions: ["CreateNamespace=true"]
EOF

step "sync the parent against that list — 'a commit landed under the apps directory', nothing applied against the children directly"
argocd app sync "${PARENT}" --local "${TMPDIR}/apps" >/dev/null 2>&1 || true

step "the parent's managed resources are Application objects, not Deployments or Services"
kinds="$(kubectl get application "${PARENT}" -n argocd -o jsonpath='{range .status.resources[*]}{.kind}{"\n"}{end}' 2>/dev/null | sort -u)"
if [ -n "${kinds}" ] && ! printf '%s\n' "${kinds}" | grep -qvE '^(Application)?$'; then
  _pass "the parent's managed resources are all kind=Application: $(printf '%s' "${kinds}" | tr '\n' ' ')"
else
  _fail "expected the parent's managed resources to be exclusively kind=Application, got: $(printf '%s' "${kinds}" | tr '\n' ' ') — the composition boundary this lesson teaches (parent manages Applications, never workloads directly) does not hold"
fi

step "the children reconcile on their own — created by the parent alone, then sync themselves (automated+selfHeal)"
wait_for_sync "${CHILD_DEV}" 180
wait_for_sync "${CHILD_PAY}" 180
_pass "both children reached Synced/Healthy without a single kubectl command aimed at either one directly"

step "curl the fourth child end to end, same as the lesson's own closing proof"
kubectl port-forward -n "${NS_PAY}" svc/payments 18082:80 >/dev/null 2>&1 &
pf_pid=$!
sleep 3
body="$(curl -s --max-time 5 localhost:18082 || true)"
kill "${pf_pid}" >/dev/null 2>&1 || true
if printf '%s' "${body}" | grep -q "payments"; then
  _pass "payments-dev serves real traffic, onboarded through nothing but the parent: '${body}'"
else
  _fail "payments child did not serve the expected banner (got '${body:-empty}') — onboarding through the parent alone did not actually stand up a working service"
fi

smoke_done
