#!/usr/bin/env bash
# S13 L02 — a CMP sidecar whose generate script writes anything to stdout ahead of its YAML
# produces a SILENT no-op sync, not an error. Argo CD reads everything `generate` sends to
# stdout as the manifest; one stray echo line ahead of it and there is nothing left to parse,
# and nothing left to complain about either.
#
# This builds the sidecar for real against the live repo-server, proves the bug (a sync that
# deploys nothing), then proves the one-line fix (redirect the echo to stderr).
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S13-L02 "a CMP whose generate script echoes to stdout ahead of its YAML produces a silent no-op sync"
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
      name: s13l02-envsubst-plugin
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NS}
  syncPolicy:
    syncOptions: ["CreateNamespace=true"]
EOF

step "the bug reproduces: syncing deploys nothing"
sleep 15
argocd app sync "${APP}" >/dev/null 2>&1 || true
sleep 10
if kubectl get configmap s13l02-cmp-output -n "${NS}" >/dev/null 2>&1; then
  _fail "the ConfigMap was deployed even with the stdout-leak bug in place — the no-op did not reproduce, so the fix below cannot be defended against it"
else
  _pass "with the stray echo ahead of the YAML, the sync is a genuine no-op — nothing was deployed"
fi

step "redirecting the echo to stderr (>&2) fixes it — generate's stdout is YAML alone"
write_plugin_cm " >&2"
sleep 60   # kubelet's periodic ConfigMap remount, not instant
argocd app sync "${APP}" >/dev/null 2>&1 || true
sleep 10
if kubectl get configmap s13l02-cmp-output -n "${NS}" >/dev/null 2>&1; then
  _pass "once generate's echo is redirected to stderr, the plugin's manifest deploys for real"
else
  _fail "the ConfigMap still did not deploy after fixing the stdout leak — the one-line fix this lesson teaches did not hold on this cluster"
fi

smoke_done
