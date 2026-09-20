#!/usr/bin/env bash
# S11 L03 — a CI pipeline that gates the image push on its own tests.
#
# The lesson runs in GitHub Actions against the app repository, breaks a test, and shows the push
# not happening. None of that can run inside this repo's CI: it needs a second repository, a
# GHCR token, and a workflow run. So this script asserts what IS checkable from here and then
# DECLARES the rest rather than returning a green it has not earned.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S11-L03 "the image push depends on the tests, so a red test ships nothing"
tier external

step "repo-side invariant: this repo must NOT contain the application's source"
# The whole point of S11 L02/L03 is that source and config live apart. If a Dockerfile or a Go
# module ever appears here, the deploy-loop the section warns about becomes possible in the very
# repo that teaches against it.
for stray in Dockerfile go.mod package.json pyproject.toml; do
  if [ -e "${REPO_ROOT}/${stray}" ]; then
    _fail "${stray} is in the CONFIG repo — S11 L02 teaches that source and config live apart, and this breaks it"
  fi
done
_pass "no application source in the config repo — the app/config split the section teaches is intact"

step "repo-side invariant: nothing here writes back into the repo it builds from"
if grep -rlE 'git (commit|push)' "${REPO_ROOT}/.github/workflows" >/dev/null 2>&1; then
  _fail "a workflow in this repo commits or pushes — that is exactly the write-back loop S11 L02 warns about"
fi
_pass "no workflow in this repo commits back into it"

needs_external "the app repository (abohmeed/argocd-class-app), a GHCR token and a live Actions run" \
  "verified once by hand instead: passing tests build the static binary, and a deliberately broken test halts the run before the build step — the live run published ghcr.io/abohmeed/argocd-class-app:<sha>"
