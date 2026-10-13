#!/usr/bin/env bash
# lesson: s12_l05 What argocd admin export backs up, and what it doesn't
# What `argocd admin export` actually backs up, and what it silently does not.
#
# The lesson's claim is exact and negative: the export carries argocd-cm, argocd-rbac-cm,
# argocd-secret, every Application/AppProject/ApplicationSet, and it carries NEITHER
# argocd-notifications-cm NOR argocd-cmd-params-cm NOR the Sealed Secrets controller's sealing
# key. That is provable from a single real export against the live cluster, without standing up
# a second Argo CD instance to receive an import.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L05 "argocd admin export captures Applications, AppProjects and argocd-secret: never argocd-notifications-cm, argocd-cmd-params-cm, or the sealing key"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

backup="$(mktemp -u)"
PROBE_APP="s12l05-probe"
cleanup() {
  rm -f "${backup}"
  kubectl delete application "${PROBE_APP}" -n argocd --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# The export holds Applications only if there are some: an empty namespace would fail the positive check for a
# reason that has nothing to do with the lesson. One scratch Application is enough, and it is removed on exit.
kubectl apply -f - >/dev/null <<EOF_APP
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: ${PROBE_APP}, namespace: argocd}
spec:
  project: default
  source: {repoURL: "https://github.com/abohmeed/argocd-class-resources.git", targetRevision: main, path: apps/storefront/base}
  destination: {server: "https://kubernetes.default.svc", namespace: s12l05-probe}
EOF_APP

step "take a real export from the live cluster"
if argocd admin export -o "${backup}" >/dev/null 2>&1; then
  [ -s "${backup}" ] || _fail "argocd admin export produced an empty file"
  _pass "export written"
else
  _fail "argocd admin export failed: confirm the argocd CLI is logged in against this cluster"
fi

step "it captures the positive set: Applications, AppProjects, argocd-cm, argocd-secret"
for want in 'kind: Application$' 'kind: AppProject$' 'name: argocd-cm$' 'name: argocd-secret$'; do
  if grep -qE "^ *${want}" "${backup}"; then
    _pass "export contains ${want}"
  else
    _fail "export is missing ${want}: the positive half of this lesson's claim does not hold"
  fi
done

step "it does NOT capture argocd-notifications-cm, argocd-cmd-params-cm, or the Sealed Secrets sealing key: the gap the whole lesson is built on"
# Anchored to the two-space indent of an exported object's own metadata.name. Unanchored, the
# argocd Application's status.resources (it manages both ConfigMaps via bootstrap/install.yaml) matches too.
for absent in '^  name: argocd-notifications-cm$' '^  name: argocd-cmd-params-cm$' 'sealed-secrets-key'; do
  if grep -q "${absent}" "${backup}"; then
    _fail "export UNEXPECTEDLY contains '${absent}': if this ever changes, the lesson's central gap has closed and the lesson is stale"
  else
    _pass "export does not contain '${absent}', as the lesson claims"
  fi
done

smoke_done
