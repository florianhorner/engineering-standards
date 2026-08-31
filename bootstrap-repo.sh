#!/usr/bin/env bash
# bootstrap-repo.sh — self-verifying installer for the commit-message-standards
# system. Idempotent: re-running refreshes managed files in place between
# markers; never double-appends.
#
# Usage:
#   bash bootstrap-repo.sh                 # bootstrap the current directory
#   bash bootstrap-repo.sh /path/to/repo   # bootstrap a specific repo
#   bash <(curl -fsSL https://raw.githubusercontent.com/florianhorner/engineering-standards/main/bootstrap-repo.sh) /path/to/repo
#
# DX D1: this script is the load-bearing TTHW artifact. Sub-5-minute time
# to first compliant commit + green CI is the target. Self-verifying means
# the script reports PASS/FAIL for each step and runs a dry-run validator
# against the last 3 commits at the end so you know it works.

set -euo pipefail
export LC_ALL=C.UTF-8

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly ENGSTD_REPO="florianhorner/engineering-standards"
readonly ENGSTD_RAW_BASE="https://raw.githubusercontent.com/${ENGSTD_REPO}"
readonly RULES_PATH=".config/commit-rules.json"
readonly COMMITLINTRC_PATH=".commitlintrc.json"
readonly CI_WORKFLOW_PATH=".github/workflows/commit-lint.yml"
readonly DEPENDABOT_PATH=".github/dependabot.yml"
readonly CLAUDE_MD="CLAUDE.md"
readonly CONTRIBUTING_MD="CONTRIBUTING.md"
readonly AUTHOR_NOTES_MD="AUTHOR-NOTES.md"
# HOOK_PATH resolved at runtime via git rev-parse --git-dir (worktree-safe;
# `.git` is a file pointer in worktrees, not a directory). Falls back to
# `.git/hooks/commit-msg` only when not in a git repo (caught earlier in pre-flight).
HOOK_PATH=""
readonly MARKER_BEGIN="<!-- BEGIN: commit-message-standards (managed by bootstrap-repo.sh — do not hand-edit) -->"
readonly MARKER_END="<!-- END: commit-message-standards -->"

# Track every file we touch and every step's result for the final summary.
TOUCHED_FILES=()
PASS_STEPS=()
FAIL_STEPS=()
WARN_STEPS=()
START_SECONDS=$SECONDS

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_BOLD=$'\e[1m'; C_GREEN=$'\e[32m'; C_BLUE=$'\e[34m'; C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
else
  C_BOLD=""; C_GREEN=""; C_BLUE=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_RESET=""
fi

step_start() {
  local n="$1" total="$2" label="$3"
  printf '%s[%d/%d]%s %s ... ' "$C_BOLD" "$n" "$total" "$C_RESET" "$label"
}

step_pass() {
  local label="$1"
  printf '%s%sPASS%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  PASS_STEPS+=("$label")
}

step_warn() {
  local label="$1" detail="${2:-}"
  printf '%s%sWARN%s %s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET" "$detail"
  WARN_STEPS+=("$label: $detail")
}

step_fail() {
  local label="$1" detail="${2:-}"
  printf '%s%sFAIL%s %s\n' "$C_BOLD" "$C_RED" "$C_RESET" "$detail"
  FAIL_STEPS+=("$label: $detail")
}

info()    { printf '%s    %s%s\n' "$C_DIM" "$1" "$C_RESET"; }

die() {
  local step="$1" reason="$2" how_to_recover="$3"
  step_fail "$step" "$reason"
  printf '\n%s%sBOOTSTRAP HALTED%s\n' "$C_BOLD" "$C_RED" "$C_RESET" >&2
  printf '%sStep:%s    %s\n' "$C_BOLD" "$C_RESET" "$step" >&2
  printf '%sReason:%s  %s\n' "$C_BOLD" "$C_RESET" "$reason" >&2
  printf '%sRecover:%s %s\n\n' "$C_BOLD" "$C_RESET" "$how_to_recover" >&2
  printf 'Partial state has NOT been rolled back — that would be more dangerous than\n' >&2
  printf 'leaving it inspectable. Re-run the script after fixing the underlying issue.\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET_REPO="${1:-$(pwd)}"
if [ ! -d "$TARGET_REPO" ]; then
  die "args" "Target '$TARGET_REPO' is not a directory" "Pass a valid path: bash bootstrap-repo.sh /path/to/repo"
fi
TARGET_REPO="$(cd "$TARGET_REPO" && pwd)"
cd "$TARGET_REPO"

printf '\n%s== commit-standards bootstrap ==%s\n' "$C_BOLD" "$C_RESET"
printf '%sTarget:%s  %s\n' "$C_BOLD" "$C_RESET" "$TARGET_REPO"
printf '%sSource:%s  %s\n\n' "$C_BOLD" "$C_RESET" "https://github.com/${ENGSTD_REPO}"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
printf '%s-- Pre-flight --%s\n' "$C_BOLD" "$C_RESET"

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  die "pre-flight" "Target is not a git repository (or worktree)" \
      "cd into a repo with 'git init' first, or pass a valid repo path."
fi
info "git repo detected: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')"

if ! command -v gh >/dev/null 2>&1; then
  die "pre-flight" "gh CLI not installed" \
      "Install via 'brew install gh' (macOS) or see https://cli.github.com/"
fi
if ! gh auth status >/dev/null 2>&1; then
  die "pre-flight" "gh CLI not authenticated" \
      "Run 'gh auth login' and re-run bootstrap."
fi
info "gh CLI authenticated as $(gh api user --jq .login 2>/dev/null || echo '?')"

# Archived-repo guard: GitHub returns HTTP 403 on push to archived repos, but
# only AFTER bootstrap has dropped local files — leaving partial state with no
# way to land it. Catch this up-front. Real cause: conversation-flow blocked
# Phase 5B push because the repo is archived; bootstrap had already run.
IS_ARCHIVED="$(gh repo view --json isArchived --jq .isArchived 2>/dev/null || echo 'unknown')"
case "$IS_ARCHIVED" in
  true)
    die "pre-flight" "Target repo is ARCHIVED on GitHub — pushes will fail with HTTP 403" \
        "Unarchive at https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '<owner/repo>')/settings (Settings > Danger Zone), or skip this repo."
    ;;
  false)
    info "repo is active (not archived)"
    ;;
  *)
    info "archive status unknown — gh repo view failed; continuing (likely no remote yet)"
    ;;
esac

