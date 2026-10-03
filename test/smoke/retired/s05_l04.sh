#!/usr/bin/env bash
# S05 L04 — SOPS and age: encrypted in Git, but never wired into Argo CD's sync.
#
# The lesson's payload isn't "sops can encrypt a file" — it's the reason this repo stops short of
# connecting it: Argo CD's own docs warn that a Config Management Plugin (KSOPS) decrypts into
# Redis's rendered-manifest cache in plaintext, so encrypting the file in Git only moves the
# exposure, it doesn't remove it. This lesson never touches the cluster (its own runbook says so),
# so the claim worth defending lives entirely in the repo: no KSOPS/CMP is wired anywhere, the
# private key never lands in Git, and if the lesson's own committed ciphertext artifact exists, it
# stays unwired and genuinely ciphertext. Sealing/decrypting with real `sops`/`age` binaries needs
# no cluster either, but it isn't repeated here — replaying it would test the sops CLI, not this
# lesson's claim, which is about what the repo does and does not connect to Argo CD.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S05-L04 "sops/age ciphertext is committed, but never wired into Argo CD's sync — KSOPS stays disconnected on purpose"
tier repo

step "no Config Management Plugin for SOPS/KSOPS is wired into this repo, anywhere"
# The lesson's whole closing point is that a KSOPS CMP is deliberately NOT installed. If one ever
# gets wired in without updating the lesson, the "Argo CD caches the plaintext in Redis" warning
# this lesson teaches silently stops being true of this repo.
hits="$(grep -rliE --exclude-dir=.git --exclude-dir=test -e 'ksops' -e 'configManagementPlugins' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no ksops / configManagementPlugins reference anywhere in the repo — the CMP the lesson warns against is not wired in"
else
  _fail "a KSOPS/CMP reference showed up in: ${hits} — this lesson teaches that Argo CD never decrypts sops files itself; if that changed, the lesson's warning is now wrong"
fi

step "no age private key is ever committed"
# The lesson's other hard rule: key.txt never leaves /tmp. A committed AGE-SECRET-KEY line means
# every ciphertext value this section has ever produced is readable by anyone with repo access.
hits="$(grep -rlE --exclude-dir=.git --exclude-dir=test -e 'AGE-SECRET-KEY-' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no age private key material committed anywhere in the repo"
else
  _fail "an age PRIVATE key is committed in: ${hits} — every sops ciphertext this section has produced is now readable; rotate the key and scrub history before recording anything else"
fi

step "sops/age are pinned to the versions the narration states on camera"
assert_file_contains "test/versions.env" 'SOPS_VERSION="v3\.13\.3"' "sops pinned to v3.13.3, matching the narration"
assert_file_contains "test/versions.env" 'AGE_VERSION="v1\.3\.2"' "age pinned to v1.3.2, matching the narration"

step "if the lesson's own ciphertext artifact has been committed, it stays unwired and stays ciphertext"
# The demo's own Teardown says apps/checkout/sops-demo/secret.enc.yaml and .sops.yaml become
# permanent repo state once recorded. Before that recording lands, this file legitimately does not
# exist yet — that is not a defect, so this block only runs once the artifact shows up, and from
# then on it is a permanent regression guard.
ENC_FILE="apps/checkout/sops-demo/secret.enc.yaml"
if [ -f "${REPO_ROOT}/${ENC_FILE}" ]; then
  assert_file_contains "${ENC_FILE}" '^sops:' \
    "${ENC_FILE} carries sops's own metadata block — it really is sops-encrypted output, not a hand-written stand-in"
  assert_file_lacks "apps/checkout/base/kustomization.yaml" 'sops-demo' \
    "sops-demo/ is not listed in checkout's kustomization.yaml — Argo CD's repo server never renders it"
  # The plaintext credential this section has used throughout every other lesson. If it shows up
  # readable in the "encrypted" file, sops encrypted nothing.
  assert_file_lacks "${ENC_FILE}" 'northwind-checkout-db-2026' \
    "${ENC_FILE} does not contain the plaintext database password in the clear"
else
  _pass "apps/checkout/sops-demo/secret.enc.yaml not committed yet — nothing to check until this lesson is recorded; the two checks above (no KSOPS wiring, no committed private key) still hold regardless"
fi

smoke_done
