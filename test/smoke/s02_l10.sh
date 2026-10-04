#!/usr/bin/env bash
# lesson: s02_l10 Argo CD managing its own installation (self-management)
# Argo CD manages its OWN install, and reaches Synced/Healthy without ever running
# a real sync, because the committed manifest is byte-identical to what's running.
#
# The lesson's claim is specific: "it's already synced" the moment it's applied, with no visible
# reconcile, because bootstrap/install.yaml is the exact tag already on the cluster. That only
# holds if two things stay true: the committed manifest is still pinned to ${ARGOCD_PIN}, and
# the cluster is still running ${ARGOCD_PIN}. If either drifts (a version bump on one side and
# not the other), the self-manage Application would show OutOfSync immediately, and the
# lesson's "already synced" point would be false the moment a student tries it.
#
# Note: this script reads the Application's name out of the committed file,
# bootstrap/self-manage-app.yaml (which names it `argocd`), rather than assuming a name, so it
# stays correct if the file is ever changed.
#
# No cleanup: this is the same accumulating state s02_control_plane.sh and s02_l03.sh leave
# behind. The capstone section builds on it, and deleting the self-manage Application here
# would mean Argo CD no longer manages its own install afterward.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L10 "the self-manage Application reaches Synced/Healthy with no real sync, because the committed install manifest matches what's running"
tier cluster

step "both files this lesson commits are actually in the repo"
assert_exists_file "bootstrap/install.yaml"
assert_exists_file "bootstrap/self-manage-app.yaml"

step "the two details that go beyond what the lesson spells out, and both matter"
assert_file_contains "bootstrap/self-manage-app.yaml" 'prune: *false' \
  "prune: false: an accidental Git deletion cannot take Argo CD itself down with it"
assert_file_contains "bootstrap/self-manage-app.yaml" 'ServerSideApply=true' \
  "syncOptions carries ServerSideApply=true: without it this Application hits the exact 262144-byte wall from s02_l03.sh the moment it ever needs to actually sync"

assert_file_contains "bootstrap/self-manage-app.yaml" 'include: *"\{install.yaml,self-manage-app.yaml\}"' \
  "directory.include scopes it to its own two files: bootstrap/ also holds the App of Apps root and the edge AppProject"

step "the committed install manifest is pinned to the version actually running"
if grep -q "quay.io/argoproj/argocd:${ARGOCD_PIN}" "${REPO_ROOT}/bootstrap/install.yaml"; then
  _pass "bootstrap/install.yaml pins ${ARGOCD_PIN}, matching test/versions.env"
else
  _fail "bootstrap/install.yaml does not pin ${ARGOCD_PIN}: Step 1's claim of a byte-identical copy no longer holds, and the self-manage Application will show OutOfSync on first apply"
fi

running_image="$(kubectl -n argocd get deploy argocd-server -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
case "${running_image}" in
  *":${ARGOCD_PIN}")
    _pass "the running argocd-server is also on ${ARGOCD_PIN}"
    ;;
  *)
    _fail "the running argocd-server image is '${running_image:-unknown}', not ${ARGOCD_PIN}: the cluster and the committed manifest have drifted apart"
    ;;
esac

step "apply the self-manage Application and read its own name out of the file, not out of the prose"
app_name="$(awk '/^metadata:/{f=1;next} f && /name:/{print $2; exit}' "${REPO_ROOT}/bootstrap/self-manage-app.yaml")"
[ -n "${app_name}" ] || _fail "could not read metadata.name out of bootstrap/self-manage-app.yaml"
kubectl apply -n argocd -f "${REPO_ROOT}/bootstrap/self-manage-app.yaml" >/dev/null
wait_for_sync "${app_name}" 180

step "it reached Synced/Healthy WITHOUT running a real sync operation"
# If the committed manifest actually differed from the live objects, Argo CD would have run an
# operation with a non-empty resource list to reconcile that diff. "Already synced" means either
# no operationState at all, or one whose syncResult touched nothing.
op_resources="$(kubectl get application "${app_name}" -n argocd -o jsonpath='{.status.operationState.syncResult.resources}' 2>/dev/null)"
if [ -z "${op_resources}" ] || [ "${op_resources}" = "[]" ] || [ "${op_resources}" = "null" ]; then
  _pass "no real sync operation ran: the committed manifest was already identical to the live cluster"
else
  _fail "a sync operation ran with resources to reconcile (${op_resources}): the manifest was NOT actually byte-identical to what's running, contradicting the lesson's 'already synced' point"
fi

step "it did not sweep the rest of bootstrap/ onto the cluster"
if kubectl get application root -n argocd >/dev/null 2>&1; then
  _fail "an Application named root exists after the self-manage sync: the argocd Application is syncing bootstrap/root-app.yaml, which belongs to the App of Apps lesson (check directory.include)"
else
  _pass "no root Application: the self-manage Application stayed inside install.yaml and itself"
fi

smoke_done
