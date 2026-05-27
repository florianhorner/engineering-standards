# engineering-standards

Florian's public engineering standards. Single source of truth for commit message hygiene, code review checklists, and contribution conventions across every repo and AI tool he uses (Claude Code, Conductor, Codex web, Claude Code Cloud, manual git push).

## What's here

- **[specs/commit-message-spec.md](specs/commit-message-spec.md)** — Conventional Commits + body-when-it-matters + agent-metadata trailers. 30-second cheat sheet at top.
- **[specs/commit-rules.json](specs/commit-rules.json)** — Machine-readable rules consumed by validator binary, commit-msg hook, and CI workflow.
- **[docs/commit-system-operator.md](docs/commit-system-operator.md)** — How to bootstrap a repo, normal flow, override flow, troubleshooting.
- **[.github/workflows/commit-lint-reusable.yml](.github/workflows/commit-lint-reusable.yml)** — Reusable workflow consumer repos call via `uses:`.
- **[validator/](validator/)** — Python hook generator (`generate-hook.py`) that emits the `commit-msg` hook from `specs/commit-rules.json`.
- **[templates/](templates/)** — Drop-in files the bootstrap script copies into consumer repos.

## Why a public repo

GitHub blocks public repos from calling reusable workflows in private repos without per-consumer PAT secrets. Florian's portfolio repos (lightener, mammamiradio, etc.) need to consume these workflows, so the canonical source must be public.

## Versioning

Rules and workflows are SHA-pinned by consumers. Breaking changes land as new rule_ids; existing rule_ids are immutable once shipped. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
