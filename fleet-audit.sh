#!/usr/bin/env bash
# Report installation inventory across local repository origins; never modify them.
# MISSING and STALE describe metadata, not publication safety or adoption policy.
set -euo pipefail
export LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly ENGSTD_REPO="florianhorner/engineering-standards"
readonly ENGSTD_OWNER="florianhorner"
readonly REPOS_ROOT="/Users/florianhorner/repos"
readonly WORKSPACES_ROOT="/Users/florianhorner/conductor/workspaces"
readonly CI_WORKFLOW_PATH=".github/workflows/commit-lint.yml"
readonly META_PATH=".config/commit-rules.meta.json"

# ---------------------------------------------------------------------------
# Output helpers (mirrors bootstrap-repo.sh style)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_BLUE=$'\e[34m'; C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_RESET=""
fi

info()    { printf '%s    %s%s\n' "$C_DIM" "$1" "$C_RESET"; }
warn()    { printf '%s%sWARN%s %s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$1"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --apply)
      printf 'Fleet apply has been removed. Select one clean feature checkout and use bootstrap-repo.sh TARGET --repo OWNER/REPO --ref SHA.\n' >&2
      exit 2
      ;;
    -h|--help)
      printf 'Usage: bash fleet-audit.sh\n'
      printf '  (no flags)  dry-run: print the compliance table, write nothing\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s (use --help)\n' "$arg" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  printf '%sFAIL%s gh CLI not installed. Install via "brew install gh".\n' "$C_RED" "$C_RESET" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  printf '%sFAIL%s gh CLI not authenticated. Run "gh auth login".\n' "$C_RED" "$C_RESET" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf '%sFAIL%s python3 not installed.\n' "$C_RED" "$C_RESET" >&2
  exit 1
fi

printf '\n%s== fleet-audit ==%s\n' "$C_BOLD" "$C_RESET"
printf '%sMode:%s    report only (no writes)\n' "$C_BOLD" "$C_RESET"
printf '%sRoots:%s   %s, %s\n\n' "$C_BOLD" "$C_RESET" "$REPOS_ROOT" "$WORKSPACES_ROOT"

# ---------------------------------------------------------------------------
# Resolve upstream engineering-standards HEAD SHA once, up front.
# ---------------------------------------------------------------------------
printf '%sResolving upstream HEAD...%s ' "$C_DIM" "$C_RESET"
UPSTREAM_SHA="$(gh api "repos/${ENGSTD_REPO}/commits/main" --jq .sha 2>/dev/null || true)"
if [ -z "$UPSTREAM_SHA" ]; then
  UPSTREAM_SHA="$(git ls-remote "https://github.com/${ENGSTD_REPO}" main 2>/dev/null | cut -f1 || true)"
fi
if [ -z "$UPSTREAM_SHA" ]; then
  printf '%sFAIL%s\n' "$C_RED" "$C_RESET" >&2
  printf 'Could not resolve florianhorner/engineering-standards@main SHA via gh api or git ls-remote.\n' >&2
  exit 1
fi
printf '%s%s%s\n\n' "$C_GREEN" "${UPSTREAM_SHA:0:7}" "$C_RESET"

# ---------------------------------------------------------------------------
# Step 1: enumerate .git directories.
#   - repos/: one level deep (repos/*/. git)
#   - conductor/workspaces/: nested project/variant subdirs, so search wider.
#     Capped at depth 6 (workspaces/<project>/<variant>/.git = depth 3, but
#     Conductor sometimes nests an extra level for sub-checkouts) — cheap
#     insurance against runaway find on a home directory, not a hard project
#     assumption.
# ---------------------------------------------------------------------------
GIT_DIRS=()
while IFS= read -r -d '' gitdir; do
  GIT_DIRS+=("$(dirname "$gitdir")")
done < <(find "$REPOS_ROOT" -mindepth 2 -maxdepth 2 -name ".git" -print0 2>/dev/null)

while IFS= read -r -d '' gitdir; do
  GIT_DIRS+=("$(dirname "$gitdir")")
done < <(find "$WORKSPACES_ROOT" -mindepth 2 -maxdepth 6 -name ".git" -print0 2>/dev/null)

info "found ${#GIT_DIRS[@]} local git checkouts"

