#!/usr/bin/env bash
# Shared assertions for the smoke suite.
#
# Every script sources this. Nothing here is clever on purpose: a test harness that is hard to read
# is a test harness nobody fixes when it goes red.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/test/versions.env"

_pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
# %b, not %s: several call sites embed "\n<details>" to print captured output under the
# headline. With %s those arrive as a literal backslash-n and the details run on one line.
_fail() {
  printf "  \033[31mFAIL\033[0m %b\n" "$1" >&2
  argocd_cli_release 2>/dev/null || true
  exit 1
}

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# _require_dirs <dir>... — every directory a repo-wide scan claims to cover must exist.
#
# The scans below pipe grep through `|| true`, because grep exits 1 when it finds nothing and
# "found nothing" is the passing case. That same `|| true` also swallows "No such file or
# directory", so a scan over a directory that is not there reports ok having read nothing —
# a green tick from a path that did no work. This was not hypothetical: `platform/` held only
# empty subdirectories, git does not track those, and the first push produced a repo where
# `assert_images_pinned` and `assert_no_plaintext_secrets` both passed while scanning a
# directory that did not exist. Absence must fail loudly or the check is decoration.
_require_dirs() {
  local d
  for d in "$@"; do
    [ -d "${d}" ] || _fail "scan target is missing: ${d#"${REPO_ROOT}"/} — this check would otherwise pass by reading nothing"
  done
}

# assert_kustomize_builds <path> — the overlay renders at all.
assert_kustomize_builds() {
  local path="$1"
  if kubectl kustomize "${REPO_ROOT}/${path}" >/dev/null 2>&1; then
    _pass "kustomize builds: ${path}"
  else
    _fail "kustomize build failed: ${path}"
  fi
}

# assert_renders_kind <path> <kind> — the overlay produces at least one object of this kind.
assert_renders_kind() {
  local path="$1" kind="$2"
  if kubectl kustomize "${REPO_ROOT}/${path}" | grep -q "^kind: ${kind}$"; then
    _pass "${path} renders a ${kind}"
  else
    _fail "${path} rendered no ${kind}"
  fi
}

# assert_no_forbidden_sources — the course-wide bans, enforced mechanically.
#
# These are not style preferences. Bitnami moved its versioned images to a paid catalogue in 2025 —
# the charts still resolve, but `:16.4.0` is a 404 and only `:latest` is free, so a chart from there
# cannot be pinned. ingress-nginx was archived in March 2026. Either one appearing in this repo
# means a student hits a wall the course promised they would not.
assert_no_forbidden_sources() {
  local hits
  hits="$(grep -rIl --exclude-dir=.git --exclude-dir=test \
    -e 'charts\.bitnami\.com' \
    -e 'bitnami/charts' \
    -e 'ingress-nginx' \
    -e 'nginx\.ingress\.kubernetes\.io' \
    "${REPO_ROOT}" 2>/dev/null || true)"
  if [ -z "${hits}" ]; then
    _pass "no Bitnami charts and no ingress-nginx anywhere in the repo"
  else
    _fail "forbidden source referenced in: ${hits}"
  fi
}

# assert_no_legacy_appset_templating — {{foo}} without a dot, under goTemplate: true, is a
# hard PARSE ERROR in Argo CD 3.5 ("function \"foo\" not defined"). Catch it here, not on camera.
assert_no_legacy_appset_templating() {
  local hits
  # Comments are stripped before scanning. The manifests document this very rule —
  # "the legacy dot-less {{name}} form is a HARD PARSE ERROR" — and the first version
  # of this check matched its own explanatory comment and failed a correct file.
  # Naming a forbidden form in order to warn against it is not using it.
  _require_dirs "${REPO_ROOT}/applicationsets"
  hits="$(grep -rIn --exclude-dir=.git --include='*.yaml' -E '\{\{[a-zA-Z_]' "${REPO_ROOT}/applicationsets" 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+: *#' || true)"
  if [ -z "${hits}" ]; then
    _pass "no legacy (dot-less) ApplicationSet templating"
  else
    _fail "legacy {{name}} templating found — 3.5 fails this at parse time:\n${hits}"
  fi
}