# Conductor-style untracked files: detect known blockers that cause
# 'git switch -c <branch> origin/<DEFAULT>' to refuse with "untracked working
# tree files would be overwritten." Real cause: every Phase 5B agent hit
# these. Informational only — print + suggest stash; user keeps control.
CONDUCTOR_UNTRACKED=()
for f in conductor.json conductor.json.bak entities.json mempalace.yaml; do
  if [ -f "$f" ] && ! git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    CONDUCTOR_UNTRACKED+=("$f")
  fi
done
# Heuristics for common Conductor scratchpad patterns.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  CONDUCTOR_UNTRACKED+=("$f")
done < <(git ls-files --others --exclude-standard 2>/dev/null \
  | grep -E '(-orchestrator\.md$|^engineering-.+\.md$)' || true)

if [ "${#CONDUCTOR_UNTRACKED[@]}" -gt 0 ]; then
  printf '%s%s    Conductor-style untracked files detected (%d):%s\n' \
    "$C_DIM" "$C_YELLOW" "${#CONDUCTOR_UNTRACKED[@]}" "$C_RESET"
  for f in "${CONDUCTOR_UNTRACKED[@]}"; do
    printf '%s      - %s%s\n' "$C_DIM" "$f" "$C_RESET"
  done
  printf '%s    These will block "git switch -c <branch> origin/<DEFAULT>".%s\n' "$C_DIM" "$C_RESET"
  printf '%s    Suggestion: git stash push -u -m "conductor-scratch" -- %s%s\n' \
    "$C_DIM" "${CONDUCTOR_UNTRACKED[*]}" "$C_RESET"
fi

if ! command -v python3 >/dev/null 2>&1; then
  die "pre-flight" "python3 not installed" \
      "Install Python 3 (macOS: 'brew install python', Linux: apt/yum)."
fi
info "python3: $(python3 --version 2>&1)"

if ! command -v curl >/dev/null 2>&1; then
  die "pre-flight" "curl not installed" "Install curl from your package manager."
fi

printf '\n%s-- Steps --%s\n' "$C_BOLD" "$C_RESET"

# ---------------------------------------------------------------------------
# Resolve the engineering-standards SHA up-front (used by step 1 and step 3).
# ---------------------------------------------------------------------------
ENGSTD_SHA="$(gh api "repos/${ENGSTD_REPO}/commits/main" --jq .sha 2>/dev/null || true)"
if [ -z "$ENGSTD_SHA" ]; then
  ENGSTD_SHA="main"
  info "Could not resolve ${ENGSTD_REPO}@main SHA via gh; falling back to ref name 'main'."
fi

# ---------------------------------------------------------------------------
# Helper: render a marker-block file (idempotent append/refresh).
#   $1 = target file path
#   $2 = content (without the BEGIN/END markers)
# If markers exist, replace between them. Otherwise, append.
# ---------------------------------------------------------------------------
render_marker_block() {
  local target="$1" content="$2"
  local block tmp
  block="${MARKER_BEGIN}
${content}
${MARKER_END}"

  if [ ! -f "$target" ]; then
    printf '%s\n' "$block" > "$target"
    return
  fi

  if grep -qF -- "$MARKER_BEGIN" "$target" 2>/dev/null; then
    # Strip existing block (single-line -v args only — BSD awk hates multi-line -v values)
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
      $0 == begin { in_block = 1; next }
      $0 == end   { in_block = 0; next }
      !in_block   { print }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
  fi
  # Append fresh block via shell (no awk -v needed for the multi-line content)
  if [ -s "$target" ]; then
    printf '\n' >> "$target"
  fi
  printf '%s\n' "$block" >> "$target"
}

# ---------------------------------------------------------------------------
# Dependabot generation helpers (step 4)
# ---------------------------------------------------------------------------
# Issue #1: step 4 used to vendor a fixed snippet in which every block said
# `directory: "/"`, so any package tree outside root was silently unmanaged —
# flora-signal's server/ (@aws-sdk, ws), mammamiradio's ha-addon Dockerfile,
# and this repo's own actions/ha-app-docs-lint/action.yml, which sat on a
# setup-python pin Dependabot never bumped while the workflows moved on.
# The config is now generated from what the repo actually tracks.
#
# Manifests that exist to be parsed rather than installed: vendored trees,
# virtualenvs, build output, and fixture/template package trees (ha-fp2-sleep
# carries eight of them under videos/). Skipped manifests are reported, never
# dropped silently — the operator can add them by hand.
readonly DEPENDABOT_SKIP_RE='(^|/)(node_modules|bower_components|vendor|third_party|\.venv|venv|\.tox|dist|build|target)/|(^|/)(fixtures?|__fixtures__|testdata|_template)/'

# Map a tracked path to its Dependabot ecosystem ("" if it is not a manifest).
dependabot_ecosystem_for() {
  case "${1##*/}" in
    package.json)                         printf 'npm' ;;
    pyproject.toml|Pipfile|setup.py)      printf 'pip' ;;
    requirements*.txt)                    printf 'pip' ;;
    Cargo.toml)                           printf 'cargo' ;;
    composer.json)                        printf 'composer' ;;
    go.mod)                               printf 'gomod' ;;
    Gemfile)                              printf 'bundler' ;;
    action.yml|action.yaml)               printf 'github-actions' ;;
    Dockerfile|Dockerfile.*|*.Dockerfile) printf 'docker' ;;
    *)                                    printf '' ;;
  esac
}

# Ecosystems that distinguish dev dependencies accept commit-message.prefix-development.
dependabot_has_dev_prefix() {
  case "$1" in
    npm|pip|composer|bundler|mix|maven) return 0 ;;
    *)                                  return 1 ;;
  esac
}

# Render one update block. `dirs` is a newline-separated, pre-sorted list.
dependabot_render_block() {
  local eco="$1" dirs="$2" count d
  count="$(printf '%s\n' "$dirs" | grep -c . || true)"
  printf '  - package-ecosystem: "%s"\n' "$eco"
  if [ "$count" -le 1 ]; then
    printf '    directory: "%s"\n' "$dirs"
  else
    # `directories` (plural) takes a list; one block per ecosystem instead of
    # one block per directory, because GitHub rejects the whole config when two
    # blocks of the same ecosystem overlap. Paths are enumerated explicitly —
    # globbing is documented but broken (dependabot-core#12348).
    printf '    directories:\n'
    while IFS= read -r d; do
      [ -n "$d" ] && printf '      - "%s"\n' "$d"
    done <<< "$dirs"
  fi
  printf '    schedule:\n'
  printf '      interval: "weekly"\n'
  printf '    open-pull-requests-limit: 5\n'
  printf '    commit-message:\n'
  printf '      prefix: "chore"\n'
  if dependabot_has_dev_prefix "$eco"; then
    printf '      prefix-development: "chore"\n'
  fi
  printf '      include: "scope"\n'
  if [ "$count" -gt 1 ]; then
    # open-pull-requests-limit is not reliably enforced across a multi-directory
    # block (dependabot-core#10395: 26 directories produced 26 PRs against a
    # limit of 10), so grouping is the thing that actually caps volume.
    printf '    groups:\n'
    printf '      %s-all:\n' "$eco"
    printf '        applies-to: version-updates\n'
    printf '        patterns:\n'
    printf '          - "*"\n'
  fi
  printf '\n'
}

