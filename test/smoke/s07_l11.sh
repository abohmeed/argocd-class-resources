#!/usr/bin/env bash
# S07 L11 — groups to RBAC, and the 3.0 subject change that breaks old policies.
#
# The claim is that Argo CD 3.0 changed which claim it checks a `g` line's subject against for an
# OIDC/Dex-federated login: `federated_claims.user_id`, not the bare `sub` the token also carries.
# A `g` line written against the old `sub` value silently matches nobody after the change.
#
# There is no way to reproduce a real `federated_claims` claim without a real Dex-federated OIDC
# login through an actual identity provider — this repo's convention is Authentik (S07 L10), and
# that lesson is itself declared external for the same reason: a live browser handshake, not
# something a bash script drives headlessly. `federated_claims` does not exist on a local-account
# token at all (only on a federated one), so there is no local-account substitute that would
# actually exercise this claim rather than a different one.
#
# What IS checkable without SSO: this course's own committed RBAC snippet
# (teams/checkout/rbac-policy.csv.snippet) already documents this exact 3.0 change and keys its
# admin grant on a `federated_claims.user_id` placeholder, never a raw `sub`. That is the one
# artifact in this repo that could silently regress back to the pre-3.0 convention this lesson
# exists to warn against, so it is worth its own repo-tier check, every time, regardless of
# whether the live SSO path ever runs here.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S07-L11 "Argo CD 3.0 checks a federated g-line's subject against federated_claims.user_id, not sub — a policy keyed on the old claim silently matches nobody"
tier external

step "the one committed artifact that encodes this exact fact stays keyed on federated_claims.user_id, not sub"
SNIPPET="teams/checkout/rbac-policy.csv.snippet"
assert_exists_file "${SNIPPET}"
assert_file_contains "${SNIPPET}" 'federated_claims' \
  "${SNIPPET}'s admin g-line still documents the federated_claims.user_id convention"
# A `g` line's subject is its second comma-separated field. None may be a bare `sub`-shaped
# reference (the string "sub" on its own) where the federated_claims convention belongs instead —
# that would be the exact regression this lesson warns against landing back in committed policy.
bad="$(grep -E '^g,' "${REPO_ROOT}/${SNIPPET}" | awk -F',' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}' \
  | grep -xE 'sub' || true)"
if [ -z "${bad}" ]; then
  _pass "no committed g-line is keyed on a bare 'sub' subject"
else
  _fail "${SNIPPET} has a g-line keyed on the pre-3.0 'sub' subject — this is exactly the silent-match-nobody bug S07 L11 exists to warn against"
fi

step "no committed file leaks what could be a real decoded JWT subject or federated_claims value"
# The real values only ever exist in a live token, decoded on camera and pasted, never committed —
# both L11's own runbook and D-XXX-style course conventions say so explicitly. A long opaque
# base64url-looking string sitting next to "sub" or "federated_claims" in a committed file would
# mean a real identity got captured into source control by accident.
hits="$(grep -rIn --exclude-dir=.git --exclude-dir=test -E '"(sub|user_id)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]{20,}"' \
  "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no realistic decoded-JWT subject value committed anywhere"
else
  _fail "a realistic-looking sub/user_id value is committed — this looks like a real identity captured from a live token:\n${hits}"
fi

needs_external "a browser, a live Authentik login through Dex, and a real federated OIDC token to decode" \
  "verified once by hand instead, continuing directly from S07 L10's live session: the decoded token's sub and federated_claims.user_id differ, a g-line keyed on sub matches nobody, and the identical line re-keyed on federated_claims.user_id grants role:admin — not re-verifiable here because it depends on L10's own unresolved runtime gaps"
