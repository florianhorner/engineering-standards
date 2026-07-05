#!/usr/bin/env bash
# fleet-audit.sh — fleet-wide compliance audit for the commit-message-standards
# system. Walks every local git checkout under ~/repos and
# ~/conductor/workspaces, dedupes by origin remote, classifies each unique
# repo, and reports drift against the engineering-standards upstream.
#
# Why this exists: bootstrap-repo.sh (this repo's sibling script) makes a
# SINGLE repo compliant. Nothing previously checked the whole fleet, so repos
# silently drifted out of sync — some pinned to an engineering-standards SHA
# 50+ days stale — with no signal anywhere. This script is the missing
# "is the fleet actually in sync" read.
#
# Usage:
#   bash fleet-audit.sh            # dry-run: print the table, touch nothing
#   bash fleet-audit.sh --apply    # also auto-bootstrap OWN + MISSING repos
#
# Design decisions (kept here, not in the final chat report, per instructions):
#
# 1. Dedup key is the normalized origin, not the directory path. Conductor
#    workspaces intentionally create N worktree checkouts of the same logical
#    repo (e.g. conductor/workspaces/retro/toronto-v3, .../valencia-v6, ...
#    all -> florianhorner/retro). Auditing "the repo" means auditing the
#    remote once. We keep ALL paths per origin (PATHS_BY_ORIGIN) but
#    CLASSIFICATION never reads from an arbitrary local path — see note 1b.
#
# 1b. Classification is read from the GitHub default branch via `gh api
#    repos/<owner>/<repo>/contents/<path>` (no `ref=` means "default branch"),
#    never from a local worktree file. Local checkouts under
#    conductor/workspaces/ are frequently old/abandoned feature branches that
#    never carried the CI workflow and never will (they're not going anywhere
#    near the default branch) — sampling "the first local path that happens
#    to exist for this origin" produced false MISSING/STALE reads for repos
#    whose actual default branch was fine (confirmed live for florianhorner/
#    retro: toronto-v3 has commit-lint.yml, several old branches don't; an
#    arbitrary pick landed on a bare one). Local paths are kept ONLY to give
#    --apply a concrete directory to write into (see note 5b) — never for
#    deciding the fleet's compliance status.
#
# 2. Third-party clones are identified via `gh repo view --json nameWithOwner`
#    against the OWNER, not by string-matching the local directory name.
#    Directory names lie (e.g. repos/retro is florianhorner/retro but
#    repos/lightener's origin is actually lightener-studio — a rename evades
#    naming heuristics entirely). The nameWithOwner from GitHub is the only
#    trustworthy signal.
#
# 3. Forks are only special-cased when florianhorner is ALSO the owner
#    (isFork:true AND owner is florianhorner) — that covers upstream-tracking
#    forks like adaptive-lighting-fork. A fork owned by someone else that
#    Florian happened to clone locally is just a THIRD-PARTY-CLONE; "isFork"
#    alone isn't enough, ownership decides the bucket.
#
# 4. STALE freshness compares .config/commit-rules.meta.json's `sha_pin`
#    field against upstream main HEAD — NOT the `uses: .../commit-lint-
#    reusable.yml@<SHA>` pin embedded in the repo's own CI workflow file.
#    Those two SHAs drift independently: Dependabot (trusted-bot allowlisted,
#    vendored via dependabot-snippet.yml) auto-bumps the workflow's `uses:`
#    pin whenever upstream publishes a new commit-lint-reusable.yml, but
#    nothing except bootstrap-repo.sh itself touches commit-rules.meta.json's
#    sha_pin. A repo can show a fully current commit-lint.yml pin while its
#    actual vendored commit-rules.json/CLAUDE.md guidance is many commits
#    stale — meta.json's sha_pin is the only field that reflects "when did
#    bootstrap-repo.sh last actually run here." The AGE in days is read from
#    the same meta.json's fetched_at, for the same "trust the artifact
#    bootstrap-repo.sh already emits" reason. commit-lint.yml is still used
#    for the MISSING check (its mere presence/absence), just not for
#    freshness.
#
# 5. --apply only ever touches bucket OWN + status MISSING. OWN-FORK is never
#    auto-bootstrapped (forks carry AUTHOR-NOTES.md and upstream-tracking
#    concerns that deserve a human looking at the diff before CI rules land).
#    STALE is never auto-applied for ANY bucket — refreshing a SHA pin is a
#    deliberate, visible action (it changes what CI enforces), not a silent
#    background fix. THIRD-PARTY-CLONE is never touched, full stop — there's
#    no repo of Florian's to push standards to.
#
# 5b. bootstrap-repo.sh needs a real local git working tree to write into —
#    the GitHub API used for classification (note 1b) can read files but
#    can't run bootstrap-repo.sh's writes/commits. So for a repo classified
#    MISSING+OWN and eligible for --apply, we pick the local checkout (from
#    PATHS_BY_ORIGIN) that is actually ON the default branch (`git branch
#    --show-current` == the repo's default_branch, both read via `gh api
#    repos/<owner>/<repo>` --jq .default_branch and `git -C <path> branch
#    --show-current`). If NO local checkout is on the default branch (e.g.
#    every local copy is an old feature-branch worktree), the repo is
#    reported but NOT added to APPLY_TARGETS — instead it's flagged with a
#    note to check out the default branch locally first.

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
readonly BOOTSTRAP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/bootstrap-repo.sh"

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
APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    -h|--help)
      printf 'Usage: bash fleet-audit.sh [--apply]\n'
      printf '  (no flags)  dry-run: print the compliance table, write nothing\n'
      printf '  --apply     also auto-bootstrap OWN repos classified MISSING\n'
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s (use --apply or --help)\n' "$arg" >&2
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
printf '%sMode:%s    %s\n' "$C_BOLD" "$C_RESET" "$([ "$APPLY" -eq 1 ] && echo 'APPLY (will bootstrap OWN+MISSING repos)' || echo 'dry-run (no writes)')"
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
APPLY_TARGETS=()      # paths to actually bootstrap under --apply
MANUAL_TARGETS=()     # "path|reason" to print as copy-paste commands