# What shape may the managed block take inside an existing dependabot.yml?
#   document — a whole `version:` / `updates:` document (the block owns the file)
#   items    — bare `- package-ecosystem:` entries continuing an existing list
#   unknown  — a layout this script will not guess at; leave the file alone
# A file that already declares `updates:` outside our markers must get `items`:
# a second `version:`/`updates:` is a duplicate top-level key, and YAML lets the
# later one win, so the hand-written blocks silently stop being updated.
dependabot_block_shape() {
  local shape facts last_before after last_key
  if grep -qF "# BEGIN: commit-message-standards" "$DEPENDABOT_PATH"; then
    facts="$(awk '
      /^# BEGIN: commit-message-standards/ { seen = 1; before = lastkey; inblk = 1; next }
      /^# END: commit-message-standards/   { inblk = 0; next }
      inblk { next }
      /^[A-Za-z_][A-Za-z0-9_-]*:/ { lastkey = $0; sub(/:.*/, "", lastkey); if (seen) after++ }
      END { printf "%s|%d", before, after + 0 }
    ' "$DEPENDABOT_PATH")"
    last_before="${facts%%|*}"
    after="${facts##*|}"
    if [ "$after" -gt 0 ]; then
      shape="unknown:keys-after-the-managed-block"
    elif [ -z "$last_before" ]; then
      shape="document"
    elif [ "$last_before" = "updates" ]; then
      shape="items"
    else
      shape="unknown:${last_before}"
    fi
  else
    last_key="$(grep -oE '^[A-Za-z_][A-Za-z0-9_-]*:' "$DEPENDABOT_PATH" | tail -n1 | tr -d ':' || true)"
    if [ -z "$last_key" ]; then
      shape="document"
    elif [ "$last_key" = "updates" ]; then
      shape="items"
    else
      shape="unknown:${last_key}"
    fi
  fi
  # Continuing a list only works if our entries line up with the existing ones.
  if [ "$shape" = "items" ] \
     && grep -qE '^[[:space:]]*-' "$DEPENDABOT_PATH" \
     && ! grep -qE '^  -' "$DEPENDABOT_PATH"; then
    shape="unknown:list-indentation"
  fi
  printf '%s' "$shape"
}

# Ecosystem+directory pairs already claimed by blocks OUTSIDE our markers —
# i.e. the hand-edit workaround from issue #1. Emitting those again would make
# Dependabot reject the entire file for overlapping directories.
dependabot_foreign_pairs() {
  [ -f "$DEPENDABOT_PATH" ] || return 0
  awk '
    /^# BEGIN: commit-message-standards/ { inblk = 1; next }
    /^# END: commit-message-standards/   { inblk = 0; next }
    inblk { next }
    /package-ecosystem:[ \t]*/ {
      eco = $0; sub(/.*package-ecosystem:[ \t]*/, "", eco)
      gsub(/["'"'"']/, "", eco); gsub(/[ \t]+$/, "", eco); indirs = 0; next
    }
    /directories:[ \t]*$/ { indirs = 1; next }
    /directory:[ \t]*/ {
      d = $0; sub(/.*directory:[ \t]*/, "", d)
      gsub(/["'"'"']/, "", d); gsub(/[ \t]+$/, "", d); indirs = 0
      if (eco != "") print eco "|" d
      next
    }
    indirs && /^[ \t]*-[ \t]*/ {
      d = $0; sub(/^[ \t]*-[ \t]*/, "", d)
      gsub(/["'"'"']/, "", d); gsub(/[ \t]+$/, "", d)
      if (eco != "") print eco "|" d
      next
    }
    { indirs = 0 }
  ' "$DEPENDABOT_PATH"
}

TOTAL_STEPS=14

# ---------------------------------------------------------------------------
# Step 1: vendor commit-rules.json (SHA-pinned)
# ---------------------------------------------------------------------------
step_start 1 "$TOTAL_STEPS" "vendor commit-rules.json @ ${ENGSTD_SHA:0:7}"
mkdir -p "$(dirname "$RULES_PATH")"
TMP_RULES="$(mktemp)"
RULES_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/specs/commit-rules.json"
if ! curl -fsSL --max-time 30 "$RULES_URL" -o "$TMP_RULES"; then
  rm -f "$TMP_RULES"
  step_fail "vendor commit-rules.json" "curl from $RULES_URL failed"
  die "step 1" "Could not fetch commit-rules.json" \
      "Verify network access and that ${ENGSTD_REPO} is public. URL: $RULES_URL"
fi
# Validate JSON before writing.
if ! python3 -c "import json,sys; json.load(open('$TMP_RULES'))" 2>/dev/null; then
  rm -f "$TMP_RULES"
  die "step 1" "Fetched commit-rules.json is not valid JSON" \
      "Source repo may be mid-edit; re-run in a few seconds."
fi
{
  printf '// Vendored from %s/blob/%s/specs/commit-rules.json\n' \
    "https://github.com/${ENGSTD_REPO}" "$ENGSTD_SHA"
  printf '// SHA pin: %s\n' "$ENGSTD_SHA"
  printf '// Refresh by re-running bootstrap-repo.sh.\n'
  cat "$TMP_RULES"
} > "$RULES_PATH"
# Strip the JSON-illegal `//` comment lines for actual parsing — store them
# alongside in a sidecar metadata file to keep the rules file pure JSON.
mkdir -p ".config"
{
  printf '{\n'
  printf '  "vendored_from": "https://github.com/%s/blob/%s/specs/commit-rules.json",\n' \
    "$ENGSTD_REPO" "$ENGSTD_SHA"
  printf '  "sha_pin": "%s",\n' "$ENGSTD_SHA"
  printf '  "fetched_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '}\n'
} > ".config/commit-rules.meta.json"
# Now overwrite the rules path with pure JSON (no comments).
cp "$TMP_RULES" "$RULES_PATH"
rm -f "$TMP_RULES"
TOUCHED_FILES+=("$RULES_PATH" ".config/commit-rules.meta.json")
step_pass "vendor commit-rules.json"

