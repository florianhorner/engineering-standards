# Commit policy installation

Bootstrap prepares one explicitly selected consumer repository for commit-policy CI.
It requires Python 3.9+, Git, authenticated GitHub CLI access, and a reviewed full
40-character source commit SHA.

## Install

Use a clean, dedicated feature checkout belonging to the repository you intend to
change. The installer refuses main, master, the GitHub default branch (regardless
of its name), detached HEAD, dirty trees, unknown visibility, archived repositories,
forks, other owners, and an origin that does not match the explicit repository.

```bash
bash bootstrap-repo.sh /path/to/feature-checkout \
  --repo florianhorner/example \
  --ref <reviewed-40-character-commit-sha>
```

Public and private repositories receive exactly these files:

| File | Purpose |
|---|---|
| `.github/workflows/commit-lint.yml` | Read-only PR workflow pinned to the selected source SHA |
| `.config/commit-rules.json` | Minimal installation marker required by the existing reusable workflow |
| `.config/commit-rules.meta.json` | Source pin used by the inventory scripts |

The JSON files contain installation metadata, not executable or vendored rules.
Existing local tooling that expects the full policy must keep its own reviewed
policy installation. Bootstrap does not migrate that tooling.

Bootstrap never changes Git hooks, Git configuration, agent instructions,
Dependabot, CodeRabbit, contributor files, author notes, or proof logs. Those are
separate setup decisions. It does not commit, push, or open a pull request.

Review the generated diff before publication. A prepared caller is not proof that
CI ran or that branch protection requires the check.

## Refresh and migration

Only files bearing the minimal installer's managed marker can be refreshed.
Existing unmarked files are refused before any file is written. This deliberately
requires a separately reviewed migration for legacy installations, rather than
overwriting contributor work or old local-tool dependencies.

After committing a minimal installation locally, running again at the same SHA
produces no changes. Selecting another reviewed SHA updates the caller and both
metadata files together. Partial write failures restore previous file contents.
Do not run another writer in the same checkout during installation.

## Reusable workflow trust boundary

The consumer calls a workflow at an exact commit SHA. The reusable workflow checks
out consumer code as untrusted data and obtains its validator, rules, and locked
toolchain from its own verified source revision. Consumer metadata is not executed.
The existing hosted workflow fixtures verify the pinned workflow identities;
bootstrap unit tests verify the local installation boundaries.

## Inventory

`bash fleet-audit.sh` reports local origins against GitHub default branches.
It never installs anything; `--apply` exits with an error before scanning.

`bash fleet-audit-remote.sh` reports public repositories only. Private and unknown
visibility are excluded before fetching repository contents, including when the
report is destined for an Actions summary or a public issue. The local audit may
contain private inventory and must remain local.

MISSING means the expected installation files are absent. STALE means the recorded
source SHA differs from current main; this can follow an unrelated source commit.
Neither means the repository is unsafe or must adopt the policy. Decide whether
adoption is appropriate before changing a repository.

## Fleet remediation (two-phase)

Detection and remediation are deliberately split, and only detection is autonomous.

**Scope:** this audit checks commit-policy installation and pins, not project priorities, PR blockers, or next actions. It enumerates at most 200 repositories and reports only public ones, so a repository absent from the report is not evidence of compliance. No credential expansion is part of this workflow.

**Failed reads are not missing files.** HTTP 403/429/5xx, transport failures, invalid file responses, malformed inventories, and invalid `sha_pin` metadata stop the audit with a nonzero exit before a new JSON report or issue is published. Only a file-level 404 followed by a successful root contents listing establishes absence. This keeps access failures out of the `remediable` target set. Consumers must require a successful audit run; an older artifact is not a substitute for a failed run.

| Phase | Runs as | Cadence | Writes |
|---|---|---|---|
| 1, detect | `fleet-audit-monthly.yml` (GitHub Actions) | monthly, 08:07 UTC on the 1st | issue in this repo plus the `fleet-audit-report` artifact |
| 2, remediate | Claude Code cloud routine, **poke-only** (no schedule) | only when a human fires it | draft PRs in downstream repos |

**Why phase 2 has no schedule.** It is the phase with push access to repos outside this one. Leaving it unscheduled means the unattended monthly job stays read-only, and every cross-repo write traces back to a person firing the routine. Fire it from the Routines list, or with `fire_trigger` from a session.

**Why phase 2 reads the artifact, not the issue.** The monthly report reaches the issue as a body plus follow-up comments, and comments are writable by anyone who can comment on the repo. An agent that parsed that thread to decide which repos to push to would be taking its target list from an attacker-writable surface. `fleet-audit.json`, uploaded as a workflow-run artifact, is written only by the workflow and is immutable once the run finishes.

**Why the eligibility flag lives in the script.** `fleet-audit-remote.sh --json` decides `remediable` per repo: OWN plus MISSING only. OWN-FORK is never auto-remediated (author notes and upstream-tracking concerns need a human on the diff), STALE is never auto-remediated for any bucket (a SHA-pin refresh changes what CI enforces), archived repos never enter the report. The script is the only place that policy is written down, so the consuming agent filters on a boolean instead of interpreting prose, and a prompt-injection attempt cannot argue its way into a different target set.

A `remediable` row is an eligibility flag, never an instruction to install. Adoption stays a per-repository decision, and installation still runs through one explicitly selected feature checkout.

Remaining guardrails, which do not depend on the agent behaving:

- Draft PRs only, never merge, never enable auto-merge.
- Branch protection with required review on downstream repos, the backstop if everything above fails.
- `add_repo` re-authorizes per call, so the routine cannot reach repos outside the account's granted set even if its instructions are subverted.

```bash
# Reproduce phase 1 locally (needs gh auth):
bash fleet-audit-remote.sh --json fleet-audit.json
python3 -c "import json;d=json.load(open('fleet-audit.json'));print(d['summary'])"
```
