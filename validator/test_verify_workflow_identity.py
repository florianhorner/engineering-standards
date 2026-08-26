#!/usr/bin/env python3
"""Behavior tests for immutable reusable-workflow identity verification."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

import verify_workflow_identity


REPOSITORY = "florianhorner/engineering-standards"
SHA = "a" * 40
WORKFLOW_REF = (
    f"{REPOSITORY}/.github/workflows/commit-lint-reusable.yml@{SHA}"
)
VERIFIER = Path(__file__).with_name("verify_workflow_identity.py")


class VerifyWorkflowIdentityTest(unittest.TestCase):
    def test_accepts_https_and_ssh_origins_at_the_exact_sha(self) -> None:
        for origin in (
            f"https://github.com/{REPOSITORY}.git",
            f"git@github.com:{REPOSITORY}.git",
        ):
            with self.subTest(origin=origin):
                verify_workflow_identity.verify_identity(
                    REPOSITORY,
                    WORKFLOW_REF,
                    SHA,
                    origin,
                    SHA,
                )

    def test_rejects_every_identity_mismatch(self) -> None:
        cases = {
            "invalid repository": (
                "../engineering-standards",
                WORKFLOW_REF,
                SHA,
                f"https://github.com/{REPOSITORY}.git",
                SHA,
                "Invalid reusable-workflow repository identity.",
            ),
            "mutable caller ref": (
                REPOSITORY,
                f"{REPOSITORY}/.github/workflows/commit-lint-reusable.yml@main",
                SHA,
                f"https://github.com/{REPOSITORY}.git",
                SHA,
                "must be called with its exact 40-hex SHA.",
            ),
            "invalid sha": (
                REPOSITORY,
                WORKFLOW_REF,
                "main",
                f"https://github.com/{REPOSITORY}.git",
                SHA,
                "SHA is not an immutable 40-hex revision.",
            ),
            "unsupported origin": (
                REPOSITORY,
                WORKFLOW_REF,
                SHA,
                f"ssh://github.com/{REPOSITORY}.git",
                SHA,
                "checkout origin mismatch.",
            ),
            "wrong repository": (
                REPOSITORY,
                WORKFLOW_REF,
                SHA,
                "https://github.com/attacker/engineering-standards.git",
                SHA,
                "checkout origin mismatch.",
            ),
            "wrong checkout sha": (
                REPOSITORY,
                WORKFLOW_REF,
                SHA,
                f"https://github.com/{REPOSITORY}.git",
                "b" * 40,
                "checkout SHA mismatch.",
            ),
        }

        for name, (*arguments, message) in cases.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(
                    verify_workflow_identity.IdentityError,
                    message,
                ):
                    verify_workflow_identity.verify_identity(*arguments)

    def test_cli_fails_closed_on_bad_arguments(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", str(VERIFIER)],
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn(b"usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
