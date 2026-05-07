# Commit Message Spec

Canonical commit-message standard for every repo and AI tool Florian uses. Machine-readable rules: [`commit-rules.json`](commit-rules.json). Operator manual: [`../docs/commit-system-operator.md`](../docs/commit-system-operator.md).

---

<!-- AI-AGENT-QUICK-REF -->

## 30-second cheat sheet

**Format:** `type(scope): subject`

**Allowed types:** `feat fix docs style refactor test chore ci build perf revert`

**Subject:** ≤72 chars, imperative mood, no trailing period, no version prefix.

**Body:** Required only when `feat` AND >50 lines changed. Body must include `Why: <one-line>`. Otherwise optional.

**Banned in body:** operator attribution (`florian asked`), agent self-talk (`addressed all comments`).
**Banned in subject:** GitHub web-UI defaults (`Add files via upload`, `Update README.md`), version prefix (`v1.2.3`).

**Exempt subjects** (skip format check entirely): `Merge `, `Revert `, `cherry-pick: `, `[hotfix] `.

**Trusted bots** (skip Why-required): `renovate[bot]`, `dependabot[bot]`, `pre-commit-ci[bot]`, `app/github-actions`.

**Bypass** (sanctioned): `git commit --no-verify` with `Policy-Override: <reason>` trailer. Logged to `~/.commit-bypass.log`.

### 5 good examples

```
fix(auth): handle expired session cookie returning undefined
```

```
docs(readme): clarify install prerequisites
```

```
feat(curve-card): add brightness scrubber with bar gauges

Why: ops team needs at-a-glance brightness state without opening editor.
Tested: e2e curve-editor + unit tests for scrubber state.
Refs: closes #67
Tool: claude-code
Skill-Run: ship
Test-Suite: 247/247
Reviewed-By: codex
```

```
chore(ci): pin floating actions to SHA
```

```
revert: "feat(api): rate-limit by token"

Why: triggered cascade rate-limits on legitimate batch jobs; revert pending design.
Refs: incident #42
```

### 5 bad examples (with the rule they violate)

```
fix: review cleanup                                  # vague — no scope, no specifics
Add files via upload                                 # WEB_UI_DEFAULT
v2.10.11 feat(jamendo): country + order filters     # VERSION_IN_SUBJECT
fix: stuff

florian asked me to fix this                        # OPERATOR_ATTRIBUTION (body)
chore: addressed all the review comments            # AGENT_SELF_TALK (subject)
```

---

## Deep dive

### Format grammar

```
<type>(<optional-scope>): <subject>

<optional-body, paragraphs separated by blank lines>

<optional-trailers, single block at end via git interpret-trailers>
```

### Subjects

- **Length:** ≤72 chars total (type + scope + colon + space + subject).
- **Imperative mood:** "fix bug" not "fixed bug" or "fixes bug".
- **No trailing period.** Subjects are not sentences.
- **No version prefix.** `v1.2.3` belongs in CHANGELOG.md, not commit subjects.
- **Scope** is optional; use it for the affected area: `feat(auth)`, `fix(curve-card)`, `docs(readme)`. Single-word, lowercase, hyphenated.

### Why body

The `Why:` line is the load-bearing portfolio signal. Future-you and recruiters reading `git log` learn the *reason*, not just the *what*.

**Required (CI blocks):** type is `feat` AND `git diff --shortstat` shows >50 lines changed.
**Advisory (local hook warns, CI does not block):** all other non-trivial commits.

**Acceptable terse `Why:` templates:**
- `Why: closes #N` — when the issue body has the context
- `Why: incident response — outage 2026-05-08T03:00Z`
- `Why: requested by ops at 0900 standup; needed for Italy launch Friday`
- `Why: spec at <url>; see decision log section 3`
- `Why: empirical — 30% latency reduction on prod traffic mirror`

### Trailers (metadata)

Free-form git trailers parsed via `git interpret-trailers`. **OMIT if not detectable; never fabricate.**

| Trailer | Source env var | Purpose |
|---|---|---|
| `Skill-Run:` | `$COMMIT_SKILL_RUN` | Which gstack skill triggered the commit (e.g., `ship`, `investigate`). |
| `Test-Suite:` | `$COMMIT_TEST_SUITE` | `<pass>/<total>` if test results known (e.g., `247/247`). |
| `Reviewed-By:` | `$COMMIT_REVIEWED_BY` | `codex` / `subagent` / `none` if `/review` or `/codex` ran since last commit on this branch. |
| `Tool:` | `$COMMIT_TOOL` | `claude-code` / `codex` / `conductor` / `cloud` — what tool created the commit. |

These trailers are the actual portfolio differentiator over plain Conventional Commits — `git log --pretty='%(trailers:key=Skill-Run)'` becomes agent telemetry.

**Trailer-block ordering:** All trailers MUST appear in a single contiguous block at message end. Never insert blank lines mid-block. Use `git interpret-trailers --in-place --trailer 'Skill-Run: ship' --trailer 'Tool: claude-code'`.

### Trailers (override)

`Policy-Override: <reason>` — required when bypassing the validator with `--no-verify` for a non-exempted commit. Audit log entry written to `~/.commit-bypass.log` by pre-push hook. CI records the exception but does not block.