# Fetches a file's contents from a repo's DEFAULT branch via the GitHub API
# (omitting `ref=` means "default branch" — no local checkout involved).
# Prints decoded file contents to stdout, or nothing + non-zero exit if the
# file doesn't exist / repo inaccessible. See design note 1b.
gh_default_branch_file() {
  local name_with_owner="$1" path="$2"
  gh api "repos/${name_with_owner}/contents/${path}" --jq '.content' 2>/dev/null \
    | tr -d '\n' | base64 --decode 2>/dev/null
}

# Given nameWithOwner + default_branch, returns the local path (from the
# newline-joined $3 list) that is currently checked out ON that branch, or
# empty if none qualify. See design note 5b.
pick_local_checkout_on_default_branch() {
  local default_branch="$1" paths="$2" p current
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    current="$(git -C "$p" branch --show-current 2>/dev/null || true)"
    if [ "$current" = "$default_branch" ]; then
      printf '%s' "$p"
      return 0
    fi
  done <<< "$paths"
  return 1
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
    # canonical repo. Merge path lists so --apply still sees every local
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

  # Local checkout eligible for --apply: must actually be on the default
  # branch. If none qualifies, --apply has nowhere safe to write.
  apply_path=""
  if [ -n "$default_branch" ]; then
    apply_path="$(pick_local_checkout_on_default_branch "$default_branch" "$all_paths" || true)"
  fi
  no_apply_note="no local checkout on default branch (${default_branch:-unknown}); bootstrap manually after checking one out"

  # --- Classification step 3: commit-lint workflow presence, read from the
  #     GitHub default branch (not a local worktree — see note 1b). ---
  workflow_contents="$(gh_default_branch_file "$name_with_owner" "$CI_WORKFLOW_PATH" || true)"

  if [ -z "$workflow_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|no ${CI_WORKFLOW_PATH} on default branch (${default_branch:-?})|${primary_path}")
    if [ "$bucket" = "OWN" ]; then
      if [ -n "$apply_path" ]; then
        APPLY_TARGETS+=("$apply_path")
      else
        MANUAL_TARGETS+=("${primary_path}|${no_apply_note}")
      fi
    else
      MANUAL_TARGETS+=("${primary_path}|MISSING, bucket ${bucket} — never auto-applied")
    fi
    continue
  fi

  # --- Classification step 4: freshness, read from commit-rules.meta.json's
  #     sha_pin field on the default branch — NOT the commit-lint.yml `uses:`
  #     pin, which Dependabot bumps independently. See design note 4. ---
  meta_contents="$(gh_default_branch_file "$name_with_owner" "$META_PATH" || true)"

  if [ -z "$meta_contents" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${CI_WORKFLOW_PATH} exists but no ${META_PATH} on default branch (${default_branch:-?}) — can't determine freshness|${primary_path}")
    if [ "$bucket" = "OWN" ]; then
      if [ -n "$apply_path" ]; then
        APPLY_TARGETS+=("$apply_path")
      else
        MANUAL_TARGETS+=("${primary_path}|${no_apply_note}")
      fi
    else
      MANUAL_TARGETS+=("${primary_path}|missing meta.json, bucket ${bucket} — never auto-applied")
    fi
    continue
  fi

  pinned_sha="$(printf '%s' "$meta_contents" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha_pin",""))' 2>/dev/null || true)"
  if [ -z "$pinned_sha" ]; then
    ROWS+=("${name_with_owner}|${bucket}|MISSING|${META_PATH} exists but has no parseable sha_pin field|${primary_path}")
    if [ "$bucket" = "OWN" ]; then
      if [ -n "$apply_path" ]; then
        APPLY_TARGETS+=("$apply_path")
      else
        MANUAL_TARGETS+=("${primary_path}|${no_apply_note}")
      fi
    else
      MANUAL_TARGETS+=("${primary_path}|unparseable sha_pin, bucket ${bucket} — never auto-applied")
    fi
    continue
  fi

  if [ "$pinned_sha" = "$UPSTREAM_SHA" ]; then
    ROWS+=("${name_with_owner}|${bucket}|FRESH|sha_pin @ ${pinned_sha:0:7} matches upstream main|${primary_path}")
    continue
  fi

  # STALE: compute age from meta.json's fetched_at (the source of truth
  # bootstrap-repo.sh itself writes), not from looking up when pinned_sha
  # landed upstream — see design note 4 at the top of this file.
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
  MANUAL_TARGETS+=("${primary_path}|STALE — SHA pin refresh is never auto-applied, review the diff")
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
# Step 5: act (or advise), depending on mode.
# ---------------------------------------------------------------------------
if [ "$APPLY" -eq 0 ]; then
  printf '\n%sDry-run only — no files were touched.%s\n' "$C_DIM" "$C_RESET"
  if [ "${#APPLY_TARGETS[@]}" -gt 0 ]; then
    printf '\n%sWould auto-bootstrap under --apply (bucket OWN, status MISSING):%s\n' "$C_BOLD" "$C_RESET"
    for t in "${APPLY_TARGETS[@]}"; do
      printf '  bash %s %s\n' "$BOOTSTRAP_SCRIPT" "$t"
    done
  fi
  if [ "${#MANUAL_TARGETS[@]}" -gt 0 ]; then
    printf '\n%sNeeds a human — copy-paste when ready (never auto-applied):%s\n' "$C_BOLD" "$C_RESET"
    for t in "${MANUAL_TARGETS[@]}"; do
      IFS='|' read -r path reason <<< "$t"
      printf '  bash %s %s   %s# %s%s\n' "$BOOTSTRAP_SCRIPT" "$path" "$C_DIM" "$reason" "$C_RESET"
    done
  fi
  printf '\nRe-run with --apply to auto-bootstrap the OWN+MISSING repos listed above.\n'
  exit 0
fi

printf '\n%s== Applying ==%s\n' "$C_BOLD" "$C_RESET"
if [ "${#APPLY_TARGETS[@]}" -eq 0 ]; then
  info "nothing to apply — no OWN repos are MISSING"
else
  for t in "${APPLY_TARGETS[@]}"; do
    printf '\n%s-- bootstrapping %s --%s\n' "$C_BOLD" "$t" "$C_RESET"
    bash "$BOOTSTRAP_SCRIPT" "$t" || warn "bootstrap-repo.sh exited non-zero for $t — inspect above output"
  done
fi

if [ "${#MANUAL_TARGETS[@]}" -gt 0 ]; then
  printf '\n%sSkipped (never auto-applied) — run by hand when ready:%s\n' "$C_BOLD" "$C_RESET"
  for t in "${MANUAL_TARGETS[@]}"; do
    IFS='|' read -r path reason <<< "$t"
    printf '  bash %s %s   %s# %s%s\n' "$BOOTSTRAP_SCRIPT" "$path" "$C_DIM" "$reason" "$C_RESET"
  done
fi

exit 0
