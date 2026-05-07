# Changelog

All notable changes to commit-rules.json, validator, and reusable workflows.

Versioning: SHA-pinned by consumers. Existing rule_ids are immutable once shipped; breaking changes land as NEW rule_ids.

## [Unreleased]

### Added
- **Phase 1 (foundation)**: spec doc with cheat-sheet-at-top, machine-readable rules.json, operator manual
- **Phase 1.5 (validator)**: Python generator at `validator/generate-hook.py` reads `commit-rules.json` and emits the Bash commit-msg hook (single source of truth — Bash hook is generated artifact, never hand-written)
- **Phase 1.5 (corpus)**: golden test corpus at `specs/test-corpus/` — 26 pass + 25 fail + 7 false-positives covering all 11 types, all 7 rule_ids, boundary cases (72/73 chars), exemptions, bot patterns, and known false-positive guards (`my-config`, `our-team`, version-in-body, period-mid-subject)
- **Phase 1.5 (templates)**: 7 drop-in files at `templates/` — per-repo CLAUDE snippet, CONTRIBUTING cheat sheet (self-sufficient for cloud agents), AUTHOR-NOTES.md (Tier 1A forks), .commitlintrc.json, per-repo workflow includer, dependabot snippet, README. All snippets use `<!-- BEGIN/END: commit-message-standards -->` markers for idempotent in-place refresh.
- **Phase 1.5 (CI)**: `.github/workflows/commit-lint-reusable.yml` — reusable workflow consumers call via `uses:`. Validates PR commit range bounded by `git merge-base origin/main HEAD`, posts per-commit review comments via `gh pr review`, emits markdown table to `$GITHUB_STEP_SUMMARY`, hard 60s timeout. Public repo so private/public consumers can both call it.
- **Phase 1.5 (CI)**: `.github/workflows/test-corpus.yml` — self-test workflow that validates the validator against the corpus on every push to engineering-standards.
- **Phase 1.5 (bootstrap)**: `bootstrap-repo.sh` — 12-step self-verifying installer. Vendors `commit-rules.json` SHA-pinned, drops .commitlintrc.json + workflow includer + dependabot config + CONTRIBUTING + CLAUDE snippet + AUTHOR-NOTES (if fork), generates local commit-msg hook, dry-runs against last 3 commits, checks Actions enabled, prints TTHW timer. Idempotent. Smoke-tested at 4s first run, 2s on re-run.


### Fixed
- WEB_UI_DEFAULT regex widened from `^Update [A-Z][a-z]+\.md$` to `^Update [A-Z][A-Za-z]*\.md$` so it correctly catches all-caps filenames (`README.md`, `CHANGELOG.md`, `LICENSE.md`). The original regex required mixed-case (`Readme.md`), missing the most common GitHub web-UI default. Caught by CI on first push of test corpus. Rule_id unchanged (semantic widening, not a breaking change).
- Corpus `# expected:` headers updated from `FORMAT` → `SUBJECT_FORMAT` to match the actual rule_id the validator emits. Naming-mismatch caught by CI on first push.

### Conventions
- Conventional Commits format with body-when-it-matters policy (Why required only for `feat` AND >50 lines)
- Metadata trailer policy (`Skill-Run`, `Test-Suite`, `Reviewed-By`, `Tool`) with fork-strip behavior on upstream-bound branches
- Override trailer (`Policy-Override`) for sanctioned bypass with audit log to `~/.commit-bypass.log`
- Bot allowlist (`renovate[bot]`, `dependabot[bot]`, `pre-commit-ci[bot]`, `app/github-actions`)
- Subject exemptions (`Merge `, `Revert `, `cherry-pick: `, `[hotfix] `)

### Related
- Local install (this machine): `~/.git-hooks/commit-msg` (generated from commit-rules.json), `~/.git-hooks/pre-push` augmented with cap-20-commits revalidation, `~/.claude/skills/commit/SKILL.md` (the `/commit` slash skill), `~/.claude/CLAUDE.md` (global rule)