# ---------------------------------------------------------------------------
# Step 2: drop .commitlintrc.json
# ---------------------------------------------------------------------------
step_start 2 "$TOTAL_STEPS" "install ${COMMITLINTRC_PATH}"
COMMITLINTRC_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/.commitlintrc.json"
TMP_COMMITLINTRC="$(mktemp)"
if curl -fsSL --max-time 30 "$COMMITLINTRC_URL" -o "$TMP_COMMITLINTRC" 2>/dev/null \
   && [ -s "$TMP_COMMITLINTRC" ]; then
  cp "$TMP_COMMITLINTRC" "$COMMITLINTRC_PATH"
  TOUCHED_FILES+=("$COMMITLINTRC_PATH")
  step_pass ".commitlintrc.json"
else
  # Fallback: write a minimal config inline so bootstrap never blocks on a
  # missing template.
  cat > "$COMMITLINTRC_PATH" <<'JSON'
{
  "extends": ["@commitlint/config-conventional"]
}
JSON
  TOUCHED_FILES+=("$COMMITLINTRC_PATH")
  step_warn ".commitlintrc.json" "template not yet published; wrote minimal fallback"
fi
rm -f "$TMP_COMMITLINTRC"

# ---------------------------------------------------------------------------
# Step 3: drop .github/workflows/commit-lint.yml (5-line includer)
# ---------------------------------------------------------------------------
step_start 3 "$TOTAL_STEPS" "install ${CI_WORKFLOW_PATH} pinned to ${ENGSTD_SHA:0:7}"
mkdir -p "$(dirname "$CI_WORKFLOW_PATH")"
CI_WORKFLOW_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/per-repo-commit-lint.yml"
TMP_CI="$(mktemp)"
if curl -fsSL --max-time 30 "$CI_WORKFLOW_URL" -o "$TMP_CI" 2>/dev/null \
   && [ -s "$TMP_CI" ]; then
  # Substitute the SHA pin marker.
  sed "s|<SHA-PIN>|${ENGSTD_SHA}|g" "$TMP_CI" > "$CI_WORKFLOW_PATH"
  TOUCHED_FILES+=("$CI_WORKFLOW_PATH")
  step_pass "${CI_WORKFLOW_PATH}"
else
  # Fallback: write the includer inline pinned to the resolved SHA.
  cat > "$CI_WORKFLOW_PATH" <<YAML
name: commit-lint
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  commit-lint:
    uses: ${ENGSTD_REPO}/.github/workflows/commit-lint-reusable.yml@${ENGSTD_SHA}
YAML
  TOUCHED_FILES+=("$CI_WORKFLOW_PATH")
  step_warn "${CI_WORKFLOW_PATH}" "template not yet published; wrote inline fallback pinned to ${ENGSTD_SHA:0:7}"
fi
rm -f "$TMP_CI"

# ---------------------------------------------------------------------------
# Step 4: generate .github/dependabot.yml from the manifests this repo tracks
# ---------------------------------------------------------------------------
step_start 4 "$TOTAL_STEPS" "generate ${DEPENDABOT_PATH} from detected manifests"
TMP_DEP="$(mktemp)"
DEP_PAIRS="$(mktemp)"
DEP_SKIPPED=()

# git ls-files, not find: tracked files only, so ignored trees (node_modules,
# dist, .venv) never reach the skip list in the first place. Read via a temp
# file rather than process substitution — some sandboxes have no /dev/fd.
DEP_TRACKED="$(mktemp)"
git ls-files > "$DEP_TRACKED" 2>/dev/null || true
while IFS= read -r dep_path; do
  [ -z "$dep_path" ] && continue
  dep_eco="$(dependabot_ecosystem_for "$dep_path")"
  [ -z "$dep_eco" ] && continue
  if printf '%s\n' "$dep_path" | grep -Eq "$DEPENDABOT_SKIP_RE"; then
    DEP_SKIPPED+=("$dep_path")
    continue
  fi
  dep_dir="/$(dirname "$dep_path")"
  [ "$dep_dir" = "/." ] && dep_dir="/"
  printf '%s|%s\n' "$dep_eco" "$dep_dir" >> "$DEP_PAIRS"
done < "$DEP_TRACKED"
rm -f "$DEP_TRACKED"

# github-actions always covers "/": Dependabot reads .github/workflows from
# there, and step 3 just installed a workflow into it.
printf 'github-actions|/\n' >> "$DEP_PAIRS"

# Drop anything a hand-added block outside our markers already claims.
DEP_COLLISIONS=()
if [ -f "$DEPENDABOT_PATH" ]; then
  DEP_FOREIGN="$(mktemp)"
  # Empty lines would turn `grep -f` into "match everything" and wipe the
  # generated config, so they are filtered before the file is used as a pattern.
  dependabot_foreign_pairs 2>/dev/null | grep -v '^[[:space:]]*$' > "$DEP_FOREIGN" || true
  if [ -s "$DEP_FOREIGN" ]; then
    dep_sorted="$(mktemp)"
    sort -u "$DEP_PAIRS" > "$dep_sorted"
    while IFS= read -r dep_pair; do
      [ -z "$dep_pair" ] && continue
      if grep -qxF "$dep_pair" "$DEP_FOREIGN"; then
        DEP_COLLISIONS+=("$dep_pair")
      fi
    done < "$dep_sorted"
    rm -f "$dep_sorted"
    if [ "${#DEP_COLLISIONS[@]}" -gt 0 ]; then
      dep_kept="$(mktemp)"
      grep -vxF -f "$DEP_FOREIGN" "$DEP_PAIRS" > "$dep_kept" || true
      mv "$dep_kept" "$DEP_PAIRS"
    fi
  fi
  rm -f "$DEP_FOREIGN"
fi

DEP_HEADER="$(mktemp)"
DEP_BLOCKS="$(mktemp)"
{
  printf '# Generated by bootstrap-repo.sh from the manifests this repo tracks.\n'
  printf '# Re-run the bootstrap to refresh after adding or removing a package tree;\n'
  printf '# do not hand-edit between the markers. Blocks outside the markers are kept.\n'
  printf '#\n'
  printf '# The `commit-message.prefix: "chore"` line is the load-bearing part —\n'
  printf "# Dependabot's default subject \"Bump foo from 1 to 2\" fails the format rule\n"
  printf '# per Eng E8. Everything else is sensible defaults.\n'
  printf '#\n'
  printf '# Spec reference: https://github.com/%s/blob/main/specs/commit-message-spec.md#bot-allowlist\n' "$ENGSTD_REPO"
} > "$DEP_HEADER"

