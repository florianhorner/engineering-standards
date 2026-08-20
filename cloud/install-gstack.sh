#!/usr/bin/env bash
# install-gstack.sh — install gstack (github.com/garrytan/gstack) on a headless
# cloud box so its /gstack-* skills exist for every agent host.
#
# Why this file exists: agent skills live in ~/.claude (and ~/.codex, ~/.cursor),
# which is a Mac-local directory. Conductor's "files to copy" runs for local Mac
# workspaces only, and `scripts.setup` in .conductor/settings.toml does not run in
# cloud at all — so nothing user-global ever reaches a cloud workspace. The only
# persistent hook is the Cloud Computer "Install software" script, which runs once
# per build from $HOME under `set -euo pipefail`; its filesystem becomes the
# snapshot every new cloud workspace boots from. This script is what that hook runs.
#
# Usage:
#   cloud/install-gstack.sh                  # bake into the snapshot (build time)
#   GSTACK_REF=v1.2.3 cloud/install-gstack.sh
#   GSTACK_HOSTS="claude codex" cloud/install-gstack.sh
#
# Idempotent: re-running updates the checkout in place and re-registers skills
# (~5 s), so it also works as a repair/update inside a live workspace. Skills
# registered mid-session only take effect after the session restarts.
#
# Environment:
#   GSTACK_REF    git ref to install (default: main). Pin to a tag/SHA for
#                 reproducible builds — gstack moves fast.
#   GSTACK_HOSTS  space-separated agent hosts (default: "claude codex cursor").
#                 ./setup --help lists claude, codex, kiro, factory, opencode,
#                 openclaw, hermes, gbrain; `cursor` works but is undocumented.
#
# Not set here: GSTACK_ANTHROPIC_API_KEY / GSTACK_OPENAI_API_KEY. Conductor strips
# ANTHROPIC_API_KEY, so gstack reads the GSTACK_-prefixed names — add them as Cloud
# Computer environment variables, never inline in a script.
#
# Measured on a Conductor cloud sandbox (Amazon Linux 2023, 8 vCPU / 16 GB):
# ~30 s cold, 1.4 GB on disk (node_modules + the 82 MB browse binary + Chromium).
#
# Changelog:
#   2026-08-20: first version, extracted from a verified manual run.

set -uo pipefail

log()  { printf '[install-gstack] %s\n' "$*"; }
warn() { printf '[install-gstack] WARN: %s\n' "$*" >&2; }
die()  { printf '[install-gstack] FATAL: %s\n' "$*" >&2; exit 1; }

GSTACK_DIR="$HOME/.claude/skills/gstack"
GSTACK_REF="${GSTACK_REF:-main}"
GSTACK_HOSTS="${GSTACK_HOSTS:-claude codex cursor}"
BUN_BIN="$HOME/.bun/bin"

# ── bun ────────────────────────────────────────────────────────────────────
# Hard requirement: gstack's ./setup aborts with "bun is required but not
# installed" before it registers anything. Not preinstalled on the cloud image.
ensure_bun() {
  export PATH="$BUN_BIN:$PATH"
  if command -v bun >/dev/null 2>&1; then
    log "bun already present ($(bun --version))"
  else
    log 'installing bun ...'
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 \
      || die 'bun install failed'
    command -v bun >/dev/null 2>&1 || die 'bun installed but not on PATH'
    log "bun $(bun --version) installed"
  fi

  # The snapshot keeps the filesystem, not shell state. bun's installer writes
  # ~/.bash_profile itself; ~/.profile is the one cloud login shells source
  # transitively, so make sure both carry it.
  local line='export PATH="$HOME/.bun/bin:$PATH"'
  local f
  for f in "$HOME/.bash_profile" "$HOME/.profile"; do
    grep -qsF '.bun/bin' "$f" || printf '\n%s\n' "$line" >> "$f"
  done
}

