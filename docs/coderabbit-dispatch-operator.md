# CodeRabbit leftover dispatcher — operator manual

How to enable, disable, and read the hourly job in this repo. Product contract: [`../specs/coderabbit-dispatch-spec.md`](../specs/coderabbit-dispatch-spec.md).

## Enable

Both are required:

1. File `.github/coderabbit-dispatch.enabled` present (already on `main`)
2. Repository **variable** (not a secret) `CODERABBIT_DISPATCH=1` at
   https://github.com/florianhorner/engineering-standards/settings/variables/actions

An unset or empty variable skips the Actions job: the workflow `if:` is
`vars.CODERABBIT_DISPATCH != '0'`, and GitHub treats missing as `0`. The
script would treat unset as on, but checkout never runs.

## Disable

Either:

- delete `.github/coderabbit-dispatch.enabled`, or
- set `CODERABBIT_DISPATCH` to literal `0`

Both are enforced in `coderabbit-dispatch-remote.sh`, not only the workflow `if:`.

## Job

- Workflow: [CodeRabbit dispatch (shadow)](https://github.com/florianhorner/engineering-standards/actions/workflows/coderabbit-dispatch-hourly.yml)
- Schedule: `7 * * * *` UTC, plus `workflow_dispatch`
- Output: job summary only (report-only; no comments, labels, or writes)

`DISABLED` in the summary means a kill switch is on. Other summary lines are the ranker output for that tick.

## Config files

`templates/.coderabbit.yaml` is an optional reference. Bootstrap does not copy or refresh it. Installation steps: [`templates/README.md`](../templates/README.md#optional-coderabbit-setup).

Org-level YAML is edited at https://app.coderabbit.ai (Organization Settings → YAML Editor → Apply). A repo uses that YAML only when it is set to use organization settings.

## Local

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
bash coderabbit-dispatch-remote.sh   # needs gh; report-only
```
