#!/usr/bin/env bash
# S06 L02 — sync waves order resources inside a phase.
#
# The runbook's own Preconditions say it plainly: "the committed repo already carries the fix
# this lesson teaches." The take itself strips the wave annotations on camera to reproduce a
# crash, then restores exactly what is already committed — so the durable, always-true claim this
# repo can defend on every PR, without a cluster, is that the restored state stays restored: the
# Postgres StatefulSet and its Service carry sync-wave "-1", and the API Deployment stays at the
# unannotated default wave 0, one wave behind.
#
# What this script does NOT claim: the runbook's own narration says removing the annotation
# produces a `CrashLoopBackOff` with a connection-refused/timeout error reaching the database. The
# committed `checkout` Deployment (apps/checkout/base/deployment.yaml) is hashicorp/http-echo
# serving a static `-text=$(BANNER)` string — it never opens a connection to Postgres at all, at
# startup or otherwise. Wave ordering genuinely governs *when* the two objects are created, which
# is what this script defends; it does not reproduce the crashloop the runbook narrates, because
# nothing in the current checkout app has a code path that could crash on a missing database.
# Flagged for the producer rather than silently asserting a failure mode that cannot fire.
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

step "the checkout API Deployment stays at the default wave — no sync-wave annotation of its own"
assert_file_lacks "apps/checkout/base/deployment.yaml" 'argocd\.argoproj\.io/sync-wave:' \
  "deployment.yaml has no sync-wave annotation, so it defaults to wave 0 — after the database's wave -1"

step "both resources are wired into the Application that actually ships them"
assert_file_contains "apps/checkout/base/kustomization.yaml" 'postgres-statefulset\.yaml' \
  "postgres-statefulset.yaml is in checkout's kustomization"
assert_file_contains "apps/checkout/base/kustomization.yaml" 'postgres-service\.yaml' \
  "postgres-service.yaml is in checkout's kustomization"

smoke_done
