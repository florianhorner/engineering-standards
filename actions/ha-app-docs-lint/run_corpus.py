#!/usr/bin/env python3
"""Run ha-app-docs-lint against its test corpus. Local CI + the workflow both call this.

Contract (mirrors specs/test-corpus.yml):
  - specs/ha-app-docs-test-corpus/pass/*.md      -> exit 0
  - specs/ha-app-docs-test-corpus/fail/*.md       -> exit != 0 AND every rule_id in the
    `<!-- profile: X | expected: RULE_A, RULE_B -->` header appears on a `BLOCK:` line.
Each case's first line carries its profile and expected outcome.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = Path(__file__).resolve().parent / "ha_app_docs_lint.py"
RULES = ROOT / "specs" / "ha-app-docs-rules.json"
CORPUS = ROOT / "specs" / "ha-app-docs-test-corpus"
HDR = re.compile(r"profile:\s*([a-z0-9-]+)\s*\|\s*expected:\s*(.+?)\s*-->", re.I)


def header(path: Path):
    first = path.read_text(encoding="utf-8").splitlines()[0]
    m = HDR.search(first)
    if not m:
        return None
    profile = m.group(1)
    expected = [x.strip() for x in m.group(2).split(",") if x.strip()]
    return profile, expected


def run_check(path: Path, profile: str):
    r = subprocess.run(
        [sys.executable, str(CHECK), str(path), "--profile", profile, "--rules", str(RULES)],
        capture_output=True, text=True,
    )
    return r.returncode, r.stdout + r.stderr


def main() -> None:
    total = mismatch = 0
    log = []
    for bucket in ("pass", "fail"):
        for f in sorted((CORPUS / bucket).glob("*.md")):
            total += 1
            hdr = header(f)
            if hdr is None:
                mismatch += 1
                log.append(f"{f}: missing '<!-- profile: X | expected: Y -->' header on line 1")
                continue
            profile, expected = hdr
            rc, out = run_check(f, profile)
            rel = f.relative_to(ROOT)
            if bucket == "pass":
                if rc != 0:
                    mismatch += 1
                    log.append(f"{rel}: expected PASS (exit 0), got exit {rc}\n{out}")
                else:
                    print(f"PASS  {rel}")
            else:
                if rc == 0:
                    mismatch += 1
                    log.append(f"{rel}: expected FAIL, got exit 0")
                    continue
                missing = [rid for rid in expected
                           if not re.search(rf"^BLOCK: {re.escape(rid)} ", out, re.M)]
                if missing:
                    mismatch += 1
                    log.append(f"{rel}: rule_ids not found in output: {missing}\n{out}")
                else:
                    print(f"PASS  {rel} (failed as expected: {', '.join(expected)})")

    print(f"\nha-app-docs corpus: {total} cases, {mismatch} mismatches")
    if mismatch:
        print("\n".join(log))
        sys.exit(1)
    print("ALL GREEN")
    sys.exit(0)


if __name__ == "__main__":
    main()
