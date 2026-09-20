#!/usr/bin/env bash
# S04 L06 — Off the Bitnami pin loss, onto OCI; the oci:// prefix flips depending on whether
# Argo CD is reading a Helm chart or a plain artifact.
#
# Two of this lesson's three claims need a live, credentialed OCI registry this CI does not
# have (the live state of Bitnami's registry, and a real push/pull round-trip
# against ghcr.io/northwind). Those are declared, not faked — see needs_external below. What IS
# checkable from the repo alone, and matters just as much: the Bitnami pin loss is never "fixed"
# by hard-coding a private mirror (it is the teaching point, not a bug), and the fictional
# ghcr.io/northwind org this course's prose uses for illustration never becomes a real pull
# target in a committed manifest — if it ever did, a student's `apply` would 404 on camera.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L06 "Bitnami's charts still install but their versioned images are gone, so the pin dies; a Helm-over-OCI repoURL drops oci://, a plain OCI artifact keeps it"
tier external

step "no working Bitnami mirror or workaround is committed anywhere in the repo"
hits="$(grep -rIl --exclude-dir=.git --exclude-dir=test \
  -e 'charts\.bitnami\.com' -e 'bitnami/charts' "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no Bitnami chart repository referenced anywhere — the dead pin is never routed around"
else
  _fail "a Bitnami reference is committed: ${hits} — S04 L06's whole point is that this is NOT worked around"
fi

step "the fictional ghcr.io/northwind org never becomes a real pull target"
assert_exists_dir "apps"
assert_exists_dir "applicationsets"
assert_exists_dir "bootstrap"
hits="$(grep -rIln --exclude-dir=.git --exclude-dir=test -e 'ghcr\.io/northwind' \
  "${REPO_ROOT}/apps" "${REPO_ROOT}/applicationsets" "${REPO_ROOT}/bootstrap" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "ghcr.io/northwind appears nowhere as a committed image/repoURL — it stays prose-only, as it must"
else
  _fail "ghcr.io/northwind is referenced in a committed manifest: ${hits} — that org is fictional and nothing may pull from it"
fi

step "the image tag this course actually pulls is pinned to the real, existing tag"
assert_file_contains "test/versions.env" 'HTTP_ECHO_IMAGE="hashicorp/http-echo:1\.0"' \
  "the pinned image is hashicorp/http-echo:1.0 — 1.4.2 is a 404 and must stay prose-only"

needs_external "write access to ghcr.io/northwind (a real, producer-owned OCI registry) and a live charts.bitnami.com probe" \
  "MEASURED 2026-09-20, and it corrects this repo's earlier record: charts.bitnami.com/bitnami is NOT 403. It 302-redirects to repo.broadcom.com/bitnami-files and serves a 26 MB index with 144 charts; individual .tgz files download 200. What actually moved is the IMAGES — docker.io/bitnami/postgresql:16.4.0 is 404 while :latest is 200, so the free tier keeps only a floating tag. The break a student hits is therefore a green sync followed by ImagePullBackOff on a version that no longer exists, and the only way to make it pull is :latest, which this course bans. CI must not depend on reaching any of it either way, since that state can move again between here and the take: re-probe before recording. The OCI push/pull round-trip also needs the producer's registry credentials, which this CI does not hold"
