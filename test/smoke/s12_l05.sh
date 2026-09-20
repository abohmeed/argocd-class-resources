#!/usr/bin/env bash
# S12 L05 — what `argocd admin export` actually backs up, and what it silently does not.
#
# The lesson's claim is exact and negative: the export carries argocd-cm, argocd-rbac-cm,
# argocd-secret, every Application/AppProject/ApplicationSet — and it carries NEITHER
# argocd-notifications-cm NOR argocd-cmd-params-cm NOR the Sealed Secrets controller's sealing
# key. That is provable from a single real export against the live cluster, without standing up
# a second Argo CD instance to receive an import.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S12-L05 "argocd admin export captures Applications, AppProjects and argocd-secret — never argocd-notifications-cm, argocd-cmd-params-cm, or the sealing key"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

backup="$(mktemp -u)"
trap 'rm -f "${backup}"' EXIT

step "take a real export from the live cluster"
if argocd admin export -o "${backup}" >/dev/null 2>&1; then
  [ -s "${backup}" ] || _fail "argocd admin export produced an empty file"
  _pass "export written"
else
  _fail "argocd admin export failed — confirm the argocd CLI is logged in against this cluster"
fi

step "it captures the positive set: Applications, AppProjects, argocd-cm, argocd-secret"
for want in 'kind: Application$' 'kind: AppProject$' 'name: argocd-cm$' 'name: argocd-secret$'; do
  if grep -qE "^${want}" "${backup}"; then
    _pass "export contains ${want}"
  else
    _fail "export is missing ${want} — the positive half of this lesson's claim does not hold"
  fi
done

step "it does NOT capture argocd-notifications-cm, argocd-cmd-params-cm, or the Sealed Secrets sealing key — the gap the whole lesson is built on"
for absent in 'name: argocd-notifications-cm$' 'name: argocd-cmd-params-cm$' 'sealed-secrets-key'; do
  if grep -q "${absent}" "${backup}"; then
    _fail "export UNEXPECTEDLY contains '${absent}' — if this ever changes, the lesson's central gap has closed and the narration is stale"
  else
    _pass "export does not contain '${absent}', as the lesson claims"
  fi
done

smoke_done
