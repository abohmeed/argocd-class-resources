#!/usr/bin/env bash
# Keeps every lesson and its smoke script in step, so the repo cannot drift away from the course.
#
# Each demo lesson has a smoke script, test/smoke/sNN_lMM.sh, that checks the commands and files
# the lesson uses. This script enforces the rules that keep that true:
#
#   1. every smoke script names its lesson on line 2      (# lesson: sNN_lMM <lesson title>)
#   2. every smoke script declares its lesson and a tier  (so the runner can report honestly)
#   3. no smoke script references a repo path that is not there
#   4. no smoke script pins an image tag that does not exist (hashicorp/http-echo:1.4.2)
#   5. optional: every demo lesson in the course's lesson index has a script, and each script's
#      header names the lesson that sits at its position
#
# Run it from a checkout; it needs no cluster. Check 5 needs the course's lesson index, a
# tab-separated file of "<id> <TAB> <NN - Section>/<NN - Lesson title>" lines that lives with the
# course materials, not in this repo. Point LESSON_INDEX at it to run check 5. Without it, check 5
# is skipped and says so; checks 1 to 4 still run and still decide the exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

# --- 1. every per-lesson script names its lesson on line 2 -------------------------------------
# The header carries the lesson's position (the file name's sNN_lMM) and its title. If a lesson is
# renumbered, its script's file name and header have to move with it, and check 5 notices when
# they do not.
for s in "${ROOT}"/test/smoke/s[0-9][0-9]_l[0-9][0-9]*.sh; do
  [ -e "$s" ] || continue
  n="$(basename "$s" .sh)"
  id="${n:0:7}"
  line2="$(sed -n 2p "$s")"
  case "${line2}" in
    "# lesson: ${id} "?*) ;;
    *) echo "FAIL ${n}.sh line 2 must be '# lesson: ${id} <lesson title>', has '${line2}'" >&2; fail=1 ;;
  esac
done

# --- 2. every per-lesson script declares its lesson and tier -----------------------------------
for s in "${ROOT}"/test/smoke/s[0-9][0-9]_l[0-9][0-9]*.sh; do
  [ -e "$s" ] || continue
  n="$(basename "$s")"
  grep -qE '^[[:space:]]*lesson [A-Z][0-9]{2}-L[0-9]{2}' "$s" \
    || { echo "FAIL ${n} does not declare its lesson (needs: lesson SNN-LMM \"<claim>\")" >&2; fail=1; }
  grep -qE '^[[:space:]]*tier (repo|cluster|external)' "$s" \
    || { echo "FAIL ${n} does not declare a tier (repo | cluster | external)" >&2; fail=1; }
  # An external script must never claim a pass; smoke_done is the only thing allowed to print one.
  if grep -qE '^[[:space:]]*tier external' "$s" && grep -qE '^[[:space:]]*smoke_done' "$s"; then
    echo "FAIL ${n} is tier external but calls smoke_done: a script that did not run must not report a pass" >&2
    fail=1
  fi
done

# --- 3. referenced repo paths exist ------------------------------------------------------------
# A script may name a path that does not exist BECAUSE ITS LESSON DEPENDS ON THE ABSENCE.
# One lesson points Argo CD at `apps/storefront/overlays/development` on purpose and reads the
# resulting error; its smoke script asserts the path stays missing. Flagging that would demand the
# very thing that breaks the lesson. So a script that declares the absence is exempt, and the
# declaration has to be in the file, which is what keeps this from becoming a blanket hole.
for s in "${ROOT}"/test/smoke/s*.sh; do
  [ -e "$s" ] || continue
  grep -qiE 'on purpose|does not exist|deliberately|the typo is the lesson|absence' "$s" && continue
  while IFS= read -r p; do
    [ -e "${ROOT}/${p}" ] || { echo "FAIL $(basename "$s") references a path that does not exist: ${p}" >&2; fail=1; }
  done < <(grep -oE 'apps/[a-z-]+/(base|manifests|overlays/[a-z-]+)' "$s" | sort -u)
