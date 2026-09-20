#!/usr/bin/env bash
# S06 L07 — PostSync/SyncFail notifications, and why not to hand-roll them.
#
# The demo's actual proof — a SyncFail hook posts to a real Slack webhook and the message shows
# up in a channel — needs a live Slack workspace CI does not have and must not fabricate a
# webhook for. What this repo CAN defend on every PR: the lesson's central factual claim, that the
# Notifications controller ships IN-TREE with Argo CD and is never a separate install, and the
# repo-side hygiene claim that matters most for a public repo — no Slack token shaped like a real
# one ever gets committed, since GitHub's push protection rejects the whole push the moment one
# does, taking every other file in that commit down with it.
source "$(dirname "${BASH_SOURCE[0]}")/../assert/lib.sh"

lesson S06-L07 "the Notifications controller ships in-tree with Argo CD; a hand-rolled Slack hook stays a placeholder in Git"
tier external

step "the Notifications controller ships from the SAME manifest as the rest of Argo CD, not a separate install"
# The lesson's claim is specifically that nobody manages this controller on its own. The stock
# install manifest is expected to define it — that IS "in-tree" — so the check is that it comes
# from exactly that one manifest and nowhere else.
assert_file_contains "bootstrap/install.yaml" 'name: argocd-notifications-controller' \
  "bootstrap/install.yaml (the one Argo CD install manifest) defines argocd-notifications-controller itself"

hits="$(grep -rliE --exclude-dir=.git --exclude-dir=test --exclude='install.yaml' \
  -e 'notification[s]?-controller' -e 'argocd-notifications' \
  "${REPO_ROOT}/bootstrap" "${REPO_ROOT}/applicationsets" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no SEPARATE Notifications controller install anywhere else in bootstrap/ or applicationsets/"
else
  _fail "a standalone Notifications controller reference showed up outside the main install manifest, in: ${hits} — the lesson teaches it ships in-tree and is never installed separately"
fi

step "no realistic-looking Slack token is committed anywhere in the repo"
# A real Slack bot/webhook token has a recognisable shape (xoxb-..., xoxp-..., or a
# hooks.slack.com/services/T.../B.../... path with real-looking segments). GitHub's push
# protection blocks the push the instant one appears, which would cost the take, not just this
# file.
hits="$(grep -rlE --exclude-dir=.git --exclude-dir=test \
  -e 'xox[bp]-[A-Za-z0-9-]+' -e 'hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+' \
  "${REPO_ROOT}" 2>/dev/null || true)"
if [ -z "${hits}" ]; then
  _pass "no realistic-looking Slack token or webhook URL anywhere in the repo"
else
  _fail "a realistic-looking Slack token/webhook showed up in: ${hits} — GitHub push protection will reject this exact push; replace with an angle-bracket placeholder like <your-slack-webhook-url>"
fi

step "if the hand-rolled SyncFail hook has been committed, its webhook is still an obvious placeholder"
HOOK_FILE="apps/checkout/base/notify-fail-job.yaml"
if [ -f "${REPO_ROOT}/${HOOK_FILE}" ]; then
  assert_file_contains "${HOOK_FILE}" 'argocd\.argoproj\.io/hook: SyncFail' \
    "${HOOK_FILE} is annotated as a SyncFail hook"
  assert_file_contains "${HOOK_FILE}" '<your-slack-webhook-url>' \
    "${HOOK_FILE} still carries the angle-bracket placeholder, not a real webhook URL"
else
  _pass "apps/checkout/base/notify-fail-job.yaml not committed yet — nothing to check until this lesson is recorded; the two repo-wide checks above still hold regardless"
fi

needs_external "a Slack workspace and a real Incoming Webhook URL, plus watching the message land in the channel" \
  "verified once by hand instead: with a real webhook substituted in locally (never committed), a forced sync failure fires the SyncFail hook Job, and the Slack channel the webhook posts to receives the 'checkout sync FAILED' message within seconds"
