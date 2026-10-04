#!/usr/bin/env bash
# lesson: s08_l03 List generator: naming a short fleet explicitly
# Repo invariant: every ApplicationSet labels what it generates with its own name.
#
# Argo CD v3.5.3 adds no label to the Applications an ApplicationSet generates; the only link back
# is the ownerReference (applicationset_controller.go at v3.5.3 copies the template's labels and
# nothing else). So the course never selects on argocd.argoproj.io/application-set-name, which
# matches nothing. Instead every ApplicationSet template sets
#     spec.template.metadata.labels.appset: <the ApplicationSet's own metadata.name>
# and every lesson lists its Applications with "kubectl get applications -n argocd -l appset=<name>".
# A committed ApplicationSet without that label, or with a label that names a different
# ApplicationSet, makes a lesson's listing print "No resources found" (or the wrong fleet).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S08-L03 "every committed ApplicationSet carries appset=<its own name> on its template, and every smoke script that selects on it sets it"
tier repo

step "committed manifests: spec.template.metadata.labels.appset equals metadata.name"
# Reads top-level documents only: an indented "kind: ApplicationSet" (the CRD's own names block in
# bootstrap/install.yaml, or prose in Markdown) is not a manifest and is not counted.
seen=0; bad=""
while IFS= read -r f; do
  while IFS=$'\t' read -r name label; do
    [ -n "${name}" ] || continue
    seen=$((seen+1))
    rel="${f#"${REPO_ROOT}"/}"
    if [ "${label}" = "${name}" ]; then
      _pass "${rel}: ${name} labels its Applications appset=${name}"
    else
      bad="${bad}\n    ${rel}: metadata.name '${name}', template label appset '${label:-<missing>}'"
    fi
  done < <(awk -v q="'" '
    function flush() { if (isas) printf "%s\t%s\n", name, label; isas=0; name=""; label=""; sect=""; tpl=0; tmeta=0; inlabels=0 }
    function unq(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub("^[\"" q "]|[\"" q "]$", "", s); return s }
    /^---/                      { flush(); next }
    /^[ \t]*#/                  { next }
    /^kind:[ \t]*ApplicationSet[ \t]*$/ { isas=1; next }
    /^[A-Za-z]/                 { sect=$1; tpl=0; tmeta=0; inlabels=0; next }
    sect=="metadata:" && /^  name:/ { sub(/^  name:/, ""); name=unq($0); next }
    sect=="spec:" && /^  [A-Za-z]/  { tpl=($0 ~ /^  template:/); tmeta=0; inlabels=0; next }
    tpl && /^    [A-Za-z]/          { tmeta=($0 ~ /^    metadata:/); inlabels=0; next }
    tmeta && /^      labels:[ \t]*\{/ { s=$0; if (match(s, /appset:[^,}]*/)) { v=substr(s, RSTART+7, RLENGTH-7); label=unq(v) } next }
    tmeta && /^      [A-Za-z]/      { inlabels=($0 ~ /^      labels:/); next }
    inlabels && /^        appset:/  { sub(/^        appset:/, ""); label=unq($0); next }
    END { flush() }
  ' "${f}")
done < <(grep -rlE --exclude-dir=.git --include='*.yaml' --include='*.yml' '^kind:[[:space:]]*ApplicationSet[[:space:]]*$' "${REPO_ROOT}" | sort)

# A scan that found nothing proves nothing: applicationsets/ holds four committed manifests today.
[ "${seen}" -ge 4 ] || _fail "found ${seen} committed ApplicationSet manifest(s), expected at least 4; the scan read nothing it should have"
[ -z "${bad}" ] || _fail "ApplicationSet template without its own appset label (lessons select -l appset=<name>):${bad}"
_pass "all ${seen} committed ApplicationSets label their Applications with their own name"

step "smoke scripts: none selects on the label v3.5.3 never sets"
hits="$(grep -nE 'application-set-name=' "${REPO_ROOT}"/test/smoke/s*.sh | grep -v "$(basename "${BASH_SOURCE[0]}")" || true)"
[ -z "${hits}" ] && _pass "no smoke script selects on argocd.argoproj.io/application-set-name" \
  || _fail "smoke scripts still select on a label Argo CD v3.5.3 never sets (they count 0):\n${hits}"

step "smoke scripts: every script that selects -l appset=\${APPSET} applies an ApplicationSet that sets it"
users=0
for s in "${REPO_ROOT}"/test/smoke/s*.sh; do
  [ "$(basename "$s")" = "$(basename "${BASH_SOURCE[0]}")" ] && continue
  grep -q -- '-l appset=${APPSET}' "$s" || continue
  users=$((users+1))
  grep -qE 'labels: \{appset: \$\{APPSET\}\}|^[[:space:]]+appset: \$\{APPSET\}' "$s" \
    && _pass "$(basename "$s") sets appset=\${APPSET} on the template it applies" \
    || _fail "$(basename "$s") selects -l appset=\${APPSET} but the ApplicationSet it applies never sets that label"
done
[ "${users}" -ge 3 ] || _fail "expected at least 3 smoke scripts selecting -l appset=\${APPSET} (s08_l03.sh, s08_l05.sh, s08_l13.sh), found ${users}"

smoke_done