### Fork branch behavior

When committing to a branch destined for an upstream PR (detected via `gh repo view --json isFork`), `/commit` skill **strips** these trailers: `Skill-Run`, `Reviewed-By`, `Tool`. **Preserved on forks:** `Co-Authored-By`, `Tested`, `Refs`, `Signed-off-by`, `Policy-Override`.

Rationale: upstream maintainers are a different audience than portfolio recruiters. Agent telemetry in upstream history is unwelcome by some maintainers; stripping on fork-bound branches keeps the differentiator on YOUR repos without polluting OTHER people's history.

### Banned patterns

#### Body-only

| Rule ID | Pattern | Example violation | Fix |
|---|---|---|---|
| `OPERATOR_ATTRIBUTION` | `florian asked\|as requested\|per request\|per my request` (case-insensitive) | "florian asked me to fix this" | Replace with WHY: "fix X because Y" |
| `AGENT_SELF_TALK` | `addressed all\|fix all\|fixed all\|cleaned up everything` (case-insensitive) | "addressed all the review comments" | Name specific changes: "fix N+1 in Foo.query, dedupe Bar.helper" |

These rules apply to the BODY only. Subjects rarely contain these phrases legitimately, but body false-positives like `my-config` or `our-team` made the original first-person regex too brittle, so first-person is NOT banned.

#### Subject-only

| Rule ID | Pattern | Example violation | Fix |
|---|---|---|---|
| `WEB_UI_DEFAULT` | `^Add files via upload$\|^Update [A-Z][a-z]+\.md$\|^Initial commit$` | "Add files via upload" | Use `type(scope): subject`; describe what was added |
| `VERSION_IN_SUBJECT` | `^v[0-9]` | "v2.10.11 feat: country filter" | Drop version prefix; use `chore(release): 2.10.11` if needed |

### Exemptions

Subjects matching these patterns skip the format check entirely:

- `^Merge ` — git merge commits
- `^Revert ` — `git revert`-generated commits
- `^cherry-pick: ` — labeled cherry-picks
- `^\[hotfix\] ` — emergency hotfix override

### Bot allowlist

Commits from these author identities skip the `WHY_REQUIRED` rule. Subject banned-patterns still apply.

- `renovate[bot]`
- `dependabot[bot]` (requires `.github/dependabot.yml` with `commit-message.prefix: "chore"` to format conventionally)
- `pre-commit-ci[bot]`
- `app/github-actions`

### Bypass policy (`--no-verify`)

`git commit --no-verify` skips the local commit-msg hook. CI still validates on push. To pass CI on a sanctioned bypass:

1. Subject matches an exemption pattern (Merge / Revert / cherry-pick / `[hotfix]`), OR
2. Body includes `Policy-Override: <reason>` trailer

The pre-push hook logs every `--no-verify` to `~/.commit-bypass.log` with the override reason. Repeated overrides without sanctioned reasons surface in the audit log for review.

### Validator implementation

- **Single binary** (`@florianhorner/commit-validator`) consumed by Bash hook, commitlint plugin, and `/commit` skill. The Bash hook is GENERATED at `bootstrap-repo.sh` install time from this spec — three-loaders-drift is structurally impossible.
- **POSIX-ERE only.** No PCRE. No `(?:...)` non-capturing groups. macOS BSD grep + Linux GNU grep + LANG=C all produce identical output.
- **Force `LC_ALL=C.UTF-8`** at top of validator binary and Bash hook.

### Error format

Validator emits errors in this canonical template (carried by `commit-rules.json` per rule):

```
BLOCK: <rule_id> <message>
FIX: <fix_hint>
SPEC: <spec_url>#<rule_id>
OFFENDING: <literal failing line>
```

CI additionally emits a markdown table to `$GITHUB_STEP_SUMMARY` (`SHA | subject | rule | fix hint`) and posts per-commit `gh pr review --comment` for each failing SHA.

### Versioning

`commit-rules.json` is SHA-pinned by consumers. Existing rule_ids are immutable once shipped — modifying a rule_id breaks every consumer mid-flight. **Breaking changes land as NEW rule_ids; old ones get deprecated, never modified.** Schema version bumps when the JSON shape itself changes.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Hook rejects with `BLOCK: WHY_REQUIRED` on a small fix | Subject was inferred as `feat` but it's actually `fix`/`chore` | Use explicit type prefix |
| CI passes but local hook blocks (or vice versa) | SHA pin drift between local validator and CI validator | Re-run `bootstrap-repo.sh` to refresh local hook from current rules |
| `Skill-Run:` trailer missing on commits made by a skill | `$COMMIT_SKILL_RUN` env var not set by skill wrapper | Verify wrapper exports the env var; OMIT-not-fabricate means missing var = missing trailer (correct) |
| First commit on a fresh repo fails with `Add files via upload` | You used GitHub web UI to upload files | Use git CLI; the message will pass the WEB_UI_DEFAULT check |
| Dependabot PRs all fail CI | `.github/dependabot.yml` not configured with `commit-message.prefix` | Re-run `bootstrap-repo.sh`; it patches dependabot config |

See [`../docs/commit-system-operator.md`](../docs/commit-system-operator.md) for the full operator manual.
