## Commit messages

Use `type(scope): subject`, for example `fix(auth): reject expired sessions`.
Allowed types are `feat fix docs style refactor test chore ci build perf revert`.
Keep the subject at most 72 characters and omit a trailing period.

For a feature changing more than 50 lines, include a body line beginning with
`Why:` that explains the reason for the change. Describe the engineering result
and provide relevant test evidence.

The repository's pinned CI workflow defines the enforced policy. Installation
metadata does not substitute for local tooling or a successful CI run.
