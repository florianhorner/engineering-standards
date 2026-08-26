#!/usr/bin/env python3
"""Verify that a reusable workflow was called and checked out by exact SHA."""

from __future__ import annotations

import re
import sys


REPOSITORY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
WORKFLOW_PATH = ".github/workflows/commit-lint-reusable.yml"


class IdentityError(ValueError):
    """A safe, user-facing immutable-workflow identity failure."""


def is_repository(value: str) -> bool:
    """Return whether value is a canonical GitHub owner/repository name."""
    return bool(REPOSITORY_RE.fullmatch(value)) and value.rsplit("/", 1)[1] not in {
        ".",
        "..",
    }


def repository_from_origin(origin: str) -> str:
    """Return owner/repository for a supported GitHub checkout origin."""
    prefixes = ("https://github.com/", "git@github.com:")
    for prefix in prefixes:
        if origin.startswith(prefix):
            repository = origin.removeprefix(prefix).removesuffix(".git")
            if is_repository(repository):
                return repository
            break
    raise IdentityError("Reusable-workflow checkout origin mismatch.")


def verify_identity(
    expected_repository: str,
    expected_ref: str,
    expected_sha: str,
    actual_origin: str,
    actual_sha: str,
) -> None:
    """Raise IdentityError unless caller context and checkout are identical."""
    if not is_repository(expected_repository):
        raise IdentityError("Invalid reusable-workflow repository identity.")
    if not SHA_RE.fullmatch(expected_sha):
        raise IdentityError(
            "Reusable-workflow SHA is not an immutable 40-hex revision."
        )

    required_ref = f"{expected_repository}/{WORKFLOW_PATH}@{expected_sha}"
    if expected_ref != required_ref:
        raise IdentityError(
            "Reusable workflow must be called with its exact 40-hex SHA."
        )
    if repository_from_origin(actual_origin) != expected_repository:
        raise IdentityError("Reusable-workflow checkout origin mismatch.")
    if actual_sha != expected_sha:
        raise IdentityError("Reusable-workflow checkout SHA mismatch.")


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print(
            "usage: verify_workflow_identity.py "
            "<repository> <workflow-ref> <workflow-sha> <origin> <checkout-sha>",
            file=sys.stderr,
        )
        return 2

    try:
        verify_identity(*argv[1:])
    except IdentityError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
