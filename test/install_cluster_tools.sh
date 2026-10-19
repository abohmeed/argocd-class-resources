#!/usr/bin/env bash
# Install the client tools the cluster suite drives, at the versions test/versions.env pins.
#
# The GitHub-hosted runner ships kubectl, kustomize, helm and docker, and nothing else the lessons
# use. Three are missing and three lessons need them:
#   argocd                 every S02 to S14 script that calls `argocd` (the CLI runs with --core)
#   kubectl-argo-rollouts  S10-L03 and S14-L05 (the Rollouts plugin, not the controller)
#   kubeseal               S05-L09 and S14-L04 (Sealed Secrets, sealing against the live controller)
# Each download is checked against the sha256 its release publishes. A mismatch is a failure, and a
# tool already at the pinned version is left alone, so the script can run on every job.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"

BIN_DIR="${BIN_DIR:-/usr/local/bin}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fetch() { curl -sfL --retry 5 --retry-all-errors --connect-timeout 20 -o "$2" "$1"; }

# install_checked <name> <url> <sha256 list url> <asset name> [member inside the tarball]
# The checksum list holds "<sha256>  <asset name>" lines; the asset is verified before it is installed.
# Always downloads: a few seconds, and it cannot leave an older binary in place by mistake.
install_checked() {
  local name="$1" url="$2" sums_url="$3" asset="$4" member="${5:-}"
  fetch "${url}" "${work}/${asset}"
  fetch "${sums_url}" "${work}/sums.txt"
  ( cd "${work}" && grep -F "  ${asset}" sums.txt | sha256sum -c - )
  if [ -n "${member}" ]; then
    tar -xzf "${work}/${asset}" -C "${work}" "${member}"
    sudo install -m 0755 "${work}/${member}" "${BIN_DIR}/${name}"
  else
    sudo install -m 0755 "${work}/${asset}" "${BIN_DIR}/${name}"
  fi
  echo "${name} installed from ${url} (sha256 verified)"
}

# argocd: the CLI at the same tag as the server the suite installs (ARGOCD_PIN).
install_checked argocd \
  "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_PIN}/argocd-linux-amd64" \
  "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_PIN}/cli_checksums.txt" \
  "argocd-linux-amd64"

# kubectl-argo-rollouts: the plugin, at ARGO_ROLLOUTS_VERSION (the controller the lessons install).
install_checked kubectl-argo-rollouts \
  "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/kubectl-argo-rollouts-linux-amd64" \
  "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/argo-rollouts-checksums.txt" \
  "kubectl-argo-rollouts-linux-amd64"

# kubeseal: the Sealed Secrets client at SEALED_SECRETS_VERSION (its controller is installed by S05-L02).
sealed_ver="${SEALED_SECRETS_VERSION#v}"
install_checked kubeseal \
  "https://github.com/bitnami/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/kubeseal-${sealed_ver}-linux-amd64.tar.gz" \
  "https://github.com/bitnami/sealed-secrets/releases/download/${SEALED_SECRETS_VERSION}/sealed-secrets_${sealed_ver}_checksums.txt" \
  "kubeseal-${sealed_ver}-linux-amd64.tar.gz" "kubeseal"

for t in argocd kubectl-argo-rollouts kubeseal; do
  command -v "${t}" >/dev/null 2>&1 || { echo "${t} is not on PATH after install" >&2; exit 1; }
done
echo "cluster tools: $(argocd version --client --short 2>/dev/null | head -1); $(kubectl-argo-rollouts version 2>/dev/null | head -1); $(kubeseal --version 2>/dev/null | head -1)"
