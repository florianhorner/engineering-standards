#!/usr/bin/env python3
"""Regression tests for hostile commitlint output rendering."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import sanitize_output


SANITIZER = Path(__file__).with_name("sanitize_output.py")


class SanitizeOutputTest(unittest.TestCase):
    def test_prefixes_hostile_lines_and_removes_terminal_controls(self) -> None:
        hostile = (
            b"::error file=x,line=1::forged\n"
            b"apostrophe ' backtick ` expression ${{ github.token }}\n"
            b"\x1b[31mred\x1b[0m\rrewrite\x00tail\n"
            + "bidi \u202e isolate \u2066\n".encode("utf-8")
        )

        rendered = sanitize_output.sanitize(hostile)

        self.assertLessEqual(len(rendered), sanitize_output.MAX_OUTPUT_BYTES)
        self.assertNotIn(b"\x1b", rendered)
        self.assertNotIn(b"\x00", rendered)
        self.assertNotIn("\u202e".encode("utf-8"), rendered)
        self.assertNotIn("\u2066".encode("utf-8"), rendered)
        self.assertIn(b"apostrophe ' backtick ` expression ${{ github.token }}", rendered)
        for line in rendered.splitlines():
            self.assertTrue(line.startswith(b"commitlint | "), line)
            self.assertFalse(line.startswith(b"::"), line)

    def test_caps_large_and_invalid_utf8_output(self) -> None:
        hostile = b"\xff" + (b"x" * (sanitize_output.MAX_INPUT_BYTES * 2))

        rendered = sanitize_output.sanitize(hostile)

        self.assertLessEqual(len(rendered), sanitize_output.MAX_OUTPUT_BYTES)
        self.assertIn(sanitize_output.TRUNCATED.encode(), rendered)
        self.assertTrue(rendered.startswith(b"commitlint | "))

    def test_cli_sanitizes_stdin_and_reports_truncation(self) -> None:
        result = subprocess.run(
            [sys.executable, "-I", str(SANITIZER), "-"],
            input=b"::warning::forged\n" + (b"x" * sanitize_output.MAX_INPUT_BYTES),
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith(b"commitlint | "))
        self.assertNotIn(b"\n::warning", result.stdout)
        self.assertIn(sanitize_output.TRUNCATED.encode(), result.stdout)

    def test_cli_accepts_a_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output_file = Path(directory) / "commitlint.log"
            output_file.write_bytes(b"\x1b[31merror\x1b[0m\n")

            result = subprocess.run(
                [sys.executable, "-I", str(SANITIZER), str(output_file)],
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"commitlint | error\n")

    def test_cli_rejects_a_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "target.log"
            target.write_text("safe", encoding="utf-8")
            link = Path(directory) / "link.log"
            link.symlink_to(target)

            result = subprocess.run(
                [sys.executable, "-I", str(SANITIZER), str(link)],
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"must be a regular file", result.stderr)

    def test_cli_rejects_missing_arguments_and_files(self) -> None:
        missing_argument = subprocess.run(
            [sys.executable, "-I", str(SANITIZER)],
            capture_output=True,
            check=False,
        )
        missing_file = subprocess.run(
            [sys.executable, "-I", str(SANITIZER), "/definitely/missing/output.log"],
            capture_output=True,
            check=False,
        )

        self.assertEqual(missing_argument.returncode, 2)
        self.assertIn(b"usage:", missing_argument.stderr)
        self.assertEqual(missing_file.returncode, 2)
        self.assertIn(b"output is unavailable", missing_file.stderr)


if __name__ == "__main__":
    unittest.main()
