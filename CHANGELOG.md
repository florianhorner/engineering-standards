# Changelog

All notable changes to commit-rules.json, validator, and reusable workflows.

Versioning: SHA-pinned by consumers. Existing rule_ids are immutable once shipped; breaking changes land as NEW rule_ids.

## [Unreleased]

### Added
- Initial spec, machine-readable rules, operator manual stub
- Conventional Commits format with body-when-it-matters policy
- Metadata trailer policy (Skill-Run, Test-Suite, Reviewed-By, Tool) with fork-strip behavior
- Override trailer (Policy-Override) for sanctioned bypass with audit log
- Bot allowlist (renovate, dependabot, pre-commit-ci, github-actions)
- Subject exemptions (Merge, Revert, cherry-pick, [hotfix])
