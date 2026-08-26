#!/usr/bin/env python3
"""Static regressions for the reusable commit-policy workflow trust boundary."""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "commit-lint-reusable.yml"
CORPUS_WORKFLOW = ROOT / ".github" / "workflows" / "test-corpus.yml"


def job_block(text: str, job_name: str) -> str:
    marker = f"  {job_name}:\n"
    start = text.index(marker)
    remainder = text[start + len(marker) :]
    next_job = re.search(r"^  [a-zA-Z0-9_-]+:\s*$", remainder, re.MULTILINE)
    return remainder[: next_job.start()] if next_job else remainder


class WorkflowSecurityContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.corpus_workflow = CORPUS_WORKFLOW.read_text(encoding="utf-8")

    def test_validator_source_is_exact_workflow_identity(self) -> None:
        self.assertIn("repository: ${{ job.workflow_repository }}", self.workflow)
        self.assertIn("ref: ${{ job.workflow_sha }}", self.workflow)
        self.assertIn("EXPECTED_WORKFLOW_REPOSITORY: ${{ job.workflow_repository }}", self.workflow)
        self.assertIn("EXPECTED_WORKFLOW_REF: ${{ job.workflow_ref }}", self.workflow)
        self.assertIn("EXPECTED_WORKFLOW_SHA: ${{ job.workflow_sha }}", self.workflow)
        self.assertIn(
            "python3 -I trusted/validator/verify_workflow_identity.py",
            self.workflow,
        )
        self.assertNotIn("ENGSTD_REF", self.workflow)
        self.assertNotRegex(self.workflow, r"(?m)^\s*ref:\s*main\s*$")
        self.assertIn("ImageOS", self.workflow)
        self.assertIn("ImageVersion", self.workflow)

    def test_consumer_and_trusted_checkouts_are_sibling_directories(self) -> None:
        validate = job_block(self.workflow, "validate")
        self.assertIn("repository: ${{ github.repository }}", validate)
        self.assertIn("ref: ${{ github.sha }}", validate)
        self.assertIn("path: consumer", validate)
        self.assertIn("path: trusted", validate)
        self.assertNotIn("head.repo.full_name", validate)
        self.assertIn(
            'git merge-base --is-ancestor "$PR_HEAD_SHA" "$HEAD_SHA"',
            validate,
        )

    def test_all_remote_actions_are_full_sha_pinned(self) -> None:
        expected_actions = {
            "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",
            "actions/setup-node": "820762786026740c76f36085b0efc47a31fe5020",
            "actions/setup-python": "5fda3b95a4ea91299a34e894583c3862153e4b97",
        }
        for path, text in (
            (WORKFLOW, self.workflow),
            (CORPUS_WORKFLOW, self.corpus_workflow),
        ):
            for target in re.findall(r"(?m)^\s*uses:\s*([^\s#]+)", text):
                if target.startswith("./"):
                    continue
                self.assertIn("@", target, f"{path}: unpinned action {target}")
                ref = target.rsplit("@", 1)[1]
                action = target.rsplit("@", 1)[0]
                self.assertRegex(
                    ref,
                    r"^[0-9a-f]{40}$",
                    f"{path}: action ref is not a full SHA: {target}",
                )
                if action.startswith("actions/"):
                    self.assertIn(action, expected_actions, f"{path}: unexpected action")
                    self.assertEqual(ref, expected_actions[action], f"{path}: wrong action pin")
                else:
                    self.assertEqual(
                        action,
                        "florianhorner/engineering-standards/.github/workflows/commit-lint-reusable.yml",
                        f"{path}: unexpected reusable workflow",
                    )

    def test_validation_job_is_read_only_and_uses_trusted_toolchain(self) -> None:
        validate = job_block(self.workflow, "validate")
        self.assertIn("contents: read", validate)
        self.assertNotIn("pull-requests: write", validate)
        self.assertGreaterEqual(validate.count("persist-credentials: false"), 2)
        self.assertIn("working-directory: trusted", validate)
        self.assertIn("node-version: '24'", validate)
        self.assertIn("npm ci --ignore-scripts --no-audit --no-fund", validate)
        self.assertIn("NPM_CONFIG_USERCONFIG: /dev/null", validate)
        self.assertIn(
            "--config ../trusted/.commitlintrc.json", validate
        )
        self.assertIn(
            'RULES_FILE="$TRUSTED_ROOT/specs/commit-rules.json"',
            validate,
        )
        self.assertNotRegex(validate, r"(?m)^\s*cp\s+\.config/")
        self.assertNotIn('RULES_FILE=".config/commit-rules.json"', validate)
        self.assertNotRegex(validate, r"python3\s+-c\b")
        for command in re.findall(r"(?m)^\s*(python3[^\n]+)$", validate):
            self.assertTrue(command.startswith("python3 -I "), command)
        self.assertNotIn("git log -1 --format=%an", validate)
        self.assertIn('mktemp -d "${RUNNER_TEMP}/commit-policy.XXXXXX"', validate)
        self.assertNotIn(".ci-tmp", validate)
        self.assertIn(
            "| python3 -I ../trusted/validator/sanitize_output.py -",
            validate,
        )
        self.assertIn('PIPE_STATUSES=("${PIPESTATUS[@]}")', validate)
        self.assertNotRegex(validate, r"\bnpm install\b")
        self.assertNotRegex(validate, r"\bnpx\b")
        self.assertNotIn("commitlint.config.js", validate)

    def test_workflow_has_no_write_scoped_publisher(self) -> None:
        self.assertIn("permissions: {}", self.workflow.split("jobs:", 1)[0])
        self.assertNotRegex(self.workflow, r"(?m)^\s+[a-z-]+:\s*write\s*$")
        self.assertNotIn("publish-review", self.workflow)
        self.assertNotIn("pull-requests: write", self.workflow)
        self.assertNotRegex(self.workflow, r"(?m)^\s*GH_TOKEN:")
        self.assertNotRegex(self.workflow, r"(?m)^\s*gh pr ")

    def test_hosted_fixtures_use_exact_candidate_shas(self) -> None:
        expected = {
            "18282d55b7d945ad3d49941b784e9a3886a5a678",
            "1767592a5b49d7a1324e2fb2133349b0045c3f2d",
        }
        actual = set(
            re.findall(
                r"uses: florianhorner/engineering-standards/\.github/workflows/"
                r"commit-lint-reusable\.yml@([0-9a-f]{40})",
                self.corpus_workflow,
            )
        )
        self.assertEqual(actual, expected)
        verifier = job_block(
            self.corpus_workflow,
            "verify_immutable_workflow_fixtures",
        )
        self.assertIn("permissions: {}", verifier)
        self.assertIn(f'PRIMARY_SHA: ${{{{ needs.immutable_workflow_primary_fixture.outputs.workflow_sha }}}}', verifier)
        self.assertIn('test "$ROLLBACK_RESULT" = "success"', verifier)
        self.assertIn('test "$PRIMARY_RESULT" = "success"', verifier)
        self.assertIn(
            'test "$PRIMARY_SHA" = "1767592a5b49d7a1324e2fb2133349b0045c3f2d"',
            verifier,
        )

    def test_workflow_exports_verified_identity(self) -> None:
        for name in ("workflow_repository", "workflow_ref", "workflow_sha"):
            self.assertIn(f"{name}: ${{{{ steps.identity.outputs.{name} }}}}", self.workflow)
            self.assertIn(f'echo "{name}=$EXPECTED_WORKFLOW_', self.workflow)

    def test_commitlint_install_is_locked(self) -> None:
        package = json.loads((ROOT / "package.json").read_text(encoding="utf-8"))
        lock = json.loads((ROOT / "package-lock.json").read_text(encoding="utf-8"))
        expected = {
            "@commitlint/cli": "19.5.0",
            "@commitlint/config-conventional": "19.5.0",
        }
        self.assertEqual(package.get("devDependencies"), expected)
        self.assertEqual(lock["packages"][""]["devDependencies"], expected)


if __name__ == "__main__":
    unittest.main()