# assert_images_pinned — no :latest, and no untagged images. A demo that floats is a demo that rots.
assert_images_pinned() {
  local hits
  _require_dirs "${REPO_ROOT}/apps"
  hits="$(grep -rIn --exclude-dir=.git --include='*.yaml' -E 'image: .*:latest|image: [^:]+$' \
    "${REPO_ROOT}/apps" 2>/dev/null || true)"
  if [ -z "${hits}" ]; then
    _pass "every image is pinned to an explicit tag"
  else
    _fail "unpinned or :latest image:\n${hits}"
  fi
}

# assert_no_plaintext_secrets — a Secret with literal data committed to git is the exact mistake
# S05 L01 opens on. It must never be in the repo outside the one lesson that demonstrates it.
assert_no_plaintext_secrets() {
  local hits
  _require_dirs "${REPO_ROOT}/apps" "${REPO_ROOT}/teams"
  hits="$(grep -rIl --exclude-dir=.git --include='*.yaml' -e '^kind: Secret$' \
    "${REPO_ROOT}/apps" "${REPO_ROOT}/teams" 2>/dev/null || true)"
  if [ -z "${hits}" ]; then
    _pass "no plaintext Secret manifests committed"
  else
    _fail "plaintext Secret committed — use a SealedSecret: ${hits}"
  fi
}

# wait_for_sync <app> [timeout] — Argo CD reports Synced AND Healthy, not just Synced.
wait_for_sync() {
  local app="$1" timeout="${2:-300}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local sync health
    sync="$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
      _pass "${app} is Synced and Healthy"
      return 0
    fi
    sleep 5
  done
  _fail "${app} did not reach Synced/Healthy within ${timeout}s (last: sync=${sync:-?} health=${health:-?})"
}

# wait_for_rollout <kind/name> <namespace>
wait_for_rollout() {
  if kubectl rollout status "$1" -n "$2" --timeout=180s >/dev/null 2>&1; then
    _pass "$1 rolled out in $2"
  else
    _fail "$1 did not roll out in $2"
  fi
}

# assert_yaml_parses <path> — every standalone manifest is at least valid YAML that kubectl accepts.
# This exists because the manifests were authored on a machine with no kubectl; CI is the first
# place they are parsed at all, so CI has to actually do it rather than assume.
assert_yaml_parses() {
  local path="$1"
  # Distinguish "no kubectl here" from "this file is broken". The first version said
  # "does not parse" in both cases, and on a k3s host — where the binary is `k3s
  # kubectl`, not `kubectl` — it blamed a manifest that was perfectly valid. An
  # environment fault reported as a content defect sends the reader hunting in the
  # wrong file.
  local kc=""
  if command -v kubectl >/dev/null 2>&1; then kc="kubectl"
  elif command -v k3s >/dev/null 2>&1; then kc="k3s kubectl"
  else
    _fail "cannot check ${path}: no kubectl or k3s on PATH (this is an environment fault, not a defect in the file)"
    return
  fi
  # `apply --dry-run=client` is NOT an offline parse. kubectl still has to reach the API
  # server's discovery endpoint to recognise a kind, so a custom kind like Application
  # fails here on a host with no cluster even when the YAML is perfect. Two environment
  # faults look identical to a broken file unless they are named:
  #   - the kubeconfig is unreadable (k3s writes /etc/rancher/k3s/k3s.yaml as root, mode
  #     600, and `kubectl` on a k3s host is a symlink to `k3s` that falls back to that
  #     path whenever KUBECONFIG is empty);
  #   - no API server is reachable.
  # Reporting either as "does not parse" sends the reader hunting in a file that is fine.
  local out rc
  out="$(${kc} apply --dry-run=client --validate=false -f "${REPO_ROOT}/${path}" 2>&1)" && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    _pass "parses: ${path}"
  elif printf '%s' "${out}" | grep -qE 'error loading config file|permission denied|Unable to read /etc/rancher'; then
    _fail "cannot check ${path}: kubeconfig is unreadable (environment fault, not a defect in the file). Copy it somewhere you own: mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown \$USER ~/.kube/config && export KUBECONFIG=~/.kube/config"
  elif printf '%s' "${out}" | grep -qE 'connection refused|no such host|Couldn.t get current server API group list|did you specify the right host or port'; then
    _fail "cannot check ${path}: no reachable API server (environment fault, not a defect in the file). This assertion needs a live cluster, because client dry-run still resolves kinds through discovery."
  else
    _fail "does not parse: ${path}\n${out}"
  fi
}

