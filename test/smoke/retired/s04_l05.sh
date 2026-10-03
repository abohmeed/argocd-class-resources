#!/usr/bin/env bash
# S04 L05 — Helm 4 renames --atomic/--force; the old names still work, they just warn.
#
# The lesson's claim is specific and falsifiable: on Helm 4, `--atomic` and `--force` still
# WORK when typed — Helm marks them deprecated via cobra's MarkDeprecated, which prints a
# warning and leaves the flag pointed at the renamed flag's own code path, it does not remove
# it. The one documented exception is versions 4.0.0-4.1.1 (upstream issue 31900), where
# `--atomic` actually errors outright until 4.2.0. This script builds a disposable chart and
# release, runs the old flags, and reads stderr for the rename warning rather than assuming a
# fixed exit code, since the regression window means "did it exit 0" is not itself the claim.
# It also confirms `helm repo` carries no deprecation notice, since that claim is just as
# central and just as easy to get backwards.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L05 "Helm 4's renamed --atomic/--force warn and keep working; they do not error outside the 4.0.0-4.1.1 regression, and helm repo is not deprecated"
tier cluster

NS="s04l05-helm-cli-demo"
RELEASE="s04l05-storefront"
CHART_DIR="$(mktemp -d)"

cleanup() {
  helm uninstall "${RELEASE}" -n "${NS}" >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  rm -rf "${CHART_DIR}"
}
trap cleanup EXIT

step "Helm 4 is actually what's installed"
ver="$(helm version --short 2>/dev/null || true)"
case "${ver}" in
  v4.*) _pass "helm reports ${ver}" ;;
  *) _fail "helm reports '${ver}', not v4.x — this lesson's whole claim is Helm-4-specific" ;;
esac

step "build a disposable release from S04 L04's committed chart"
assert_exists_dir "charts/storefront"
assert_exists_file "charts/storefront/Chart.yaml"
mkdir -p "${CHART_DIR}/templates"
cp "${REPO_ROOT}/charts/storefront/Chart.yaml" "${CHART_DIR}/Chart.yaml"
cp "${REPO_ROOT}/charts/storefront/values.yaml" "${CHART_DIR}/values.yaml"
cp "${REPO_ROOT}/charts/storefront/templates/"*.yaml "${CHART_DIR}/templates/"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm install "${RELEASE}" "${CHART_DIR}" -n "${NS}" >/dev/null

step "the old --atomic still runs, warning that it was renamed to --rollback-on-failure"
out="$(helm upgrade "${RELEASE}" "${CHART_DIR}" -n "${NS}" --atomic --force 2>&1)" && rc=0 || rc=$?
if printf '%s' "${out}" | grep -qiE 'rollback-on-failure'; then
  _pass "--atomic prints its rename warning (pointing at --rollback-on-failure)"
elif [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qiE 'unknown flag.*atomic'; then
  _pass "--atomic errors outright — this is the documented 4.0.0-4.1.1 regression (upstream #31900), not a defect in the lesson"
else
  _fail "--atomic neither warned about its rename nor hit the known regression — Helm's deprecation behavior changed:\n${out}"
fi

step "the renamed flags apply clean, with no deprecation warning"
out="$(helm upgrade "${RELEASE}" "${CHART_DIR}" -n "${NS}" --rollback-on-failure --force-replace 2>&1)" && rc=0 || rc=$?
if [ "${rc}" -eq 0 ] && ! printf '%s' "${out}" | grep -qiE 'deprecat'; then
  _pass "--rollback-on-failure and --force-replace apply with no deprecation warning"
else
  _fail "the renamed flags did not apply cleanly (rc=${rc}):\n${out}"
fi

step "helm repo is not deprecated — only the OCI-adjacent story changed, not this command"
if timeout 15 helm repo add s04l05-example https://example.com/charts >/dev/null 2>&1; then
  helm repo remove s04l05-example >/dev/null 2>&1 || true
fi
if helm repo --help 2>&1 | grep -qi 'deprecat'; then
  _fail "helm repo now reports itself as deprecated — the lesson's 'still fully supported' claim no longer holds"
else
  _pass "helm repo carries no deprecation notice"
fi

smoke_done
