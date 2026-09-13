#!/usr/bin/env bash
# coderabbit-dispatch-remote.sh — GitHub-hosted-runner enumerator for the
# shadow CodeRabbit leftover dispatcher.
#
# Why this exists (and why it's a SEPARATE script in this repo, not a
# mammamiradio workflow and not a Claude Code cloud routine): CodeRabbit
# Team allowance is per developer identity. Shotgun auto-incrementals on
# every push burn that quota; other repos starve. The countermeasure has
# to see every florianhorner-owned repo in one tick, so it lives next to
# fleet-audit-remote.sh and uses the same hosted-runner enumerator
# (`gh repo list florianhorner`).
#
# This script is REPORT-ONLY. There is no --apply. It never comments
# `@coderabbitai review`, never adds labels, never writes to any other
# repo, and never files an hourly GitHub issue (unlike monthly fleet-audit).
# The job summary is the artifact.
#
# Kill switches (enforced HERE, not only in the workflow `if:`):
#   - absent .github/coderabbit-dispatch.enabled
#   - repository variable CODERABBIT_DISPATCH set to the literal 0
#
# Usage:
#   bash coderabbit-dispatch-remote.sh
#
# Env:
#   GH_TOKEN / GITHUB_TOKEN   auth for `gh` (set by Actions)
#   CODERABBIT_DISPATCH       literal 0 disables (same as LAND_QUEUE)
#   GITHUB_STEP_SUMMARY       if set, markdown is appended
#   CODERABBIT_DISPATCH_ROOT  repo root override (tests)

set -euo pipefail
export LC_ALL=C.UTF-8

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="${CODERABBIT_DISPATCH_ROOT:-$ROOT}"
export CODERABBIT_DISPATCH_ROOT="$ROOT"

ENABLE_FILE="${ROOT}/.github/coderabbit-dispatch.enabled"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      printf 'Usage: bash coderabbit-dispatch-remote.sh\n'
      printf '  Report-only shadow dispatcher. No --apply. No GitHub writes.\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s (report-only; no --apply)\n' "$arg" >&2
      exit 1
      ;;
  esac
done

# Kill switch. Same shape as mammamiradio land-queue: file is the on-switch,
# literal 0 on the repo variable is the off-switch. Checked in this script so
# "off" means off from a local run, a second workflow, or `workflow_dispatch`,
# not only from the hourly job's `if:`.
if [ ! -f "$ENABLE_FILE" ] || [ "${CODERABBIT_DISPATCH:-1}" = "0" ]; then
  REPORT="# CodeRabbit dispatch (shadow)

**Outcome:** \`DISABLED\`
**Mode:** shadow — job summary only. No comments, no labels, no writes to other repos.
**Kill switch:** \`$(if [ ! -f "$ENABLE_FILE" ]; then printf '.github/coderabbit-dispatch.enabled is absent'; else printf 'CODERABBIT_DISPATCH=0'; fi)\`

_Report-only. Restore the enable file, or unset/change the variable from literal 0, to turn it back on._
"
  printf '%s\n' "$REPORT"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$REPORT" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'FAIL gh CLI not installed.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL python3 not installed.\n' >&2
  exit 1
fi

python3 "${ROOT}/coderabbit_dispatch.py" --root "$ROOT"
