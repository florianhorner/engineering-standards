# HA App Docs Contract

Drift-proof install-docs standard for Home Assistant app/add-on repositories.

## 30-second cheat sheet

Home Assistant renames its UI roughly every 6 months (Add-ons became Apps; "Install app"; the old "Settings > Add-ons > Add-on Store" path is gone). Hardcoded nav paths in READMEs rot, and a new user can't follow them. This contract lints for the durable pattern and against the known-stale wording.

- **Do:** write install nav paths as **My Home Assistant redirect badges** (`https://my.home-assistant.io/redirect/<slug>/`). Home Assistant keeps these pointing at the right page across renames.
- **Don't:** write literal stale nav prose — `Add-on Store`, `Settings > Add-ons`, `Hass.io`.
- **Machine-readable rules:** [`ha-app-docs-rules.json`](ha-app-docs-rules.json) (SSOT). Consumed by the linter, the action, and CI.
- **Run it:** `python3 actions/ha-app-docs-lint/ha_app_docs_lint.py README.md --profile addon`, or add the action (below).

## What it checks

1. **Install badge required** (`INSTALL_BADGE_REQUIRED`) — install docs must contain at least one `my.home-assistant.io/redirect/` link. The `addon` profile requires it; HACS profiles do not.
2. **Banned stale phrases** (`ADDON_STORE`, `SETTINGS_ADDONS`, `HASS_IO`) — literal wording Home Assistant has renamed. Only exact multi-word nav phrases are banned; bare words like "Supervisor" and "add-on" are **not** flagged (they carry non-nav meanings and were measured at ~100% false-positive as bare words).
3. **Repo-type profile markers** (`SECTION_MARKER`) — HACS profiles must carry a `<!-- contract:install-hacs -->` marker so the HACS install step is documented.

## Markdown-aware matching

The linter matches **rendered prose, not raw markdown source**. Before matching it skips fenced/inline code and strips markdown link/image URL targets (`](...)`). So a badge whose URL contains `supervisor_store`, or a stale phrase quoted inside a ```code fence```, never false-positives. Measured on 11 real repos: naive substring matching = ~45% false-positive; markdown-aware = ~0%. `CHANGELOG*` files are excluded entirely — stale phrases live there as legitimate history.

## Redirect badge

Use a badge per install step. Valid slugs (from Home Assistant's canonical `redirect.json`):

| Step | Slug |
|------|------|
| Open the app/add-on store | `supervisor_store` |
| Open a specific add-on | `supervisor_addon` |
| Add/configure the MQTT integration | `config_flow_start?domain=mqtt` / `config_mqtt` |
| Add dashboard resources / dashboards | `lovelace_resources` / `lovelace_dashboards` |
| Developer tools → states | `developer_states` |
| Integrations page | `integrations` |

**Two documented fallbacks (write these as plain text, not a badge):**

- **Add a repository** (`supervisor_add_addon_repository`) — the redirect is broken end-to-end on current Home Assistant ([my.home-assistant.io#698](https://github.com/home-assistant/my.home-assistant.io/issues/698), open since 2026-04): it drops the repository URL. For add-on repos this is the critical step, so the plain-text instruction ("Settings > Apps, store, three-dot menu > Repositories, paste the URL") is **canonical** until the upstream fix lands; the badge is optional there.
- **Generic HACS** — there is no generic "open HACS" slug (only `hacs_repository` for one named repo). Write "install via HACS" as plain text.

## Profiles

| Profile | Requires install badge | Required markers |
|---------|-----------------------|------------------|
| `addon` | yes | — |
| `hacs-integration` | no | `contract:install-hacs` |
| `hacs-frontend` | no | `contract:install-hacs` |

An add-on repo is **not** required to document HACS, and vice versa. Pick the profile that matches how the repo is actually installed.

## Known limitation (honest)

This is precision-first, not recall-complete. The phrase denylist catches known-stale wording; it will **not** catch every paraphrase, localized phrasing, or a stale instruction embedded in a screenshot. The drift protection is the **positive** rule — requiring a redirect badge — because that survives renames automatically. The denylist is a backstop, not a guarantee. When Home Assistant renames something new, add the phrase via a PR to `ha-app-docs-rules.json`.

## Consume the action

```yaml
# .github/workflows/docs.yml in your app repo
name: docs
on: [push, pull_request]
permissions:
  contents: read
jobs:
  ha-app-docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: florianhorner/engineering-standards/actions/ha-app-docs-lint@<tag-or-sha>
        with:
          profile: addon          # or hacs-integration / hacs-frontend
          paths: "README.md docs"
```

Pin `<tag-or-sha>` to an immutable tag or commit SHA, not a moving branch.

## Reference template

[`templates/ha-app-docs-README.template.md`](../templates/ha-app-docs-README.template.md) is a README that passes this contract (profile `addon`). CI asserts it stays conformant.

## Versioning

Rule_ids are immutable once shipped; a rename or new banned phrase lands as a NEW rule_id (same policy as the commit standard). See [CHANGELOG.md](../CHANGELOG.md).