# Fixed ecosystem order keeps the emitted file stable across runs, which is what
# makes the marker refresh a no-op when nothing changed.
DEP_ECO_COUNT=0
DEP_DIR_COUNT=0
for dep_eco in github-actions npm pip docker cargo composer gomod bundler; do
  dep_dirs="$(grep "^${dep_eco}|" "$DEP_PAIRS" 2>/dev/null | cut -d'|' -f2 | sort -u || true)"
  [ -z "$dep_dirs" ] && continue
  DEP_ECO_COUNT=$((DEP_ECO_COUNT + 1))
  DEP_DIR_COUNT=$((DEP_DIR_COUNT + $(printf '%s\n' "$dep_dirs" | grep -c . || true)))
  dependabot_render_block "$dep_eco" "$dep_dirs" >> "$DEP_BLOCKS"
done
rm -f "$DEP_PAIRS"

# Two renderings: a whole document, and the entries alone for the case where an
# existing `updates:` list has to be continued rather than redeclared. Command
# substitution eats the trailing blank line the last block leaves behind, which
# is what makes a re-run byte-identical.
TMP_DEP_ITEMS="$(mktemp)"
printf '%s\n' "$(cat "$DEP_HEADER"; printf 'version: 2\nupdates:\n'; cat "$DEP_BLOCKS")" > "$TMP_DEP"
printf '%s\n' "$(cat "$DEP_HEADER"; cat "$DEP_BLOCKS")" > "$TMP_DEP_ITEMS"
rm -f "$DEP_HEADER" "$DEP_BLOCKS"

DEP_SUMMARY="${DEP_ECO_COUNT} ecosystem(s), ${DEP_DIR_COUNT} director(ies)"
if [ "$DEP_ECO_COUNT" -eq 0 ]; then
  # Everything this repo has is already claimed by blocks outside the markers.
  # Writing the block anyway would leave an empty `updates:` list, which
  # Dependabot rejects outright.
  step_warn "dependabot.yml" "nothing left to manage — every detected manifest is already claimed by blocks outside the markers; file left untouched"
elif [ ! -f "$DEPENDABOT_PATH" ]; then
  mkdir -p "$(dirname "$DEPENDABOT_PATH")"
  {
    printf '# BEGIN: commit-message-standards\n'
    cat "$TMP_DEP"
    printf '# END: commit-message-standards\n'
  } > "$DEPENDABOT_PATH"
  TOUCHED_FILES+=("$DEPENDABOT_PATH")
  step_pass "dependabot.yml (created — ${DEP_SUMMARY})"
else
  # A whole document when the managed block owns the file, bare list entries
  # when it has to slot into a config someone else wrote.
  DEP_SHAPE="$(dependabot_block_shape)"
  case "$DEP_SHAPE" in
    document) DEP_SNIPPET="$TMP_DEP" ;;
    items)    DEP_SNIPPET="$TMP_DEP_ITEMS" ;;
    *)        DEP_SNIPPET="" ;;
  esac

  if [ -z "$DEP_SNIPPET" ]; then
    step_warn "dependabot.yml" "existing config has a layout this script will not guess at (${DEP_SHAPE#unknown:}) — left untouched"
    info "  Add the generated blocks by hand, or move the config to a plain version:/updates: file and re-run."
  elif grep -qF "# BEGIN: commit-message-standards" "$DEPENDABOT_PATH"; then
    # Idempotent merge: the markers already exist, so refresh what is between
    # them. Dependabot YAML has no comment convention of its own, so the markers
    # are literal `# <BEGIN/END>` lines.
    tmp="$(mktemp)"
    awk -v begin="# BEGIN: commit-message-standards" \
        -v end="# END: commit-message-standards" \
        -v file="$DEP_SNIPPET" '
      BEGIN {
        while ((getline line < file) > 0) snippet = snippet line "\n"
        close(file)
      }
      # No blank line after the marker: the create path does not emit one, and
      # refresh has to match it byte-for-byte or every re-run shows a diff.
      $0 ~ begin { in_block = 1; printf "%s\n", begin; printf "%s", snippet; printf "%s\n", end; next }
      $0 ~ end   { in_block = 0; next }
      !in_block  { print }
    ' "$DEPENDABOT_PATH" > "$tmp"
    mv "$tmp" "$DEPENDABOT_PATH"
    TOUCHED_FILES+=("$DEPENDABOT_PATH")
    step_pass "dependabot.yml (refreshed in place as ${DEP_SHAPE} — ${DEP_SUMMARY})"
  else
    {
      printf '\n# BEGIN: commit-message-standards\n'
      cat "$DEP_SNIPPET"
      printf '# END: commit-message-standards\n'
    } >> "$DEPENDABOT_PATH"
    TOUCHED_FILES+=("$DEPENDABOT_PATH")
    step_pass "dependabot.yml (appended as ${DEP_SHAPE} — ${DEP_SUMMARY})"
  fi
fi
rm -f "$TMP_DEP" "$TMP_DEP_ITEMS"

# Never cap coverage silently: say which manifests were left out and why.
if [ "${#DEP_SKIPPED[@]}" -gt 0 ]; then
  info "Dependabot: skipped ${#DEP_SKIPPED[@]} fixture/vendored manifest(s) — add by hand if intended:"
  for dep_path in "${DEP_SKIPPED[@]}"; do
    info "  - ${dep_path}"
  done
fi
if [ "${#DEP_COLLISIONS[@]}" -gt 0 ]; then
  step_warn "dependabot.yml" "${#DEP_COLLISIONS[@]} director(ies) already claimed by a block outside the markers — left alone to avoid a duplicate-directory config error"
  for dep_pair in "${DEP_COLLISIONS[@]}"; do
    info "  - ${dep_pair%%|*} ${dep_pair##*|} (verify it sets commit-message.prefix: chore, or delete it and re-run)"
  done
fi

# ---------------------------------------------------------------------------
# Step 5: append CLAUDE.md snippet (idempotent, marker-bracketed)
# ---------------------------------------------------------------------------
step_start 5 "$TOTAL_STEPS" "update ${CLAUDE_MD}"
CLAUDE_SNIPPET_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/per-repo-CLAUDE-snippet.md"
TMP_CL="$(mktemp)"
if curl -fsSL --max-time 30 "$CLAUDE_SNIPPET_URL" -o "$TMP_CL" 2>/dev/null \
   && [ -s "$TMP_CL" ]; then
  # The published snippet already contains BEGIN/END markers — render it
  # whole between our markers idempotently.
  CONTENT="$(cat "$TMP_CL")"
  # If the snippet already carries its own markers, strip them — we wrap the
  # body in our standard markers to keep the idempotency contract uniform.
  CONTENT_STRIPPED="$(printf '%s\n' "$CONTENT" | grep -vE '^<!-- (BEGIN|END): commit-message-standards')"
  render_marker_block "$CLAUDE_MD" "$CONTENT_STRIPPED"
  TOUCHED_FILES+=("$CLAUDE_MD")
  step_pass "CLAUDE.md"
