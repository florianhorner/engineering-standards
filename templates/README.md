# Templates

Bootstrap now generates a fixed minimal CI caller and two installation metadata
files directly. It does not download or automatically copy these templates.

`per-repo-commit-lint.yml` remains a reference caller. Replace its SHA placeholder
with a reviewed full commit SHA before use.

The contributor and author-note templates contain optional public contribution
guidance. Review them for the receiving repository before copying. The legacy
commitlint, Dependabot and CodeRabbit templates are separate opt-in configurations;
bootstrap neither installs nor refreshes them.

## Optional CodeRabbit setup

For an explicitly approved repository, separately confirm that the CodeRabbit
GitHub App is authorized to review that repository. Bootstrap does not install or
authorize the App.

On a clean feature branch, create `.coderabbit.yaml` using only the `reviews:`
mapping from the [reference configuration](.coderabbit.yaml). Review the settings
for that repository and omit template comments and operational notes. If a
configuration already exists, merge the selected settings into it; do not replace
the file wholesale. Review the diff and obtain publication approval before pushing.

Verify `reviews.auto_review.enabled: true` for automatic first reviews, with
incrementals disabled, drafts excluded, and bot authors including Dependabot
ignored. Check organization dashboard defaults and effective repository settings
as well. See the [automatic review controls](https://docs.coderabbit.ai/configuration/auto-review)
for the setting definitions. Do not disable auto-review or introduce a label-only
gate. No live setting is implied by this reference or by bootstrap completion.

Changing a template here does not update any consumer. Existing generated copies
and old public history require a separate migration or cleanup.
