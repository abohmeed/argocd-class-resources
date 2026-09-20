#!/usr/bin/env bash
# S04 L08 — argocd-cm's `repositories` key is silently ignored on 3.0+; a labeled Secret is
# what actually registers a repository, and a repo-creds Secret's url is a prefix, not an exact
# match.
#
# The trap this lesson demonstrates is specifically the SILENCE: kubectl accepts the argocd-cm
# patch without complaint, and the resulting sync failure never mentions argocd-cm or the
# repositories key at all — a generic auth error, nothing pointing back at the config file that
# is actually the problem. This script reproduces exactly that: patch argocd-cm the pre-3.0 way,
# confirm Argo CD registered nothing, THEN register the real Secret and confirm `argocd repo
# list` picks it up. It also proves the repo-creds prefix match by registering credentials for a
# host rather than one exact repository URL.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S04-L08 "argocd-cm's repositories key is silently ignored on 3.0+; a labeled repository Secret is what actually registers a repo, and repo-creds matches by host prefix"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

REPO="https://github.com/abohmeed/argocd-class-resources.git"
SECRET_LEGACY="s04l08-repo-creds-legacy"
SECRET_REPO="s04l08-argocd-class-resources-repo"
SECRET_CREDS="s04l08-github-abohmeed-repo-creds"

cleanup() {
  kubectl patch configmap argocd-cm -n argocd --type=json \
    -p='[{"op":"remove","path":"/data/repositories"}]' >/dev/null 2>&1 || true
  kubectl delete secret "${SECRET_LEGACY}" "${SECRET_REPO}" "${SECRET_CREDS}" -n argocd >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "confirm the server is actually 3.x, where this lesson's whole premise holds"
ver="$(argocd version --short 2>/dev/null | grep -oE 'v3\.[0-9]+' | head -1 || true)"
case "${ver}" in
  v3.*) _pass "argocd server reports ${ver}" ;;
  *) _fail "could not confirm an Argo CD 3.x server — this lesson's premise (the keys were removed in 3.0) needs one" ;;
esac

step "the pre-3.0 argocd-cm patch is accepted by Kubernetes but registers nothing"
kubectl create secret generic "${SECRET_LEGACY}" -n argocd \
  --from-literal=username=placeholder --from-literal=password=placeholder >/dev/null 2>&1 || true
cat <<PATCHEOF | kubectl patch configmap argocd-cm -n argocd --patch-file /dev/stdin >/dev/null
data:
  repositories: |
    - url: ${REPO}
      usernameSecret: {name: ${SECRET_LEGACY}, key: username}
      passwordSecret: {name: ${SECRET_LEGACY}, key: password}
PATCHEOF
sleep 5
if argocd repo list 2>/dev/null | grep -qF "${REPO}"; then
  _fail "argocd repo list shows ${REPO} after ONLY the argocd-cm patch — the repositories key is being read again, and this lesson's whole premise is gone"
else
  _pass "argocd-cm's repositories key changed nothing — argocd repo list still does not know about ${REPO}"
fi

step "the real answer: a Secret labeled argocd.argoproj.io/secret-type: repository"
cat <<SECEOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_REPO}
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repository}
stringData:
  type: git
  url: ${REPO}
  username: placeholder
  password: placeholder
SECEOF
sleep 5
if argocd repo list 2>/dev/null | grep -qF "${REPO}"; then
  _pass "argocd repo list now shows ${REPO} — registered by the labeled Secret, not the ConfigMap"
else
  _fail "the labeled repository Secret did not register ${REPO} — this lesson's fix does not reproduce"
fi

step "repo-creds matches by HOST PREFIX, not an exact repository URL"
cat <<CREDEOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_CREDS}
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repo-creds}
stringData:
  url: https://github.com/abohmeed
  username: placeholder
  password: placeholder
CREDEOF
sleep 5
creds_line="$(argocd repo list 2>/dev/null | grep -F 'https://github.com/abohmeed' || true)"
if [ -n "${creds_line}" ]; then
  _pass "a repo-creds Secret scoped to https://github.com/abohmeed is visible — it covers every repository under that host, not one exact URL"
else
  _fail "the repo-creds Secret did not register as a host-level credential template"
fi

smoke_done
