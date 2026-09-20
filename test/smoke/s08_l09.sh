#!/usr/bin/env bash
# S08 L09 — SCM Provider generator: the fleet discovers new repos.
#
# The lesson's claim: an scmProvider generator filtered by a shared GitHub topic discovers
# every repo under the instructor's own account carrying that topic, with none of them named in
# the ApplicationSet — and a repo created live, tagged with the same topic, is picked up on a
# forced refresh with no edit to the generator. This needs real repos created under a live
# GitHub account (gh repo create), a real token Secret, and a live scmProvider reconcile — none
# of which this repo's CI can do without writing GitHub objects into someone's real account on
# every run. So this defends the one thing checkable from the repo alone.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L09 "an scmProvider generator filtered by topic discovers every matching repo, with none of them named by hand"
tier external

step "repo-side invariant: this lesson's ApplicationSet is not committed anywhere in the repo"
# scm-appset.yaml is a scratch file the runbook builds live and never commits (same pattern as
# L02/L03's appset.yaml). If a committed manifest ever starts using this generator, this
# script's tier and its repo-side checks need revisiting, not just a passing grep.
assert_exists_dir "applicationsets"
for f in "${REPO_ROOT}"/applicationsets/*.yaml; do
  [ -e "${f}" ] || continue
  if grep -q 'scmProvider:' "${f}"; then
    _fail "${f#"${REPO_ROOT}"/} already commits an scmProvider generator — L09 builds scm-appset.yaml live and never commits it; if this is intentional, this script's 'external' tier needs revisiting"
  fi
done
_pass "no committed ApplicationSet uses the scmProvider generator"

needs_external "real repositories created under a live GitHub account (gh repo create), a scm-github-token Secret, and a live scmProvider reconcile" \
  "verified once by hand: two seed repos tagged with the shared topic were both discovered as Application objects with neither named in the ApplicationSet; a third repo created live and tagged the same way was picked up on a forced refresh with no edit to scm-appset.yaml"
