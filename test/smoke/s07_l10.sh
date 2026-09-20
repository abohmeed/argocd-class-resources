#!/usr/bin/env bash
# S07 L10 — standing up SSO end to end: Authentik, Dex, and first login.
#
# None of this lesson's actual claim runs in CI. It installs a second stateful component
# (Authentik, its own Postgres/Redis), provisions it through a Blueprint whose exact chart-values
# shape the runbook itself flags as unverified, and closes on `argocd login --sso`, which opens a
# real browser at a real identity provider's login page — there is no headless equivalent to
# automate here honestly. The runbook's own header already marks this lesson "RUNTIME OWED": this
# script does not pretend otherwise.
#
# What IS checkable from a repo checkout, and is worth checking every time regardless of whether
# the live SSO path is ever exercised in CI:
#   - the course's own stated choice of identity provider. Authentik, never Keycloak — the runbook
#     names the reason (Keycloak's default footprint was rejected for this course's node budget).
#     A stray Keycloak reference would mean the course drifted from its own documented decision.
#   - no OIDC client secret committed anywhere looks like a real credential. A realistic-looking
#     token shape gets the whole repo push rejected by GitHub push protection — this exists to
#     catch that before a push does, not after.
#   - versions.env pins every other external tool this course installs; Authentik does not have an
#     entry yet, and the runbook's own Preconditions flag that gap. This assertion is EXPECTED TO
#     FAIL until that pin is added — that is real, current, and this script's job is to say so
#     rather than quietly not check it.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L10 "Authentik (never Keycloak) is the identity provider; SSO first-login is a live, browser-driven OIDC handshake this suite cannot automate honestly"
tier external

step "the course's own documented identity-provider choice holds: no Keycloak reference anywhere"
hits="$(grep -rIli --exclude-dir=.git --exclude-dir=test -e 'keycloak' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no Keycloak reference in the repo — Authentik is the only identity provider named"
else
  _fail "Keycloak referenced in: ${hits} — S07 L10's own runbook explains why Keycloak was rejected for this course; this drifted from that decision"
fi

step "no OIDC client secret committed anywhere looks like a real credential"
hits="$(grep -rIln --exclude-dir=.git --exclude-dir=test -iE 'client[_-]?secret' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no clientSecret/client_secret reference committed yet — nothing to check the shape of"
else
  bad=""
  while IFS= read -r f; do
    # A real secret is a long, dense base64/hex-looking token. A placeholder is angle-bracketed
    # or reads like an instruction (contains a space, or starts with < or REPLACE).
    while IFS= read -r line; do
      val="$(printf '%s' "${line}" | grep -oiE 'client[_-]?secret["'"'"']?\s*[:=]\s*["'"'"']?[^"'"'"',[:space:]]+' | sed -E 's/.*[:=][[:space:]]*["'"'"']?//')"
      [ -z "${val}" ] && continue
      case "${val}" in
        \<*|REPLACE*|CHANGE*|TODO*|YOUR_*) ;;
        *) if printf '%s' "${val}" | grep -qE '^[A-Za-z0-9_./+=-]{20,}$'; then bad="${bad}\n  ${f}: ${val}"; fi ;;
      esac
    done < <(grep -iE 'client[_-]?secret' "${f}")
  done <<< "${hits}"
  if [ -z "${bad}" ]; then
    _pass "every committed client-secret-looking reference is an obvious placeholder, not a realistic token"
  else
    _fail "a client-secret-looking value is NOT an obvious placeholder — this would get the repo's next push rejected by GitHub push protection, or worse, actually leak a credential:${bad}"
  fi
fi

step "versions.env: Authentik's version pin (this is a known, currently-open gap — see the runbook's own Preconditions callout)"
assert_file_contains "test/versions.env" "AUTHENTIK" \
  "Authentik has a pinned version like every other external tool this course installs (versions.env)"

needs_external "a browser, a live Authentik instance, and a real Dex OIDC handshake" \
  "verified once by hand instead, on the recording cluster, once the two gaps this runbook flags (the missing AUTHENTIK_VERSION pin and the untested multi-host TLS/HTTPRoute plumbing) are resolved — not yet done as of the runbook's own 'RUNTIME OWED' header"
