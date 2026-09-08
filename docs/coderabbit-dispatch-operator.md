# CodeRabbit leftover dispatcher — operator manual

How to turn the shadow dispatcher on, read a tick, kill it, and keep CodeRabbit Fair Usage from burning on every push. Audience: future-Florian, AI agents operating the system.

Product (locked) lives in [`../specs/coderabbit-dispatch-spec.md`](../specs/coderabbit-dispatch-spec.md). This doc is the ops runbook. Do not treat chat transcripts as source of truth.

Merged as [PR #27](https://github.com/florianhorner/engineering-standards/pull/27) (`956cce9` on `main`).

---

## Where this knowledge belongs

| Place | What goes there |
|---|---|
| `specs/coderabbit-dispatch-spec.md` | Locked product: who is reviewed, rank order, fail-closed budget, shadow vs live |
| **This file** | Kill switches, GitHub variable, org dashboard vs yaml, how to read a run, what not to do |
| `README.md` | One-paragraph pointer |
| Chat / MemPalace | Scratch only. If it matters, land it here |

Do not add a catch-all TODO. Do not put the scheduler in mammamiradio. Do not implement the GitHub App write path until shadow has been trusted.

---

## Architecture

```
  CodeRabbit org YAML (app.coderabbit.ai)     templates/.coderabbit.yaml
  live first-review + incremental kill        durable fleet copy; bootstrap
           │                                  only overwrites unmarked files
           ▼
  First review: automatic on open/ready
  Incrementals: NOT automatic
           │
           ▼
  engineering-standards hourly job (:07 UTC)
  coderabbit-dispatch-hourly.yml
    → coderabbit-dispatch-remote.sh
      → coderabbit_dispatch.py
  REPORT-ONLY. Job summary. No comments, labels, or writes.
```

Quota is per GitHub identity (`florianhorner`). One central job in this repo ranks at most one later review per tick across owned non-forks plus allowlisted forks. CodeRabbit still does the actual review; this job only names who would get one.

---

## On / off

### On-switch (required)

Create the repository **variable** (not a secret):

- Name: `CODERABBIT_DISPATCH`
- Value: `1`
- URL: https://github.com/florianhorner/engineering-standards/settings/variables/actions

The enable file `.github/coderabbit-dispatch.enabled` is already on `main`. That is not enough by itself.

**Unset is off.** The workflow `if:` is `vars.CODERABBIT_DISPATCH != '0'`. GitHub Actions coerces an unset/empty var to `0` in that comparison, so a missing variable skips the job before checkout. Runs #1–#4 after merge skipped for that reason. The script’s `${CODERABBIT_DISPATCH:-1}` would treat unset as on, but the job never starts.

Literal `0` is the documented off-switch. Any other value (including `1`) is on, provided the enable file exists.

### Kill switches

Either one disables the dispatcher. Both are enforced in `coderabbit-dispatch-remote.sh`, not only the workflow `if:`:

1. Delete `.github/coderabbit-dispatch.enabled`
2. Set `CODERABBIT_DISPATCH` to literal `0`

Restore by putting the enable file back and setting the variable to `1`.

---

## CodeRabbit yaml vs org dashboard

`templates/.coderabbit.yaml` is the durable fleet copy: `auto_review.enabled: true`, `auto_incremental_review: false`, `auto_pause_after_reviewed_commits: 1`, `drafts: false`, bot `ignore_usernames`. Bootstrap installs it into a consumer **only when that repo has no unmarked hand-written file**. The `# BEGIN/END: engineering-standards-coderabbit` markers are a provenance stamp, not a section boundary — a stamped file is replaced wholesale.

**Yaml in git is not enough.** The CodeRabbit **org dashboard** is the live kill for incrementals (especially mammamiradio). An agent cannot click that UI.

1. Open https://app.coderabbit.ai → Organization Settings → YAML Editor
2. Keep the quiet profile / path filters / path_instructions / finishing_touches already there
3. Ensure `reviews.auto_review.enabled: true`, `auto_incremental_review: false`, `auto_pause_after_reviewed_commits: 1`, `drafts: false`, and `ignore_usernames` covering dependabot / renovate / github-actions / pre-commit-ci
4. Apply Changes

mammamiradio only inherits this if **Use Organization Settings** is on for that repo.

Do **not** turn `auto_review.enabled` off. That starves first reviews and is not a quota save. Do not add a label-only gate in yaml.

---

## What a tick prints

Workflow: [CodeRabbit dispatch (shadow)](https://github.com/florianhorner/engineering-standards/actions/workflows/coderabbit-dispatch-hourly.yml)

- Cron `7 * * * *` UTC plus `workflow_dispatch`
- Job name `shadow rank`
- `permissions`: `contents: read`, `pull-requests: read`, `issues: read` (PR comments are the Issues API)

Outcomes to watch:

| Outcome | Meaning |
|---|---|
| `DISABLED` | Enable file missing or `CODERABBIT_DISPATCH=0` |
| `BUDGET_HELD` | 7-day included count unknown or at/above 35, or hourly remaining is 0 — no `WOULD_REVIEW` |
| `WOULD_REVIEW` | Shadow would name one PR. Still does not comment |
| `NONE` / empty candidate set | Filters left nobody to rank |

Fail-closed: if the 7-day integer cannot be read (even via the 24h carry-forward), there is no `WOULD_REVIEW`. Hourly remaining > 0 is not a reason to burn leftover slots.

A new non-draft human PR’s **first** auto-review may print a footer with the 7-day count; later ticks can then `WOULD_REVIEW`. Do not mint that footer by commenting `@coderabbitai review`, `full review`, or `rate limit` — that spends quota.

### Observed 2026-09-08 (first successful run)

[Run #5](https://github.com/florianhorner/engineering-standards/actions/runs/34236777562) (`workflow_dispatch`, `CODERABBIT_DISPATCH=1`):

- Outcome `BUDGET_HELD`
- 7-day included count unknown (no CodeRabbit footer in the last 24h with the integer)
- Hourly remaining 0; hourly allowance unparsed
- Filters behaved: Dependabot, Copilot app, drafts, paused+HEAD-reviewed (mammamiradio #1114 class) skipped
- Report-only: no comments, labels, or issues

That is a healthy first state, not a bug. Leave the hourly job on and watch summaries.

---

## Repo set and rank

- Owned non-forks of `florianhorner`, plus allowlisted forks **`lightener-studio`** and **`govee2mqtt-extended`** only
- `templates/README.md` mentioning `lightener-curve-editor` is a bootstrap AUTHOR-NOTES example, **not** the dispatcher allowlist
- Only human `florianhorner` PRs; never Dependabot, GitHub Apps, or drafts
- Rank: never-reviewed HEAD first → oldest HEAD-stale → `mammamiradio` only as tie-break
- `GITHUB_TOKEN` is this repo’s installation token: public repos only. Private owned repos are silently out of scope

---

## Do not

- Do not `@coderabbitai review` / `full review` / `rate limit` from this job or from an agent “just to get a footer”
- Do not comment, label, or open issues from the shadow workflow
- Do not put a copy of this scheduler in mammamiradio
- Do not disable first-review auto (`reviews.auto_review.enabled: true` stays)
- Do not treat leftover hourly slots as something that must be spent
- Do not add `--slurp` to `gh api --paginate` (the live API already returns one flat array)

---

## Follow-up (not yet)

When shadow has run long enough to trust: a small GitHub App installation token for cross-repo writes (preferred: add label `review-ready`; comment `@coderabbitai review` as fallback after a one-PR probe). CodeRabbit’s own App still does the review. No PAT.

Optional later: change the workflow `if:` so an unset variable does not skip (today the on-switch is “create `=1`”). Do not silently invert kill-switch meaning.

Local / CI:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
bash coderabbit-dispatch-remote.sh   # needs gh; report-only
```
