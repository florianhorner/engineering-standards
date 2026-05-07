# validator/

Generator for the local commit-msg Bash hook.

## Why a generator (not a hand-written hook)

`commit-rules.json` in `../specs/` is the single source of truth. Three places consume the rules:

1. The local Bash commit-msg hook (this generator's output)
2. The CI commit-lint workflow
3. The `/commit` skill prompt

Hand-writing the Bash hook means three loaders that drift apart silently — a bug fixed in one place stays broken in the others. By generating the hook from `commit-rules.json`, **three-loaders-drift is structurally impossible**: change the rule, regenerate, ship. The generator is the contract.

## Regenerate the hook

```bash
python3 validator/generate-hook.py > ~/.git-hooks/commit-msg
chmod +x ~/.git-hooks/commit-msg
```

Run this command after **any** change to `specs/commit-rules.json` or to `validator/generate-hook.py` itself. The generated hook contains a header comment with the schema version and a "DO NOT EDIT" warning — if you edit the hook directly, the next regeneration silently overwrites your change.

## Schema version + when to regenerate

The generator stamps the `schema_version` from `commit-rules.json` into the hook header. Compare:

```bash
grep '^# Source rules:' ~/.git-hooks/commit-msg
grep '"schema_version"' specs/commit-rules.json
```

If they differ, regenerate. Cases that require a regeneration:

- A new banned pattern (`banned_patterns.body_only` or `subject_only`) was added.
- An existing rule's `pattern`, `message`, or `fix_hint` changed.
- The list of allowed `types` changed.
- `subject.max_length` changed.
- The exemption patterns or trusted-bot list changed.
- `spec_url` changed.

Schema-version bumps signal a JSON-shape change (add or remove a top-level key). The generator may need a code change in those cases — it parses by key path, so unknown keys are ignored, but missing required keys crash loud.

## Conventions baked into the hook

- POSIX ERE only. No PCRE, no `(?:...)` non-capturing groups, no lookaround. Works under macOS BSD grep and Linux GNU grep identically.
- `LC_ALL=C.UTF-8` forced at hook start so locale-dependent regex behavior is uniform.
- Errors emit the canonical four-line format from `commit-rules.json#error_format.template`:

  ```
  BLOCK: <rule_id> <message>
  FIX: <fix_hint>
  SPEC: <spec_url>#<rule_id>
  OFFENDING: <line>
  ```

- The `WHY_REQUIRED` rule has `local_severity: warn` — the local hook emits a `WARN:` block to stderr but does NOT exit 1. CI does the authoritative block with real `git diff --shortstat` data the hook cannot trust.
- Subjects matching exemption patterns (`Merge `, `Revert `, `cherry-pick: `, `[hotfix] `) skip ALL further checks.
- Body-only banned patterns are skipped entirely when the body is empty (so single-line commits with no body don't trip OPERATOR_ATTRIBUTION false-positives).