# ---------------------------------------------------------------------------
# Step 2: normalize origin -> owner/repo, dedupe.
#   git@github.com:owner/repo.git  -> owner/repo
#   https://github.com/owner/repo.git -> owner/repo
#   (trailing .git stripped either way; case preserved as GitHub returns it
#   later via nameWithOwner, which is the canonical casing we report.)
#
# macOS ships bash 3.2 (no associative arrays) — bootstrap-repo.sh avoids
# `declare -A` for the same reason, so this mirrors that constraint. Dedup is
# done with two parallel indexed arrays (ORIGIN_LIST + PATHS_BY_ORIGIN_LIST,
# same index i) and a linear scan via origin_index(). Fleet size is in the
# dozens, not thousands, so O(n) lookups are invisible in practice.
# ---------------------------------------------------------------------------
ORIGIN_LIST=()
PATHS_BY_ORIGIN_LIST=()   # same index as ORIGIN_LIST; newline-joined paths
NO_ORIGIN_DIRS=()

normalize_origin() {
  local url="$1"
  url="${url%.git}"
  if [[ "$url" =~ ^git@github\.com:(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^https://github\.com/(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$url" =~ ^ssh://git@github\.com/(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$url"
  fi
}

# Prints the index of $1 in ORIGIN_LIST, or empty string if not found.
origin_index() {
  local needle="$1" i
  for i in "${!ORIGIN_LIST[@]}"; do
    [ "${ORIGIN_LIST[$i]}" = "$needle" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

for dir in "${GIT_DIRS[@]}"; do
  origin_url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  if [ -z "$origin_url" ]; then
    NO_ORIGIN_DIRS+=("$dir")
    continue
  fi
  norm="$(normalize_origin "$origin_url")"
  idx="$(origin_index "$norm" || true)"
  if [ -z "$idx" ]; then
    ORIGIN_LIST+=("$norm")
    PATHS_BY_ORIGIN_LIST+=("$dir")
  else
    PATHS_BY_ORIGIN_LIST[$idx]="${PATHS_BY_ORIGIN_LIST[$idx]}"$'\n'"$dir"
  fi
done

info "${#ORIGIN_LIST[@]} unique origins after de-duping local checkouts"
if [ "${#NO_ORIGIN_DIRS[@]}" -gt 0 ]; then
  info "${#NO_ORIGIN_DIRS[@]} checkout(s) skipped (no origin remote): ${NO_ORIGIN_DIRS[*]}"
fi
printf '\n'

# ---------------------------------------------------------------------------
# Step 3: classify each unique origin.
# Result rows stored as pipe-delimited strings for later sorting/printing:
#   nameWithOwner|bucket|status|detail|primary_local_path
# ---------------------------------------------------------------------------
ROWS=()

# Fetches a file's contents from a repo's DEFAULT branch via the GitHub API
# (omitting `ref=` means "default branch" — no local checkout involved).
# Prints decoded file contents to stdout, or nothing + non-zero exit if the
# file doesn't exist / repo inaccessible.
gh_default_branch_file() {
  local name_with_owner="$1" path="$2"
  gh api "repos/${name_with_owner}/contents/${path}" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 --decode 2>/dev/null
}

# ---------------------------------------------------------------------------
# Step 2b: resolve each raw origin to GitHub's CANONICAL nameWithOwner, then
# re-merge by that canonical name.
#
# Why this exists: Step 2 dedupes by the LOCAL git remote URL string, which
# is correct and bug-free for that job — but it's the wrong key when a repo
# has been renamed upstream. Two local checkouts can carry different remote
# URLs (e.g. florianhorner/fakeitaliradio and florianhorner/mammamiradio)
# that both resolve, via GitHub's rename-redirect, to the SAME current repo
# (`gh repo view` on either returns nameWithOwner: florianhorner/mammamiradio).
# Confirmed live: florianhorner/fakeitaliradio -> mammamiradio, and
# florianhorner/lightener-curve-editor -> lightener-studio. Classifying by
# raw origin string produced two ROWS for one real repo. Fix: do exactly one
# `gh repo view` per raw origin (same call count as before — no new API
# load), then merge any origins whose resolved nameWithOwner collides,
# concatenating their path lists, BEFORE the classification loop below runs.
# Stays bash 3.2-compatible: same linear-scan-over-indexed-arrays pattern as
# origin_index(), no `declare -A`.
# ---------------------------------------------------------------------------
RESOLVED_NAME_LIST=()          # canonical nameWithOwner, or "" on lookup failure
RESOLVED_ISFORK_LIST=()
RESOLVED_DEFAULT_BRANCH_LIST=()
RESOLVED_RAW_ORIGIN_LIST=()    # raw origin string, kept for GH-LOOKUP-FAILED rows
RESOLVED_PATHS_LIST=()         # newline-joined paths, merged across collisions

resolved_index_for_name() {
  local needle="$1" i
  for i in "${!RESOLVED_NAME_LIST[@]}"; do
    [ -n "$needle" ] && [ "${RESOLVED_NAME_LIST[$i]}" = "$needle" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

for i in "${!ORIGIN_LIST[@]}"; do
  origin="${ORIGIN_LIST[$i]}"
  all_paths="${PATHS_BY_ORIGIN_LIST[$i]}"

  view_json="$(gh repo view "$origin" --json isFork,parent,nameWithOwner,defaultBranchRef 2>/dev/null || true)"
  if [ -z "$view_json" ]; then
    # Lookup failure: never merges with anything (no canonical name to key
    # on) — keep it as its own row, same as before this fix.
    RESOLVED_NAME_LIST+=("")
    RESOLVED_ISFORK_LIST+=("")
    RESOLVED_DEFAULT_BRANCH_LIST+=("")
    RESOLVED_RAW_ORIGIN_LIST+=("$origin")
    RESOLVED_PATHS_LIST+=("$all_paths")
    continue
  fi

  name_with_owner="$(printf '%s' "$view_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["nameWithOwner"])')"
  is_fork="$(printf '%s' "$view_json" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["isFork"]).lower())')"
  default_branch="$(printf '%s' "$view_json" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("defaultBranchRef") or {}; print(d.get("name",""))')"

  ridx="$(resolved_index_for_name "$name_with_owner" || true)"
  if [ -z "$ridx" ]; then
    RESOLVED_NAME_LIST+=("$name_with_owner")
    RESOLVED_ISFORK_LIST+=("$is_fork")
    RESOLVED_DEFAULT_BRANCH_LIST+=("$default_branch")
    RESOLVED_RAW_ORIGIN_LIST+=("$origin")
    RESOLVED_PATHS_LIST+=("$all_paths")
  else
    # Collision: a rename made this origin resolve to an already-seen
    # canonical repo. Merge path lists to retain every local
    # checkout (old-name and new-name alike).
    RESOLVED_PATHS_LIST[$ridx]="${RESOLVED_PATHS_LIST[$ridx]}"$'\n'"${all_paths}"
  fi
done

info "${#RESOLVED_NAME_LIST[@]} unique repos after merging renamed-origin collisions"
printf '\n'

for i in "${!RESOLVED_NAME_LIST[@]}"; do
  origin="${RESOLVED_RAW_ORIGIN_LIST[$i]}"
  name_with_owner="${RESOLVED_NAME_LIST[$i]}"
  is_fork="${RESOLVED_ISFORK_LIST[$i]}"
  default_branch="${RESOLVED_DEFAULT_BRANCH_LIST[$i]}"
  all_paths="${RESOLVED_PATHS_LIST[$i]}"
  primary_path="$(printf '%s\n' "$all_paths" | head -n1)"

  if [ -z "$name_with_owner" ]; then
    ROWS+=("${origin}|UNKNOWN|GH-LOOKUP-FAILED|gh repo view failed (renamed/deleted/private-no-access?)|${primary_path}")
    continue
  fi

  owner="${name_with_owner%%/*}"

  # --- Classification step 1: ownership gate ---
  if [ "$owner" != "$ENGSTD_OWNER" ]; then
    ROWS+=("${name_with_owner}|THIRD-PARTY-CLONE|n/a|owner is ${owner}, not ${ENGSTD_OWNER} — no repo of Florian's to standardize|${primary_path}")
    continue
  fi

  # --- Classification step 2: fork bucket ---
  bucket="OWN"
  [ "$is_fork" = "true" ] && bucket="OWN-FORK"

  # --- Classification step 3: commit-lint workflow presence, read from the
  #     GitHub default branch, not a local worktree. ---
  workflow_contents="$(gh_default_branch_file "$name_with_owner" "$CI_WORKFLOW_PATH" || true)"

  if [ -z "$workflow_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|no ${CI_WORKFLOW_PATH} on default branch (${default_branch:-?})|${primary_path}")
    continue
  fi

  # --- Classification step 4: freshness, read from commit-rules.meta.json's
  #     sha_pin field on the default branch — NOT the commit-lint.yml `uses:`
  #     pin, which Dependabot can bump independently. ---
  meta_contents="$(gh_default_branch_file "$name_with_owner" "$META_PATH" || true)"

  if [ -z "$meta_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${CI_WORKFLOW_PATH} exists but no ${META_PATH} on default branch (${default_branch:-?}) — can't determine freshness|${primary_path}")
    continue
  fi

  pinned_sha="$(printf '%s' "$meta_contents" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha_pin",""))' 2>/dev/null || true)"
  if [ -z "$pinned_sha" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${META_PATH} exists but has no parseable sha_pin field|${primary_path}")
    continue
  fi

  if [ "$pinned_sha" = "$UPSTREAM_SHA" ]; then
    ROWS+=("${name_with_owner}|${bucket}|FRESH|sha_pin @ ${pinned_sha:0:7} matches upstream main|${primary_path}")
    continue
  fi

  # STALE: compute age from meta.json's fetched_at (the source of truth
  # bootstrap-repo.sh itself writes), not from looking up when pinned_sha
  # landed upstream. Minimal installations omit timestamps and show unknown age.
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
  ROWS+=("${name_with_owner}|${bucket}|STALE(${age_days}d)|${detail}|${primary_path}")
done

# ---------------------------------------------------------------------------
# Step 4: print the summary table, problems first.
# Sort order: MISSING, STALE, THIRD-PARTY-CLONE/OWN-FORK-noted, then FRESH,
# then UNKNOWN. Within a status group, alphabetical by nameWithOwner.
# ---------------------------------------------------------------------------
rank_of() {
  case "$1" in
    MISSING*)   echo 0 ;;
    STALE*)     echo 1 ;;
    n/a)        echo 2 ;;   # THIRD-PARTY-CLONE
    FRESH)      echo 3 ;;
    *)          echo 4 ;;   # UNKNOWN / GH-LOOKUP-FAILED
  esac
}

