# Commit-Message Test Corpus

Golden test corpus for the commit-message validator. **Single corpus, three consumers** — the validator binary, the Bash hook installed by `bootstrap-repo.sh`, and the CI workflow all run against these files. Identical pass/fail behavior across consumers is the whole point.

## Purpose

These files are the **ground truth** for what the rules in [`../commit-rules.json`](../commit-rules.json) actually mean. The spec ([`../commit-message-spec.md`](../commit-message-spec.md)) is the prose; this corpus is the test oracle.

When you change a rule, you change the corpus. When the corpus changes, all three consumers must agree on the new outcome — that's how drift between the local hook, the commitlint plugin, and the CI workflow stays structurally impossible.

## Format

Each `.txt` file is a complete commit message:

```
<subject line>
<blank line>
<body paragraphs, blank-separated>
<blank line>
<trailer block (single contiguous block at end)>
```

A file's contents are exactly what `git log --format=%B <sha>` would print — newlines, blank lines, and trailers preserved.

## Layout

```
test-corpus/
  pass/                  Valid commit messages — validator MUST exit 0.
    <short-slug>.txt
  fail/                  Invalid commit messages — validator MUST exit non-zero.
    <RULE_ID>-<short-slug>.txt
  false-positives/       Tricky messages that LOOK like they should fail but MUST pass.
    <short-slug>.txt
```

## Naming

- **`pass/<slug>.txt`** — short kebab-case slug describing the case (e.g., `feat-with-full-trailers.txt`, `revert-exemption.txt`). The slug is for humans browsing the directory; the validator does not parse it.
- **`fail/<RULE_ID>-<slug>.txt`** — slug is prefixed with the canonical `RULE_ID` (from `commit-rules.json`) that this case is designed to trip. One file per (rule, case) pair. If a single message intentionally violates two rules, pick the primary one for the filename and document the secondary in a `# expected:` comment line.
- **`false-positives/<slug>.txt`** — same as `pass/`, but reserved for messages that previously caused regressions or that look superficially like they should fail. These are the regression suite for the rule patterns themselves.

## The `# expected:` comment line

The first line of every `fail/*.txt` file MUST be a comment of the form:

```
# expected: <RULE_ID>
```

The validator strips lines beginning with `#` (the same convention `git commit` uses for the editor template), so this annotation is invisible at validation time but documents which rule the case is targeting. Multiple expected rules can be listed comma-separated:

```
# expected: WEB_UI_DEFAULT, AGENT_SELF_TALK
```

`pass/` and `false-positives/` files do not require the `# expected:` line — but a brief `# note:` comment is welcome to explain non-obvious cases.

## How to add a new case

1. Decide which bucket it belongs in (`pass`, `fail`, `false-positives`).
2. Pick a slug (and `RULE_ID` for `fail/`).
3. Write the file. For `fail/`, put `# expected: <RULE_ID>` on line 1.
4. Run the validator against the corpus locally — your new case must produce the expected outcome and existing cases must keep passing.
5. Commit the corpus change in the same PR that changes the validator/rule logic. Corpus and code move together; otherwise CI catches the drift on the next push.

## Why a corpus and not just unit tests

Inline regex tests in the validator's source language (Bash for the hook, TypeScript for the commitlint plugin) cannot share a fixture set across runtimes. A flat directory of `.txt` files can. The same `pass/feat-with-trailers.txt` is read identically by the Bash hook test harness, the Node-side commitlint snapshot test, and the GitHub Actions integration test. That is what guarantees three loaders never drift.
