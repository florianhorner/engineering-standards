#!/usr/bin/env python3
"""Hermetic tests for the shadow CodeRabbit leftover dispatcher."""

from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import coderabbit_dispatch as crd  # noqa: E402

GOOD_BUDGET = (
    "3 reviews are currently available. Your 22 included PR review attempts "
    "over the past 7 days set your current allowance at 10 reviews per hour."
)
FOOTER_1114 = (
    "**Included review availability:** 4 reviews are currently available. "
    "Your included PR review attempts over the past 7 days set your current "
    "allowance at 5 reviews per hour."
)
RATE_LIMIT_FOOTER = (
    "## Review limit reached\n"
    "You’ve used the included review currently available. Your 92 included "
    "PR review attempts over the past 7 days set your current allowance at "
    "1 review per hour."
)
PAUSE_AND_COVERED = textwrap.dedent(
    """\
    <!-- This is an auto-generated comment: review paused by coderabbit.ai -->
    ## Reviews paused
    CodeRabbit has automatically paused this review.
    <!-- final_review_risk_coverage:{"sourceCommitId":"aaa1111","coveredCommitId":"%s","kind":"reviewed"} -->
    """
)

HEAD_A = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HEAD_C = "cccccccccccccccccccccccccccccccccccccccc"
OLD_SHA = "dddddddddddddddddddddddddddddddddddddddd"


def repo(name: str, *, fork: bool = False, archived: bool = False) -> dict:
    return {
        "nameWithOwner": f"florianhorner/{name}",
        "name": name,
        "isFork": fork,
        "isArchived": archived,
    }


def pr(
    number: int,
    *,
    author: str = "florianhorner",
    is_bot: bool = False,
    user_type: str = "User",
    draft: bool = False,
    head: str = HEAD_A,
    created: str = "2026-09-01T00:00:00Z",
    updated: str = "2026-09-01T00:00:00Z",
) -> dict:
    return {
        "number": number,
        "isDraft": draft,
        "author": {"login": author, "is_bot": is_bot, "type": user_type},
        "headRefOid": head,
        "createdAt": created,
        "updatedAt": updated,
    }


def comment(body: str, *, login: str = "coderabbitai[bot]", when: str = "2026-09-07T12:00:00Z") -> dict:
    return {"user": {"login": login, "type": "Bot"}, "body": body, "created_at": when}


def review(
    body: str,
    *,
    commit_id: str,
    login: str = "coderabbitai[bot]",
    when: str = "2026-09-07T12:00:00Z",
) -> dict:
    return {
        "user": {"login": login, "type": "Bot"},
        "body": body,
        "commit_id": commit_id,
        "submitted_at": when,
    }


def run(
    repos,
    pulls,
    comments=None,
    reviews=None,
    *,
    enabled=True,
    dispatch_var="1",
):
    comments = comments or {}
    reviews = reviews or {}
    return crd.evaluate(
        repos=repos,
        pulls_by_repo=pulls,
        comments_by_pr=comments,
        reviews_by_pr=reviews,
        enabled_file_present=enabled,
        dispatch_var=dispatch_var,
    )


def would_review(report: crd.Report):
    return [r for r in report.prs if r.verdict == crd.OUTCOME_WOULD_REVIEW]


class ParseBudgetTest(unittest.TestCase):
    def test_1114_footer_has_remaining_but_no_seven_day_count(self):
        b = crd.parse_budget(FOOTER_1114)
        self.assertEqual(b.hourly_remaining, 4)
        self.assertEqual(b.hourly_allowance, 5)
        self.assertIsNone(b.seven_day)
        self.assertFalse(b.known)

    def test_rate_limit_footer_has_count_and_zero_remaining(self):
        b = crd.parse_budget(RATE_LIMIT_FOOTER)
        self.assertEqual(b.seven_day, 92)
        self.assertEqual(b.hourly_allowance, 1)
        self.assertEqual(b.hourly_remaining, 0)

    def test_good_budget(self):
        b = crd.parse_budget(GOOD_BUDGET)
        self.assertEqual(b.seven_day, 22)
        self.assertEqual(b.hourly_remaining, 3)
        self.assertEqual(b.hourly_allowance, 10)


