#!/usr/bin/env bash
# S09 L05 — narrowing the default cluster credential via impersonation.
#
# The claim: `argocd cluster add`'s default ServiceAccount grants a wide-open ClusterRole on the
# managed cluster, and Service Account Impersonation narrows the Application's effective identity
# to a scoped Role — proven live by syncing against the narrow Role, watching it fail on a missing
# verb, then succeed once the verb is added. This is inherently a two-cluster story (hub + prod-us)
# and inherently behavioural (a live sync failing and then succeeding), so none of it reproduces
# on a single-node CI cluster. The repo-side invariant this lesson shares with the rest of S09:
# no committed manifest hardcodes a cluster address.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L05 "the default argocd cluster add credential is wide open; impersonation narrows it to a scoped Role"
tier external

step "repo-side invariant: no hardcoded private/loopback IP in any committed manifest"
# An array, not a space-joined string — REPO_ROOT contains spaces ("Mastering GitOps with Argo
# CD"), and a space-joined path list silently word-splits into bogus grep targets that read
# nothing and report a green tick for a scan that never ran.
targets=()
for d in apps applicationsets bootstrap teams platform; do
  [ -d "${REPO_ROOT}/${d}" ] && targets+=("${REPO_ROOT}/${d}")
done
hits="$(grep -rInE '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|127\.0\.0\.1)([^0-9]|$)' \
  --include='*.yaml' --include='*.yml' --exclude=install.yaml "${targets[@]}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no hardcoded private or loopback IP in any committed manifest"
else
  _fail "hardcoded private/loopback IP found:\n${hits}"
fi

step "repo-side invariant: any committed narrowed Role for a managed cluster grants no wildcard verb"
# S09 L05's whole point is narrowing away from the wide-open default ClusterRole argocd
# cluster add creates. A committed "narrowed" Role that still grants '*' verbs or resources
# would be the lesson contradicting itself in its own companion repo.
if [ -d "${REPO_ROOT}/platform/clusters" ]; then
  hits2="$(grep -rIln 'storefront-deployer\|storefront-prod-us-role' "${REPO_ROOT}/platform/clusters" 2>/dev/null || true)"
  if [ -n "${hits2}" ]; then
    bad=""
    while IFS= read -r f; do
      [ -z "${f}" ] && continue
      grep -qE 'verbs: *\[.*"\*".*\]|resources: *\[.*"\*".*\]' "${f}" && bad="${bad}
  ${f#"${REPO_ROOT}"/}"
    done <<< "${hits2}"
    if [ -z "${bad}" ]; then
      _pass "the committed narrowed Role grants no wildcard verb or resource"
    else
      _fail "a narrowed Role still grants a wildcard — that is the default credential this lesson exists to replace:${bad}"
    fi
  else
    _pass "platform/clusters/ exists but the narrowed Role isn't committed yet"
  fi
else
  _pass "platform/clusters/ not committed yet — S09 L05 authors the narrowed Role live"
fi

needs_external "a second cluster (prod-us) with a real argocd-manager ClusterRoleBinding, and AppProject impersonation configured" \
  "verified by hand: the default ClusterRoleBinding grants '*' verbs/resources/API groups; a sync under the narrowed Role fails on the missing 'patch' verb (Argo CD's normal apply path patches an existing resource) and succeeds once it's added — this needs a second managed cluster, which this single k3s CI node does not have"
