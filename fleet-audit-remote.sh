#!/usr/bin/env bash
# fleet-audit-remote.sh — GitHub-hosted-runner counterpart to fleet-audit.sh.
#
# Why this exists (and why it's a SEPARATE script, not a flag on
# fleet-audit.sh): fleet-audit.sh walks LOCAL git checkouts under ~/repos and
# ~/conductor/workspaces — that only works because it runs on Florian's own
# machine. A GitHub Actions cloud routine (or any hosted runner) has no
# filesystem access to those paths, full stop. This script instead enumerates
# every repo Florian actually owns via `gh repo list florianhorner`, which is
# MORE complete than the local walk for this specific question ("is the
# fleet compliant") since it also catches repos he owns but hasn't cloned to
# this machine.
#
# Bucket model is simpler here than in fleet-audit.sh: `gh repo list
# florianhorner` only ever returns repos florianhorner owns or has direct
# access to, so the THIRD-PARTY-CLONE bucket (arbitrary local clones of OTHER
# people's repos, e.g. hacksider/Deep-Live-Cam) cannot occur — there is
# nothing to walk that isn't his. Buckets are just:
#   OWN       - isFork:false
#   OWN-FORK  - isFork:true
#
# Archived repos are skipped entirely — no classification, no output row.
#
# This script is REPORT-ONLY. It never writes to any other repo, never calls
# bootstrap-repo.sh, and has no --apply equivalent. If the report flags
# something, fixing it is a separate, human-initiated action (either by hand
# or via `fleet-audit.sh --apply` run locally).
#
# --json emits the same classification as a machine-readable artifact, and is
# the ONLY input a remediation agent should ever read. Rationale: the markdown
# report is delivered as a GitHub issue body plus follow-up COMMENTS, and
# anyone who can comment on that issue can append text that looks exactly like
# a report row. An agent that parses the issue thread to decide which repos to
# push to is therefore taking instructions from an attacker-writable surface.
# A workflow-run artifact is written only by this workflow and cannot be
# appended to after the fact.
#
# The per-repo `remediable` flag in that JSON is decided HERE, in code, not by
# whatever reads it. It encodes fleet-audit.sh's note-5 policy verbatim:
# only bucket OWN + status MISSING is auto-fixable; OWN-FORK never is (forks
# carry AUTHOR-NOTES.md and upstream-tracking concerns), STALE never is for
# any bucket (a SHA-pin refresh changes what CI enforces, so it stays a
# deliberate visible action), and archived repos never enter the report at
# all. Keeping that decision in the script means an agent consuming the
# artifact has no policy left to interpret — it filters on a boolean.
#
# Usage:
#   bash fleet-audit-remote.sh                  # print markdown table to stdout
#   bash fleet-audit-remote.sh --github-issue    # also file/update the GH issue
#   bash fleet-audit-remote.sh --json PATH       # also write the JSON artifact
#
# Env (only read when --github-issue is passed):
#   GITHUB_REPOSITORY   owner/repo to file the issue against (set by Actions)
#   GH_TOKEN / GITHUB_TOKEN   auth for `gh` (set by Actions)

set -euo pipefail
export LC_ALL=C.UTF-8

readonly ENGSTD_REPO="florianhorner/engineering-standards"
readonly ENGSTD_OWNER="florianhorner"
readonly CI_WORKFLOW_PATH=".github/workflows/commit-lint.yml"
readonly META_PATH=".config/commit-rules.meta.json"
readonly ISSUE_LABEL="fleet-audit"

FILE_ISSUE=0
JSON_PATH=""

# Both --json spellings fail the same way on an empty path. Silently accepting
# `--json=` would leave JSON_PATH empty, skip the emitter below, and still exit
# 0 — a caller that asked for the artifact would get a green run and no file.
json_path_required() {
  printf '%s\n' 'FAIL --json requires a non-empty path argument' >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --github-issue) FILE_ISSUE=1 ;;
    --json)
      shift
      if [ "$#" -eq 0 ] || [ -z "$1" ]; then
        json_path_required
      fi
      JSON_PATH="$1"
      ;;
    --json=*)
      JSON_PATH="${1#--json=}"
      [ -n "$JSON_PATH" ] || json_path_required
      ;;
    -h|--help)
      printf 'Usage: bash fleet-audit-remote.sh [--github-issue] [--json PATH]\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s (use --github-issue, --json PATH, or --help)\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

if [ -n "$JSON_PATH" ] && [ -d "$JSON_PATH" ]; then
  printf 'FAIL --json path is a directory, not a file: %s\n' "$JSON_PATH" >&2
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'FAIL gh CLI not installed.\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL python3 not installed.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Resolve upstream engineering-standards HEAD SHA once, up front. Never
# hardcoded — always the live value at run time.
# ---------------------------------------------------------------------------
UPSTREAM_SHA="$(gh api "repos/${ENGSTD_REPO}/commits/main" --jq .sha 2>/dev/null || true)"
if [ -z "$UPSTREAM_SHA" ]; then
  printf 'FAIL could not resolve %s@main SHA via gh api.\n' "$ENGSTD_REPO" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Fetches a file's contents from a repo's DEFAULT branch via the GitHub API.
