#!/usr/bin/env bash
# Install the single-node k3s both CI jobs run on, at the exact version test/versions.env pins.
#
# The install script downloads the k3s binary itself, with no retry. On 2026-10-11 a stalled
# connection to update.k3s.io failed the repo tier for hours (curl error 28 after five minutes),
# so the whole install is retried, and a half-finished install is removed before the next try.
# The version is pinned (K3S_VERSION in versions.env), so a point release cannot change the cluster
# under the suite between two runs.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"

# Pull Docker official images (Argo CD's redis comes from public.ecr.aws/docker/library) through
# mirror.gcr.io, which serves the same digests. On 2026-10-18, 20 and 21 argocd-redis sat in
# ImagePullBackOff on shared runner IPs; containerd still falls back to public.ecr.aws if the mirror fails.
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/registries.yaml >/dev/null <<'YAML'
mirrors:
  public.ecr.aws:
    endpoint:
      - "https://mirror.gcr.io"
    rewrite:
      "^docker/library/(.*)": "library/$1"
YAML

for attempt in 1 2 3; do
  if curl -sfL --retry 5 --retry-all-errors --connect-timeout 20 https://get.k3s.io \
       | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -; then
    break
  fi
  echo "k3s install attempt ${attempt} failed; removing any partial install before retrying" >&2
  sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
  sleep 15
done

command -v k3s >/dev/null 2>&1 || { echo "k3s is not installed after 3 attempts" >&2; exit 1; }