# ---------------------------------------------------------------------------
# Per-lesson smoke scripts: identity, tier, and honest non-execution.
#
# Blueprint §8 wants one CI script per lesson, carrying that lesson's own commands, so the
# companion repo cannot hold something different from what the lesson shows. Three facts make
# that harder than it sounds, and these helpers exist for the third:
#
#   1. Some lessons need nothing but the repo (does the overlay build, is the templating legal).
#   2. Some need a live cluster (does the sync actually reach Healthy).
#   3. Some cannot run in CI AT ALL — they open a browser for SSO, raise a GitHub pull request,
#      push to a registry, or build Multipass VMs.
#
# The danger is entirely in the third group. A script that quietly returns 0 because it decided
# not to do anything is indistinguishable from one that passed, and a suite of those reports a
# green wall while testing nothing. So a lesson in that group DECLARES itself, exits 78, and the
# runner counts it in a separate column with its reason printed. Green means ran-and-passed, and
# nothing else is allowed to look like it.
# ---------------------------------------------------------------------------

SMOKE_LESSON=""
SMOKE_TIER=""

# lesson <SNN-LMM> <one-line claim this script defends>
lesson() {
  SMOKE_LESSON="$1"; shift
  printf '\033[1m%s\033[0m — %s\n' "${SMOKE_LESSON}" "$*"
}

# tier repo|cluster|external
tier() {
  case "$1" in
    repo|cluster|external) SMOKE_TIER="$1" ;;
    *) _fail "unknown tier '$1' (expected repo, cluster or external)" ;;
  esac
}

# needs_external <what it needs> <why CI cannot provide it>
# Terminates the script with 78. NOT a pass, and it never prints one.
needs_external() {
  printf '  \033[33mDECLARED\033[0m %s needs %s — %s\n' "${SMOKE_LESSON:-this lesson}" "$1" "$2"
  printf '  \033[33m         this script asserts the repo-side invariants only; the rest is a take-day check\033[0m\n'
  exit 78
}

# smoke_done — the only thing allowed to print a pass line.
smoke_done() {
  argocd_cli_release 2>/dev/null || true
  printf '\n\033[32m%s passed\033[0m\n' "${SMOKE_LESSON:-smoke}"
}

# assert_exists_dir <path> / assert_exists_file <path> — repo-tier building blocks.
# A lesson that syncs a path the repo does not hold fails on camera; these are the cheapest
# possible guard against that, and they run without a cluster.
assert_exists_dir() {
  [ -d "${REPO_ROOT}/$1" ] && _pass "directory present: $1" \
    || _fail "directory MISSING: $1 — a lesson names it, so either the lesson or the repo is wrong"
}

assert_exists_file() {
  [ -f "${REPO_ROOT}/$1" ] && _pass "file present: $1" \
    || _fail "file MISSING: $1 — a lesson names it, so either the lesson or the repo is wrong"
}

# assert_file_contains <path> <extended-regex> <what it means>
assert_file_contains() {
  if grep -qE "$2" "${REPO_ROOT}/$1" 2>/dev/null; then
    _pass "$3"
  else
    _fail "$1 does not match /$2/ — $3"
  fi
}

# assert_file_lacks <path> <extended-regex> <why it must not be there>
assert_file_lacks() {
  if grep -qE "$2" "${REPO_ROOT}/$1" 2>/dev/null; then
    _fail "$1 contains /$2/ — $3"
  else
    _pass "$3"
  fi
}