# Prints decoded file contents to stdout, or nothing + non-zero exit if the
# file doesn't exist / repo inaccessible.
# ---------------------------------------------------------------------------
gh_default_branch_file() {
  local name_with_owner="$1" path="$2"
  gh api "repos/${name_with_owner}/contents/${path}" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 --decode 2>/dev/null
}

# ---------------------------------------------------------------------------
# Enumerate Florian's real GitHub repos (owned or accessible), not a local
# filesystem walk.
# ---------------------------------------------------------------------------
REPO_LIST_JSON="$(gh repo list florianhorner --limit 200 --json nameWithOwner,isFork,parent,isArchived)"

# ---------------------------------------------------------------------------
# Classify each repo. Rows: nameWithOwner|bucket|status|detail
# ---------------------------------------------------------------------------
ROWS=()

while IFS=$'\t' read -r name_with_owner is_fork is_archived; do
  [ -z "$name_with_owner" ] && continue

  # Skip archived repos entirely: no writes, don't even classify.
  if [ "$is_archived" = "true" ]; then
    continue
  fi

  bucket="OWN"
  [ "$is_fork" = "true" ] && bucket="OWN-FORK"

  workflow_contents="$(gh_default_branch_file "$name_with_owner" "$CI_WORKFLOW_PATH" || true)"

  if [ -z "$workflow_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|no ${CI_WORKFLOW_PATH} on default branch")
    continue
  fi

  meta_contents="$(gh_default_branch_file "$name_with_owner" "$META_PATH" || true)"
  if [ -z "$meta_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${CI_WORKFLOW_PATH} exists but no ${META_PATH} — can't determine freshness")
    continue
  fi

  pinned_sha="$(printf '%s' "$meta_contents" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha_pin",""))' 2>/dev/null || true)"
  if [ -z "$pinned_sha" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${META_PATH} exists but has no parseable sha_pin field")
    continue
  fi

  if [ "$pinned_sha" = "$UPSTREAM_SHA" ]; then
    ROWS+=("${name_with_owner}|${bucket}|FRESH|sha_pin @ ${pinned_sha:0:7} matches upstream main")
    continue
  fi

  age_days="?"
  fetched_at="$(printf '%s' "$meta_contents" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("fetched_at",""))' 2>/dev/null || true)"
  if [ -n "$fetched_at" ]; then
    age_days="$(python3 -c "
import sys
from datetime import datetime, timezone
try:
    fetched = datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    print((now - fetched).days)
except Exception:
    print('?')
" "$fetched_at" 2>/dev/null || echo '?')"
  fi
  detail="sha_pin @ ${pinned_sha:0:7}, upstream @ ${UPSTREAM_SHA:0:7}"
  [ "$age_days" != "?" ] && detail="${detail}, meta.json fetched_at is ${age_days}d old"
  ROWS+=("${name_with_owner}|${bucket}|STALE(${age_days}d)|${detail}")

done < <(printf '%s' "$REPO_LIST_JSON" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    name = r["nameWithOwner"]
    is_fork = str(r["isFork"]).lower()
    is_archived = str(r["isArchived"]).lower()
    print(name + "\t" + is_fork + "\t" + is_archived)
')

# ---------------------------------------------------------------------------
# Also flag engineering-standards itself if MISSING — it's the SSOT and
# currently doesn't consume its own commit-lint.yml includer. This is a known,
# correct finding from a prior audit, not a bug to "fix" here.
# ---------------------------------------------------------------------------
# (already covered by the loop above since engineering-standards is in
# `gh repo list florianhorner` — no special-casing needed beyond this comment
# documenting why it's expected to show MISSING.)

# ---------------------------------------------------------------------------
# Sort: problems first (MISSING, STALE), then FRESH, alphabetical within group.
# ---------------------------------------------------------------------------
rank_of() {
  case "$1" in
    MISSING*) echo 0 ;;
    STALE*)   echo 1 ;;
    FRESH)    echo 2 ;;
    *)        echo 3 ;;
  esac
}

SORTED_ROWS=()
while IFS= read -r line; do
  SORTED_ROWS+=("$line")
done < <(
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name bucket status detail <<< "$row"
    printf '%d\t%s\t%s\n' "$(rank_of "$status")" "$name" "$row"
  done | sort -t $'\t' -k1,1n -k2,2 | cut -f3-
)

MISSING_COUNT=0; STALE_COUNT=0; FRESH_COUNT=0

TABLE="| Repo | Bucket | Status | Detail |
|---|---|---|---|"
for row in "${SORTED_ROWS[@]}"; do
  IFS='|' read -r name bucket status detail <<< "$row"
  case "$status" in
    MISSING*) MISSING_COUNT=$((MISSING_COUNT+1)) ;;
    STALE*)   STALE_COUNT=$((STALE_COUNT+1)) ;;
    FRESH)    FRESH_COUNT=$((FRESH_COUNT+1)) ;;
  esac
  TABLE="${TABLE}
| ${name} | ${bucket} | ${status} | ${detail} |"
done