else
  step_warn "CLAUDE.md" "template not yet published; skipped"
fi
rm -f "$TMP_CL"

# ---------------------------------------------------------------------------
# Step 6: append CONTRIBUTING.md cheat sheet
# ---------------------------------------------------------------------------
step_start 6 "$TOTAL_STEPS" "update ${CONTRIBUTING_MD}"
CONTRIB_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/per-repo-CONTRIBUTING-snippet.md"
TMP_CO="$(mktemp)"
if curl -fsSL --max-time 30 "$CONTRIB_URL" -o "$TMP_CO" 2>/dev/null \
   && [ -s "$TMP_CO" ]; then
  CONTENT="$(cat "$TMP_CO")"
  CONTENT_STRIPPED="$(printf '%s\n' "$CONTENT" | grep -vE '^<!-- (BEGIN|END): commit-message-standards')"
  render_marker_block "$CONTRIBUTING_MD" "$CONTENT_STRIPPED"
  TOUCHED_FILES+=("$CONTRIBUTING_MD")
  step_pass "CONTRIBUTING.md"
else
  step_warn "CONTRIBUTING.md" "template not yet published; skipped"
fi
rm -f "$TMP_CO"

# ---------------------------------------------------------------------------
# Step 7: AUTHOR-NOTES.md only if target is a fork
# ---------------------------------------------------------------------------
step_start 7 "$TOTAL_STEPS" "drop AUTHOR-NOTES.md if fork"
IS_FORK="false"
IS_FORK="$(gh repo view --json isFork --jq .isFork 2>/dev/null || echo 'unknown')"
case "$IS_FORK" in
  true)
    AUTHOR_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/AUTHOR-NOTES.md"
    TMP_AN="$(mktemp)"
    if curl -fsSL --max-time 30 "$AUTHOR_URL" -o "$TMP_AN" 2>/dev/null \
       && [ -s "$TMP_AN" ]; then
      cp "$TMP_AN" "$AUTHOR_NOTES_MD"
      TOUCHED_FILES+=("$AUTHOR_NOTES_MD")
      step_pass "AUTHOR-NOTES.md (fork detected)"
    else
      step_warn "AUTHOR-NOTES.md" "fork detected but template not yet published; skipped"
    fi
    rm -f "$TMP_AN"
    ;;
  false)
    info "not a fork — AUTHOR-NOTES.md skipped (correct behavior)"
    step_pass "AUTHOR-NOTES.md (n/a — not a fork)"
    ;;
  *)
    step_warn "AUTHOR-NOTES.md" "fork detection failed (gh repo view); manually check if this is a fork"
    ;;
esac

# ---------------------------------------------------------------------------
# Step 8: generate commit-msg hook (worktree-safe path resolution)
# ---------------------------------------------------------------------------
# Resolve the actual git hooks dir — for regular repos it's .git/hooks/, for
# worktrees `git rev-parse --git-dir` returns the per-worktree gitdir which is
# where worktree-local hooks belong. Honors core.hooksPath if set.
GIT_HOOKS_DIR="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ -z "$GIT_HOOKS_DIR" ]; then
  GIT_DIR_RESOLVED="$(git rev-parse --git-dir 2>/dev/null || echo '.git')"
  GIT_HOOKS_DIR="${GIT_DIR_RESOLVED}/hooks"
fi
HOOK_PATH="${GIT_HOOKS_DIR}/commit-msg"
step_start 8 "$TOTAL_STEPS" "generate ${HOOK_PATH}"
GENERATOR_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/validator/generate-hook.py"
TMP_GEN="$(mktemp)"
GEN_SOURCE=""
if curl -fsSL --max-time 30 "$GENERATOR_URL" -o "$TMP_GEN" 2>/dev/null && [ -s "$TMP_GEN" ]; then
  GEN_SOURCE="remote (${ENGSTD_SHA:0:7})"
else
  # Local fallback: if the bootstrap script is being run from a clone of
  # engineering-standards, use the on-disk generator. This makes the script
  # usable BEFORE the validator/ directory is published to main.
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  LOCAL_GEN="${SCRIPT_DIR}/validator/generate-hook.py"
  if [ -f "$LOCAL_GEN" ]; then
    cp "$LOCAL_GEN" "$TMP_GEN"
    GEN_SOURCE="local fallback (${LOCAL_GEN})"
  else
    rm -f "$TMP_GEN"
    die "step 8" "Could not fetch generate-hook.py from $GENERATOR_URL and no local fallback at $LOCAL_GEN" \
        "Verify ${ENGSTD_REPO} is reachable and that validator/generate-hook.py exists at the pinned SHA, or run from a clone of the engineering-standards repo."
  fi
fi
# Stage the rules where the generator expects them, then run it.
GEN_DIR="$(mktemp -d)"
mkdir -p "${GEN_DIR}/specs" "${GEN_DIR}/validator"
cp "$RULES_PATH" "${GEN_DIR}/specs/commit-rules.json"
cp "$TMP_GEN" "${GEN_DIR}/validator/generate-hook.py"
mkdir -p "$(dirname "$HOOK_PATH")"
if ! python3 "${GEN_DIR}/validator/generate-hook.py" > "$HOOK_PATH" 2>/dev/null; then
  rm -rf "$GEN_DIR"; rm -f "$TMP_GEN"
  die "step 8" "generate-hook.py failed to produce a hook" \
      "Inspect manually: python3 validator/generate-hook.py (must succeed and emit Bash)."
fi
chmod +x "$HOOK_PATH"
rm -rf "$GEN_DIR"; rm -f "$TMP_GEN"
TOUCHED_FILES+=("$HOOK_PATH")
step_pass "${HOOK_PATH} ($(wc -l < "$HOOK_PATH" | tr -d ' ') lines, source: ${GEN_SOURCE})"

