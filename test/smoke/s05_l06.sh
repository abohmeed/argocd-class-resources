#!/usr/bin/env bash
# S05 L06 — when the sealing key is gone: backup, rotation and disaster recovery.
#
# The lesson's actual demonstration destroys and rebuilds the lab's ONLY cluster host (Proxmox VM
# 130, `ssh pve 'qm destroy 130 --purge'`) to prove a rebuilt cluster's fresh Sealed Secrets
# controller cannot decrypt what the old one sealed, then restores from a key backup. That is not
# something CI may ever do on its own initiative — it is the one shared lab host every other
# section's cluster-tier smoke script also depends on, and destroying it out from under a nightly
# run would take the whole suite down with it, not just this lesson. So this script asserts the
# repo-side facts that make the demo possible and honest, then declares the rest.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S05-L06 "a Sealed Secrets key backup, taken before disaster, is the only thing that survives a rebuilt controller"
tier external

step "the rebuild script this lesson depends on actually exists"
assert_exists_file "test/runtime-verification/build-acd.sh"
assert_exists_file "test/runtime-verification/acd-lab-user-data"

step "sealed-secrets is pinned to the CURRENT org and a current version, not the ancient bitnami-labs v0.20.5"
assert_file_contains "test/versions.env" 'SEALED_SECRETS_VERSION="v0\.40\.0"' \
  "sealed-secrets pinned to v0.40.0"
hits="$(grep -rliE --exclude-dir=.git --exclude-dir=test \
  -e 'bitnami-labs/sealed-secrets' -e 'sealed-secrets/releases/download/v0\.20\.5' \
  "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no reference anywhere in the repo to the retired bitnami-labs org or the ancient v0.20.5 release"
else
  _fail "a stale bitnami-labs/v0.20.5 sealed-secrets reference showed up in: ${hits} — a student following it installs a controller that no longer exists at that address"
fi

needs_external "the Proxmox lab host (ssh pve), a destroy-and-rebuild of VM 130, and the offline key backup at ~/Backups/acd-lab-sealed-secrets-main.key" \
  "verified once by hand instead: with the pre-rebuild key backed up, a freshly rebuilt cluster's new Sealed Secrets controller cannot decrypt the committed checkout-db SealedSecret (status/events report a decryption failure, kubectl get secret returns NotFound), and re-applying the backed-up key Secret then restarting the controller restores decryption to the exact same value the SealedSecret held before the rebuild"
