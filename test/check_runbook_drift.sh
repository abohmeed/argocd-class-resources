#!/usr/bin/env bash
# The mechanism that makes repo drift structurally impossible.
#
# A lesson's screen guide and its smoke script must agree, and every demo lesson must have one.
# The runbooks now exist, so this enforces the full invariant rather than the weaker placeholder
# it started as:
#
#   1. every DEMO lesson has a smoke script                     (coverage — nothing silently unbuilt)
#   2. every smoke script names its lesson and declares a tier  (so the runner can be honest)
#   3. no smoke script references a repo path that is not there (the original check, kept)
#   4. no smoke script pins an image tag that does not exist    (the 1.4.2 trap)
#
# Run from a checkout; needs no cluster. The course share is not assumed to be present — when it
# is not, coverage is skipped LOUDLY rather than quietly passing, because a coverage check that
# cannot see the lesson list is a coverage check that always agrees with you.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHARE="$(cd "${ROOT}/.." 2>/dev/null && pwd)"
fail=0

# --- 1. coverage: every demo lesson has a script ---------------------------------------------
if [ -d "${SHARE}/_scripts/draft" ] && [ -d "${SHARE}/_visuals" ]; then
  missing=""
  for f in "${SHARE}"/_scripts/draft/*.script.md; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .script.md)"                       # SNN-LMM
    # A lesson with a visuals spec is a LECTURE — the screen is its visual, and it gets no script.
    [ -e "${SHARE}/_visuals/${id}.visuals.yaml" ] && continue
    sec="$(printf '%s' "$id" | cut -d- -f1 | tr '[:upper:]' '[:lower:]')"
    les="$(printf '%s' "$id" | cut -d- -f2 | tr '[:upper:]' '[:lower:]')"
    [ -e "${ROOT}/test/smoke/${sec}_${les}.sh" ] || missing="${missing} ${id}"
  done
  if [ -n "$missing" ]; then
    echo "FAIL demo lessons with no smoke script:${missing}" >&2
    fail=1
  else
    echo "ok   every demo lesson has a smoke script"
  fi
else
  echo "SKIP coverage — the course share is not mounted beside this repo, so the lesson list" >&2
  echo "     cannot be read. This is NOT a pass: run this check from the share to verify coverage." >&2
fi

# --- 2. every per-lesson script declares its lesson and tier ---------------------------------
for s in "${ROOT}"/test/smoke/s[0-9][0-9]_l[0-9][0-9]*.sh; do
  [ -e "$s" ] || continue
  n="$(basename "$s")"
  grep -qE '^[[:space:]]*lesson [A-Z][0-9]{2}-L[0-9]{2}' "$s" \
    || { echo "FAIL ${n} does not declare its lesson (needs: lesson SNN-LMM \"<claim>\")" >&2; fail=1; }
  grep -qE '^[[:space:]]*tier (repo|cluster|external)' "$s" \
    || { echo "FAIL ${n} does not declare a tier (repo | cluster | external)" >&2; fail=1; }
  # An external script must never claim a pass; smoke_done is the only thing allowed to print one.
  if grep -qE '^[[:space:]]*tier external' "$s" && grep -qE '^[[:space:]]*smoke_done' "$s"; then
    echo "FAIL ${n} is tier external but calls smoke_done — an unrun lesson must not report a pass" >&2
    fail=1
  fi
done

# --- 3. referenced repo paths exist -----------------------------------------------------------
# A script may name a path that does not exist BECAUSE ITS LESSON DEPENDS ON THE ABSENCE.
# S03 L01 points Argo CD at `apps/storefront/overlays/development` on purpose and reads the
# resulting error on screen; its smoke script asserts the path stays missing. Flagging that would
# demand the very thing that breaks the lesson. So a script that declares the absence is exempt —
# and the declaration has to be in the file, which is what keeps this from becoming a blanket hole.
for s in "${ROOT}"/test/smoke/s*.sh; do
  [ -e "$s" ] || continue
  grep -qiE 'on purpose|does not exist|deliberately|the typo is the lesson|absence' "$s" && continue
  while IFS= read -r p; do
    [ -e "${ROOT}/${p}" ] || { echo "FAIL $(basename "$s") references a path that does not exist: ${p}" >&2; fail=1; }
  done < <(grep -oE 'apps/[a-z-]+/(base|manifests|overlays/[a-z-]+)' "$s" | sort -u)
done

# --- 4. no dead image tag ---------------------------------------------------------------------
# hashicorp/http-echo:1.4.2 does not exist (HTTP 404) and ImagePullBackOffs on camera. 1.4.2 is
# legitimate ONLY on the fictional ghcr.io/northwind image, which nothing ever pulls. Lines that
# warn AGAINST the tag are not uses of it.
for s in "${ROOT}"/test/smoke/s*.sh; do
  [ -e "$s" ] || continue
  # The smoke scripts that GUARD against this tag naturally contain it — in a _fail message, in a
  # _pass message saying it is absent, or in a comment explaining the trap. Only a line that is
  # neither a warning nor an assertion counts as a use.
  if grep -E 'hashicorp/http-echo:1\.4\.2' "$s" \
     | grep -qvEi 'never|not exist|non-existent|nonexistent|404|do not|trap|would|_fail|_pass|^#|assert|guard'; then
    echo "FAIL $(basename "$s") pins hashicorp/http-echo:1.4.2, which does not exist" >&2
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "ok   every smoke script names a lesson, declares a tier, and references only paths that exist"
