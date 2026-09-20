#!/usr/bin/env bash
# S12 L08 — the ApplicationSet CRD's own annotation blows past kubectl's 262144-byte
# last-applied-configuration ceiling on a client-side apply, and --server-side --force-conflicts
# is the fix — not a bigger cluster, not a different flag.
#
# S02 L03 owns first-install diagnosis of the same wall; this lesson is the UPGRADE procedure.
# This script reproduces both halves against a real cluster: client-side fails with the exact
# "Too long" message (never confused with an RBAC Forbidden, which has a visibly different
# shape), and --server-side --force-conflicts succeeds against the identical file.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L08 "client-side apply of the ApplicationSet CRD hits the 262144-byte annotation wall; --server-side --force-conflicts does not"
tier cluster

install_url="https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.3/manifests/install.yaml"
tmpfile="$(mktemp)"
trap 'rm -f "${tmpfile}"' EXIT
curl -sfL -o "${tmpfile}" "${install_url}" || _fail "could not download the pinned v3.5.3 install manifest"

step "force a genuinely fresh client-side history on the CRD, so the wall is real rather than already-settled"
kubectl delete crd applicationsets.argoproj.io >/dev/null 2>&1 || true
kubectl apply -n argocd -f "${tmpfile}" >/dev/null 2>&1 || true

step "client-side apply of the same file fails on the CRD's annotation size, not on RBAC"
out="$(kubectl apply -n argocd -f "${tmpfile}" 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'Too long'; then
  _pass "client-side apply fails with the expected 'Too long' annotation-size error"
elif [ "${rc}" -eq 0 ]; then
  _fail "client-side apply SUCCEEDED — the CRD's ownership history is already server-side-settled on this cluster; this wall no longer reproduces here"
else
  _fail "client-side apply failed, but not with the expected 'Too long' message:\n${out}"
fi

step "the same failure looks nothing like an RBAC Forbidden — the two must never be confused"
forbidden_shape="$(kubectl get pods -n a-namespace-this-user-cannot-see 2>&1 | head -1)"
if printf '%s' "${forbidden_shape}" | grep -qE 'Forbidden|forbidden'; then
  _pass "an RBAC failure names a verb and a resource, and never mentions size — visibly different from Step 1's error"
else
  _fail "expected an RBAC Forbidden shape from a namespace this account cannot list, got:\n${forbidden_shape}"
fi

step "--server-side --force-conflicts succeeds on the identical file where client-side just failed"
if kubectl apply --server-side --force-conflicts -n argocd -f "${tmpfile}" >/dev/null 2>&1; then
  _pass "server-side apply with --force-conflicts succeeds"
else
  _fail "server-side apply with --force-conflicts also failed — this is the fix the entire lesson turns on"
fi

smoke_done