SORTED_ROWS=()
while IFS= read -r line; do
  SORTED_ROWS+=("$line")
done < <(
  for row in "${ROWS[@]}"; do
    IFS='|' read -r name bucket status detail path <<< "$row"
    printf '%d\t%s\t%s\n' "$(rank_of "$status")" "$name" "$row"
  done | sort -t $'\t' -k1,1n -k2,2 | cut -f3-
)

printf '%s%-42s %-18s %-16s %s%s\n' "$C_BOLD" "REPO" "BUCKET" "STATUS" "DETAIL" "$C_RESET"
printf '%s%s%s\n' "$C_DIM" "$(printf '%.0s-' {1..110})" "$C_RESET"

MISSING_COUNT=0; STALE_COUNT=0; FRESH_COUNT=0; FORK_COUNT=0; CLONE_COUNT=0; UNKNOWN_COUNT=0

for row in "${SORTED_ROWS[@]}"; do
  IFS='|' read -r name bucket status detail path <<< "$row"
  color="$C_RESET"
  case "$status" in
    MISSING*) color="$C_RED"; MISSING_COUNT=$((MISSING_COUNT+1)) ;;
    STALE*)   color="$C_YELLOW"; STALE_COUNT=$((STALE_COUNT+1)) ;;
    FRESH)    color="$C_BLUE"; FRESH_COUNT=$((FRESH_COUNT+1)) ;;
    n/a)      color="$C_DIM"; CLONE_COUNT=$((CLONE_COUNT+1)) ;;
    *)        color="$C_YELLOW"; UNKNOWN_COUNT=$((UNKNOWN_COUNT+1)) ;;
  esac
  [ "$bucket" = "OWN-FORK" ] && FORK_COUNT=$((FORK_COUNT+1))
  printf '%-42s %-18s %s%-16s%s %s\n' "$name" "$bucket" "$color" "$status" "$C_RESET" "$detail"
done

printf '\n%sTotals:%s %d repo(s) audited — %d MISSING, %d STALE, %d FRESH, %d THIRD-PARTY-CLONE, %d OWN-FORK, %d UNKNOWN\n' \
  "$C_BOLD" "$C_RESET" "${#SORTED_ROWS[@]}" "$MISSING_COUNT" "$STALE_COUNT" "$FRESH_COUNT" "$CLONE_COUNT" "$FORK_COUNT" "$UNKNOWN_COUNT"

# ---------------------------------------------------------------------------
# Report only; installation is an explicit, separately reviewed operation.
printf '\nInventory only. Missing or older metadata does not imply that adoption is required.\n'
printf 'To adopt, select one clean feature checkout and run bootstrap-repo.sh TARGET --repo OWNER/REPO --ref SHA.\n'
