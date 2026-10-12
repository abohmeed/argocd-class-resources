#!/usr/bin/env bash
# Install the single-node k3s both CI jobs run on, on the channel test/versions.env declares.
#
# The install script downloads the k3s binary itself, with no retry. On 2026-10-11 a stalled
# connection to update.k3s.io failed the repo tier for hours (curl error 28 after five minutes),
# so the whole install is retried, and a half-finished install is removed before the next try.
# K3S_CHANNEL was declared in versions.env but never passed to the installer; it is now.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"

for attempt in 1 2 3; do
  if curl -sfL --retry 5 --retry-all-errors --connect-timeout 20 https://get.k3s.io \
       | INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" sh -; then
    break
  fi
  echo "k3s install attempt ${attempt} failed; removing any partial install before retrying" >&2
  sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
  sleep 15
done

command -v k3s >/dev/null 2>&1 || { echo "k3s is not installed after 3 attempts" >&2; exit 1; }
