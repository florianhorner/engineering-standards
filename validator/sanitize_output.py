#!/usr/bin/env python3
"""Bound and neutralize untrusted validator output before GitHub logs it."""

from __future__ import annotations

import os
import re
import stat
import sys
import unicodedata
from pathlib import Path


MAX_INPUT_BYTES = 65_536
MAX_OUTPUT_BYTES = 16_384
PREFIX = "commitlint | "
TRUNCATED = "[output truncated]"
ANSI_ESCAPE_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-_])")


def _clean_line(line: str) -> str:
    without_ansi = ANSI_ESCAPE_RE.sub("", line)
    return "".join(
        character
        if ord(character) >= 32
        and not 127 <= ord(character) <= 159
        and unicodedata.category(character) not in {"Cc", "Cf", "Cs"}
        else "�"
        for character in without_ansi
    )


def sanitize(data: bytes, *, already_truncated: bool = False) -> bytes:
    """Return prefixed UTF-8 text with controls removed and a hard byte cap."""
    input_truncated = already_truncated or len(data) > MAX_INPUT_BYTES
    text = data[:MAX_INPUT_BYTES].decode("utf-8", errors="replace")
    output = bytearray()
    truncated = input_truncated

    for line in text.splitlines():
        encoded = f"{PREFIX}{_clean_line(line)}\n".encode("utf-8")
        if len(output) + len(encoded) > MAX_OUTPUT_BYTES:
            truncated = True
            break
        output.extend(encoded)

    if truncated:
        marker = f"{PREFIX}{TRUNCATED}\n".encode("utf-8")
        if len(output) + len(marker) <= MAX_OUTPUT_BYTES:
            output.extend(marker)
        elif len(marker) <= MAX_OUTPUT_BYTES:
            output = bytearray(marker)

    return bytes(output)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: sanitize_output.py <regular-file-or-stdin-dash>", file=sys.stderr)
        return 2

    if argv[1] == "-":
        handle = sys.stdin.buffer
        data = handle.read(MAX_INPUT_BYTES + 1)
        truncated = len(data) > MAX_INPUT_BYTES
        while handle.read(65_536):
            truncated = True
    else:
        path = Path(argv[1])
        try:
            mode = os.lstat(path).st_mode
        except OSError:
            print("commitlint output is unavailable", file=sys.stderr)
            return 2
        if not stat.S_ISREG(mode):
            print("commitlint output must be a regular file", file=sys.stderr)
            return 2
        with path.open("rb") as handle:
            data = handle.read(MAX_INPUT_BYTES + 1)
        truncated = len(data) > MAX_INPUT_BYTES

    sys.stdout.buffer.write(
        sanitize(data[:MAX_INPUT_BYTES], already_truncated=truncated)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