class DispatcherContractTest(unittest.TestCase):
    def test_dependabot_skip(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1, author="dependabot[bot]", is_bot=True, user_type="Bot")]},
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
        )
        self.assertEqual(would_review(report), [])
        self.assertIn("Dependabot", report.prs[0].why)

    def test_app_author_skip(self):
        report = run(
            [repo("tools")],
            {
                "florianhorner/tools": [
                    pr(1, author="renovate[bot]", is_bot=True, user_type="Bot")
                ]
            },
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
        )
        self.assertEqual(would_review(report), [])
        self.assertIn("GitHub App author", report.prs[0].why)

    def test_draft_skip(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1, draft=True)]},
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
        )
        self.assertEqual(would_review(report), [])
        self.assertEqual(report.prs[0].why, "draft")

    def test_non_allowlisted_fork_skip(self):
        report = run(
            [repo("adaptive-lighting-fork", fork=True)],
            {"florianhorner/adaptive-lighting-fork": [pr(1)]},
            {("florianhorner/adaptive-lighting-fork", 1): [comment(GOOD_BUDGET)]},
        )
        self.assertEqual(would_review(report), [])
        self.assertIn("non-allowlisted fork", report.prs[0].why)

    def test_allowlisted_fork_included(self):
        report = run(
            [repo("lightener-studio", fork=True)],
            {"florianhorner/lightener-studio": [pr(7, head=HEAD_A)]},
            {("florianhorner/lightener-studio", 7): [comment(GOOD_BUDGET)]},
        )
        selected = would_review(report)
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].repo, "florianhorner/lightener-studio")
        self.assertEqual(selected[0].number, 7)
        self.assertEqual(selected[0].candidate_kind, crd.KIND_NEVER)
        self.assertEqual(selected[0].would_command, crd.CMD_FULL)

    def test_never_reviewed_beats_head_stale(self):
        report = run(
            [repo("alpha"), repo("mammamiradio")],
            {
                "florianhorner/alpha": [pr(1, head=HEAD_A, created="2026-09-06T00:00:00Z")],
                "florianhorner/mammamiradio": [pr(9, head=HEAD_B, created="2026-01-01T00:00:00Z")],
            },
            {
                ("florianhorner/alpha", 1): [comment(GOOD_BUDGET)],
                ("florianhorner/mammamiradio", 9): [comment(GOOD_BUDGET)],
            },
            {
                ("florianhorner/mammamiradio", 9): [
                    review("reviewed", commit_id=OLD_SHA, when="2026-01-02T00:00:00Z")
                ]
            },
        )
        selected = would_review(report)
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].repo, "florianhorner/alpha")
        self.assertEqual(selected[0].candidate_kind, crd.KIND_NEVER)

    def test_mammamiradio_tie_break_only(self):
        # Equal never-reviewed age → mammamiradio wins the tie only.
        report = run(
            [repo("lightener-studio", fork=True), repo("mammamiradio")],
            {
                "florianhorner/lightener-studio": [
                    pr(1, head=HEAD_A, created="2026-09-01T00:00:00Z")
                ],
                "florianhorner/mammamiradio": [
                    pr(2, head=HEAD_B, created="2026-09-01T00:00:00Z")
                ],
            },
            {
                ("florianhorner/lightener-studio", 1): [comment(GOOD_BUDGET)],
                ("florianhorner/mammamiradio", 2): [comment(GOOD_BUDGET)],
            },
        )
        selected = would_review(report)
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].repo, "florianhorner/mammamiradio")

        # Older non-mmr HEAD-stale beats newer mmr HEAD-stale — repo is not a rank key.
        report = run(
            [repo("govee2mqtt-extended", fork=True), repo("mammamiradio")],
            {
                "florianhorner/govee2mqtt-extended": [pr(1, head=HEAD_A)],
                "florianhorner/mammamiradio": [pr(2, head=HEAD_B)],
            },
            {
                ("florianhorner/govee2mqtt-extended", 1): [comment(GOOD_BUDGET)],
                ("florianhorner/mammamiradio", 2): [comment(GOOD_BUDGET)],
            },
            {
                ("florianhorner/govee2mqtt-extended", 1): [
                    review("old", commit_id=OLD_SHA, when="2026-01-01T00:00:00Z")
                ],
                ("florianhorner/mammamiradio", 2): [
                    review("newer", commit_id=OLD_SHA, when="2026-08-01T00:00:00Z")
                ],
            },
        )
        selected = would_review(report)
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0].repo, "florianhorner/govee2mqtt-extended")
        self.assertEqual(selected[0].candidate_kind, crd.KIND_STALE)

    def test_unknown_budget_no_review(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1)]},
            {("florianhorner/tools", 1): [comment(FOOTER_1114)]},
        )
        self.assertEqual(report.outcome, crd.OUTCOME_BUDGET_HELD)
        self.assertEqual(would_review(report), [])
        self.assertIn("unknown", report.hold_reason.lower())

    def test_kill_switch_off_missing_file(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1)]},
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
            enabled=False,
        )
        self.assertEqual(report.outcome, crd.OUTCOME_DISABLED)
        self.assertEqual(report.prs, [])
        self.assertEqual(would_review(report), [])

    def test_kill_switch_off_literal_zero(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1)]},
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
            dispatch_var="0",
        )
        self.assertEqual(report.outcome, crd.OUTCOME_DISABLED)
        self.assertEqual(would_review(report), [])

    def test_at_most_one_would_review(self):
        report = run(
            [repo("one"), repo("two"), repo("three")],
            {
                "florianhorner/one": [pr(1, head=HEAD_A, created="2026-01-01T00:00:00Z")],
                "florianhorner/two": [pr(2, head=HEAD_B, created="2026-02-01T00:00:00Z")],
                "florianhorner/three": [pr(3, head=HEAD_C, created="2026-03-01T00:00:00Z")],
            },
            {
                ("florianhorner/one", 1): [comment(GOOD_BUDGET)],
                ("florianhorner/two", 2): [comment(GOOD_BUDGET)],
                ("florianhorner/three", 3): [comment(GOOD_BUDGET)],
            },
        )
        self.assertEqual(len(would_review(report)), 1)
        self.assertEqual(report.outcome, crd.OUTCOME_WOULD_REVIEW)
        self.assertEqual(report.selected.repo, "florianhorner/one")
        skipped_candidates = [r for r in report.prs if "at most one" in r.why]
        self.assertEqual(len(skipped_candidates), 2)

    def test_paused_and_head_reviewed_skipped(self):
        report = run(
            [repo("mammamiradio")],
            {"florianhorner/mammamiradio": [pr(1114, head=HEAD_A)]},
            {
                ("florianhorner/mammamiradio", 1114): [
                    comment(PAUSE_AND_COVERED % HEAD_A + "\n" + GOOD_BUDGET)
                ]
            },
            {
                ("florianhorner/mammamiradio", 1114): [
                    review("ok", commit_id=HEAD_A)
                ]
            },
        )
        self.assertEqual(would_review(report), [])
        self.assertIn("paused and HEAD already reviewed", report.prs[0].why)

    def test_ceiling_holds_budget(self):
        heavy = (
            "2 reviews are currently available. Your 40 included PR review "
            "attempts over the past 7 days set your current allowance at "
            "6 reviews per hour."
        )
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1)]},
            {("florianhorner/tools", 1): [comment(heavy)]},
        )
        self.assertEqual(report.outcome, crd.OUTCOME_BUDGET_HELD)
        self.assertEqual(would_review(report), [])
        self.assertIn("ceiling", report.hold_reason)

    def test_does_not_burn_leftover_hours_without_a_candidate(self):
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1, head=HEAD_A)]},
            {("florianhorner/tools", 1): [comment(GOOD_BUDGET)]},
            {("florianhorner/tools", 1): [review("current", commit_id=HEAD_A)]},
        )
        self.assertEqual(report.outcome, crd.OUTCOME_NONE)
        self.assertEqual(would_review(report), [])
        self.assertEqual(report.budget.hourly_remaining, 3)

    def test_hourly_zero_holds_even_under_ceiling(self):
        footer = (
            "You've used the included review currently available. Your 22 included "
            "PR review attempts over the past 7 days set your current allowance at "
            "10 reviews per hour."
        )
        report = run(
            [repo("tools")],
            {"florianhorner/tools": [pr(1)]},
            {("florianhorner/tools", 1): [comment(footer)]},
        )
        self.assertEqual(report.outcome, crd.OUTCOME_BUDGET_HELD)
        self.assertEqual(would_review(report), [])
        self.assertIn("hourly remaining is 0", report.hold_reason)

    def test_govee_allowlisted_fork_included(self):
        report = run(
            [repo("govee2mqtt-extended", fork=True)],
            {"florianhorner/govee2mqtt-extended": [pr(3, head=HEAD_C)]},
            {("florianhorner/govee2mqtt-extended", 3): [comment(GOOD_BUDGET)]},
        )
        self.assertEqual(len(would_review(report)), 1)
        self.assertEqual(report.selected.repo, "florianhorner/govee2mqtt-extended")


