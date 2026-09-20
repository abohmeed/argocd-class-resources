#!/usr/bin/env bash
# S02 L01 — a real control plane, and the root-owned kubeconfig fixed the RIGHT way.
#
# The lesson's specific, repeatable claim is not "k3s installs" (CI's own "Install k3s" step
# already proves that, every run, before this ever executes) — it is that the FIX for the
# permission-denied kubeconfig is a user-owned COPY at ~/.kube/config, never a chmod on the
# original. The runbook says so explicitly: "Do not sudo chmod it — the narration is explicit
# that the fix is a copy, not a permission change on the original." If the original file were
# ever left world/group-readable, that would be a real security regression this lesson
# specifically tells students not to make, on camera, and this is the cheapest way to catch it.
#
# What this does NOT re-assert: the exact pinned k3s version (v1.37.0+k3s1). CI's own k3s
# install step runs the unpinned installer, so a version mismatch here would be a known gap in
# the CI harness, not a defect in this lesson — see this lesson's own runbook header. Asserting
# it here would just fail on a limitation this script cannot fix.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S02-L01 "the kubeconfig fix is a user-owned COPY, never a chmod on the k3s-owned original"
tier cluster

step "exactly one node, Ready — the shot this lesson builds to"
node_count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
node_status="$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')"
if [ "${node_count}" = "1" ] && [ "${node_status}" = "Ready" ]; then
  _pass "one node, Ready"
else
  _fail "expected exactly one Ready node, got ${node_count:-0} node(s), status(es): ${node_status:-none}"
fi

step "the ORIGINAL k3s kubeconfig was not loosened — the fix is a copy, not a chmod"
K3S_CFG="/etc/rancher/k3s/k3s.yaml"
if [ -e "${K3S_CFG}" ]; then
  perm="$(stat -c '%a' "${K3S_CFG}" 2>/dev/null || stat -f '%Lp' "${K3S_CFG}" 2>/dev/null)"
  if [ "${perm}" = "600" ]; then
    _pass "${K3S_CFG} is still mode 600 — nobody took the chmod shortcut this lesson warns against"
  else
    _fail "${K3S_CFG} is mode ${perm:-unknown}, not 600 — the ORIGINAL was loosened instead of copied, which is exactly the anti-pattern this lesson tells students not to use"
  fi
else
  _fail "${K3S_CFG} does not exist — cannot check whether the copy-not-chmod fix was followed"
fi

step "a user-owned COPY exists at ~/.kube/config, and it actually works"
USER_CFG="${HOME}/.kube/config"
if [ -f "${USER_CFG}" ]; then
  owner="$(stat -c '%U' "${USER_CFG}" 2>/dev/null || stat -f '%Su' "${USER_CFG}" 2>/dev/null)"
  if [ "${owner}" != "root" ]; then
    _pass "~/.kube/config exists and is owned by ${owner}, not root"
  else
    _fail "~/.kube/config exists but is still root-owned — the copy step (chown) was skipped"
  fi
  if KUBECONFIG="${USER_CFG}" kubectl get nodes >/dev/null 2>&1; then
    _pass "the copy at ~/.kube/config actually authenticates against the cluster"
  else
    _fail "~/.kube/config exists but kubectl cannot use it to reach the cluster — the copy is stale or wrong"
  fi
else
  _fail "~/.kube/config does not exist — Step 3's copy was never made; every later lesson's Preconditions assume it is"
fi

smoke_done
