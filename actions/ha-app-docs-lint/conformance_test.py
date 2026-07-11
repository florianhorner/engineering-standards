#!/usr/bin/env python3
"""Conformance: the rules file is valid, and the reference template satisfies it.

Guards the "spec/template is SSOT" claim from drifting — if someone edits the rules
without updating the template (or vice versa), this fails loudly.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = Path(__file__).resolve().parent / "ha_app_docs_lint.py"
RULES = ROOT / "specs" / "ha-app-docs-rules.json"
TEMPLATE = ROOT / "templates" / "ha-app-docs-README.template.md"


def main() -> None:
    errs = []
    rules = json.loads(RULES.read_text(encoding="utf-8"))

    ids = [b["rule_id"] for b in rules["banned_phrases"]] + [rules["install_badge"]["rule_id"]]
    dupes = {r for r in ids if ids.count(r) > 1}
    if dupes:
        errs.append(f"duplicate rule_ids: {sorted(dupes)}")

    for b in rules["banned_phrases"]:
        try:
            re.compile(b["pattern"])
        except re.error as e:
            errs.append(f"invalid regex for {b['rule_id']}: {e}")

    if not TEMPLATE.exists():
        errs.append(f"missing reference template: {TEMPLATE}")
    else:
        r = subprocess.run(
            [sys.executable, str(CHECK), str(TEMPLATE), "--profile", "addon", "--rules", str(RULES)],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            errs.append("README.template.md does not satisfy its own rules:\n" + r.stdout + r.stderr)

    if errs:
        print("CONFORMANCE FAIL:\n" + "\n".join(errs))
        sys.exit(1)
    print("conformance OK (rules valid, template passes its own check)")
    sys.exit(0)


if __name__ == "__main__":
    main()