done

# --- 4. no dead image tag ----------------------------------------------------------------------
# hashicorp/http-echo:1.4.2 does not exist (HTTP 404) and ends in ImagePullBackOff. 1.4.2 is
# legitimate ONLY on the fictional ghcr.io/northwind image, which nothing ever pulls.
for s in "${ROOT}"/test/smoke/s*.sh; do
  [ -e "$s" ] || continue
  # The smoke scripts that GUARD against this tag naturally contain it: in a _fail message, in a
  # _pass message saying it is absent, or in a comment explaining the trap. Only a line that is
  # neither a warning nor an assertion counts as a use.
  if grep -E 'hashicorp/http-echo:1\.4\.2' "$s" \
     | grep -qvEi 'never|not exist|non-existent|nonexistent|404|do not|trap|would|_fail|_pass|^#|assert|guard'; then
    echo "FAIL $(basename "$s") pins hashicorp/http-echo:1.4.2, which does not exist" >&2
    fail=1
  fi
done

# --- 5. optional: coverage against the course's lesson index -----------------------------------
# A lesson folder holding Do.md and no visuals.yaml is a demo lesson and owes a smoke script named
# for its position. The script's header title must match the lesson's title, which is what catches
# a renumber that moved a lesson out from under its script. Folder titles use " - " where the
# lesson title has a colon or a comma, so titles are compared with that punctuation folded away.
norm() { printf '%s' "$1" | sed -E 's/ - / /g; s/[:,]//g'; }
INDEX="${LESSON_INDEX:-}"
if [ -n "${INDEX}" ] && [ -f "${INDEX}" ]; then
  COURSE="${LESSON_COURSE_DIR:-$(cd "$(dirname "${INDEX}")/.." && pwd)}"
  missing=""; wrongtitle=""; demos=0
  while IFS=$'\t' read -r key folder; do
    case "${key}" in ''|'#'*) continue ;; esac
    dir="${COURSE}/${folder}"
    [ -f "${dir}/Do.md" ] || continue
    [ -e "${dir}/visuals.yaml" ] && continue
    demos=$((demos+1))
    sec="${folder%%/*}"; sec="${sec%% *}"                 # "02"
    les="${folder#*/}";  les="${les%% *}"                 # "04"
    title="${folder#*/}"; title="${title#* - }"           # lesson title, folder spelling
    id="s${sec}_l${les}"
    s="${ROOT}/test/smoke/${id}.sh"
    if [ ! -e "${s}" ]; then
      missing="${missing} ${id}"
      continue
    fi
    has="$(sed -n 2p "${s}")"; has="${has#"# lesson: ${id} "}"
    if [ "$(norm "${has}")" != "$(norm "${title}")" ]; then
      wrongtitle="${wrongtitle}\n    ${id}.sh: expected '${title}', has '${has}'"
    fi
  done < "${INDEX}"
  if [ "${demos}" -eq 0 ]; then
    echo "FAIL coverage read ${INDEX} but found no demo lesson folders under ${COURSE}; the check ran on nothing" >&2
    fail=1
  fi
  if [ -n "$missing" ]; then
    echo "FAIL demo lessons with no smoke script:${missing}" >&2
    fail=1
  fi
  if [ -n "$wrongtitle" ]; then
    printf 'FAIL smoke scripts whose header does not name the lesson at their position:%b\n' "${wrongtitle}" >&2
    fail=1
  fi
  [ -z "${missing}${wrongtitle}" ] && [ "${demos}" -gt 0 ] \
    && echo "ok   every one of ${demos} demo lessons has a smoke script whose header names it"
else
  echo "skip coverage against the lesson index: LESSON_INDEX is not set, so checks 1 to 4 ran without it"
fi

[ "$fail" -eq 0 ] || exit 1
echo "ok   every smoke script names its lesson, declares a tier, and references only paths that exist"
