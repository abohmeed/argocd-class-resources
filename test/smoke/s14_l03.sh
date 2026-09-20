#!/usr/bin/env bash
# S14 L03 — the Matrix ApplicationSet templates on .git.path.basename (directory-mode's real
# parameter, once pathParamPrefix nests it under "git"), never the bare .git.team this lesson's
# own runbook mistakenly worried about — and it never uses the legacy dot-less {{name}} form,
# which is a hard parse error on goTemplate: true.
#
# assert_no_legacy_appset_templating already sweeps every applicationset in this repo for the
# dot-less trap; this script adds the field-name check specific to this generator and then
# dry-runs it for real against the live repo.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S14-L03 "the Matrix generator templates on .git.path.basename, never the legacy dot-less form or a nonexistent .git.team"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

step "repo-tier: applicationsets/teams-fleet.yaml exists and templates on .git.path.basename"
assert_exists_file "applicationsets/teams-fleet.yaml"
assert_file_contains "applicationsets/teams-fleet.yaml" '\{\{ \.git\.path\.basename \}\}' \
  "teams-fleet.yaml's template resolves the team name from .git.path.basename"
assert_file_lacks "applicationsets/teams-fleet.yaml" '\{\{ *\.git\.team *\}\}' \
  "teams-fleet.yaml does not reference a nonexistent .git.team field — this lesson's own runbook flags that field name as unverified; the committed file does not actually use it"
assert_no_legacy_appset_templating

step "the committed generator dry-runs without error against the live repo and cluster"
if command -v argocd >/dev/null 2>&1; then
  out="$(argocd appset generate applicationsets/teams-fleet.yaml 2>&1)" && rc=0 || rc=$?
  # The Cluster generator half of this Matrix only yields rows once a cluster carries
  # tier: staging (Step 5/6 of this lesson's own runbook) — a matrix with an empty side
  # legitimately produces zero Applications. So this does not require a specific row count;
  # it requires that the template's field references resolve without error, which is the
  # actual claim in question (not "how many clusters are registered right now").
  if [ "${rc}" -eq 0 ]; then
    _pass "argocd appset generate resolves teams-fleet.yaml without error — .git.path.basename and every other field reference are valid"
  elif printf '%s' "${out}" | grep -qE 'function ".*" not defined|map has no entry for key|nil pointer'; then
    _fail "argocd appset generate failed on a field-resolution error — exactly the class of bug this lesson is about:\n${out}"
  else
    _fail "argocd appset generate failed:\n${out}"
  fi
else
  _fail "the argocd CLI is not on PATH — cannot dry-run the generator"
fi

smoke_done
