#!/bin/bash
r(){ printf '%-6s %-24s %s\n' "$1" "$2" "$3"; }
echo "===== P. Helm 4.3.0 (S02-L02) ====="
curl -sSL -o /tmp/helm4.tgz https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz 2>/dev/null
if tar tzf /tmp/helm4.tgz >/dev/null 2>&1; then
  sudo tar xzf /tmp/helm4.tgz -C /tmp 2>/dev/null
  sudo install -m 755 /tmp/linux-amd64/helm /usr/local/bin/helm4 2>/dev/null
  r PASS "helm4-available" "$(/usr/local/bin/helm4 version --short 2>/dev/null)"
  /usr/local/bin/helm4 repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1
  /usr/local/bin/helm4 repo update >/dev/null 2>&1
  APP=$(/usr/local/bin/helm4 show chart argo/argo-cd --version 10.9.2 2>/dev/null | grep -i '^appVersion' | awk '{print $2}')
  [ "$APP" = "v3.5.3" ] && r PASS "chart-10.9.2-appversion" "appVersion: $APP (verified with Helm 4)" || r FAIL "chart-10.9.2-appversion" "got '$APP'"
  TPL=$(/usr/local/bin/helm4 template argocd argo/argo-cd --version 10.9.2 2>/dev/null | grep -c 'kind: ')
  [ "$TPL" -gt 0 ] && r PASS "helm4-renders-chart" "$TPL objects rendered under Helm 4" || r FAIL "helm4-renders-chart" "template failed"
else
  r FAIL "helm4-available" "could not download helm v4.3.0 (release may not exist at that URL)"
  curl -sSL https://api.github.com/repos/helm/helm/releases/latest 2>/dev/null | grep -m1 '"tag_name"' | sed 's/^/       latest: /'
fi

echo
echo "===== Q. Multipass info --format json schema (S09-L02, RUNTIME OWED) ====="
if [ -e /dev/kvm ]; then r INFO "nested-kvm" "/dev/kvm present"; else r INFO "nested-kvm" "ABSENT — multipass cannot launch a VM here"; fi
if ! command -v multipass >/dev/null 2>&1; then
  sudo snap install multipass >/tmp/mp.log 2>&1 || true
fi
if command -v multipass >/dev/null 2>&1; then
  r INFO "multipass" "$(multipass version 2>/dev/null | head -1 | tr '\n' ' ')"
  sudo multipass launch --name schematest --cpus 1 --memory 1G --disk 5G >/tmp/mplaunch.log 2>&1
  if sudo multipass info schematest --format json >/tmp/mpinfo.json 2>/dev/null; then
    r PASS "multipass-json-captured" "schema captured"
    echo "       top-level keys: $(jq -r 'keys|join(\", \")' /tmp/mpinfo.json 2>/dev/null)"
    echo "       ipv4 path test: $(jq -r '.info.schematest.ipv4[0] // "NOT AT .info.<name>.ipv4[0]"' /tmp/mpinfo.json 2>/dev/null)"
    jq . /tmp/mpinfo.json 2>/dev/null | head -25 | sed 's/^/       /'
  else
    r FAIL "multipass-json-captured" "info failed; launch log:"; tail -3 /tmp/mplaunch.log 2>/dev/null | sed 's/^/       /'
  fi
else
  r FAIL "multipass" "snap install failed"; tail -3 /tmp/mp.log 2>/dev/null | sed 's/^/       /'
fi
