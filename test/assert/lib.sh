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
_fail() { printf '  \033[31mFAIL\033[0m %b\n' "$1" >&2; exit 1; }

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
# These are not style preferences. Bitnami's free chart repo went paid in 2025 and ingress-nginx
# was archived in March 2026; either one appearing in this repo means a student hits a wall the
# course promised they would not.
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
