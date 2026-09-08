# Templates

Bootstrap now generates a fixed minimal CI caller and two installation metadata
files directly. It does not download or automatically copy these templates.

`per-repo-commit-lint.yml` remains a reference caller. Replace its SHA placeholder
with a reviewed full commit SHA before use.

The contributor and author-note templates contain optional public contribution
guidance. Review them for the receiving repository before copying. The legacy
commitlint, Dependabot and CodeRabbit templates are separate opt-in configurations;
bootstrap neither installs nor refreshes them.

Changing a template here does not update any consumer. Existing generated copies
and old public history require a separate migration or cleanup.
