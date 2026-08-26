# Commit System Operator Manual

How to bootstrap, run, debug, and upgrade the commit-message standards system across Florian's repos. Audience: future-Florian, AI agents operating the system.

For the format itself, see [`../specs/commit-message-spec.md`](../specs/commit-message-spec.md). This doc is about operating the *infrastructure*.

---

## Architecture

```
        ┌─────────────────────────────────────────────────┐
        │  florianhorner/engineering-standards (PUBLIC)   │
        │  - specs/commit-rules.json (SSOT)               │
        │  - specs/commit-message-spec.md                 │
        │  - validator/ (TS, single binary)               │
        │  - .github/workflows/commit-lint-reusable.yml   │
        │  - templates/ (for bootstrap-repo.sh)           │
        └────────────────┬────────────────────────────────┘
                         │ SHA-pinned
                         ↓
   ┌────────────────────────────────────────────────────────┐
   │  Consumer repo (e.g. lightener, mammamiradio)          │
   │                                                         │
   │  Per-repo (vendored at bootstrap):                     │
   │   .config/commit-rules.json (frozen at SHA)            │
   │   .commitlintrc.json                                   │
   │   .github/workflows/commit-lint.yml (5-line includer)  │
   │   .github/dependabot.yml (commit-message.prefix=chore) │
   │   CONTRIBUTING.md (cheat sheet for Codex web)          │
   │   CLAUDE.md (skill routing + commit standards link)    │
   │                                                         │
   │  Generated artifact:                                    │
   │   .git/hooks/commit-msg (generated from rules.json     │
   │     by validator binary at bootstrap time)             │
   └────────────────────────────────────────────────────────┘

   Local laptop (separate from any specific repo):
     ~/.git-hooks/commit-msg → calls validator binary
     ~/.git-hooks/pre-push → augmented to revalidate range
     ~/.claude/skills/commit/SKILL.md → /commit slash command
     ~/.claude/CLAUDE.md → global rule with link to spec
     ~/.commit-bypass.log → audit log for --no-verify uses
```

### Reusable workflow trust boundary

Consumer repositories call the reusable workflow at an exact 40-character commit SHA. The job checks out the consumer merge commit as untrusted data in `consumer/`, checks out validator code, rules, and commitlint configuration from `job.workflow_repository` at `job.workflow_sha` in `trusted/`, then verifies that checkout's origin and `HEAD` before running policy. Scratch files live under a fresh `$RUNNER_TEMP` directory, third-party actions are full-SHA pinned, package installation disables lifecycle scripts, and the called workflow has no pull-request write permission.

The workflow exposes `workflow_repository`, `workflow_ref`, and `workflow_sha` outputs so hosted fixtures can prove which immutable policy revision ran. A consumer's `.config/commit-rules.json` remains local installation metadata; CI does not execute or import policy from the PR head.

---

## Bootstrap a new repo

```bash
# From any directory:
bash <(curl -fsSL https://raw.githubusercontent.com/florianhorner/engineering-standards/main/bootstrap-repo.sh) /path/to/target/repo
```

The bootstrap script (Phase 4 deliverable) is self-verifying. It:

1. Vendors `commit-rules.json` from a SHA-pinned source into `.config/commit-rules.json`
2. Drops `.commitlintrc.json`
3. Drops `.github/workflows/commit-lint.yml` (5-line `uses:` includer)
4. Generates `.github/dependabot.yml` with `commit-message.prefix: "chore"` — one block per ecosystem, listing every directory that holds a tracked manifest (`server/package.json`, `src-tauri/Cargo.toml`, a composite action's own `action.yml`), not just `/`
5. Drops `CONTRIBUTING.md` snippet (cheat sheet for Codex web / human contributors)
6. Appends commit-standards section to `CLAUDE.md`
7. Generates `.git/hooks/commit-msg` from the validator binary
8. Runs validator dry-run against last 3 commits to verify
9. Checks `gh api repos/$X/actions/permissions` to confirm Actions enabled
10. Prints final pass/fail checklist with copy-paste `gh` commands for any manual-only steps remaining
11. Emits TTHW (time to hello world) timer

**Idempotency:** Running twice detects existing markers and refreshes in place. Doesn't double-append.

---

## Normal flow

### Local commit (laptop)

```bash
git add specific-file.ts
/commit                          # in Claude Code / Conductor — drafts message
                                 # OR
git commit -m "fix(scope): subject"   # manual
                                 # commit-msg hook validates locally
git push                         # pre-push hook revalidates range (cap 20 commits)
                                 # CI on push validates again
```

### Cloud agent commit (Claude Code Cloud / Codex web)

The agent reads the repo-local `CONTRIBUTING.md` cheat sheet and `commit-rules.json`. It crafts the message conformantly because it was trained on the spec from the snippet. CI on push catches anything that drifts.

### Bot commits (renovate, dependabot, pre-commit-ci)

Bot commit messages are validated normally because Git author names are user-controlled. For the PR title only, CI compares the event author's verified GitHub login with `trusted_bots` and may skip the rule IDs in `trusted_bot_skips`. If a bot lands a non-conventional commit subject, fix the bot config rather than weakening the rules.

---

## Override flow

### Sanctioned bypass

```bash
# Emergency hotfix at 2am:
git commit -m "[hotfix] fix prod outage from migration 0042" \
  -m "" \
  -m "Policy-Override: prod outage, migrating roll-forward fix; full review tomorrow"
```

The `[hotfix]` subject prefix is exempted from format check. The `Policy-Override:` trailer logs to `~/.commit-bypass.log`. CI records the exception, doesn't block.

### Unsanctioned bypass

```bash
git commit --no-verify -m "fix stuff"
```

CI WILL block this on push. Use the sanctioned bypass above for legitimate emergency cases.

### Reverts / merges / cherry-picks

These are exempted by subject prefix (`Revert `, `Merge `, `cherry-pick: `). No special action needed.

---

## Bot behavior

| Bot | Conventional by default? | Required config |
|---|---|---|
| `renovate[bot]` | Yes (`chore(deps):`) | None |
| `dependabot[bot]` | NO (`Bump foo from 1 to 2`) | `.github/dependabot.yml` with `commit-message.prefix: "chore"` |
| `pre-commit-ci[bot]` | Yes (`[pre-commit.ci] auto fixes`) | None |
| `app/github-actions` | Varies | Configure conventional subjects for generated commits |

To add a new trusted PR author: edit the `commit-rules.json` `exemptions.trusted_bots` array, bump the schema version, and ship a new engineering-standards SHA. Consumers pick it up when they repin the reusable workflow.

To change which PR-title rules a trusted bot may trip, edit `exemptions.trusted_bot_skips`. CI reads that array from the immutable workflow checkout, so a rule ID added there takes effect on the next SHA repin. A bot PR still fails if its title trips even one rule outside the array, and commit messages receive no author-based exemption.

`SUBJECT_TOO_LONG` is in the list because Dependabot's grouped-update titles ("…in the core group across 1 directory") exceed 72 characters by construction and cannot be configured shorter.

---

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| Local hook accepts but CI blocks | SHA pin drift between local validator and CI validator | Re-run `bootstrap-repo.sh` to refresh local hook from current rules |
| Local hook blocks but CI passes | Same drift in opposite direction | Same — re-run bootstrap |
| `Skill-Run:` trailer missing on commits made by a skill | `$COMMIT_SKILL_RUN` env var not set by skill wrapper | Wrapper bug; OMIT-not-fabricate means missing var is correct behavior, but skill wrapper should set it |
| `Skill-Run:` trailer present but value is wrong | Stale env var from previous skill | Wrapper should `unset` after use |
| Bot PR title fails CI | Bot config not patched, login not in `trusted_bots`, or violation not skippable | Re-run bootstrap for Dependabot formatting; only add a verified login/rule skip when policy intends it |
| Codex web agent commits fail CI | Repo CONTRIBUTING.md cheat sheet missing | Re-run bootstrap to drop it |
| `Verify immutable workflow identity` fails | Consumer uses a moving ref or the trusted checkout does not match the called workflow | Pin `.github/workflows/commit-lint.yml` to the intended exact 40-character commit SHA |
| Pre-push hook blocking on a 50-commit rebase from upstream | Augmentation not capping commits | Verify hook contains the `[ "$count" -gt 10 ] && skip` logic |

---

## Upgrade flow

When `commit-rules.json` changes in engineering-standards:

1. CHANGELOG.md gets the entry (rule_id added/deprecated, never modified)
2. Validator version bumps (semver: minor for new rule, patch for fix, major for schema change)
3. Reusable workflow changes ship as a new commit SHA if they affect CI behavior
4. Per-repo update: bump SHA pin in `.github/workflows/commit-lint.yml` AND re-run bootstrap to refresh `.config/commit-rules.json` and `.git/hooks/commit-msg`

**Breaking-change discipline:** never modify an existing rule_id. Add new rule_id, deprecate old one in CHANGELOG. Consumers can pin to old SHA until they're ready.

---

## Audit & metrics

```bash
# Per-repo report:
bash scripts/commit-audit.sh ~/repos/lightener
# → total commits, % conventional, top 20 worst offenders, by-author breakdown

# Generate RETRO.md (recruiter-readable summary of worst commits):
bash scripts/generate-retro.sh ~/repos/lightener
# → uses Codex CLI to explain worst commits in plain English; commits RETRO.md to repo

# Bypass audit:
cat ~/.commit-bypass.log
# → who used --no-verify, when, why
```

---

## When the system is wrong

If the validator blocks a legitimate commit:

1. Check if your case matches an exemption (Merge / Revert / cherry-pick / hotfix). If yes, prefix accordingly.
2. Check if your case is a missing rule (e.g., a new bot needs allowlisting). Open issue on `florianhorner/engineering-standards`.
3. If the rule itself is wrong (false positive on legitimate phrase), open issue with example.
4. Last resort: sanctioned `Policy-Override:` trailer with reason. Logs surface the override for later review.

The system optimizes for "agent compliance + portfolio signal," not "100% rule purity." Rules that block legitimate work get refined or removed.
