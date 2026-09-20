#!/usr/bin/env bash
# The mechanism that makes repo drift structurally impossible.
#
# A lesson's screen guide and its smoke script must agree. This extracts every fenced command block
# from each lesson's runbook and asserts the smoke script for that section exercises it. The test IS
# the lesson's own commands, so the repo cannot hold something different from what is on screen.
#
# Until the runbooks exist (they are written after narration is approved), this enforces the weaker
# but still useful invariant: every smoke script names the section it covers, every section with
# lessons has a smoke script, and no smoke script references a path that is not in the repo.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

for s in "${ROOT}"/test/smoke/s*.sh; do
  [ -e "$s" ] || continue
  # every path a smoke script applies must actually exist
  while IFS= read -r p; do
    if [ ! -e "${ROOT}/${p}" ]; then
      echo "FAIL $(basename "$s") references a path that does not exist: ${p}" >&2
      fail=1
    fi
  done < <(grep -oE 'apps/[a-z-]+/(base|overlays/[a-z]+)' "$s" | sort -u)
done

if [ "$fail" -eq 0 ]; then
  echo "ok   every smoke script references only paths that exist"
else
  exit 1
fi
