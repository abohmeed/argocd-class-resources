#!/usr/bin/env bash
# Run the per-lesson smoke suite for one tier, and report a census rather than a verdict.
#
#   ./test/smoke/run_all.sh repo       # needs nothing but a checkout — runs on every PR
#   ./test/smoke/run_all.sh cluster    # needs k3s + Argo CD — nightly, and on manifest changes
#   ./test/smoke/run_all.sh all
#
# Why a census. The suite's honesty problem is not failure, it is silence: a lesson that needs a
# browser for SSO, or a GitHub pull request, or four Multipass VMs, cannot run here — and if that
# script simply returns 0 it looks exactly like one that ran and passed. So those exit 78 and are
# counted and NAMED in their own column. A run that prints "62 passed" while 29 scripts did
# nothing is the failure mode this exists to make impossible.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
WANT="${1:-all}"

pass=0; fail=0; declared=0
failed_names=""; declared_names=""

for s in test/smoke/s[0-9][0-9]_l[0-9][0-9]*.sh; do
  [ -e "$s" ] || continue
  # The tier is declared inside the script; read it without running the script.
  t="$(grep -m1 -oE '^[[:space:]]*tier (repo|cluster|external)' "$s" | awk '{print $2}')"
  [ -n "$t" ] || { printf '  \033[31mFAIL\033[0m %s declares no tier\n' "$s"; fail=$((fail+1)); failed_names="${failed_names} $(basename "$s")"; continue; }

  case "$WANT" in
    all) ;;
    repo)    [ "$t" = "repo" ] || continue ;;
    cluster) [ "$t" = "repo" ] || [ "$t" = "cluster" ] || continue ;;
    *) echo "unknown tier '$WANT' (repo | cluster | all)" >&2; exit 2 ;;
  esac

  out="$(bash "$s" 2>&1)"; rc=$?
  case "$rc" in
    0)  pass=$((pass+1)) ;;
    78) declared=$((declared+1)); declared_names="${declared_names}\n    $(printf '%s' "$out" | grep -m1 DECLARED | sed 's/^  //')" ;;
    *)  fail=$((fail+1)); failed_names="${failed_names} $(basename "$s")"
        printf '%s\n' "$out" | tail -20 ;;
  esac
done

total=$((pass + fail + declared))
printf '\n'
printf '  ran and passed   %3d\n' "$pass"
printf '  failed           %3d%s\n' "$fail" "${failed_names:+ —${failed_names}}"
printf '  declared external%3d  (not run here, and not counted as passing)\n' "$declared"
[ "$declared" -gt 0 ] && printf '%b\n' "$declared_names"
printf '  ----------------------\n'
printf '  scripts seen     %3d\n' "$total"

[ "$fail" -eq 0 ] || exit 1
printf '\n\033[32m%s tier: %d passed, %d declared external, 0 failed\033[0m\n' "$WANT" "$pass" "$declared"
