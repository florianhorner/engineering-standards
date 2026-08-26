#!/usr/bin/env python3
"""Regression tests for hostile commitlint output rendering."""

from __future__ import annotations

import unittest

import sanitize_output


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


if __name__ == "__main__":
    unittest.main()
