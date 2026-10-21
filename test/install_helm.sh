#!/usr/bin/env bash
# Install the Helm release the course pins (HELM_VERSION in test/versions.env) on the CI runner.
#
# GitHub-hosted runners ship Helm 3. S04-L07 teaches Helm 4 (its Do.md expects `helm version` to
# read v4.3.x), so the cluster job installs the pinned release from get.helm.sh and checks its
# published sha256 before installing it. Downloads are retried; a wrong version is a failure.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/versions.env"

tgz="helm-${HELM_VERSION}-linux-amd64.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl -sfL --retry 5 --retry-all-errors --connect-timeout 20 -o "${work}/${tgz}" "https://get.helm.sh/${tgz}"
curl -sfL --retry 5 --retry-all-errors --connect-timeout 20 -o "${work}/${tgz}.sha256sum" "https://get.helm.sh/${tgz}.sha256sum"
( cd "${work}" && sha256sum -c "${tgz}.sha256sum" )
tar -xzf "${work}/${tgz}" -C "${work}"
sudo install -m 0755 "${work}/linux-amd64/helm" /usr/local/bin/helm

ver="$(helm version --short 2>/dev/null || true)"
case "${ver}" in
  "${HELM_VERSION}"+*|"${HELM_VERSION}") echo "helm ${ver} installed" ;;
  *) echo "helm reports '${ver}' after install, expected ${HELM_VERSION}" >&2; exit 1 ;;
esac