GH_SHIM = r'''
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
fx = Path(os.environ["CR_DISPATCH_FIXTURES"])

def out(path: Path):
    if not path.is_file():
        sys.stdout.write("[]\n")
        return 0
    sys.stdout.write(path.read_text())
    if not path.read_text().endswith("\n"):
        sys.stdout.write("\n")
    return 0

args = sys.argv[1:]
if args[:2] == ["repo", "list"]:
    raise SystemExit(out(fx / "repos.json"))
if args[:2] == ["pr", "list"]:
    repo = args[args.index("--repo") + 1]
    raise SystemExit(out(fx / "prs" / (repo.replace("/", "_") + ".json")))
if args and args[0] == "api":
    rest = [a for a in args[1:] if a != "--paginate"]
    endpoint = rest[0].split("?", 1)[0]
    parts = endpoint.split("/")
    # repos/{owner}/{name}/issues/{n}/comments
    # repos/{owner}/{name}/pulls/{n}/reviews
    if len(parts) >= 6 and parts[0] == "repos":
        nwo = parts[1] + "_" + parts[2]
        n = parts[4]
        kind = "comments" if parts[-1] == "comments" else "reviews"
        raise SystemExit(out(fx / kind / f"{nwo}_{n}.json"))
    sys.stderr.write("unhandled gh api " + endpoint + "\n")
    raise SystemExit(1)
sys.stderr.write("unhandled gh " + " ".join(args) + "\n")
raise SystemExit(1)
'''


