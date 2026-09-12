#!/usr/bin/env bash
# fleet-audit-remote.sh — GitHub-hosted-runner counterpart to fleet-audit.sh.
#
# Why this exists (and why it's a SEPARATE script, not a flag on
# fleet-audit.sh): fleet-audit.sh walks LOCAL git checkouts under ~/repos and
# ~/conductor/workspaces — that only works because it runs on Florian's own
# machine. A GitHub Actions cloud routine (or any hosted runner) has no
# filesystem access to those paths, full stop. This script instead enumerates
# repos via `gh repo list` (limit 200), including repos without a local
# checkout, and reports only the PUBLIC ones — the report can land in a public
# issue or an Actions summary. This is NOT proof of full-fleet coverage: a
# repository absent from the table may be private, unlisted or beyond the cap.
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
# through an explicitly selected feature checkout).
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
# whatever reads it. Only bucket OWN + status MISSING is eligible; OWN-FORK
# never is (forks carry author notes and upstream-tracking concerns), STALE
# never is for any bucket (a SHA-pin refresh changes what CI enforces, so it
# stays a deliberate visible action), and archived repos never enter the
# report at all. That rule came from fleet-audit.sh's --apply gate, which no
# longer exists; this script is now the only place it is written down.
# Keeping the decision here means an agent consuming the artifact has no
# policy left to interpret — it filters on a boolean. Eligibility is not an
# instruction to install: adoption stays a per-repository decision.
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
# Prints decoded nonempty file contents, or nothing on confirmed absence.
# Any uncertain read fails the entire audit before JSON or issue publication.
# A 404 alone is ambiguous (GitHub also hides inaccessible resources): require
# a successful root contents listing before treating the file as missing.
# ---------------------------------------------------------------------------
gh_default_branch_file() {
  local name_with_owner="$1" path="$2" response status_line root_contents
  if response="$(gh api "repos/${name_with_owner}/contents/${path}" --include 2>/dev/null)"; then
    printf '%s' "$response" | python3 -c '
import base64, json, sys
try:
    _, separator, body = sys.stdin.read().replace("\r\n", "\n").partition("\n\n")
    if not separator:
        raise ValueError("missing response headers")
    payload = json.loads(body)
    if payload["type"] != "file" or payload["encoding"] != "base64":
        raise ValueError("not an encoded file")
    content = base64.b64decode("".join(payload["content"].split()), validate=True).decode("utf-8")
    if not content.strip():
        raise ValueError("empty file")
    sys.stdout.write(content)
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit("FAIL invalid or empty file response; audit stopped")
'
    return
  fi
  status_line="${response%%$'\n'*}"
  if [[ "$status_line" =~ ^HTTP/[0-9.]+[[:space:]]404([[:space:]]|$) ]]; then
    if root_contents="$(gh api "repos/${name_with_owner}/contents" 2>/dev/null)" &&
       printf '%s' "$root_contents" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)' 2>/dev/null; then
      return 0
    fi
  fi
  printf 'FAIL cannot verify %s/%s; audit stopped (not MISSING)\n' "$name_with_owner" "$path" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Enumerate Florian's real GitHub repos (owned or accessible), not a local
# filesystem walk.
# ---------------------------------------------------------------------------
REPO_LIST_JSON="$(gh repo list "$ENGSTD_OWNER" --limit 200 --json nameWithOwner,isFork,parent,isArchived,visibility)"

# Parse before entering the loop: process-substitution failures otherwise get
# lost, allowing an incomplete inventory to produce a successful report.
REPO_ROWS="$(printf '%s' "$REPO_LIST_JSON" | python3 -c '
import json, re, sys
owner = sys.argv[1]
try:
    repos = json.load(sys.stdin)
    if not isinstance(repos, list):
        raise ValueError("not a repository list")
    for r in repos:
        # This report can enter public issues and Actions summaries. Omit
        # private and unknown visibility even when the token can enumerate
        # them. Filtering first also keeps the strict checks below scoped to
        # rows that will actually be published.
        if r.get("visibility") != "PUBLIC":
            continue
        name = r["nameWithOwner"]
        if not isinstance(name, str) or not re.fullmatch(re.escape(owner) + r"/[A-Za-z0-9_.-]+", name):
            raise ValueError("unexpected repository owner or name")
        if not isinstance(r["isFork"], bool) or not isinstance(r["isArchived"], bool):
            raise ValueError("invalid repository flags")
        print(name + "\t" + str(r["isFork"]).lower() + "\t" + str(r["isArchived"]).lower())
except (ValueError, KeyError, TypeError):
    sys.exit("FAIL invalid repository inventory; audit stopped")
' "$ENGSTD_OWNER")"

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

  workflow_contents="$(gh_default_branch_file "$name_with_owner" "$CI_WORKFLOW_PATH")"

  if [ -z "$workflow_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|no ${CI_WORKFLOW_PATH} on default branch")
    continue
  fi

  meta_contents="$(gh_default_branch_file "$name_with_owner" "$META_PATH")"
  if [ -z "$meta_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${CI_WORKFLOW_PATH} exists but no ${META_PATH} — can't determine freshness")
    continue
  fi

  pinned_sha="$(printf '%s' "$meta_contents" | python3 -c '
import json, re, sys
try:
    sha = json.load(sys.stdin)["sha_pin"]
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("invalid sha_pin")
    print(sha)
except (ValueError, KeyError, TypeError):
    sys.exit("FAIL invalid commit-rules metadata; audit stopped (not MISSING)")
')"

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

done <<< "$REPO_ROWS"

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

# Every "${arr[@]}" below is guarded on the count first. Bash only made
# expanding an empty array under `set -u` legal in 4.4; on 3.2 (what macOS
# ships) it is an unbound-variable abort, and the public-visibility filter
# above makes a zero-row run easy to reach.
SORTED_ROWS=()
while IFS= read -r line; do
  SORTED_ROWS+=("$line")
done < <(
  [ "${#ROWS[@]}" -eq 0 ] && exit 0
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name bucket status detail <<< "$row"
    printf '%d\t%s\t%s\n' "$(rank_of "$status")" "$name" "$row"
  done | sort -t $'\t' -k1,1n -k2,2 | cut -f3-
)

MISSING_COUNT=0; STALE_COUNT=0; FRESH_COUNT=0

TABLE="| Repo | Bucket | Status | Detail |
|---|---|---|---|"
for row in ${SORTED_ROWS[@]+"${SORTED_ROWS[@]}"}; do
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

_Public repositories only, at most 200 enumerated. A repository absent from this table is not evidence of compliance._

_Inventory is not an adoption requirement. Installation requires one explicit clean feature checkout: bootstrap-repo.sh TARGET --repo OWNER/REPO --ref SHA._
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
  printf '%s\n' ${SORTED_ROWS[@]+"${SORTED_ROWS[@]}"} | python3 -c '
import json, sys
from datetime import datetime, timezone

upstream_sha, out_path = sys.argv[1], sys.argv[2]

# Order matters: the OWN+MISSING allow-case is tested first, so every other
# combination falls through to a block reason and nothing is remediable by
# default.
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
        "source": "fleet-audit-remote.sh (inherited from the removed fleet-audit.sh --apply gate)",
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
