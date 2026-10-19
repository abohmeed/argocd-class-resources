#!/usr/bin/env bash
# lesson: s02_l10 Rotating or deleting Argo CD's initial admin secret
# The admin password actually rotates; the OLD one stops working.
#
# The lesson's claim is not "argocd account update-password prints 'Password updated'": a
# broken rotation could still print that. The claim that matters is behavioural: after
# rotation, the ORIGINAL bootstrap password must stop authenticating and the NEW one must work.
# If `update-password` ever silently no-opped (wrong account, wrong server, a swallowed error),
# the old password would keep working and the lesson's premise: "whatever gets typed here
# becomes the account's password going forward": would be false while the CLI output still
# looked like success.
#
# This reuses the real "admin" account and the real Gateway route from the TLS lesson
# (s02_l09.sh), because there is only one admin account to test. It leaves the password rotated
# at the end, same as the lesson does: this is accumulating state the rest of this section
# assumes, not a probe.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L10 "argocd account update-password really rotates the credential: the old bootstrap password stops working, the new one works"
tier cluster

if ! command -v argocd >/dev/null 2>&1; then
  step "argocd CLI not on PATH: installing ${ARGOCD_PIN} to match the server"
  curl -sSL -o /tmp/argocd "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_PIN}/argocd-linux-amd64" \
    && sudo install -m 555 /tmp/argocd /usr/local/bin/argocd \
    || _fail "could not install the argocd CLI"
fi

grep -q 'argocd\.local' /etc/hosts 2>/dev/null || echo '127.0.0.1 argocd.local' | sudo tee -a /etc/hosts >/dev/null

step "Argo CD is reachable over TLS through the Gateway route from the TLS lesson"
code="$(curl -sk -o /dev/null -w '%{http_code}' https://argocd.local/ 2>/dev/null)"
[ "${code}" = "200" ] && _pass "https://argocd.local/ -> 200" \
  || _fail "https://argocd.local/ -> ${code:-no response}: the Gateway route from the TLS lesson (s02_l09.sh) must be up before this lesson can run"

step "the bootstrap Secret exists and decodes to a real password"
initial_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)"
if [ -n "${initial_pw}" ]; then
  _pass "argocd-initial-admin-secret decodes to a non-empty password"
else
  _fail "argocd-initial-admin-secret is missing or empty: either an earlier run already deleted it, or the bootstrap never ran; cannot test the rotation this lesson demonstrates"
fi

step "the bootstrap password logs in"
if argocd login argocd.local --insecure --username admin --password "${initial_pw}" >/dev/null 2>&1; then
  _pass "logged in with the bootstrap password"
else
  _fail "could not log in with the bootstrap password: either it was already rotated by an earlier run or the login path itself is broken"
fi

step "rotate the password"
new_pw="rotation-probe-$(date +%s)"
if argocd account update-password --insecure --server argocd.local \
    --current-password "${initial_pw}" --new-password "${new_pw}" >/dev/null 2>&1; then
  _pass "argocd account update-password reported success"
else
  _fail "argocd account update-password failed outright"
fi

step "the NEW password logs in"
if argocd login argocd.local --insecure --username admin --password "${new_pw}" >/dev/null 2>&1; then
  _pass "logged in with the rotated password"
else
  _fail "the NEW password does not log in: rotation did not actually take effect, even though update-password reported success"
fi

step "the OLD bootstrap password must NOT log in anymore"
if argocd login argocd.local --insecure --username admin --password "${initial_pw}" >/dev/null 2>&1; then
  _fail "the OLD bootstrap password STILL logs in after rotation: update-password is cosmetic, not real, and the lesson's central claim is false"
else
  _pass "the old bootstrap password no longer authenticates: the rotation is real, not cosmetic"
fi

# Teardown for the suite, not a lesson step: the random password above exists only in this script, and every
# later lesson that logs in as admin (through argocd.local, with the bootstrap secret the lesson teaches) would
# fail on it. Set the bootstrap value back, as the admin account's own update-password does, and check it logs in.
step "restore the bootstrap password, so the admin logins later lessons use still work on this cluster"
argocd login argocd.local --insecure --username admin --password "${new_pw}" >/dev/null 2>&1 || true
if argocd account update-password --insecure --server argocd.local \
    --current-password "${new_pw}" --new-password "${initial_pw}" >/dev/null 2>&1 \
   && argocd login argocd.local --insecure --username admin --password "${initial_pw}" >/dev/null 2>&1; then
  _pass "the bootstrap password is back in place for the later sections"
else
  _fail "could not restore the bootstrap password: every later admin login on this cluster will fail"
fi

smoke_done