TOTAL="${#SORTED_ROWS[@]}"
SUMMARY_LINE="**${TOTAL}** repo(s) audited — **${MISSING_COUNT}** MISSING, **${STALE_COUNT}** STALE, **${FRESH_COUNT}** FRESH. Upstream \`engineering-standards@main\` at \`${UPSTREAM_SHA:0:7}\`."

REPORT="$(cat <<EOF
${SUMMARY_LINE}

${TABLE}

_Report-only. This workflow never writes to any other repo. To fix a finding, run \`bootstrap-repo.sh\` locally (see fleet-audit.sh --apply) or ask Claude Code to do it in a local session._
EOF
)"

printf '%s\n' "$REPORT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s\n' "$REPORT" >> "$GITHUB_STEP_SUMMARY"
fi

# ---------------------------------------------------------------------------
# Machine-readable artifact. See the header note: this, not the issue thread,
# is what a remediation agent reads, and `remediable` is decided here rather
# than by the consumer.
# ---------------------------------------------------------------------------
if [ -n "$JSON_PATH" ]; then
  printf '%s\n' "${SORTED_ROWS[@]}" | python3 -c '
import json, sys
from datetime import datetime, timezone

upstream_sha, out_path = sys.argv[1], sys.argv[2]

# Policy mirrors fleet-audit.sh note 5. Order matters: the OWN+MISSING
# allow-case is tested first, so every other combination falls through to a
# block reason and nothing is remediable by default.
#
# FRESH is tested before OWN-FORK deliberately. Both are correct for a fresh
# fork and neither is remediable, but "sha_pin already matches upstream" is
# the actionable state; "a fork needs a human on the diff" would imply there
# is a diff to look at. The remediable flag is what the consumer reads, and
# it is false either way.
def classify(bucket, status):
    if bucket == "OWN" and status.startswith("MISSING"):
        return True, ""
    if status.startswith("FRESH"):
        return False, "FRESH — sha_pin already matches upstream, nothing to remediate"
    if bucket == "OWN-FORK":
        return False, "OWN-FORK — AUTHOR-NOTES.md and upstream-tracking concerns need a human on the diff"
    if status.startswith("STALE"):
        return False, "STALE — a SHA-pin refresh changes what CI enforces; deliberate action, never automated"
    return False, "unrecognized status — not eligible"

repos, remediable_count = [], 0
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    name, bucket, status, detail = line.split("|", 3)
    remediable, block_reason = classify(bucket, status)
    remediable_count += remediable
    repos.append({
        "name_with_owner": name,
        "bucket": bucket,
        "status": status,
        "detail": detail,
        "remediable": remediable,
        "remediation_block_reason": block_reason,
    })

report = {
    "schema_version": "1.0.0",
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "upstream_sha": upstream_sha,
    "policy": {
        "source": "fleet-audit.sh note 5",
        "auto_remediable": "bucket OWN + status MISSING",
        "never_auto": [
            "OWN-FORK (any status)",
            "STALE (any bucket)",
            "archived repos (excluded from the report entirely)",
        ],
        "consumer_contract": "act only on repos where remediable is true; open draft PRs only; never merge",
    },
    "summary": {
        "total": len(repos),
        "missing": sum(1 for r in repos if r["status"].startswith("MISSING")),
        "stale": sum(1 for r in repos if r["status"].startswith("STALE")),
        "fresh": sum(1 for r in repos if r["status"].startswith("FRESH")),
        "remediable": remediable_count,
    },
    "repos": repos,
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(report, fh, indent=2, ensure_ascii=False)
    fh.write("\n")

# stderr, not stdout: stdout carries the markdown report verbatim and callers
# capture it. --json adds a file, never a line to that report.
print("Wrote %s (%d repo(s), %d remediable)" % (out_path, len(repos), remediable_count),
      file=sys.stderr)
' "$UPSTREAM_SHA" "$JSON_PATH"
fi

if [ "$FILE_ISSUE" -eq 0 ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# File or update a GitHub issue so this is genuinely visible to Florian
# (issue notification), not just buried in the step summary.
# ---------------------------------------------------------------------------
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set to file an issue}"

# Ensure the label exists (idempotent — ignore "already exists" errors).
gh label create "$ISSUE_LABEL" \
  --repo "$GITHUB_REPOSITORY" \
  --description "Monthly fleet-wide commit-message-standards compliance report" \
  --color "5319e7" >/dev/null 2>&1 || true

MONTH_TITLE="Fleet compliance report — $(date -u +%Y-%m)"

EXISTING_ISSUE="$(gh issue list --repo "$GITHUB_REPOSITORY" --label "$ISSUE_LABEL" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)"

if [ -n "$EXISTING_ISSUE" ]; then
  gh issue comment "$EXISTING_ISSUE" --repo "$GITHUB_REPOSITORY" --body "$REPORT"
  printf 'Added comment to existing issue #%s\n' "$EXISTING_ISSUE"
else
  gh issue create \
    --repo "$GITHUB_REPOSITORY" \
    --title "$MONTH_TITLE" \
    --label "$ISSUE_LABEL" \
    --body "$REPORT"
  printf 'Created new issue: %s\n' "$MONTH_TITLE"
fi
