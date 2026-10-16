"""Draft recovery keeps the original workflow commit used in build provenance.

Run: python3 -m unittest discover -s tools (make tools-test).
"""
import contextlib, copy, io, json, pathlib, subprocess, tempfile, unittest
from unittest import mock

import find_release_draft as recovery

REPO = "scenario-labs/godot-plugin"
TARGET = "a" * 40
CURRENT = TARGET
DRAFT = {
    "id": 123,
    "draft": True,
    "prerelease": False,
    "tag_name": "godot-plugin-v0.2.0",
    "target_commitish": TARGET,
    "author": {"login": recovery.RELEASE_APP},
}


def request_for(test, pages):
    calls = []

    def request(endpoint, *, paginate=False):
        calls.append((endpoint, paginate))
        test.assertEqual(endpoint, f"repos/{REPO}/releases?per_page=100")
        test.assertTrue(paginate)
        return copy.deepcopy(pages)

    return request, calls


class FindDraft(unittest.TestCase):
    def test_no_draft_ignores_published_and_other_namespace_releases(self):
        request, calls = request_for(self, [[dict(DRAFT, draft=False)], [dict(DRAFT, tag_name="v0.1.1")]])
        self.assertEqual(recovery.find_draft(REPO, CURRENT, request), {"found": "false"})
        self.assertEqual(len(calls), 1)

    def test_original_workflow_can_recover_one_verified_draft_from_later_pages(self):
        request, _ = request_for(self, [[], [DRAFT]])
        self.assertEqual(recovery.find_draft(REPO, CURRENT, request),
                         {"found": "true", "tag_name": DRAFT["tag_name"], "sha": TARGET, "release_id": "123"})

    def test_multiple_drafts_fail_instead_of_selecting_one(self):
        request, _ = request_for(self, [[DRAFT], [dict(DRAFT, id=124, tag_name="godot-plugin-v0.2.1")]])
        with self.assertRaisesRegex(ValueError, "Multiple"):
            recovery.find_draft(REPO, CURRENT, request)

    def test_unsafe_drafts_are_rejected(self):
        cases = [
            ({"author": {"login": "other-user"}}, "GitHub App"),
            ({"author": None}, "GitHub App"),
            ({"target_commitish": "main"}, "full commit SHA"),
            ({"target_commitish": "a" * 39}, "full commit SHA"),
            ({"tag_name": "godot-plugin-v0.2.0-rc.1"}, "stable"),
            ({"tag_name": "godot-plugin-v0.2.0\nsha=bad"}, "stable"),
            ({"prerelease": True}, "stable"),
            ({"id": "123\nfound=false"}, "release ID"),
        ]
        for changes, message in cases:
            with self.subTest(changes=changes):
                request, _ = request_for(self, [[dict(DRAFT, **changes)]])
                with self.assertRaisesRegex(ValueError, message):
                    recovery.find_draft(REPO, CURRENT, request)

    def test_any_different_workflow_commit_must_rerun_the_original(self):
        for other in ("b" * 40, "c" * 40):
            with self.subTest(other=other):
                request, _ = request_for(self, [[DRAFT]])
                with self.assertRaisesRegex(ValueError, f"Rerun the original release workflow for {TARGET}"):
                    recovery.find_draft(REPO, other, request)


class Main(unittest.TestCase):
    def test_output_is_written_only_after_all_verification_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp) / "outputs"
            output.write_text("existing=value\n")
            env = {"GH_REPO": REPO, "GITHUB_SHA": CURRENT, "GITHUB_OUTPUT": str(output)}
            invalid, _ = request_for(self, [[dict(DRAFT, target_commitish="main")]])
            valid, _ = request_for(self, [[DRAFT]])
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(recovery.main(env, invalid), 1)
                self.assertEqual(recovery.main(dict(env, GITHUB_SHA="b" * 40), valid), 1)
            self.assertEqual(output.read_text(), "existing=value\n")
            self.assertEqual(recovery.main(env, valid), 0)
            self.assertTrue(output.read_text().endswith(
                f"found=true\ntag_name=godot-plugin-v0.2.0\nsha={TARGET}\nrelease_id=123\n"))

    def test_gh_pagination_keeps_tokens_out_of_command_arguments(self):
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps([[DRAFT]]))
        with mock.patch.object(recovery.subprocess, "run", return_value=completed) as run:
            self.assertEqual(recovery.gh_json("repos/example/repo/releases?per_page=100", paginate=True), [[DRAFT]])
        self.assertEqual(run.call_args.args[0],
                         ["gh", "api", "repos/example/repo/releases?per_page=100", "--paginate", "--slurp"])
        self.assertIs(run.call_args.kwargs["check"], True)

    def test_failed_api_call_does_not_emit_success_outputs(self):
        def failed(*args, **kwargs):
            raise subprocess.CalledProcessError(1, ["gh", "api"], stderr="private response")

        with tempfile.TemporaryDirectory() as tmp:
            output = pathlib.Path(tmp) / "outputs"
            env = {"GH_REPO": REPO, "GITHUB_SHA": CURRENT, "GITHUB_OUTPUT": str(output)}
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                self.assertEqual(recovery.main(env, failed), 1)
            self.assertFalse(output.exists())
            self.assertNotIn("private response", err.getvalue())


if __name__ == "__main__":
    unittest.main()
