#!/usr/bin/env bash
# lesson: s13_l05 Turning on the Source Hydrator for Northwind
# Turning on the Source Hydrator takes a separate component AND a flag. The standard
# install manifest ships neither.
#
# Re-anchored 2026-10-04 to the restored lesson and the v3.5.3 manifests. The earlier
# version of this script claimed the hydrator was "a flag on existing components, not a workload
# to deploy", and that the applicationset-controller read the flag. Both are wrong on 3.5.3:
#   - pushing hydrated manifests to Git is the job of the commit server (argocd-commit-server),
#     which only install-with-hydrator.yaml ships; the plain install.yaml this repo commits does
#     not, which is why setting sourceHydrator alone leaves the Application unable to resolve its
#     sync branch;
#   - hydrator.enabled in argocd-cmd-params-cm is read at startup by exactly two components, the
#     application controller and the API server (ARGOCD_HYDRATOR_ENABLED), so those are the two the
#     lesson restarts, and not the repo server;
#   - the push credential is a repository-write Secret created with kubectl, never committed.
# The lesson adds bootstrap/commit-server.yaml and the flag in the student's fork; this
# repo is the starting state, so this checks that state and the facts the lesson rests on.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S13-L05 "the Source Hydrator needs the separate commit server plus hydrator.enabled, read by the controller and API server only; the standard install ships neither"
tier repo

INSTALL="bootstrap/install.yaml"

# kind/name of every object in the install manifest whose text contains $1
objects_with() {
  awk -v pat="$1" '
    /^---/ { if (h) print kind "/" name; kind = ""; name = ""; h = 0; m = 0; next }
    /^kind:/ { kind = $2 }
    /^metadata:/ { m = 1; next }
    m && /^  name:/ { name = $2; m = 0 }
    index($0, pat) { h = 1 }
    END { if (h) print kind "/" name }' "${REPO_ROOT}/${INSTALL}" | sort
}

step "the pinned v3.5.3 install manifest defines sourceHydrator natively on the Application CRD"
assert_file_contains "${INSTALL}" 'sourceHydrator:' \
  "the Application CRD already carries sourceHydrator: no separate CRD to install"

step "the standard install ships no commit server: the component the hydrator needs to push"
if grep -q 'argocd-commit-server' "${REPO_ROOT}/${INSTALL}"; then
  _fail "${INSTALL} now contains argocd-commit-server: it is no longer the plain install.yaml the lesson starts from, so its 'nothing is pushing' failure would not reproduce"
else
  _pass "no argocd-commit-server in ${INSTALL}: that component only ships in install-with-hydrator.yaml, exactly the gap the lesson finds"
fi
if [ -e "${REPO_ROOT}/bootstrap/commit-server.yaml" ]; then
  _fail "bootstrap/commit-server.yaml is committed: the lesson renders it, so its starting state is gone"
else
  _pass "bootstrap/commit-server.yaml is not committed yet: the lesson renders it"
fi

step "the flag is read by the application controller and the API server, and by nothing else"
readers="$(objects_with 'ARGOCD_HYDRATOR_ENABLED' | tr '\n' ' ')"
if [ "${readers}" = "Deployment/argocd-server StatefulSet/argocd-application-controller " ]; then
  _pass "ARGOCD_HYDRATOR_ENABLED is wired into argocd-server and argocd-application-controller only, the two the lesson restarts"
else
  _fail "expected ARGOCD_HYDRATOR_ENABLED on exactly argocd-server and argocd-application-controller, found: ${readers:-none}"
fi
assert_file_contains "${INSTALL}" 'key: hydrator\.enabled' \
  "ARGOCD_HYDRATOR_ENABLED reads the hydrator.enabled key of argocd-cmd-params-cm"
if grep -qE '^ *hydrator\.enabled: *"?true' "${REPO_ROOT}/${INSTALL}"; then
  _fail "hydrator.enabled is already true in ${INSTALL}: the hydrator ships switched off, and the lesson turns it on"
else
  _pass "hydrator.enabled is not set in ${INSTALL}: the hydrator ships switched off"
fi

step "no standalone hydrator.yaml, and no committed push credential"
if find "${REPO_ROOT}" -iname 'hydrator.yaml' -not -path '*/.git/*' 2>/dev/null | grep -q .; then
  _fail "a hydrator.yaml exists in this repo: there is no standalone hydrate controller; the pieces are the commit server and the flag"
else
  _pass "no hydrator.yaml: there is no standalone hydrate controller to install"
fi
hits="$(grep -rlI --exclude-dir=.git 'secret-type: repository-write' "${REPO_ROOT}" 2>/dev/null | grep -v '/test/' || true)"
if [ -z "${hits}" ]; then
  _pass "no repository-write Secret is committed: the push credential is created with kubectl, never stored in Git"
else
  _fail "a repository-write Secret is committed:\n${hits}"
fi

smoke_done
