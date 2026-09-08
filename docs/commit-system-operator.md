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
