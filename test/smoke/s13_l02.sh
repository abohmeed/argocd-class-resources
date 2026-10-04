#!/usr/bin/env bash
# lesson: s13_l02 Building a sidecar CMP: an envsubst plugin, end to end
# A CMP sidecar whose generate script writes anything to stdout ahead of its YAML
# breaks manifest generation LOUDLY. Argo CD reads everything `generate` sends to stdout as the
# manifest, so a stray "Generating manifests..." line ahead of it makes diff and sync fail with a
# YAML parse error ("failed to unmarshal manifest"), which points at the YAML, not the script.
# Measured on v3.5.3 for the restored lesson; the pre-cut "silent no-op" claim was wrong.
#
# This builds the sidecar for real against the live repo-server, proves the bug (diff and sync
# fail, nothing deployed), then proves the fix the lesson teaches: redirect the echo to stderr,
# update the ConfigMap, restart the repo server (a subPath-mounted plugin.yaml is only read when
# the sidecar starts), and diff again with --hard-refresh so the cached error is not reused.
# The plugin is named in the Application; with spec.version set, its name carries the -v1.0
# suffix, and with no discover block a named plugin is used as-is. (The lesson relies on
# discovery instead, which needs a committed file this script does not write.)
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S13-L02 "a CMP whose generate script echoes to stdout ahead of its YAML fails diff and sync with a YAML parse error; sending the echo to stderr fixes it"
tier cluster

# This lesson is proven through Argo CD's own API layer, so the CLI needs a session. On a
# bare CI cluster there is no gateway and no login; without this the CLI dies with
# "Argo CD server address unspecified", which reads like a broken script rather than an
# unconfigured environment.
argocd_cli_ready

CM="s13l02-envsubst-plugin-config"
APP="s13l02-cmp-demo"
NS="s13l02-cmp-demo"
SIDECAR="s13l02-plugin"

cleanup() {
  kubectl delete application "${APP}" -n argocd --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1 || true
  # $patch: delete removes exactly the named list entries this script added, by key, without
  # touching anything else the deployment already carries.
  kubectl -n argocd patch deployment argocd-repo-server --type strategic -p "
spec:
  template:
    spec:
      containers:
      - name: ${SIDECAR}
        \$patch: delete
      volumes:
      - name: ${CM}
        \$patch: delete
      - name: cmp-tmp-${CM}
        \$patch: delete
" >/dev/null 2>&1 || true
  kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=120s >/dev/null 2>&1 || true
  kubectl delete configmap "${CM}" -n argocd >/dev/null 2>&1 || true
}
trap cleanup EXIT

write_plugin_cm() {
  local redirect="$1"
  kubectl create configmap "${CM}" -n argocd --from-literal=plugin.yaml="apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: s13l02-envsubst-plugin
spec:
  version: v1.0
  generate:
    command: [\"sh\", \"-c\"]
    args:
      - |
        echo \"Generating manifests...\"${redirect}
        printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: s13l02-cmp-output' 'data:' '  from: cmp'
" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

step "install the plugin sidecar, with the bug still in it: generate echoes to stdout ahead of the YAML"
write_plugin_cm ""

kubectl -n argocd patch deployment argocd-repo-server --type strategic -p "
spec:
  template:
    spec:
      containers:
      - name: ${SIDECAR}
        command: [\"/var/run/argocd/argocd-cmp-server\"]
        image: docker.io/library/busybox:1.36
        securityContext:
          runAsNonRoot: true
          runAsUser: 999
        volumeMounts:
        - name: var-files
          mountPath: /var/run/argocd
        - name: plugins
          mountPath: /home/argocd/cmp-server/plugins
        - name: ${CM}
          mountPath: /home/argocd/cmp-server/config/plugin.yaml
          subPath: plugin.yaml
        - name: cmp-tmp-${CM}
          mountPath: /tmp
      volumes:
      - name: ${CM}
        configMap:
          name: ${CM}
      - name: cmp-tmp-${CM}
        emptyDir: {}
" >/dev/null
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s >/dev/null \
  || _fail "argocd-repo-server did not roll out with the CMP sidecar added"

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP}
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/abohmeed/argocd-class-resources.git
    targetRevision: main
    path: apps/storefront/base
    plugin:
      name: s13l02-envsubst-plugin-v1.0
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF

step "the bug reproduces: diff and sync fail with a YAML parse error, and nothing is deployed"
sleep 15
diff_out="$(argocd app diff "${APP}" --hard-refresh 2>&1)" && diff_rc=0 || diff_rc=$?
if [ "${diff_rc}" -ge 2 ] && printf '%s\n' "${diff_out}" | grep -qiE 'unmarshal|yaml'; then
  _pass "argocd app diff fails (exit ${diff_rc}) with a YAML parse error from the plugin: the loud failure the lesson reads"
else
  _fail "expected argocd app diff to fail with a YAML parse error (failed to unmarshal manifest), got exit ${diff_rc}: ${diff_out}"
fi
argocd app sync "${APP}" >/dev/null 2>&1 && sync_rc=0 || sync_rc=$?
sleep 5
if [ "${sync_rc}" -ne 0 ] && ! kubectl get configmap s13l02-cmp-output -n "${NS}" >/dev/null 2>&1; then
  _pass "argocd app sync fails the same way, and nothing on the cluster changed"
else
  _fail "expected the sync to fail and deploy nothing with the stdout leak in place (sync exit ${sync_rc}); the failure did not reproduce, so the fix below cannot be defended against it"
fi

step "the fix: echo to stderr (>&2), update the ConfigMap, restart the repo server, diff with --hard-refresh"
write_plugin_cm " >&2"
kubectl -n argocd rollout restart deployment/argocd-repo-server >/dev/null
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s >/dev/null \
  || _fail "argocd-repo-server did not come back after the restart"
sleep 10
diff_out="$(argocd app diff "${APP}" --hard-refresh 2>&1)" && diff_rc=0 || diff_rc=$?
if [ "${diff_rc}" -le 1 ] && printf '%s\n' "${diff_out}" | grep -q 's13l02-cmp-output'; then
  _pass "with the echo on stderr, a hard-refreshed diff shows the real manifest the plugin generates"
else
  _fail "expected a clean diff naming s13l02-cmp-output after the fix, got exit ${diff_rc}: ${diff_out}"
fi
argocd app sync "${APP}" >/dev/null 2>&1 || true
sleep 10
if kubectl get configmap s13l02-cmp-output -n "${NS}" >/dev/null 2>&1; then
  _pass "the sync applies cleanly: the plugin's manifest is on the cluster"
else
  _fail "the ConfigMap still did not deploy after the fix: the one-line fix this lesson teaches did not hold on this cluster"
fi

smoke_done
