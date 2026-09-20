#!/usr/bin/env bash
# S07 L02 — fencing an AppProject: sourceRepos and destinations.
#
# Two claims, defended two ways.
#
# 1. Repo-tier, and it runs first, unconditionally: `teams/_template/README.md` says "CI enforces
#    that every teams/<name>/ directory matches this shape" — and nothing currently does. This
#    lesson is where the runbook itself draws the student's eye to teams/_template/ and
#    teams/checkout/ (to warn them apart from this lesson's own appproject-checkout.yaml), so it is
#    where that unenforced claim gets enforced. It needs no cluster.
#
# 2. Cluster-tier: sourceRepos is checked BEFORE Argo CD tries to reach the URL, so an unreachable,
#    unapproved fork is refused for the same reason an approved-but-unreachable one would be — and
#    a destination outside `destinations` is refused for an unrelated reason (the namespace, not
#    the repo). Built with throwaway objects, never the real `checkout` AppProject/apps the
#    recording session is accumulating state in across this section.
#
# The throwaway "good repo" test intentionally uses apps/storefront/manifests, not
# apps/checkout/overlays/dev — that overlay's kustomization.yaml hardcodes `namespace:
# checkout-dev`, which is the real recording session's own namespace. Pointing a CI script at it
# risks the same Kustomize-stamps-the-namespace ambiguity S07 L01 flags AND risks a cleanup trap
# deleting namespace checkout-dev out from under the producer. Plain-directory content proves the
# same sourceRepos/destinations claim without either risk.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L02 "an AppProject's sourceRepos refuses an unapproved repo before Argo CD ever reaches it, and destinations refuses an unapproved namespace for a different reason"
tier cluster

REPO="https://github.com/abohmeed/argocd-class-resources.git"

step "teams/_template/ is the documented canonical shape (README: 'CI enforces it')"
assert_exists_dir "teams/_template"
assert_exists_file "teams/_template/appproject.yaml"

step "every onboarded team directory matches that shape"
for d in teams/*/; do
  name="$(basename "${d}")"
  [ "${name}" = "_template" ] && continue
  assert_exists_file "teams/${name}/appproject.yaml"
  assert_exists_file "teams/${name}/rbac-policy.csv.snippet"
done

step "every committed team AppProject names only this course's own repository"
for f in teams/*/appproject.yaml; do
  [ -f "${REPO_ROOT}/${f}" ] || continue
  assert_yaml_wellformed "${f}"
  # Pull just the sourceRepos block: from the `sourceRepos:` line to the next top-level
  # (non-indented) key.
  bad="$(awk '/^  sourceRepos:/{flag=1; next} /^  [a-zA-Z]/{flag=0} flag && /^    - /{print}' \
    "${REPO_ROOT}/${f}" | grep -v -- "- ${REPO}\$" || true)"
  if [ -z "${bad}" ]; then
    _pass "${f}: sourceRepos names only ${REPO}"
  else
    _fail "${f} lists a sourceRepos entry that is not this course's own repository:\n${bad}"
  fi
done

step "every committed RBAC policy line carries its trailing effect (S07 L06/L11: omitting it is a common, silent error)"
for f in teams/*/rbac-policy.csv.snippet; do
  [ -f "${REPO_ROOT}/${f}" ] || continue
  bad=""
  while IFS= read -r line; do
    case "${line}" in
      p,*)
        fields="$(printf '%s' "${line}" | awk -F',' '{print NF}')"
        last="$(printf '%s' "${line}" | awk -F',' '{print $NF}' | tr -d ' ')"
        if [ "${fields}" -ne 6 ] || { [ "${last}" != "allow" ] && [ "${last}" != "deny" ]; }; then
          bad="${bad}\n  ${line}"
        fi
        ;;
    esac
  done < "${REPO_ROOT}/${f}"
  if [ -z "${bad}" ]; then
    _pass "${f}: every p-line is subject,resource,action,object,effect with an explicit allow/deny"
  else
    _fail "${f} has a policy line missing its mandatory trailing allow/deny:${bad}"
  fi
done

PROJ="s07l02-probe"
NS="s07l02-probe"
WRONG_NS="s07l02-wrongns"
APP_BAD="s07l02-badrepo"
APP_GOOD="s07l02-goodrepo"
APP_WRONG="s07l02-wrongns"

cleanup() {
  kubectl delete application "${APP_BAD}" "${APP_GOOD}" "${APP_WRONG}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete appproject "${PROJ}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" "${WRONG_NS}" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "fence a throwaway project to one repo and one namespace"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: ${PROJ}, namespace: argocd}
spec:
  description: "S07 L02 smoke probe — not the real checkout project."
  sourceRepos: ["${REPO}"]
  destinations:
    - {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF
_pass "project ${PROJ} created, scoped to one repo and one namespace"

step "an unapproved repository is refused (create it, do not wait for a doomed sync)"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_BAD}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "https://github.com/some-developer/checkout-fork.git", targetRevision: main, path: base}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
EOF
sleep 20
sync_status="$(kubectl get application "${APP_BAD}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${sync_status}" = "Synced" ]; then
  _fail "an Application sourced from an unapproved repo reached Synced — sourceRepos is not being enforced"
else
  _pass "unapproved-repo Application never reached Synced (status: ${sync_status:-none yet}) — sourceRepos refused it"
fi

step "the approved repo, into the approved namespace, succeeds"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_GOOD}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${NS}"}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
wait_for_sync "${APP_GOOD}" 180
if kubectl get deployment -n "${NS}" -o name 2>/dev/null | grep -q .; then
  _pass "approved repo + approved namespace: the Deployment actually landed in ${NS}"
else
  _fail "sync reported Synced but no Deployment is in ${NS}"
fi

step "the same approved repo, into a namespace NOT in destinations, is refused for a different reason"
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${APP_WRONG}, namespace: argocd}
spec:
  project: ${PROJ}
  source: {repoURL: "${REPO}", targetRevision: main, path: apps/storefront/manifests}
  destination: {server: "https://kubernetes.default.svc", namespace: "${WRONG_NS}"}
  syncPolicy:
    automated: {}
    syncOptions: ["CreateNamespace=true"]
EOF
sleep 20
sync_status="$(kubectl get application "${APP_WRONG}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
if [ "${sync_status}" = "Synced" ] || kubectl get namespace "${WRONG_NS}" >/dev/null 2>&1; then
  _fail "an Application targeting a namespace outside destinations was allowed through — destinations is not being enforced"
else
  _pass "approved repo, unapproved namespace: refused, and ${WRONG_NS} was never created"
fi

smoke_done
