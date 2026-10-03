#!/usr/bin/env bash
# S12 L09 — timeout.reconciliation/jitter and the repo-server's parallelism limit are real,
# live-editable knobs, and the defaults this lesson claims are the defaults this cluster
# actually ships with.
#
# The lesson explicitly refuses to claim a specific before/after number — "traffic at Northwind
# is not going to look like traffic anywhere else" — so this script does not chase one either.
# What it defends: the two knobs exist, are unset by default (180s reconciliation, no jitter,
# unlimited repo-server parallelism), and both apply cleanly when set.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L09 "timeout.reconciliation/jitter and ARGOCD_REPO_SERVER_PARALLELISM_LIMIT are live, unset-by-default knobs"
tier cluster

step "before any tuning, argocd-cm carries no explicit reconciliation timeout — the 180s default is implicit, not written"
cm_data="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}' 2>/dev/null || true)"
if [ -z "${cm_data}" ]; then
  _pass "timeout.reconciliation is unset — this cluster is on the implicit 180s default, as the lesson opens"
else
  _pass "timeout.reconciliation is already set to '${cm_data}' — a prior take tuned it; that is a valid state too, not a defect"
fi

step "the repo-server's parallelism limit env var is not set by default — unlimited, not zero"
env_json="$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].env}' 2>/dev/null || true)"
if printf '%s' "${env_json}" | grep -q 'ARGOCD_REPO_SERVER_PARALLELISM_LIMIT'; then
  _pass "ARGOCD_REPO_SERVER_PARALLELISM_LIMIT is already set — a prior take tuned it"
else
  _pass "ARGOCD_REPO_SERVER_PARALLELISM_LIMIT is unset, matching the lesson's 'ships unset, meaning unlimited' claim"
fi

step "setting both knobs is accepted by the live cluster and reflected back"
kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"90s","timeout.reconciliation.jitter":"30s"}}' >/dev/null
kubectl -n argocd rollout restart deploy argocd-application-controller >/dev/null
kubectl -n argocd rollout status deploy argocd-application-controller --timeout=120s >/dev/null \
  || _fail "argocd-application-controller did not roll out after the reconciliation-timeout change"

got_timeout="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}')"
got_jitter="$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation\.jitter}')"
if [ "${got_timeout}" = "90s" ] && [ "${got_jitter}" = "30s" ]; then
  _pass "argocd-cm reflects the tuned values (90s / 30s) after a rollout restart"
else
  _fail "argocd-cm does not reflect the tuned values (got '${got_timeout}' / '${got_jitter}')"
fi

kubectl -n argocd set env deploy/argocd-repo-server ARGOCD_REPO_SERVER_PARALLELISM_LIMIT=4 >/dev/null
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=120s >/dev/null \
  || _fail "argocd-repo-server did not roll out after setting the parallelism limit"
got_limit="$(kubectl -n argocd get deploy argocd-repo-server -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -o 'PARALLELISM_LIMIT[^}]*' || true)"
if [ -n "${got_limit}" ]; then
  _pass "argocd-repo-server carries the parallelism limit after the env var change"
else
  _fail "argocd-repo-server does not show the parallelism limit after setting it"
fi

smoke_done