# ---------------------------------------------------------------------------
# Step 9: validator dry-run against last 3 commits
# ---------------------------------------------------------------------------
step_start 9 "$TOTAL_STEPS" "validator dry-run vs last 3 commits"
DRY_FAIL=0
DRY_TOTAL=0
DRY_LOG="$(mktemp)"
LAST_3="$(git log -n 3 --format=%H 2>/dev/null || true)"
if [ -z "$LAST_3" ]; then
  step_warn "dry-run" "no commits yet — fresh repo, nothing to validate"
else
  while IFS= read -r SHA; do
    [ -z "$SHA" ] && continue
    DRY_TOTAL=$((DRY_TOTAL + 1))
    MSG_FILE="$(mktemp)"
    git log -1 --format=%B "$SHA" > "$MSG_FILE"
    if ! "$HOOK_PATH" "$MSG_FILE" 2> "${MSG_FILE}.err"; then
      DRY_FAIL=$((DRY_FAIL + 1))
      {
        printf '  %s — %s\n' "${SHA:0:7}" "$(head -n1 "$MSG_FILE")"
        sed 's/^/    /' "${MSG_FILE}.err"
      } >> "$DRY_LOG"
    fi
    rm -f "$MSG_FILE" "${MSG_FILE}.err"
  done <<< "$LAST_3"
  if [ "$DRY_FAIL" -eq 0 ]; then
    step_pass "dry-run ($DRY_TOTAL/$DRY_TOTAL pass)"
  else
    step_warn "dry-run" "$DRY_FAIL/$DRY_TOTAL existing commits would fail (informational, not blocking)"
    info "Existing commits won't be rewritten by bootstrap. New commits will be checked going forward."
    info "Failures:"
    while IFS= read -r line; do info "$line"; done < "$DRY_LOG"
  fi
fi
rm -f "$DRY_LOG"

# ---------------------------------------------------------------------------
# Step 10: check Actions enabled
# ---------------------------------------------------------------------------
step_start 10 "$TOTAL_STEPS" "verify GitHub Actions enabled"
REPO_SLUG=""
REPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo '')"
if [ -z "$REPO_SLUG" ]; then
  step_warn "actions" "could not resolve repo slug via gh — skipping check"
else
  ACTIONS_ENABLED="$(gh api "repos/${REPO_SLUG}/actions/permissions" --jq .enabled 2>/dev/null || echo 'unknown')"
  case "$ACTIONS_ENABLED" in
    true)
      step_pass "Actions enabled on ${REPO_SLUG}"
      ;;
    false)
      step_warn "actions disabled" "enable with: gh api -X PUT repos/${REPO_SLUG}/actions/permissions -f enabled=true -f allowed_actions=all"
      ;;
    *)
      step_warn "actions" "could not verify (${ACTIONS_ENABLED}); check manually at https://github.com/${REPO_SLUG}/settings/actions"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Step 11: print remaining manual steps
# ---------------------------------------------------------------------------
step_start 11 "$TOTAL_STEPS" "compile remaining manual checklist"
MANUAL=()
if [ -n "$REPO_SLUG" ]; then
  if [ "$ACTIONS_ENABLED" != "true" ]; then
    MANUAL+=("Enable Actions:  gh api -X PUT repos/${REPO_SLUG}/actions/permissions -f enabled=true -f allowed_actions=all")
  fi
