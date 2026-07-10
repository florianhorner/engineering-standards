#!/usr/bin/env python3
"""ha-app-docs-lint — drift-proof install-docs linter for Home Assistant app/add-on repos.

Part of florianhorner/engineering-standards. Rules SSOT: specs/ha-app-docs-rules.json.
Consumed as a reusable GitHub Action (actions/ha-app-docs-lint) or run directly.

Markdown-aware: it matches rendered prose, not raw markdown source. Fenced/inline code
and markdown link/image URL targets are stripped before matching, so badge URLs and code
blocks never false-positive (naive substring matching measured ~45% FP on real repos;
this measured ~0%). CHANGELOG files are excluded (stale phrases live there as legitimate
history). Output uses the shared BLOCK/FIX/SPEC/OFFENDING format for deterministic parsing.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

FENCE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE = re.compile(r"`[^`]*`")
LINK_TARGET = re.compile(r"\]\([^)]*\)")   # ](url) — strip the URL, keep display text
HTML_COMMENT = re.compile(r"<!--.*?-->")
HTML_TAG = re.compile(r"<[^>]+>")


class Finding:
    __slots__ = ("rule_id", "message", "fix_hint", "anchor", "location")

    def __init__(self, rule_id, message, fix_hint, anchor, location):
        self.rule_id = rule_id
        self.message = message
        self.fix_hint = fix_hint
        self.anchor = anchor
        self.location = location


def default_rules_path() -> Path:
    for cand in (
        HERE.parent.parent / "specs" / "ha-app-docs-rules.json",  # repo root/specs
        HERE / "ha-app-docs-rules.json",                          # vendored beside action
    ):
        if cand.exists():
            return cand
    return HERE.parent.parent / "specs" / "ha-app-docs-rules.json"


def is_changelog(p: Path) -> bool:
    return p.name.upper().startswith("CHANGELOG")


def prose_lines(text: str):
    """Yield (lineno, prose_only_line): skip fenced code; strip inline code,
    markdown link/image URL targets, HTML comments/tags."""
    in_fence = False
    for i, raw in enumerate(text.splitlines(), 1):
        if FENCE.match(raw):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        line = INLINE_CODE.sub(" ", raw)
        line = LINK_TARGET.sub("] ", line)
        line = HTML_COMMENT.sub(" ", line)
        line = HTML_TAG.sub(" ", line)
        yield i, line


def scan_phrases(path: Path, rules: dict) -> list[Finding]:
    if is_changelog(path):
        return []
    compiled = [
        (b, re.compile(b["pattern"], re.I if "i" in b.get("flags", "") else 0))
        for b in rules["banned_phrases"]
    ]
    out: list[Finding] = []
    text = path.read_text(encoding="utf-8")
    for lineno, line in prose_lines(text):
        for b, rx in compiled:
            if rx.search(line):
                out.append(Finding(b["rule_id"], b["message"], b.get("fix_hint", ""),
                                   b.get("spec_anchor", ""), f"{path}:{lineno}"))
    return out


def check_profile(path: Path, rules: dict, profile_name: str) -> list[Finding]:
    if is_changelog(path):
        return []
    prof = rules["profiles"].get(profile_name)
    if prof is None:
        return [Finding("UNKNOWN_PROFILE", f"unknown profile {profile_name!r}",
                        "use one of: " + ", ".join(rules["profiles"]), "profiles", str(path))]
    out: list[Finding] = []
    raw = path.read_text(encoding="utf-8")
    if prof.get("requires_install_badge"):
        ib = rules["install_badge"]
        if not re.search(ib["pattern"], raw):
            out.append(Finding(ib["rule_id"], ib["message"], ib.get("fix_hint", ""),
                               ib.get("spec_anchor", ""), str(path)))
    for marker in prof.get("required_markers", []):
        if f"<!-- {marker} -->" not in raw and f"<!--{marker}-->" not in raw:
            out.append(Finding("SECTION_MARKER",
                               f"missing required section marker <!-- {marker} --> "
                               f"for profile {profile_name!r}",
                               f"Add the marker above the relevant section: <!-- {marker} -->",
                               "profiles", str(path)))
    return out


def collect(path: Path):
    """(readmes, all_markdown). A dir scans README+docs; an explicit file is
    treated as a README (so profile checks apply). Missing paths are skipped."""
    if not path.exists():
        return [], []
    if path.is_dir():
        all_md = [p for p in sorted(path.rglob("*.md"))]
        readmes = [p for p in all_md if p.name.lower() == "readme.md"]
        return readmes, all_md
    return [path], [path]


def emit(f: Finding, spec_url: str) -> None:
    print(f"BLOCK: {f.rule_id} {f.message}", file=sys.stderr)
    if f.fix_hint:
        print(f"FIX: {f.fix_hint}", file=sys.stderr)
    print(f"SPEC: {spec_url}#{f.anchor}", file=sys.stderr)
    print(f"OFFENDING: {f.location}", file=sys.stderr)
    print("", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description="ha-app-docs-lint")
    ap.add_argument("paths", nargs="*", help="files/dirs to scan (default: README.md docs)")
    ap.add_argument("--profile", default="addon", help="repo-type profile")
    ap.add_argument("--rules", default=None, help="path to ha-app-docs-rules.json")
    args = ap.parse_args()

    rules_path = Path(args.rules) if args.rules else default_rules_path()
    rules = json.loads(rules_path.read_text(encoding="utf-8"))
    spec_url = rules.get("spec_url", "")

    paths = args.paths or ["README.md", "docs"]
    readmes, all_md = [], []
    for raw in paths:
        r, a = collect(Path(raw))
        readmes += r
        all_md += a

    findings: list[Finding] = []
    for p in dict.fromkeys(all_md):
        findings += scan_phrases(p, rules)
    for p in dict.fromkeys(readmes):
        findings += check_profile(p, rules, args.profile)

    if findings:
        for f in findings:
            emit(f, spec_url)
        print(f"ha-app-docs-lint: {len(findings)} problem(s)", file=sys.stderr)
        sys.exit(1)
    print("ha-app-docs-lint OK")
    sys.exit(0)


if __name__ == "__main__":
    main()
