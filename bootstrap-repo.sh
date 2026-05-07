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
readonly HOOK_PATH=".git/hooks/commit-msg"
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

if [ ! -d ".git" ]; then
  die "pre-flight" "Target is not a git repository (no .git directory)" \
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
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" -v new="$block" '
      $0 == begin { in_block = 1; print new; next }
      $0 == end   { in_block = 0; next }
      !in_block   { print }
    ' "$target" > "$tmp"
    mv "$tmp" "$target"
  else
    # Append, preserving a trailing newline boundary.
    if [ -s "$target" ]; then
      printf '\n' >> "$target"
    fi
    printf '%s\n' "$block" >> "$target"
  fi
}

TOTAL_STEPS=12

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
  pull-requests: write
jobs:
  commit-lint:
    uses: ${ENGSTD_REPO}/.github/workflows/commit-lint-reusable.yml@${ENGSTD_SHA}
YAML
  TOUCHED_FILES+=("$CI_WORKFLOW_PATH")
  step_warn "${CI_WORKFLOW_PATH}" "template not yet published; wrote inline fallback pinned to ${ENGSTD_SHA:0:7}"
fi
rm -f "$TMP_CI"

# ---------------------------------------------------------------------------
# Step 4: patch or create .github/dependabot.yml
# ---------------------------------------------------------------------------
step_start 4 "$TOTAL_STEPS" "patch ${DEPENDABOT_PATH} (commit-message.prefix = chore)"
DEPENDABOT_URL="${ENGSTD_RAW_BASE}/${ENGSTD_SHA}/templates/dependabot-snippet.yml"
TMP_DEP="$(mktemp)"
if curl -fsSL --max-time 30 "$DEPENDABOT_URL" -o "$TMP_DEP" 2>/dev/null \
   && [ -s "$TMP_DEP" ]; then
  if [ ! -f "$DEPENDABOT_PATH" ]; then
    mkdir -p "$(dirname "$DEPENDABOT_PATH")"
    cp "$TMP_DEP" "$DEPENDABOT_PATH"
    TOUCHED_FILES+=("$DEPENDABOT_PATH")
    step_pass "dependabot.yml (created)"
  else
    # Idempotent merge: if the snippet markers already exist, refresh; else
    # render via marker block helper. Dependabot YAML doesn't support comments
    # the same way, so we use literal `# <BEGIN/END>` lines.
    if grep -qF "# BEGIN: commit-message-standards" "$DEPENDABOT_PATH"; then
      tmp="$(mktemp)"
      awk -v begin="# BEGIN: commit-message-standards" \
          -v end="# END: commit-message-standards" \
          -v file="$TMP_DEP" '
        BEGIN {
          while ((getline line < file) > 0) snippet = snippet line "\n"
          close(file)
        }
        $0 ~ begin { in_block = 1; printf "%s%s\n", begin, "\n"; printf "%s", snippet; printf "%s\n", end; next }
        $0 ~ end   { in_block = 0; next }
        !in_block  { print }
      ' "$DEPENDABOT_PATH" > "$tmp"
      mv "$tmp" "$DEPENDABOT_PATH"
      step_pass "dependabot.yml (refreshed in place)"
    else
      {
        printf '\n# BEGIN: commit-message-standards\n'
        cat "$TMP_DEP"
        printf '# END: commit-message-standards\n'
      } >> "$DEPENDABOT_PATH"
      TOUCHED_FILES+=("$DEPENDABOT_PATH")
      step_pass "dependabot.yml (appended snippet)"
    fi
  fi
else
  if [ ! -f "$DEPENDABOT_PATH" ]; then
    mkdir -p "$(dirname "$DEPENDABOT_PATH")"
    cat > "$DEPENDABOT_PATH" <<'YAML'
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    commit-message:
      prefix: "chore"
      include: "scope"
YAML
    TOUCHED_FILES+=("$DEPENDABOT_PATH")
    step_warn "dependabot.yml" "template not yet published; wrote npm-only fallback"
  else
    step_warn "dependabot.yml" "template not published and target exists; not patched — verify commit-message.prefix manually"
  fi
fi
rm -f "$TMP_DEP"

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
  CONTENT_STRIPPED="$(printf '%s' "$CONTENT" | awk '
    /^<!-- BEGIN: commit-message-standards/ { next }
    /^<!-- END: commit-message-standards/   { next }
    { print }
  ')"
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
  CONTENT_STRIPPED="$(printf '%s' "$CONTENT" | awk '
    /^<!-- BEGIN: commit-message-standards/ { next }
    /^<!-- END: commit-message-standards/   { next }
    { print }
  ')"
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
# Step 8: generate .git/hooks/commit-msg
# ---------------------------------------------------------------------------
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
# Step 12: TTHW timer + final summary
# ---------------------------------------------------------------------------
step_start 12 "$TOTAL_STEPS" "compute TTHW"
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

printf '\n%sBootstrapped in %ds.%s Target: <5min for first compliant commit + green CI.\n\n' \
  "$C_BOLD$C_BLUE" "$ELAPSED" "$C_RESET"

if [ ${#FAIL_STEPS[@]} -gt 0 ]; then
  exit 1
fi
exit 0
