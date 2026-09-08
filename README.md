# engineering-standards

Florian's public engineering standards. Single source of truth for commit message hygiene, Home Assistant app install-docs, code review checklists, and contribution conventions across every repo and AI tool he uses (Claude Code, Conductor, Codex web, Claude Code Cloud, manual git push).

## What's here

- **[specs/commit-message-spec.md](specs/commit-message-spec.md)** — Conventional Commits + body-when-it-matters + agent-metadata trailers. 30-second cheat sheet at top.
- **[specs/commit-rules.json](specs/commit-rules.json)** — Machine-readable rules consumed by the hook generator and by the exact reusable-workflow revision each consumer pins.
- **[docs/commit-system-operator.md](docs/commit-system-operator.md)** — How to bootstrap a repo, normal flow, override flow, troubleshooting.
- **[.github/workflows/commit-lint-reusable.yml](.github/workflows/commit-lint-reusable.yml)** — Content-addressed, read-only reusable workflow consumer repos call via an exact-SHA `uses:` pin.
- **[validator/](validator/)** — Python hook generator (`generate-hook.py`) that emits the `commit-msg` hook from `specs/commit-rules.json`.
- **[templates/](templates/)** — Drop-in files the bootstrap script copies into consumer repos, including the CodeRabbit auto-review yaml (first review on, incrementals off).
- **[specs/coderabbit-dispatch-spec.md](specs/coderabbit-dispatch-spec.md)** — Shadow leftover dispatcher: at most one later CodeRabbit review per hour when the 7-day included count is known and under 35.

### HA app docs standard

- **[specs/ha-app-docs-contract.md](specs/ha-app-docs-contract.md)** — Drift-proof install-docs standard for Home Assistant app/add-on repos: require My Home Assistant redirect badges, ban stale nav wording (`Add-on Store`, `Settings > Add-ons`, `Hass.io`).
- **[specs/ha-app-docs-rules.json](specs/ha-app-docs-rules.json)** — Machine-readable rules (SSOT) consumed by the linter, action, and CI.
- **[actions/ha-app-docs-lint/](actions/ha-app-docs-lint/)** — Reusable GitHub Action + markdown-aware Python linter. Consumers add one `uses:` step. Repo-type profiles: `addon` / `hacs-integration` / `hacs-frontend`.

## Fleet-wide audits

**[fleet-audit.sh](fleet-audit.sh)** answers "is the whole fleet actually in sync," not just one repo. `bootstrap-repo.sh` makes a single repo compliant; `fleet-audit.sh` walks every local checkout under `~/repos` and `~/conductor/workspaces`, dedupes by origin remote (so N Conductor worktrees of the same repo count once), and classifies each unique repo:

- `THIRD-PARTY-CLONE` — origin owner isn't `florianhorner` (e.g. a local clone of someone else's project). Never touched.
- `OWN` / `OWN-FORK` — owned by `florianhorner`, checked against the commit-message-standards system: `MISSING` (no `.github/workflows/commit-lint.yml`), `STALE(<N>d)` (SHA pin behind upstream `main`, age from the repo's own `.config/commit-rules.meta.json`), or `FRESH`.

```bash
# Dry-run: print the compliance table, write nothing.
bash fleet-audit.sh

# Apply: also auto-bootstrap every OWN repo classified MISSING.
# STALE (any bucket), OWN-FORK (any status), and THIRD-PARTY-CLONE are never
# auto-applied — the script prints the exact bootstrap-repo.sh command to run
# by hand instead.
bash fleet-audit.sh --apply
```

**Convention:** since there's no single canonical repo-creation entrypoint to hook this into automatically yet, run `fleet-audit.sh --apply` manually right after `gh repo create` for any brand-new repo.

## CodeRabbit leftover dispatcher (shadow)

Team Fair Usage is per developer and does not bank unused hourly slots. Shotgun auto-incrementals on every push burn the 7-day window; other repos starve. This repo hosts a **central, report-only** hourly job that ranks at most one later review across Florian's owned non-forks plus allowlisted forks (`lightener-studio`, `govee2mqtt-extended`).

- First reviews stay automatic via CodeRabbit (`reviews.auto_review.enabled: true`). Incrementals are not automatic.
- Shadow only: job summary. No comments, no labels, no GitHub App, no writes to other repos, no hourly issues.
- 7-day ceiling 35 included reviews; fail closed if the count cannot be read. Does not spend leftover hourly slots just because they exist.
- CodeRabbit's newest footer sometimes omits the 7-day integer, so the count is carried forward from the newest footer that had one, within a 24h window and labelled with its age. Outside the window the job holds.
- Per-repo and per-PR read failures are isolated and reported under **Partial data**; one 403 or stalled `gh` call does not abort the tick.
- Kill switches: delete `.github/coderabbit-dispatch.enabled`, or set repository variable `CODERABBIT_DISPATCH` to literal `0`.

**[specs/coderabbit-dispatch-spec.md](specs/coderabbit-dispatch-spec.md)** is the locked product. Run `bash coderabbit-dispatch-remote.sh` (needs `gh`). Tests: `python3 -m unittest discover -s tests -p 'test_*.py'`.

`templates/.coderabbit.yaml` is the durable fleet copy (incrementals off, Dependabot ignored, drafts off, first review still on). Bootstrap installs it into a consumer when that repo has no unmarked hand-written file. **The CodeRabbit org dashboard is the live kill for incrementals on mammamiradio today** — an agent cannot click that UI. Yaml without the org click is not enough while org UI still has shotgun incrementals on. Do not turn auto-review fully off and do not add a label-only gate that would starve first reviews.

## Why a public repo

GitHub blocks public repos from calling reusable workflows in private repos without per-consumer PAT secrets. Florian's portfolio repos (lightener, mammamiradio, etc.) need to consume these workflows, so the canonical source must be public.

## Versioning

Rules and workflows are SHA-pinned by consumers. Breaking changes land as new rule_ids; existing rule_ids are immutable once shipped. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See [LICENSE](LICENSE).
