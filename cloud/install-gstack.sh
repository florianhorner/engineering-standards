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
#   GSTACK_REF=<40-char-sha> cloud/install-gstack.sh
#   GSTACK_HOSTS="claude codex" cloud/install-gstack.sh
#
# Idempotent: re-running updates the checkout in place and re-registers skills
# (~5 s), so it also works as a repair/update inside a live workspace. Skills
# registered mid-session only take effect after the session restarts.
#
# Environment:
#   GSTACK_REF    40-char commit SHA to install (default: baked-in pin below).
#                 Branch names and tags are rejected — a mutable upstream ref
#                 would execute unreviewed code at build time. Bump the default
#                 by editing this file (and reviewing the new SHA).
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
#   2026-08-31: pin gstack to a full SHA (fail closed); install bun from GitHub
#               releases with a baked SHA256 instead of curl|bash.

set -uo pipefail

log()  { printf '[install-gstack] %s\n' "$*"; }
warn() { printf '[install-gstack] WARN: %s\n' "$*" >&2; }
die()  { printf '[install-gstack] FATAL: %s\n' "$*" >&2; exit 1; }

GSTACK_DIR="$HOME/.claude/skills/gstack"
# gstack @ 2026-08-31 (v1.76.0.0, main tip). Bump by replacing this SHA.
GSTACK_REF="${GSTACK_REF:-253d1dfe2694e49d60ba083423446b8363e113eb}"
GSTACK_HOSTS="${GSTACK_HOSTS:-claude codex cursor}"
BUN_BIN="$HOME/.bun/bin"

# bun v1.4.0 (2026-08-20). Bump BUN_VERSION and the SHA256s together from
# https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/SHASUMS256.txt
BUN_VERSION='1.4.0'
BUN_SHA256_LINUX_X64='2d03fb5fb83ac8b567aca0a281b2ce1a1a19d488f56c2968d88c3f25e92fe452'
BUN_SHA256_LINUX_X64_BASELINE='184fb4595f0d401a217cf7c78c1bc430ba83314dab7a8b94805babbf7fa7097f'
BUN_SHA256_LINUX_AARCH64='4b1a332ee861983eb93bcfe6f770fff94e3e31b2c388bdaea3c8ed35e58eed0e'

is_full_sha() {
  printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

# ── bun ────────────────────────────────────────────────────────────────────
# Hard requirement: gstack's ./setup aborts with "bun is required but not
# installed" before it registers anything. Not preinstalled on the cloud image.
# Download the GitHub-release zip and verify a baked SHA256 — do not pipe
# bun.sh/install (or any other remote script) to a shell.
extract_zip() {
  local zip="$1" dest="$2"
  if command -v unzip >/dev/null 2>&1; then
    unzip -qo "$zip" -d "$dest" || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$zip" "$dest" || return 1
  else
    die 'need unzip or python3 to extract bun'
  fi
}

install_bun_pinned() {
  local zip_name expected url tmpdir zip actual bun_src
  case "$(uname -m)" in
    x86_64)
      if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
        zip_name='bun-linux-x64.zip'
        expected="$BUN_SHA256_LINUX_X64"
      else
        zip_name='bun-linux-x64-baseline.zip'
        expected="$BUN_SHA256_LINUX_X64_BASELINE"
      fi
      ;;
    aarch64|arm64)
      zip_name='bun-linux-aarch64.zip'
      expected="$BUN_SHA256_LINUX_AARCH64"
      ;;
    *)
      die "unsupported architecture $(uname -m) for bun"
      ;;
  esac

  url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/${zip_name}"
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/bun-install.XXXXXX")" || die 'mktemp failed'
  zip="$tmpdir/$zip_name"

  if ! curl -fsSL "$url" -o "$zip"; then
    rm -rf "$tmpdir"
    die "bun download failed ($url)"
  fi

  actual="$(sha256sum "$zip" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    rm -rf "$tmpdir"
    die "bun checksum mismatch for $zip_name (got $actual, want $expected)"
  fi

  if ! extract_zip "$zip" "$tmpdir"; then
    rm -rf "$tmpdir"
    die 'bun unzip failed'
  fi

  bun_src="$(find "$tmpdir" -type f -name bun | head -n1)"
  if [ -z "$bun_src" ]; then
    rm -rf "$tmpdir"
    die 'bun binary missing from archive'
  fi

  mkdir -p "$BUN_BIN" || { rm -rf "$tmpdir"; die "could not create $BUN_BIN"; }
  cp "$bun_src" "$BUN_BIN/bun"
  chmod 755 "$BUN_BIN/bun"
  ln -sfn bun "$BUN_BIN/bunx"
  rm -rf "$tmpdir"
}

ensure_bun() {
  export PATH="$BUN_BIN:$PATH"
  if command -v bun >/dev/null 2>&1 \
     && [ "$(bun --version 2>/dev/null || true)" = "$BUN_VERSION" ]; then
    log "bun already present ($(bun --version))"
    if [ -x "$BUN_BIN/bun" ] && [ ! -e "$BUN_BIN/bunx" ]; then
      ln -sfn bun "$BUN_BIN/bunx"
    fi
  else
    log "installing bun ${BUN_VERSION} from GitHub releases ..."
    install_bun_pinned
    command -v bun >/dev/null 2>&1 || die 'bun installed but not on PATH'
    command -v bunx >/dev/null 2>&1 || die 'bunx missing after bun install'
    [ "$(bun --version)" = "$BUN_VERSION" ] \
      || die "bun version $(bun --version) != pinned ${BUN_VERSION}"
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
# Fetch the pinned SHA only. No clone of default-branch as a fallback, and no
# "stay on whatever we got" warning — a miss is a failed build.
fetch_gstack() {
  local expected actual
  expected="$(printf '%s' "$GSTACK_REF" | tr 'A-F' 'a-f')"
  is_full_sha "$expected" \
    || die "GSTACK_REF must be a 40-char commit SHA (got '$GSTACK_REF')"

  if [ -d "$GSTACK_DIR/.git" ]; then
    log "updating gstack to $expected ..."
  else
    log "cloning gstack $expected ..."
    rm -rf "$GSTACK_DIR"
    mkdir -p "$(dirname "$GSTACK_DIR")" || die 'could not create ~/.claude/skills'
    git init --quiet "$GSTACK_DIR" || die 'git init failed'
    git -C "$GSTACK_DIR" remote add origin https://github.com/garrytan/gstack.git \
      || die 'could not add gstack remote'
  fi

  git -C "$GSTACK_DIR" fetch --quiet --depth 1 origin "$expected" \
    || die "could not fetch gstack SHA $expected"
  git -C "$GSTACK_DIR" checkout --quiet -f --detach FETCH_HEAD \
    || die "could not checkout gstack SHA $expected"

  actual="$(git -C "$GSTACK_DIR" rev-parse HEAD)"
  [ "$actual" = "$expected" ] \
    || die "gstack HEAD $actual != pinned $expected"
  log "gstack at $actual"
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
command -v curl >/dev/null 2>&1 || die 'curl is required'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

ensure_bun
fetch_gstack
register_hosts
verify_browser || true

log "skills registered: $(find "$HOME/.claude/skills" -maxdepth 1 -name 'gstack-*' | wc -l) for claude, in $(du -sh "$GSTACK_DIR" | cut -f1) on disk"
log 'gstack ready — /gstack-ship, /gstack-qa, /gstack-review, /gstack-browse'
