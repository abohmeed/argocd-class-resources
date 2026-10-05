#!/usr/bin/env bash
# lesson: s06_l02 Sync waves: ordering resources inside a single phase
# Sync waves order resources inside a phase.
#
# The committed repo already carries the fix this lesson teaches. The lesson itself strips the
# wave annotations to reproduce a crash, then restores exactly what is already committed, so
# the durable, always-true claim this repo can defend on every PR, without a cluster, is that the restored state stays restored: the
# Postgres StatefulSet and its Service carry sync-wave "-1", and the API Deployment stays at the
# unannotated default wave 0, one wave behind.
#
# What this script does NOT claim: the crashloop itself. With the annotations removed, the API pod
# starts alongside the database and crashloops (Init:CrashLoopBackOff), because checkout's pod runs
# a start-up check first: an init container that runs pg_isready against checkout-postgres:5432 (a
# headless Service whose name resolves only once the Postgres pod is Ready) and exits 1 until the
# database answers. Watching that needs a live cluster, so this script defends the repo side: the
# check is wired into the Deployment, and the http-echo container itself is unchanged.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S06-L02 "checkout-postgres syncs at wave -1, one wave ahead of the checkout API's default wave 0"
tier repo

step "the manifests the lesson syncs actually exist"
assert_exists_file "apps/checkout/base/postgres-statefulset.yaml"
assert_exists_file "apps/checkout/base/postgres-service.yaml"
assert_exists_file "apps/checkout/base/deployment.yaml"

step "checkout-postgres's StatefulSet and Service both sync one wave ahead"
assert_file_contains "apps/checkout/base/postgres-statefulset.yaml" \
  'argocd\.argoproj\.io/sync-wave: "-1"' \
  "postgres-statefulset.yaml carries sync-wave -1"
assert_file_contains "apps/checkout/base/postgres-service.yaml" \
  'argocd\.argoproj\.io/sync-wave: "-1"' \
  "postgres-service.yaml carries sync-wave -1"

step "the checkout API Deployment stays at the default wave: no sync-wave annotation of its own"
assert_file_lacks "apps/checkout/base/deployment.yaml" 'argocd\.argoproj\.io/sync-wave:' \
  "deployment.yaml has no sync-wave annotation, so it defaults to wave 0: after the database's wave -1"

step "the API's start-up check: it exits while Postgres is unreachable, so without the waves the pod crashloops"
assert_file_contains "apps/checkout/base/deployment.yaml" '^      initContainers:' \
  "checkout's Deployment runs an init container before the API starts"
assert_file_contains "apps/checkout/base/deployment.yaml" '^        - name: db-check$' \
  "the init container is the db-check"
assert_file_contains "apps/checkout/base/deployment.yaml" 'pg_isready -h "\$DB_HOST" -p "\$DB_PORT"' \
  "db-check probes the database with pg_isready"
assert_file_contains "apps/checkout/base/deployment.yaml" 'value: checkout-postgres' \
  "the check targets the checkout-postgres Service"
assert_file_contains "apps/checkout/base/deployment.yaml" 'cannot reach Postgres at' \
  "a failed check says why it exits"
assert_file_contains "apps/checkout/base/deployment.yaml" 'image: hashicorp/http-echo:1\.0' \
  "the API container itself is still hashicorp/http-echo:1.0"

step "both resources are wired into the Application that actually ships them"
assert_file_contains "apps/checkout/base/kustomization.yaml" 'postgres-statefulset\.yaml' \
  "postgres-statefulset.yaml is in checkout's kustomization"
assert_file_contains "apps/checkout/base/kustomization.yaml" 'postgres-service\.yaml' \
  "postgres-service.yaml is in checkout's kustomization"

smoke_done
