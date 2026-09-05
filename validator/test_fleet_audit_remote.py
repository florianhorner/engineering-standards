#!/usr/bin/env python3
"""Offline CLI regressions for fleet-audit remediation eligibility."""

from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / "fleet-audit-remote.sh"
REPO = "florianhorner/audit-fixture"
UPSTREAM = "a" * 40
WORKFLOW = f"repos/{REPO}/contents/.github/workflows/commit-lint.yml"
META = f"repos/{REPO}/contents/.config/commit-rules.meta.json"
ROOT_CONTENTS = f"repos/{REPO}/contents"

# This executable has no network path: every response comes from the fixture.
# Support the old --jq reads too, so the same tests can prove the regression.
FAKE_GH = r'''
import base64, json, os, sys
from pathlib import Path

args = sys.argv[1:]
fixture = json.loads(Path(os.environ["AUDIT_FIXTURE"]).read_text())
with open(os.environ["AUDIT_CALLS"], "a") as log:
    log.write(json.dumps(args) + "\n")
if args[:2] == ["repo", "list"]:
    print(fixture.get("inventory_raw", json.dumps(fixture["repos"])))
    sys.exit(0)
if args[:2] == ["api", "repos/florianhorner/engineering-standards/commits/main"]:
    print("a" * 40)
    sys.exit(0)
if args[0] != "api":
    sys.exit("unexpected gh call: " + repr(args))
response = fixture["responses"].get(args[1], {"status": 404, "body": {"message": "Not Found"}})
status = response["status"]
if status == 0:
    sys.exit("simulated transport failure")
body = response.get("raw", json.dumps(response.get("body")))
if "--include" in args:
    sys.stdout.write(f"HTTP/2.0 {status} Test\r\nContent-Type: application/json\r\n\r\n")
if status == 200 and "--jq" in args:
    payload = response.get("body", {})
    body = payload.get("content", "") if isinstance(payload, dict) else ""
sys.stdout.write(body)
sys.exit(0 if status == 200 else 1)
'''


def file_response(text: str) -> dict:
    return {
        "status": 200,
        "body": {
            "type": "file",
            "encoding": "base64",
            "content": base64.b64encode(text.encode()).decode(),
        },
    }


class FleetAuditRemoteTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-audit-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.report = self.directory / "fleet-audit.json"
        self.calls = self.directory / "calls.jsonl"
        self.fixture = {
            "repos": [{"nameWithOwner": REPO, "isFork": False, "isArchived": False}],
            "responses": {
                WORKFLOW: file_response("name: commit-lint\non: push\n"),
                META: file_response(json.dumps({"sha_pin": UPSTREAM})),
                ROOT_CONTENTS: {"status": 200, "body": []},
            },
        }
        fake = self.directory / "gh"
        fake.write_text(f"#!{sys.executable}\n" + FAKE_GH)
        fake.chmod(0o755)

    def run_audit(self, args: list[str] | None = None) -> subprocess.CompletedProcess:
        fixture_path = self.directory / "fixture.json"
        fixture_path.write_text(json.dumps(self.fixture))
        env = os.environ.copy()
        for key in ("GH_TOKEN", "GITHUB_TOKEN", "GITHUB_STEP_SUMMARY", "BASH_ENV", "ENV"):
            env.pop(key, None)
        env.update(
            PATH=f"{self.directory}{os.pathsep}{env['PATH']}",
            AUDIT_FIXTURE=str(fixture_path),
            AUDIT_CALLS=str(self.calls),
            GITHUB_REPOSITORY="florianhorner/engineering-standards",
        )
        return subprocess.run(
            ["bash", str(SCRIPT), *(args if args is not None else ["--json", str(self.report)])],
            cwd=self.directory, env=env, text=True, capture_output=True, timeout=10,
        )

    def assert_aborts_without_report(self) -> None:
        result = self.run_audit(["--json", str(self.report), "--github-issue"])
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.report.exists(), "uncertain audit emitted a remediation artifact")
        self.assertEqual(result.stdout, "", "uncertain audit published a markdown report")
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertFalse(any(call[0] in ("issue", "label") for call in calls))

    def test_classification_matrix(self) -> None:
        for fork in (False, True):
            for state in ("FRESH", "STALE", "missing_workflow", "missing_meta"):
                with self.subTest(fork=fork, state=state):
                    self.fixture["repos"][0]["isFork"] = fork
                    self.fixture["responses"][WORKFLOW] = file_response("name: commit-lint\n")
                    self.fixture["responses"][META] = file_response(json.dumps({
                        "sha_pin": "b" * 40 if state == "STALE" else UPSTREAM,
                    }))
                    if state.startswith("missing"):
                        path = WORKFLOW if state == "missing_workflow" else META
                        self.fixture["responses"][path] = {"status": 404, "body": {"message": "Not Found"}}
                    result = self.run_audit()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    report = json.loads(self.report.read_text())
                    row = report["repos"][0]
                    self.assertEqual(row["bucket"], "OWN-FORK" if fork else "OWN")
                    self.assertTrue(row["status"].startswith("MISSING" if state.startswith("missing") else state))
                    self.assertEqual(row["remediable"], not fork and state.startswith("missing"))
                    self.assertEqual(report["summary"]["remediable"], int(row["remediable"]))

    def test_archived_repos_are_not_read_or_reported(self) -> None:
        self.fixture["repos"][0]["isArchived"] = True
        result = self.run_audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.report.read_text())["repos"], [])
        self.assertNotIn(REPO, self.calls.read_text())

    def test_read_errors_never_become_missing(self) -> None:
        for path in (WORKFLOW, META):
            original = self.fixture["responses"][path]
            for status in (403, 429, 500, 0):
                with self.subTest(path=path, status=status):
                    self.fixture["responses"][path] = {"status": status, "body": {"message": "failure"}}
                    self.assert_aborts_without_report()
            self.fixture["responses"][path] = original

    def test_404_requires_confirmed_contents_access(self) -> None:
        self.fixture["responses"][WORKFLOW] = {"status": 404, "body": {"message": "Not Found"}}
        for response in (
            {"status": 403}, {"status": 404}, {"status": 500},
            {"status": 200, "raw": "not json"},
            {"status": 200, "body": {"message": "not a directory listing"}},
        ):
            with self.subTest(response=response):
                self.fixture["responses"][ROOT_CONTENTS] = response
                self.assert_aborts_without_report()

    def test_invalid_file_payloads_abort(self) -> None:
        for response in (
            {"status": 200, "raw": "not json"},
            {"status": 200, "body": []},
            {"status": 200, "body": {"type": "file", "encoding": "base64", "content": "%%%"}},
            {"status": 200, "body": {"type": "file", "encoding": "none", "content": ""}},
            file_response(""),
        ):
            with self.subTest(response=response):
                self.fixture["responses"][WORKFLOW] = response
                self.assert_aborts_without_report()

    def test_malformed_metadata_aborts(self) -> None:
        for meta in ("{", "[]", "{}", '{"sha_pin":null}', '{"sha_pin":42}', '{"sha_pin":""}', '{"sha_pin":"short"}'):
            with self.subTest(meta=meta):
                self.fixture["responses"][META] = file_response(meta)
                self.assert_aborts_without_report()

    def test_malformed_inventory_aborts(self) -> None:
        for raw in ("{", "{}", '[{}]', '[{"nameWithOwner":"other/repo","isFork":false,"isArchived":false}]'):
            with self.subTest(raw=raw):
                self.fixture["inventory_raw"] = raw
                self.assert_aborts_without_report()

    def test_json_does_not_pollute_markdown_stdout(self) -> None:
        markdown = self.run_audit([])
        artifact = self.run_audit()
        self.assertEqual(markdown.returncode, 0, markdown.stderr)
        self.assertEqual(artifact.returncode, 0, artifact.stderr)
        self.assertEqual(markdown.stdout, artifact.stdout)
        self.assertNotIn("Wrote", artifact.stdout)
        self.assertIn("Wrote", artifact.stderr)

    def test_json_equals_accepts_a_path_with_spaces(self) -> None:
        path = self.directory / "audit with spaces.json"
        result = self.run_audit([f"--json={path}"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(path.read_text())["summary"]["total"], 1)

    def test_invalid_json_paths_fail_before_api_calls(self) -> None:
        for args in (["--json="], ["--json"], ["--json", ""], ["--json", "."]):
            with self.subTest(args=args):
                result = self.run_audit(args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
