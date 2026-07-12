#!/usr/bin/env python3
"""Conformance: the rules file is valid, the reference template satisfies it, and the
linter's structural guarantees hold.

Guards the "spec/template is SSOT" claim from drifting — if someone edits the rules
without updating the template (or vice versa), or weakens a fail-closed guarantee, this
fails loudly.
"""

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECK = Path(__file__).resolve().parent / "ha_app_docs_lint.py"
RULES = ROOT / "specs" / "ha-app-docs-rules.json"
TEMPLATE = ROOT / "templates" / "ha-app-docs-README.template.md"


def run_check(target: str, profile: str = "addon"):
    r = subprocess.run(
        [
            sys.executable,
            str(CHECK),
            target,
            "--profile",
            profile,
            "--rules",
            str(RULES),
        ],
        capture_output=True,
        text=True,
    )
    return r.returncode, r.stdout + r.stderr


def main() -> None:
    errs = []
    rules = json.loads(RULES.read_text(encoding="utf-8"))

    # 1. rule_ids unique across banned phrases + install badge.
    ids = [b["rule_id"] for b in rules["banned_phrases"]] + [
        rules["install_badge"]["rule_id"]
    ]
    dupes = {r for r in ids if ids.count(r) > 1}
    if dupes:
        errs.append(f"duplicate rule_ids: {sorted(dupes)}")

    # 2. Every banned-phrase regex compiles.
    for b in rules["banned_phrases"]:
        try:
            re.compile(b["pattern"])
        except re.error as e:
            errs.append(f"invalid regex for {b['rule_id']}: {e}")

    # 3. install_badge pattern compiles AND captures a slug group (the linter reads
    #    group(1) to validate against known_good).
    ib = rules["install_badge"]
    try:
        rx = re.compile(ib["pattern"])
        if rx.groups < 1:
            errs.append("install_badge.pattern must have a capture group for the slug")
    except re.error as e:
        errs.append(f"invalid install_badge.pattern: {e}")

    # 4. known_good slugs present and non-empty; the template's badge slug is one of them.
    known = rules.get("redirect_slugs", {}).get("known_good", [])
    if not known:
        errs.append("redirect_slugs.known_good must be a non-empty list")

    # 5. Every profile is well-formed.
    for name, prof in rules.get("profiles", {}).items():
        if "requires_install_badge" not in prof:
            errs.append(f"profile {name!r} missing requires_install_badge")
        if not isinstance(prof.get("required_markers", []), list):
            errs.append(f"profile {name!r} required_markers must be a list")

    # 6. The reference template satisfies its own rules (addon profile).
    if not TEMPLATE.exists():
        errs.append(f"missing reference template: {TEMPLATE}")
    else:
        rc, out = run_check(str(TEMPLATE), "addon")
        if rc != 0:
            errs.append("README.template.md does not satisfy its own rules:\n" + out)

    # 7. Fail-closed guarantees (behavioral): a missing explicit path errors, and a
    #    dead-slug badge does not satisfy the install-badge rule.
    rc, out = run_check(str(ROOT / "does-not-exist-xyz.md"), "addon")
    if rc == 0 or "MISSING_PATH" not in out:
        errs.append("linter must fail closed (MISSING_PATH) on a missing explicit path")

    with tempfile.TemporaryDirectory() as td:
        dead = Path(td) / "README.md"
        dead.write_text(
            "# X\n[![badge](https://my.home-assistant.io/redirect/bogus_slug/)]"
            "(https://my.home-assistant.io/redirect/bogus_slug/)\n## Install\nhi\n",
            encoding="utf-8",
        )
        rc, out = run_check(str(dead), "addon")
        if rc == 0 or "INSTALL_BADGE_REQUIRED" not in out:
            errs.append("linter must reject a redirect badge with an unknown slug")

    if errs:
        print("CONFORMANCE FAIL:\n" + "\n".join(errs))
        sys.exit(1)
    print("conformance OK (rules valid, template passes, fail-closed guarantees hold)")
    sys.exit(0)


if __name__ == "__main__":
    main()
