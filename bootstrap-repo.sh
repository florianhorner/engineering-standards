#!/usr/bin/env bash
# Install minimal CI configuration on one explicitly selected feature branch.
# Embedded Python keeps the downloaded script self-contained.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SOURCE = "florianhorner/engineering-standards"
OWNER = "florianhorner"
WORKFLOW = ".github/workflows/commit-lint.yml"
RULES = ".config/commit-rules.json"
META = ".config/commit-rules.meta.json"
MANAGED = "engineering-standards-minimal-v1"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    if result.returncode:
        # Never relay credential-bearing remotes or arbitrary API error bodies.
        raise ValueError(f"{args[0]} read failed; verify repository access")
    return result.stdout.strip()


def current_branch():
    result = subprocess.run(
        ["git", "symbolic-ref", "--quiet", "--short", "HEAD"],
        capture_output=True, text=True, check=False)
    if result.returncode == 1:
        return None  # Detached HEAD is a local branch state, not an access failure.
    if result.returncode:
        raise ValueError("Could not read current branch")
    return result.stdout.strip()


def safe_path(root, relative):
    candidate = root / relative
    for part in (candidate, *candidate.parents):
        if part == root:
            break
        if part.is_symlink():
            raise ValueError(f"Symlink in destination: {relative}")
    if candidate.exists() and not candidate.is_file():
        raise ValueError(f"Destination is not a regular file: {relative}")
    return candidate


def payload(sha):
    workflow = (
        f"# Managed by {MANAGED}\n"
        "name: commit-lint\n\non:\n  pull_request:\n"
        "    types: [opened, reopened, synchronize, edited]\n\n"
        "permissions:\n  contents: read\n\njobs:\n  commit-lint:\n"
        f"    uses: {SOURCE}/.github/workflows/commit-lint-reusable.yml@{sha}\n"
    )
    # CI requires this path to exist but executes its own trusted policy.
    # Never copy the full policy's prose or telemetry into consumer repositories.
    metadata = {"managed_by": MANAGED, "sha_pin": sha,
                "policy_source": SOURCE, "mode": "ci-only"}
    encoded = json.dumps(metadata, indent=2) + "\n"
    return {WORKFLOW: workflow, RULES: encoded, META: encoded}


def install(root, files):
    destinations = {name: safe_path(root, name) for name in files}
    for name, dest in destinations.items():
        if dest.exists():
            old = dest.read_text(encoding="utf-8")
            if name == WORKFLOW:
                managed = old.startswith(f"# Managed by {MANAGED}\n")
            else:
                try:
                    managed = json.loads(old).get("managed_by") == MANAGED
                except (ValueError, AttributeError):
                    managed = False
            if not managed:
                raise ValueError(f"Existing unmanaged file: {name}; review migration separately")
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", "--", name], cwd=root,
            capture_output=True, check=False)
        if ignored.returncode == 0:
            raise ValueError(f"Destination is ignored by Git: {name}")
        if ignored.returncode != 1:
            raise ValueError("Could not check ignore rules")
    originals = {name: (dest.read_bytes(), dest.stat().st_mode & 0o777)
                 if dest.exists() else None for name, dest in destinations.items()}
    created_dirs, written = [], []
    try:
        for name, text in files.items():
            dest = safe_path(root, name)
            missing = []
            parent = dest.parent
            while not parent.exists():
                missing.append(parent)
                parent = parent.parent
            for directory in reversed(missing):
                directory.mkdir()
                created_dirs.append(directory)
            previous = originals[name]
            if previous and previous[0] == text.encode():
                continue
            temp = None
            try:
                with tempfile.NamedTemporaryFile(dir=dest.parent, delete=False) as staged:
                    temp = Path(staged.name)
                    staged.write(text.encode())
                temp.chmod(previous[1] if previous else 0o644)
                os.replace(temp, dest)
            finally:
                if temp is not None:
                    temp.unlink(missing_ok=True)
            written.append(name)
    except BaseException:
        for name in reversed(written):
            dest = destinations[name]
            previous = originals[name]
            if previous is None:
                dest.unlink()
            else:
                dest.write_bytes(previous[0])
                dest.chmod(previous[1])
        for directory in reversed(created_dirs):
            directory.rmdir()
        raise


def main():
    if sys.version_info < (3, 9):
        raise ValueError("Python 3.9+ is required")
    parser = argparse.ArgumentParser(description=(
        "Install CI configuration only. No hooks, agent instructions, bot settings, "
        "proof files, commits or publication. Requires Python 3.9+."))
    parser.add_argument("target", type=Path, help="Explicit repository root")
    parser.add_argument("--repo", required=True, help="Exact owned GitHub owner/repository")
    parser.add_argument("--ref", required=True, help="Reviewed full source commit SHA")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.ref):
        raise ValueError("--ref must be a full lowercase commit SHA")
    if not re.fullmatch(rf"{OWNER}/[A-Za-z0-9_.-]+", args.repo):
        raise ValueError("Only explicitly named owned repositories are eligible")
    root = args.target.resolve(strict=True)
    os.chdir(root)
    if Path(run("git", "rev-parse", "--show-toplevel")).resolve() != root:
        raise ValueError("Target must be the repository root")
    branch = current_branch()
    if not branch:
        raise ValueError("Detached HEAD; use an isolated feature branch")
    if branch in ("main", "master"):
        raise ValueError("Use an isolated feature branch, never main or master")
    if run("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Working tree must be clean, including untracked files")
    remote = run("git", "remote", "get-url", "origin")
    allowed = {f"https://github.com/{args.repo}", f"git@github.com:{args.repo}",
               f"ssh://git@github.com/{args.repo}"}
    if remote.removesuffix(".git") not in allowed:
        raise ValueError("--repo does not match origin")
    repo = json.loads(run("gh", "repo", "view", args.repo, "--json",
        "nameWithOwner,owner,isFork,parent,isArchived,visibility,defaultBranchRef"))
    if not isinstance(repo, dict):
        raise ValueError("Repository metadata is unavailable")
    default = (repo.get("defaultBranchRef") or {}).get("name")
    if (repo.get("nameWithOwner") != args.repo
            or (repo.get("owner") or {}).get("login") != OWNER
            or repo.get("isArchived") is not False
            or repo.get("isFork") is not False
            or repo.get("visibility") not in ("PUBLIC", "PRIVATE") or not default):
        raise ValueError("Ownership, visibility, fork or archive state is not eligible")
    if branch == default:
        raise ValueError("Use an isolated feature branch, never the repository default")
    source = json.loads(run("gh", "api",
        f"repos/{SOURCE}/contents/.github/workflows/commit-lint-reusable.yml?ref={args.ref}"))
    if not isinstance(source, dict) or source.get("type") != "file" or not source.get("sha"):
        raise ValueError("Pinned source workflow is unavailable")
    # Recheck local state after the network calls.
    if current_branch() != branch:
        raise ValueError("Branch changed during preflight")
    if run("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Working tree changed during preflight")
    install(root, payload(args.ref))
    print(f"Prepared CI configuration for {args.repo} ({repo['visibility']}).")
    print("\n".join(payload(args.ref)))
    print("Local changes only. Review the diff and obtain publication approval.")
    print("Git hooks, bot settings and existing instructions were not modified.")


try:
    main()
except (ValueError, OSError, subprocess.SubprocessError) as error:
    print(f"Bootstrap stopped: {error}", file=sys.stderr)
    sys.exit(1)
PY