# assert_yaml_wellformed <path> — REPO TIER. Is this valid YAML at all?
#
# Deliberately weaker than assert_yaml_parses, and usable without a cluster. `kubectl apply
# --dry-run=client` is NOT an offline parse: it resolves kinds through the API server's discovery
# endpoint, so it cannot judge a CRD-backed manifest on a machine with no cluster. This answers
# the smaller question — does it parse as YAML — which is the one a PR check can actually ask.
#
# If no YAML parser is on PATH this FAILS. It does not pass quietly: a check that cannot run must
# say so, because "0 bad" from an instrument that never started is worse than no check at all.
assert_yaml_wellformed() {
  local path="$1" f="${REPO_ROOT}/$1"
  [ -f "$f" ] || { _fail "file MISSING: ${path}"; return; }
  if command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' "$f" >/dev/null 2>&1; then
      _pass "valid YAML: ${path}"
    else
      _fail "INVALID YAML: ${path} — $(ruby -ryaml -e 'begin; YAML.load_stream(File.read(ARGV[0])); rescue => e; print e.message.lines.first.to_s.strip; end' "$f" 2>/dev/null)"
    fi
  else
    _fail "cannot check ${path}: no YAML parser on PATH (environment fault, not a defect in the file)"
  fi
}

# argocd_cli_ready — make the `argocd` CLI usable, or fail saying exactly what is missing.
#
# Many cluster-tier scripts drive the CLI rather than kubectl, because the thing they are proving
# lives in Argo CD's own API layer (RBAC, projects, sync windows) and is invisible from the
# Kubernetes side. On a bare CI cluster there is no gateway and no session, so the CLI dies with
# `Argo CD server address unspecified` — a raw fatal that reads like a broken script rather than
# an unconfigured environment. This does the port-forward and the login once, and says plainly
# which of the two failed if it cannot.
#
# Sets ARGOCD_OPTS so every later `argocd` call in the script inherits the session.
# argocd_cli_ready — make the `argocd` CLI usable without a server, a session, or a port-forward.
#
# Many cluster-tier scripts drive the CLI rather than kubectl, because what they are proving lives
# in Argo CD's own API layer (projects, sync windows, refresh semantics) and is invisible from the
# Kubernetes side. On a bare CI cluster there is no ingress and no login, and the CLI dies with
# `Argo CD server address unspecified` — a raw fatal that reads like a broken script rather than an
# unconfigured environment.
#
# `--core` is the way out: the CLI talks straight to the Kubernetes API using the kubeconfig
# already in hand, with no argocd-server session at all. It resolves `argocd-cm` through the
# CURRENT KUBE CONTEXT'S NAMESPACE, not $ARGOCD_NAMESPACE — so the namespace is switched here and
# restored on the way out. An earlier version of this port-forwarded and logged in with the
# bootstrap admin password; it was fragile (the forward did not survive a non-interactive shell,
# and `localhost` resolved to ::1 where nothing was listening) and it is unnecessary.
ARGOCD_PREV_NS=""
argocd_cli_ready() {
  command -v argocd >/dev/null 2>&1 \
    || { _fail "argocd CLI is not on PATH (environment fault, not a defect in the lesson)"; return 1; }
  command -v kubectl >/dev/null 2>&1 \
    || { _fail "kubectl is not on PATH (environment fault, not a defect in the lesson)"; return 1; }

  ARGOCD_PREV_NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
  kubectl config set-context --current --namespace=argocd >/dev/null 2>&1 \
    || { _fail "could not point the kube context at the argocd namespace (environment fault)"; return 1; }

  export ARGOCD_OPTS="--core"
  if argocd --core app list >/dev/null 2>&1; then
    _pass "argocd CLI ready in --core mode (no server session needed)"
    return 0
  fi
  _fail "argocd --core cannot reach Argo CD in this cluster (environment fault, not a defect in the lesson)"
  return 1
}

# argocd_cli_release — put the kube context back. Called by _fail and smoke_done, so a script
# never has to remember, and so this cannot clobber the script's own `trap cleanup EXIT`.
argocd_cli_release() {
  if [ -n "${ARGOCD_PREV_NS:-}" ]; then
    kubectl config set-context --current --namespace="${ARGOCD_PREV_NS}" >/dev/null 2>&1 || true
    ARGOCD_PREV_NS=""
  fi
}
