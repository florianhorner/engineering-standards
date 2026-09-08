"""Exercise the real installer with real isolated Git and a read-only fake GitHub."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
REPO = "florianhorner/example"
FILES = {".github/workflows/commit-lint.yml", ".config/commit-rules.json",
         ".config/commit-rules.meta.json"}


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.hooks = self.base / "shared-hooks"
        self.hooks.mkdir()
        self.hook = self.hooks / "commit-msg"
        self.hook.write_text("#!/bin/sh\nexit 0\n")
        self.hook.chmod(0o755)
        self.global_config = self.base / "gitconfig"
        self.global_config.write_text(f'[core]\n hooksPath = {self.hooks}\n')
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": str(self.global_config),
                    "GIT_CONFIG_NOSYSTEM": "1", "PATH": f"{self.bin}:{os.environ['PATH']}"}
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.env.pop(key, None)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("commit", "--allow-empty", "-m", "test: initial")
        self.git("switch", "-c", "adopt-policy")
        self.git("remote", "add", "origin", f"https://github.com/{REPO}.git")
        self.view = {"nameWithOwner": REPO, "owner": {"login": "florianhorner"},
                     "isFork": False, "parent": None, "isArchived": False,
                     "visibility": "PUBLIC", "defaultBranchRef": {"name": "main"}}
        self.view_file = self.base / "view.json"
        self.env["TEST_VIEW"] = str(self.view_file)
        self.calls = self.base / "calls.jsonl"
        self.env["TEST_CALLS"] = str(self.calls)
        gh = self.bin / "gh"
        gh.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["TEST_CALLS"], "a") as f: f.write(json.dumps(args) + "\\n")
if args[:2] == ["repo", "view"]:
    print(Path(os.environ["TEST_VIEW"]).read_text())
elif args[:2] == ["repo", "list"]:
    print(json.dumps([
        {"nameWithOwner": "florianhorner/public-example", "isFork": False,
         "isArchived": False, "visibility": "PUBLIC"},
        {"nameWithOwner": "florianhorner/private-example", "isFork": False,
         "isArchived": False, "visibility": "PRIVATE"},
        {"nameWithOwner": "florianhorner/unknown-example", "isFork": False,
         "isArchived": False}]))
elif args[:1] == ["api"] and args[1].endswith("/commits/main"):
    print("a" * 40)
elif args[:1] == ["api"] and len(args) == 4:
    sys.exit(1)
elif args[:1] == ["api"] and len(args) == 2 and "/contents/" in args[1]:
    if os.environ.get("TEST_SOURCE_FAIL"): sys.exit(1)
    print(json.dumps({"type": "file", "sha": "b" * 40}))
else:
    sys.exit(99)
''')
        gh.chmod(0o755)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def invoke(self, *extra):
        self.view_file.write_text(json.dumps(self.view))
        return subprocess.run(["bash", str(ROOT / "bootstrap-repo.sh"), str(self.repo),
                               "--repo", REPO, "--ref", SHA, *extra], env=self.env,
                              capture_output=True, text=True)

    def assert_unchanged(self, result, before):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertEqual(self.hook.read_text(), "#!/bin/sh\nexit 0\n")

    def test_public_and_private_minimal_payload(self):
        for visibility in ("PUBLIC", "PRIVATE"):
            with self.subTest(visibility=visibility):
                self.view["visibility"] = visibility
                result = self.invoke()
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = set(self.git("ls-files", "--others", "--exclude-standard").splitlines())
                self.assertEqual(actual, FILES)
                for name in actual:
                    text = (self.repo / name).read_text()
                    self.assertIn(SHA, text)
                    for forbidden in ("Claude", "Codex", "Conductor", "gstack", "/Users/",
                                      "recruiter", "Skill-Run", "Reviewed-By", str(self.base)):
                        self.assertNotIn(forbidden, text)
                self.assertEqual(self.hook.read_text(), "#!/bin/sh\nexit 0\n")
                self.assertEqual(self.git("branch", "--show-current"), "adopt-policy")
                for name in actual:
                    (self.repo / name).unlink()
        calls = [json.loads(x) for x in self.calls.read_text().splitlines()]
        self.assertTrue(all(c[:2] == ["repo", "view"] or c[:1] == ["api"] for c in calls))

    def test_missing_arguments_and_fleet_apply_fail_before_reads(self):
        for script, args in (("bootstrap-repo.sh", []), ("fleet-audit.sh", ["--apply"])):
            result = subprocess.run(["bash", str(ROOT / script), *args], env=self.env,
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_protected_and_custom_default_branches(self):
        self.view["defaultBranchRef"]["name"] = "adopt-policy"
        self.assert_unchanged(self.invoke(), "")
        self.view["defaultBranchRef"]["name"] = "main"
        self.git("switch", "main")
        self.assert_unchanged(self.invoke(), "")
        self.git("switch", "--detach")
        self.assert_unchanged(self.invoke(), "")

    def test_dirty_tree(self):
        (self.repo / "owned-work.txt").write_text("preserve")
        self.assert_unchanged(self.invoke(), self.git("status", "--porcelain"))

    def test_rejects_mutable_ref_and_ignored_destination(self):
        self.assert_unchanged(self.invoke("--ref", "main"), "")
        (self.repo / ".gitignore").write_text(".config/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-m", "test: ignore installation")
        self.assert_unchanged(self.invoke(), "")
        self.assertFalse((self.repo / ".github").exists())

    def test_metadata_fail_closed(self):
        for key, bad in (("visibility", "UNKNOWN"), ("isArchived", True),
                         ("isFork", True), ("defaultBranchRef", None),
                         ("owner", {"login": "someone-else"})):
            with self.subTest(key=key):
                original = self.view[key]
                self.view[key] = bad
                self.assert_unchanged(self.invoke(), "")
                self.view[key] = original

    def test_remote_mismatch_and_source_failure(self):
        self.git("remote", "set-url", "origin", "https://github.com/other/example.git")
        self.assert_unchanged(self.invoke(), "")
        self.git("remote", "set-url", "origin", f"https://github.com/{REPO}.git")
        self.env["TEST_SOURCE_FAIL"] = "1"
        self.assert_unchanged(self.invoke(), "")

    def test_symlink_and_unmanaged_files_preserved(self):
        external = self.base / "external"
        external.mkdir()
        (self.repo / ".config").symlink_to(external, target_is_directory=True)
        self.git("add", ".config")
        self.git("commit", "-m", "test: symlink")
        self.assert_unchanged(self.invoke(), "")
        self.assertEqual(list(external.iterdir()), [])
        self.git("rm", ".config")
        (self.repo / ".config").mkdir()
        (self.repo / ".config/commit-rules.json").write_text('{"custom":true}')
        self.git("add", ".config")
        self.git("commit", "-m", "test: custom policy")
        self.assert_unchanged(self.invoke(), "")
        self.assertFalse((self.repo / ".github/workflows/commit-lint.yml").exists())

    def test_idempotent_after_commit_and_preserves_unrelated_configuration(self):
        for name in ("CLAUDE.md", ".coderabbit.yaml", ".github/dependabot.yml"):
            dest = self.repo / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text("preserve\n")
        self.git("add", ".")
        self.git("commit", "-m", "test: existing configuration")
        self.assertEqual(self.invoke().returncode, 0)
        self.git("add", ".")
        self.git("commit", "-m", "test: installation")
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_real_linked_worktree(self):
        linked = self.base / "linked"
        self.git("worktree", "add", "-b", "isolated", str(linked))
        self.repo = linked
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.hook.read_text(), "#!/bin/sh\nexit 0\n")

    def test_remote_report_never_reads_or_prints_private_repositories(self):
        result = subprocess.run(["bash", str(ROOT / "fleet-audit-remote.sh")],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("public-example", result.stdout)
        self.assertNotIn("private-example", result.stdout)
        self.assertNotIn("unknown-example", result.stdout)
        self.assertNotIn("private-example", self.calls.read_text())
        self.assertNotIn("unknown-example", self.calls.read_text())

    def test_write_failure_restores_all_destinations(self):
        source = (ROOT / "bootstrap-repo.sh").read_text().split("<<'PY'\n", 1)[1]
        definitions = source.split("\ntry:\n    main()", 1)[0]
        namespace = {}
        exec(compile(definitions, "bootstrap-repo.sh", "exec"), namespace)
        original_replace = os.replace
        calls = []

        def fail_second(source, target):
            calls.append(target)
            if len(calls) == 2:
                raise OSError("injected write failure")
            return original_replace(source, target)

        with mock.patch.object(os, "replace", side_effect=fail_second):
            with self.assertRaises(OSError):
                namespace["install"](self.repo, namespace["payload"](SHA))
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse((self.repo / ".github").exists())
        self.assertFalse((self.repo / ".config").exists())


if __name__ == "__main__":
    unittest.main()
