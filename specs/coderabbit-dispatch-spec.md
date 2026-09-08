# CodeRabbit leftover dispatcher (shadow)

Central, report-only ranker for **later** CodeRabbit reviews. First reviews stay on CodeRabbit auto-review. This job does **not** burn leftover hourly slots, does **not** comment, and does **not** write to other repos.

Quota is per GitHub identity. The scheduler lives in this repo, not in mammamiradio and not as N per-repo workflows.

## Product (locked)

1. **First review** is automatic via CodeRabbit (`reviews.auto_review.enabled: true` on open/ready). Starve-proof if this dispatcher is down.
2. **Incrementals** are not automatic (`auto_incremental_review: false`). This dispatcher may name at most one later review per tick when budget allows.
3. **7-day ceiling 35** included reviews. Fail closed if the count cannot be read. Goal is to climb back toward 8–10/hour (`<30` in 7 days is the recover band; 35 is “don’t get worse”).
4. **Dependabot never. Any GitHub App author never.** Only human `florianhorner` PRs.
5. **Drafts never.**
6. **Repo set:** every `florianhorner` owned non-fork, plus allowlisted forks `lightener-studio` and `govee2mqtt-extended`. All other forks are out. Never comment on upstream.
7. **Rank (one candidate per tick):** never-reviewed HEAD first → oldest HEAD-stale → `mammamiradio` only as tie-break.
8. **Command (live, not this shadow job):** `@coderabbitai review` incremental by default; `full review` only if that PR has no prior CodeRabbit review or the change-stack is stale. Same quota cost either way.
9. **Shadow:** print what would be skipped/reviewed and why. Job summary only. Not an issue every hour.
10. **Executor:** GitHub Actions `ubuntu-latest`, `gh` API, same rationale as `fleet-audit-monthly.yml`.
11. **Live identity (follow-up PR, not this one):** a small GitHub App installation token for cross-repo writes. CodeRabbit’s own App does the actual review. No PAT.

Reference skip class: mammamiradio #1114 — auto-paused mid-churn with HEAD already reviewed. Skip until HEAD is unreviewed again.

Fair Usage: included reviews that **run** count; rate-limited attempts do not. Do not spam `@coderabbitai rate limit` in shadow.

## Kill switches

Either one disables the dispatcher (enforced in `coderabbit-dispatch-remote.sh`, not only the workflow `if:`):

- delete `.github/coderabbit-dispatch.enabled`
- set repository variable `CODERABBIT_DISPATCH` to literal `0`

## Budget signal

Parse CodeRabbit PR comment / review footers (`N reviews currently available`, `allowance at X per hour`, `N included PR review attempts over the past 7 days`). There is no Team quota API. If the 7-day count cannot be read → no `WOULD_REVIEW`.

Do not request a review just because hourly remaining > 0.

**Carry-forward window (24h).** CodeRabbit posts two footer shapes and only one carries the 7-day integer — the mammamiradio #1114 shape reads *"Your included PR review attempts over the past 7 days set your current allowance at 5 reviews per hour"*, with no number. Taking the newest budget-bearing comment wholesale therefore meant one count-less footer anywhere in the fleet pinned every later tick to `BUDGET_HELD` and the ranking never ran at all. So: hourly remaining and allowance come from the newest footer, and the 7-day integer comes from the newest footer **that actually carried one**, provided it is at most 24h older. Outside that window, or with unparseable timestamps, the count stays unknown and the job holds. A carried count is labelled with its age in the summary and is held against the same ceiling — it is a bounded relaxation of fail-closed, not a removal of it.

## Partial data

Per-repo and per-PR reads are isolated. A 403, a timeout, or an archived repo with issues disabled skips that repo or PR and lands in a **Partial data** section of the summary; it does not abort the tick. Only the top-level `gh repo list` is fatal, since without it there is nothing to rank. Hitting the `gh repo list` limit exactly is reported as partial data rather than silently ranking a truncated fleet.

`GITHUB_TOKEN` is an installation token for this repo, so cross-repo reads reach **public** repos only. Private owned repos never appear in `gh repo list` and are silently out of scope — not an error the job can detect. Closing that gap is the same follow-up as the write path: a GitHub App installation token.

## Request budget

Comments and reviews cost two requests per PR, against every open PR on every owned repo. PRs are therefore dropped on the cheap pre-filter (fork allowlist, draft, Dependabot, GitHub App author, non-human) from the PR-list row **before** those requests are made, and pagination runs at `per_page=100`. Consequence, accepted: budget footers are harvested only from eligible PRs — which is where CodeRabbit posts them anyway, given `drafts: false` and the bot `ignore_usernames` in the shipped yaml.

## `.coderabbit.yaml`

`templates/.coderabbit.yaml` is the durable fleet copy (`auto_review.enabled: true`, `auto_incremental_review: false`, `auto_pause_after_reviewed_commits: 1`, `drafts: false`, bot `ignore_usernames`). Bootstrap installs it into a consumer **only when that repo has no unmarked hand-written file**. The `# BEGIN/END: engineering-standards-coderabbit` markers are a provenance stamp, not a section boundary: a stamped file is replaced wholesale on the next bootstrap run. Delete the `# BEGIN:` line to pin a repo's own copy.

The CodeRabbit **org dashboard** is the live kill for incrementals on mammamiradio today. An agent cannot click that UI. After the yaml lands, flip org UI (incrementals off, Dependabot ignored) so Fair Usage stops burning on every push. Yaml without the org click is not enough while org UI still has shotgun incrementals on.

Do not turn auto-review fully off. Do not add a label-only gate in this file — that would starve first reviews before org UI is clicked.

## Follow-up (not this change)

When shadow has run long enough to trust: GitHub App write path (label `review-ready` add as preferred retrigger; comment as fallback after a one-PR probe).
