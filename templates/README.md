# templates/

Drop-in files that `bootstrap-repo.sh` (Phase 4 deliverable) copies or appends into consumer repos. Each template is self-sufficient — cloud agents that only see per-repo files (Claude Code Cloud, Codex web) get the full cheat sheet without needing to leave the repo.

## What lands where

| Template | Lands at (in consumer repo) | Bootstrap step |
|---|---|---|
| `per-repo-CLAUDE-snippet.md` | Appended between `BEGIN/END` markers in `CLAUDE.md` | Step 6 — append to `CLAUDE.md` |
| `per-repo-CONTRIBUTING-snippet.md` | Appended between `BEGIN/END` markers in `CONTRIBUTING.md` (created if missing) | Step 5 — drop/append `CONTRIBUTING.md` |
| `AUTHOR-NOTES.md` | Copied as `AUTHOR-NOTES.md` at repo root, **only on Tier 1A fork branches** (e.g. `lightener-curve-editor`, `govee2mqtt-extended`) | Step 5b — fork-branch-only copy |
| `.commitlintrc.json` | Copied as `.commitlintrc.json` at repo root | Step 2 — drop commitlint config |
| `per-repo-commit-lint.yml` | Copied as `.github/workflows/commit-lint.yml` (5-line includer; bootstrap script resolves `@v1` to the actual SHA-pinned ref) | Step 3 — drop CI includer |
| `dependabot-snippet.yml` | Patched into `.github/dependabot.yml` (created or merged) | Step 4 — patch dependabot config |

## Idempotency

Every template that gets appended (CLAUDE.md, CONTRIBUTING.md) is wrapped in `<!-- BEGIN: commit-message-standards --> ... <!-- END: commit-message-standards -->` markers. Re-running the bootstrap script replaces the section in place rather than double-appending.

## SHA pinning

Files that reference the engineering-standards repo (`per-repo-commit-lint.yml`, `.commitlintrc.json` indirectly via `.config/commit-rules.json`) use `@v1` as a placeholder. The bootstrap script resolves this to a concrete SHA at install time, so consumers are never broken by an unintended upstream change.

## Editing

These templates are themselves the source of truth for what bootstrap drops. Hand-edits to the deployed copies in consumer repos will be overwritten on the next `bootstrap-repo.sh` run — change the template here, push, then re-bootstrap consumers.
