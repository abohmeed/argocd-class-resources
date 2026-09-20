#!/usr/bin/env bash
# S09 L03 — registering a cluster the GitOps way: a hand-authored Secret, and the missing
# label's SILENT failure.
#
# The lesson's central claim is that Argo CD's cluster-Secret informer is a label selector on
# `argocd.argoproj.io/secret-type: cluster` — an unlabelled Secret sits in the argocd namespace
# forever, with no error and no event, and `argocd cluster list` simply never shows it. Proving
# that live needs a second cluster (staging) to register, which this single-node CI cannot
# provide. What IS checkable without one: any cluster-registration Secret this repo ever commits
# must carry the label, structurally, every time — a forward guard against the exact silent
# failure this lesson opens on.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S09-L03 "a cluster Secret is only seen by Argo CD if it carries argocd.argoproj.io/secret-type: cluster — the missing label fails silently"
tier external

step "repo-side invariant: every committed cluster-registration Secret carries the label"
# A cluster-registration Secret is identified the way Argo CD's own docs describe it: stringData
# holding server/config with a bearerToken. Scoped to the manifest directories a lesson actually
# commits to (apps/, applicationsets/, platform/, teams/) — never the whole repo, which would
# also read this script's own source (this comment names "bearerToken" too) and the vendored
# bootstrap/install.yaml, which mentions it in Argo CD's own unrelated RBAC/token plumbing.
# An array, not a space-joined string — REPO_ROOT contains spaces ("Mastering GitOps with Argo
# CD"), and a space-joined path list silently word-splits into bogus grep targets.
manifest_dirs=()
for d in apps applicationsets platform teams; do
  [ -d "${REPO_ROOT}/${d}" ] && manifest_dirs+=("${REPO_ROOT}/${d}")
done
if [ "${#manifest_dirs[@]}" -eq 0 ]; then
  _pass "no apps/, applicationsets/, platform/ or teams/ content to scan yet"
else
  hits="$(grep -rIl 'bearerToken' "${manifest_dirs[@]}" 2>/dev/null || true)"
  if [ -z "${hits}" ]; then
    _pass "no cluster-registration Secret committed yet — nothing for this guard to check (S09 L03 authors it live)"
  else
    bad=""
    while IFS= read -r f; do
      [ -z "${f}" ] && continue
      grep -q 'argocd.argoproj.io/secret-type: *cluster' "${f}" || bad="${bad}
  ${f#"${REPO_ROOT}"/}"
    done <<< "${hits}"
    if [ -z "${bad}" ]; then
      _pass "every committed cluster-registration Secret carries argocd.argoproj.io/secret-type: cluster"
    else
      _fail "cluster-registration Secret missing the label — Argo CD will silently never see it:${bad}"
    fi
  fi

  step "repo-side invariant: no hardcoded private/loopback IP in a committed cluster Secret's server field"
  iphits="$(grep -rInE 'server: *https?://(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.0\.0\.1)' "${manifest_dirs[@]}" 2>/dev/null || true)"
  if [ -z "${iphits}" ]; then
    _pass "no cluster Secret's server field is a hardcoded private/loopback address"
  else
    _fail "a server field is a hardcoded private IP — S09 L02 discovers the address at merge time, this must be pasted from that value, never retyped as a literal:\n${iphits}"
  fi
fi

needs_external "a second cluster (staging, registered on the hub as a labelled cluster Secret) and a live argocd CLI session" \
  "verified by hand: an unlabelled Secret produced zero events and did not appear in 'argocd cluster list'; relabelling it made it appear with no CLI registration step — this needs a real second cluster, which this single k3s CI node does not have"