# ── checkout ───────────────────────────────────────────────────────────────
fetch_gstack() {
  if [ -d "$GSTACK_DIR/.git" ]; then
    log "updating gstack to '$GSTACK_REF' ..."
    git -C "$GSTACK_DIR" fetch --quiet --depth 1 origin "$GSTACK_REF" \
      && git -C "$GSTACK_DIR" reset --quiet --hard FETCH_HEAD \
      || die "could not update gstack to '$GSTACK_REF'"
  else
    log "cloning gstack '$GSTACK_REF' ..."
    rm -rf "$GSTACK_DIR"
    mkdir -p "$(dirname "$GSTACK_DIR")" || die 'could not create ~/.claude/skills'
    git clone --quiet --single-branch --depth 1 --branch "$GSTACK_REF" \
      https://github.com/garrytan/gstack.git "$GSTACK_DIR" 2>/dev/null \
      || git clone --quiet --single-branch --depth 1 \
           https://github.com/garrytan/gstack.git "$GSTACK_DIR" \
      || die 'gstack clone failed'
    # --branch does not take a SHA; land on it explicitly when the ref was one.
    if [ "$GSTACK_REF" != main ] \
       && [ "$(git -C "$GSTACK_DIR" rev-parse HEAD)" != "$GSTACK_REF" ]; then
      git -C "$GSTACK_DIR" fetch --quiet --depth 1 origin "$GSTACK_REF" \
        && git -C "$GSTACK_DIR" reset --quiet --hard FETCH_HEAD \
        || warn "could not pin to '$GSTACK_REF' — staying on default branch"
    fi
  fi
  log "gstack at $(git -C "$GSTACK_DIR" rev-parse --short HEAD)"
}

# ── registration ───────────────────────────────────────────────────────────
# --prefix  → /gstack-ship, /gstack-qa. gstack's default is --no-prefix, whose
#             bare names (/ship, /qa, /review) collide with harness- and
#             repo-provided skills of the same name.
# --no-team → skip gstack's SessionStart auto-update hook. In a snapshot that
#             hook would re-clone and rebuild on every session start in every
#             workspace, which is exactly what baking it in avoids. On a
#             developer's own Mac you want team mode; never run --no-team there.
register_hosts() {
  local host rc failed=0
  for host in $GSTACK_HOSTS; do
    log "registering skills for host '$host' ..."
    if [ "$host" = claude ]; then
      (cd "$GSTACK_DIR" && ./setup --prefix --no-team -q); rc=$?
    else
      (cd "$GSTACK_DIR" && ./setup --prefix --no-team -q --host "$host"); rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      warn "setup failed for host '$host' (exit $rc)"
      failed=1
    fi
  done
  [ "$failed" -eq 0 ] || die 'at least one host failed to register'

  # setup prints "Run gstack-relink to re-apply name: patches" on every prefixed
  # install. It rewrites the `name:` frontmatter of the claude-host skills to
  # match their gstack-* directories; codex and cursor keep short frontmatter
  # names and are addressed by directory, which is what their hosts read.
  if [ -x "$GSTACK_DIR/bin/gstack-relink" ]; then
    "$GSTACK_DIR/bin/gstack-relink" >/dev/null 2>&1 \
      || warn 'gstack-relink failed — claude skill names may not carry the prefix'
  fi
}

# ── browser ────────────────────────────────────────────────────────────────
# ./setup downloads Playwright's Chromium itself, which works here — outbound
# network is open and cdn.playwright.dev is reachable. Probe rather than assume:
# a missing browser silently disables /gstack-browse and /gstack-qa.
#
# Behind a proxy that blocks cdn.playwright.dev this probe fails and no retry
# helps. The fix there is to bridge an already-present Chromium of the same
# family into the revision path Playwright asks for; see the reference
# implementation in home-assistant-config/.claude/scripts/install-gstack.sh
# (link_playwright_browser).
verify_browser() {
  local probe='const {chromium}=require("playwright");chromium.launch().then(async b=>{await b.close();process.exit(0)}).catch(e=>{console.error(e.message.split("\n")[0]);process.exit(1)})'
  if (cd "$GSTACK_DIR" && node -e "$probe") >/dev/null 2>&1; then
    log 'headless Chromium launches'
    return 0
  fi
  warn 'Chromium did not launch — retrying the Playwright download once'
  (cd "$GSTACK_DIR" && bunx playwright install chromium) >/dev/null 2>&1
  if (cd "$GSTACK_DIR" && node -e "$probe") >/dev/null 2>&1; then
    log 'headless Chromium launches after retry'
    return 0
  fi
  warn '/gstack-browse and /gstack-qa will not work — no usable Chromium'
  return 1
}

# ── run ────────────────────────────────────────────────────────────────────
command -v git >/dev/null 2>&1 || die 'git is required'
command -v node >/dev/null 2>&1 || die 'node is required'

ensure_bun
fetch_gstack
register_hosts
verify_browser || true

log "skills registered: $(find "$HOME/.claude/skills" -maxdepth 1 -name 'gstack-*' | wc -l) for claude, in $(du -sh "$GSTACK_DIR" | cut -f1) on disk"
log 'gstack ready — /gstack-ship, /gstack-qa, /gstack-review, /gstack-browse'