class ShellIntegrationTest(unittest.TestCase):
    def _tree(self, *, enabled: bool = True):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        (root / ".github").mkdir()
        if enabled:
            (root / ".github" / "coderabbit-dispatch.enabled").write_text("enabled\n")
        script = ROOT / "coderabbit-dispatch-remote.sh"
        engine = ROOT / "coderabbit_dispatch.py"
        (root / "coderabbit-dispatch-remote.sh").write_text(script.read_text())
        (root / "coderabbit_dispatch.py").write_text(engine.read_text())
        os.chmod(root / "coderabbit-dispatch-remote.sh", 0o755)
        return root

    def test_shell_kill_switch_off(self):
        root = self._tree(enabled=False)
        proc = subprocess.run(
            ["bash", str(root / "coderabbit-dispatch-remote.sh")],
            check=False,
            capture_output=True,
            text=True,
            env={**os.environ, "CODERABBIT_DISPATCH_ROOT": str(root)},
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("DISABLED", proc.stdout)
        self.assertNotIn("WOULD_REVIEW", proc.stdout)

    def test_shell_path_shimmed_gh_selects_one(self):
        root = self._tree(enabled=True)
        fx = root / "fixtures"
        (fx / "prs").mkdir(parents=True)
        (fx / "comments").mkdir()
        (fx / "reviews").mkdir()
        (fx / "repos.json").write_text(
            json_dumps(
                [repo("tools"), repo("core", fork=True), repo("lightener-studio", fork=True)]
            )
        )
        (fx / "prs" / "florianhorner_tools.json").write_text(
            json_dumps(
                [
                    pr(1, author="dependabot[bot]", is_bot=True, user_type="Bot"),
                    pr(2, draft=True, head=HEAD_B),
                    pr(3, head=HEAD_C, created="2026-09-03T00:00:00Z"),
                ]
            )
        )
        (fx / "prs" / "florianhorner_core.json").write_text(json_dumps([pr(8, head=HEAD_A)]))
        (fx / "prs" / "florianhorner_lightener-studio.json").write_text(
            json_dumps([pr(4, head=HEAD_A, created="2026-09-01T00:00:00Z")])
        )
        budget = json_dumps([comment(GOOD_BUDGET)])
        for key in (
            "florianhorner_tools_1",
            "florianhorner_tools_2",
            "florianhorner_tools_3",
            "florianhorner_core_8",
            "florianhorner_lightener-studio_4",
        ):
            (fx / "comments" / f"{key}.json").write_text(budget)
            (fx / "reviews" / f"{key}.json").write_text("[]\n")

        bindir = root / "bin"
        bindir.mkdir()
        gh = bindir / "gh"
        gh.write_text(GH_SHIM.lstrip())
        os.chmod(gh, os.stat(gh).st_mode | stat.S_IEXEC)

        env = {
            **os.environ,
            "PATH": str(bindir) + os.pathsep + os.environ.get("PATH", ""),
            "CODERABBIT_DISPATCH_ROOT": str(root),
            "CR_DISPATCH_FIXTURES": str(fx),
            "CODERABBIT_DISPATCH": "1",
        }
        proc = subprocess.run(
            ["bash", str(root / "coderabbit-dispatch-remote.sh")],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
        self.assertIn("**Outcome:** `WOULD_REVIEW`", proc.stdout)
        self.assertIn("lightener-studio", proc.stdout)
        self.assertEqual(proc.stdout.count("| `WOULD_REVIEW` |"), 1)
        self.assertIn("Dependabot", proc.stdout)
        self.assertIn("draft", proc.stdout)
        self.assertIn("non-allowlisted fork", proc.stdout)

    def test_bootstrap_vendors_coderabbit_template(self):
        text = (ROOT / "bootstrap-repo.sh").read_text(encoding="utf-8")
        self.assertIn("templates/.coderabbit.yaml", text)
        self.assertIn(".coderabbit.yaml", text)
        tmpl = (ROOT / "templates" / ".coderabbit.yaml").read_text(encoding="utf-8")
        self.assertIn("auto_incremental_review: false", tmpl)
        self.assertIn("enabled: true", tmpl)
        self.assertIn("auto_pause_after_reviewed_commits: 1", tmpl)
        self.assertIn("drafts: false", tmpl)
        self.assertIn("dependabot[bot]", tmpl)
        self.assertNotIn("review-ready", tmpl)


def json_dumps(obj) -> str:
    import json

    return json.dumps(obj) + "\n"


class WorkflowShadowContractTest(unittest.TestCase):
    def test_hourly_workflow_is_read_only_shadow(self):
        text = (ROOT / ".github" / "workflows" / "coderabbit-dispatch-hourly.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("contents: read", text)
        self.assertIn("pull-requests: read", text)
        self.assertIsNone(re.search(r"(?m)^\s+[a-z-]+:\s*write\s*$", text))
        self.assertIn("vars.CODERABBIT_DISPATCH != '0'", text)
        self.assertIn('cron: "7 * * * *"', text)
        self.assertIn("ubuntu-latest", text)
        self.assertNotIn("--github-issue", text)
        self.assertNotIn("@coderabbitai", text)
        self.assertNotIn("issues: write", text)

    def test_engine_has_no_comment_or_label_path(self):
        engine = (ROOT / "coderabbit_dispatch.py").read_text(encoding="utf-8")
        shell = (ROOT / "coderabbit-dispatch-remote.sh").read_text(encoding="utf-8")
        for text in (engine, shell):
            self.assertNotIn("gh pr comment", text)
            self.assertNotIn("gh api -X POST", text)
            self.assertNotIn("gh label", text)
        self.assertNotIn("add_argument(\"--apply\"", engine)


if __name__ == "__main__":
    unittest.main()