fi
if [ ${#WARN_STEPS[@]} -gt 0 ]; then
  MANUAL+=("Review warnings above (${#WARN_STEPS[@]} non-blocking)")
fi
if [ "${DRY_FAIL:-0}" -gt 0 ] 2>/dev/null; then
  MANUAL+=("Existing commits won't be rewritten — only new commits checked going forward.")
fi
MANUAL+=("First commit: 'git add . && git commit -m \"chore(bootstrap): adopt commit-message-standards\"' to verify the hook")
MANUAL+=("Push and watch CI: 'git push' — the reusable workflow will validate the range")
step_pass "manual checklist compiled (${#MANUAL[@]} items)"

# ---------------------------------------------------------------------------
# Step 12: auto-prettier on dropped files (if consumer has prettier configured)
# ---------------------------------------------------------------------------
# Real cause: QFE PR #21 build job rejected unformatted RETRO.md; mammamiradio
# + CID needed mid-PR prettier commits; conversation-intelligence-dashboard
# had pre-existing prettier debt that interacted with our drops. Detect the
# consumer's prettier config and format our dropped files with it BEFORE the
# user commits — eliminates the format-mismatch blocker class entirely.
step_start 12 "$TOTAL_STEPS" "auto-prettier dropped files"
PRETTIER_CONFIG=""
for cfg in .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml prettier.config.js .prettierrc.js; do
  if [ -f "$cfg" ]; then
    PRETTIER_CONFIG="$cfg"
    break
  fi
done
# package.json embedded "prettier" key counts too.
if [ -z "$PRETTIER_CONFIG" ] && [ -f "package.json" ]; then
  if python3 -c "import json,sys; sys.exit(0 if 'prettier' in json.load(open('package.json')) else 1)" 2>/dev/null; then
    PRETTIER_CONFIG="package.json"
  fi
fi

if [ -z "$PRETTIER_CONFIG" ]; then
  step_pass "auto-prettier (no prettier config — skipping)"
elif ! command -v npx >/dev/null 2>&1; then
  step_warn "auto-prettier" "prettier config detected ($PRETTIER_CONFIG) but npx not available; skipped"
else
  # Format only files this script just dropped (and exist on disk).
  PRETTIER_TARGETS=()
  for f in "$COMMITLINTRC_PATH" "$RULES_PATH" ".config/commit-rules.meta.json" \
           "$DEPENDABOT_PATH" "$CI_WORKFLOW_PATH" "$CLAUDE_MD" "$CONTRIBUTING_MD" \
           "RETRO.md" "$AUTHOR_NOTES_MD"; do
    [ -f "$f" ] && PRETTIER_TARGETS+=("$f")
  done
  if [ "${#PRETTIER_TARGETS[@]}" -eq 0 ]; then
    step_pass "auto-prettier (no targets to format)"
  else
    PRETTIER_LOG="$(mktemp)"
    if npx --no-install prettier --write "${PRETTIER_TARGETS[@]}" >"$PRETTIER_LOG" 2>&1; then
      step_pass "auto-prettier (${#PRETTIER_TARGETS[@]} files formatted via $PRETTIER_CONFIG)"
    else
      step_warn "auto-prettier" "prettier --write failed against ${#PRETTIER_TARGETS[@]} files (config: $PRETTIER_CONFIG); see $PRETTIER_LOG"
    fi
    rm -f "$PRETTIER_LOG"
  fi
fi

# ---------------------------------------------------------------------------
# Step 13: auto-create runtime proof file for verify-claims artifact reference
# ---------------------------------------------------------------------------
# Phase 5B asymmetry: 3 of 6 PRs had a runtime proof file and 3 didn't, which
# left verify-claims unable to attach a uniform artifact. Going forward EVERY
# bootstrapped repo gets a proof/<date>-commit-standards-bootstrap-runtime.txt
# containing what was installed, the SHA pin, validator dry-run result, and a
# ready-to-paste PR Proof block (prose form per verify-claims@v1.1 workaround).
step_start 13 "$TOTAL_STEPS" "auto-create runtime proof file"
PROOF_DATE="$(date -u +%Y-%m-%d)"
PROOF_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PROOF_DIR="proof"
PROOF_FILE="${PROOF_DIR}/${PROOF_DATE}-commit-standards-bootstrap-runtime.txt"
mkdir -p "$PROOF_DIR"

PROOF_PASS_COUNT="${#PASS_STEPS[@]}"
PROOF_WARN_COUNT="${#WARN_STEPS[@]}"
PROOF_FAIL_COUNT="${#FAIL_STEPS[@]}"
PROOF_TTHW_PARTIAL=$((SECONDS - START_SECONDS))

# Build the touched-files list (one per line, indented).
PROOF_TOUCHED=""
for f in "${TOUCHED_FILES[@]}" "$PROOF_FILE"; do
  PROOF_TOUCHED="${PROOF_TOUCHED}  ${f}"$'\n'
done

# Verifications: re-check JSON validity, hook presence, workflow presence.
PROOF_JSON_OK="no"
if python3 -c "import json; json.load(open('$RULES_PATH'))" 2>/dev/null; then
  PROOF_JSON_OK="yes"
fi
PROOF_HOOK_OK="no"
[ -x "$HOOK_PATH" ] && PROOF_HOOK_OK="yes"
PROOF_WORKFLOW_OK="no"
[ -f "$CI_WORKFLOW_PATH" ] && PROOF_WORKFLOW_OK="yes"

# Validator dry-run summary string.
if [ -z "${LAST_3:-}" ]; then
  PROOF_DRYRUN="no commits yet — fresh repo, nothing to validate"
elif [ "${DRY_FAIL:-0}" -eq 0 ]; then
  PROOF_DRYRUN="${DRY_TOTAL}/${DRY_TOTAL} existing commits pass"
else
  PROOF_DRYRUN="${DRY_FAIL}/${DRY_TOTAL} existing commits would fail (informational, not blocking)"
fi

cat > "$PROOF_FILE" <<EOF_PROOF
Bootstrap runtime artifact for commit-message-standards adoption.

Generated: ${PROOF_TS}
Engineering-standards SHA: ${ENGSTD_SHA}
Source: https://github.com/${ENGSTD_REPO}/commit/${ENGSTD_SHA}

Bootstrap result: ${PROOF_PASS_COUNT} pass / ${PROOF_WARN_COUNT} warn / ${PROOF_FAIL_COUNT} fail
TTHW: ${PROOF_TTHW_PARTIAL}s

Files touched:
${PROOF_TOUCHED}
Verification:
- JSON validates: ${PROOF_JSON_OK}
- Local hook generated: ${PROOF_HOOK_OK}
- Workflow installed: ${PROOF_WORKFLOW_OK}
- Validator dry-run: ${PROOF_DRYRUN}

Suggested PR body Proof block (prose form avoids gh-workflows@v1.1 parser bug):

## Proof

- [ ] build: n/a — bootstrap is config + docs only
- [x] tests: commit-lint reusable workflow validates this PR head
- [ ] lint: n/a — no source files modified
- [x] runtime: ${PROOF_FILE}
- [ ] schema: n/a — no MQTT or HA interface changes
EOF_PROOF

TOUCHED_FILES+=("$PROOF_FILE")
step_pass "runtime proof: ${PROOF_FILE}"

# ---------------------------------------------------------------------------
# Step 14: TTHW timer + final summary
# ---------------------------------------------------------------------------
step_start 14 "$TOTAL_STEPS" "compute TTHW"
ELAPSED=$((SECONDS - START_SECONDS))
step_pass "elapsed ${ELAPSED}s (target: <300s for first compliant commit + green CI)"

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
printf '\n%s== Summary ==%s\n' "$C_BOLD" "$C_RESET"
printf '%sFiles touched (%d):%s\n' "$C_BOLD" "${#TOUCHED_FILES[@]}" "$C_RESET"
for f in "${TOUCHED_FILES[@]}"; do
  printf '  %s\n' "$f"
done

printf '\n%sChecks:%s %d pass, %d warn, %d fail\n' \
  "$C_BOLD" "$C_RESET" \
  "${#PASS_STEPS[@]}" "${#WARN_STEPS[@]}" "${#FAIL_STEPS[@]}"

if [ ${#WARN_STEPS[@]} -gt 0 ]; then
  printf '\n%sWarnings:%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
  for w in "${WARN_STEPS[@]}"; do
    printf '  - %s\n' "$w"
  done
fi

if [ ${#MANUAL[@]} -gt 0 ]; then
  printf '\n%sNext steps (manual):%s\n' "$C_BOLD" "$C_RESET"
  for m in "${MANUAL[@]}"; do
    printf '  - %s\n' "$m"
  done
fi

printf '\n%sBootstrapped in %ds.%s Target: <5min for first compliant commit + green CI.\n' \
  "$C_BOLD$C_BLUE" "$ELAPSED" "$C_RESET"

# ---------------------------------------------------------------------------
# Suggested PR body Proof block (copy-paste straight into `gh pr create`).
# Mirrors the block written into proof/<date>-bootstrap-runtime.txt so the
# user has zero friction from "bootstrap done" to "PR opened with correct
# Proof block." Prose form sidesteps the verify-claims@v1.1 parser bug.
# ---------------------------------------------------------------------------
printf '\n%s== Suggested PR body Proof block ==%s\n' "$C_BOLD" "$C_RESET"
printf '%sCopy-paste into your PR body (or pass via gh pr create --body):%s\n\n' \
  "$C_DIM" "$C_RESET"
cat <<EOF_PROOF_BLOCK
## Proof

- [ ] build: n/a — bootstrap is config + docs only
- [x] tests: commit-lint reusable workflow validates this PR head
- [ ] lint: n/a — no source files modified
- [x] runtime: ${PROOF_FILE}
- [ ] schema: n/a — no MQTT or HA interface changes
EOF_PROOF_BLOCK
printf '\n'

if [ ${#FAIL_STEPS[@]} -gt 0 ]; then
  exit 1
fi
exit 0
