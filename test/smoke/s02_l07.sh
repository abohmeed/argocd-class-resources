#!/usr/bin/env bash
# S02 L07 — the admin password actually rotates; the OLD one stops working.
#
# The lesson's claim is not "argocd account update-password prints 'Password updated'" — a
# broken rotation could still print that. The claim that matters is behavioural: after
# rotation, the ORIGINAL bootstrap password must stop authenticating and the NEW one must work.
# If `update-password` ever silently no-opped (wrong account, wrong server, a swallowed error),
# the old password would keep working and the lesson's premise — "whatever gets typed here
# becomes the account's password going forward" — would be false while the CLI output still
# looked like success.
#
# This reuses the real "admin" account and the real Gateway route from S02 L06, because there
# is only one admin account to test. It leaves the password rotated at the end, same as the
# runbook's own Teardown ("None... stays active") — this is accumulating state other lessons
# in this section's narration assume, not a probe.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L07 "argocd account update-password really rotates the credential — the old bootstrap password stops working, the new one works"
tier cluster

if ! command -v argocd >/dev/null 2>&1; then
  step "argocd CLI not on PATH — installing ${ARGOCD_PIN} to match the server"
  curl -sSL -o /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_PIN}/argocd-linux-amd64" \
    && sudo install -m 555 /tmp/argocd /usr/local/bin/argocd \
    || _fail "could not install the argocd CLI"
fi

grep -q 'argocd\.local' /etc/hosts 2>/dev/null || echo '127.0.0.1 argocd.local' | sudo tee -a /etc/hosts >/dev/null

step "Argo CD is reachable over TLS through the S02 L06 Gateway route"
code="$(curl -sk -o /dev/null -w '%{http_code}' https://argocd.local:8443/ 2>/dev/null)"
[ "${code}" = "200" ] && _pass "https://argocd.local:8443/ -> 200" \
  || _fail "https://argocd.local:8443/ -> ${code:-no response} — S02 L06's route must be up before this lesson's Preconditions are met"

step "the bootstrap Secret exists and decodes to a real password"
initial_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
if [ -n "${initial_pw}" ]; then
  _pass "argocd-initial-admin-secret decodes to a non-empty password"
else
  _fail "argocd-initial-admin-secret is missing or empty — either a prior take already deleted it, or the bootstrap never ran; cannot test the rotation this lesson demonstrates"
fi

step "the bootstrap password logs in"
if argocd login argocd.local:8443 --insecure --username admin --password "${initial_pw}" >/dev/null 2>&1; then
  _pass "logged in with the bootstrap password"
else
  _fail "could not log in with the bootstrap password — either it was already rotated by an earlier take or the login path itself is broken"
fi

step "rotate the password"
new_pw="S02L07-probe-$(date +%s)"
if argocd account update-password --insecure --server argocd.local:8443 \
    --current-password "${initial_pw}" --new-password "${new_pw}" >/dev/null 2>&1; then
  _pass "argocd account update-password reported success"
else
  _fail "argocd account update-password failed outright"
fi

step "the NEW password logs in"
if argocd login argocd.local:8443 --insecure --username admin --password "${new_pw}" >/dev/null 2>&1; then
  _pass "logged in with the rotated password"
else
  _fail "the NEW password does not log in — rotation did not actually take effect, even though update-password reported success"
fi

step "the OLD bootstrap password must NOT log in anymore"
if argocd login argocd.local:8443 --insecure --username admin --password "${initial_pw}" >/dev/null 2>&1; then
  _fail "the OLD bootstrap password STILL logs in after rotation — update-password is cosmetic, not real, and the lesson's central claim is false"
else
  _pass "the old bootstrap password no longer authenticates — the rotation is real, not cosmetic"
fi

smoke_done
