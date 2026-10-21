"""Workflow policy: permissions, pull_request_target, secrets on pull requests, and the CI gate.

Run: python3 -m unittest discover -s tools (make tools-test). These checks read the
block-style YAML this repository writes; a form they do not understand fails rather
than being skipped.
"""
import pathlib, re, unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
# Adds pull requests to the Plugins project; it never checks out or runs their code.
TARGET_ALLOWED = {"project.yml"}
# The free contract check runs on pull requests that change core/; forks get no secrets.
SECRETS_ON_PR_ALLOWED = {"contract.yml"}


def block(text: str, key: str, indent: int = 0) -> str:
    """The lines under `key:` at `indent`, up to the next line indented as much or less."""
    match = re.search(rf"^{' ' * indent}{re.escape(key)}:[ \t]*(?:#.*)?$", text, re.MULTILINE)
    if match is None:
        raise AssertionError(f"expected block-style `{key}:` at indent {indent}")
    lines = []
    for line in text[match.end():].splitlines()[1:]:
        if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) <= indent:
            break
        lines.append(line)
    return "\n".join(lines)


def events(text: str) -> set[str]:
    inline = re.search(r"^on:[ \t]*(\S.*)$", text, re.MULTILINE)
    if inline and not inline.group(1).startswith("#"):
        raise AssertionError("write `on:` as a block")
    return set(re.findall(r"^  ([\w-]+):", block(text, "on"), re.MULTILINE))


def jobs(text: str) -> dict[str, str]:
    body = block(text, "jobs")
    names = re.findall(r"^  ([\w-]+):[ \t]*$", body, re.MULTILINE)
    return {name: block(body, name, indent=2) for name in names}


def write_scopes(permissions: str) -> list[str]:
    """Scopes a permissions value or block grants write on."""
    value = permissions.strip()
    if value in ("{}", "read-all"):
        return []
    if value == "write-all":
        return ["write-all"]
    out = []
    for line in value.splitlines():
        entry = line.split("#", 1)[0].strip()
        if not entry:
            continue
        scope = re.fullmatch(r"([\w-]+):\s*(read|write|none)", entry)
        if scope is None:
            raise AssertionError(f"unexpected permissions entry: {entry}")
        if scope.group(2) == "write":
            out.append(scope.group(1))
    return out


def top_permissions(text: str) -> str:
    inline = re.search(r"^permissions:[ \t]*(\S[^#\n]*)", text, re.MULTILINE)
    return inline.group(1) if inline else block(text, "permissions")


def local_actions(text: str) -> set[pathlib.Path]:
    return {ROOT / ref / "action.yml" for ref in re.findall(r"uses:\s*['\"]?(\./\.github/actions/[\w-]+)", text)}


class WorkflowPolicyTest(unittest.TestCase):
    def setUp(self):
        self.files = {path.name: path.read_text() for path in sorted(WORKFLOWS.glob("*.yml"))}
        self.assertTrue(self.files)

    def test_every_workflow_declares_permissions(self):
        for name, text in self.files.items():
            with self.subTest(workflow=name):
                self.assertRegex(text, r"(?m)^permissions:")

    def test_pull_request_target_only_where_it_never_runs_pr_code(self):
        for name, text in self.files.items():
            if "pull_request_target" not in text:
                continue
            with self.subTest(workflow=name):
                self.assertIn(name, TARGET_ALLOWED)
                self.assertNotIn("actions/checkout", text)
                self.assertNotIn("pull_request.head", text)

    def test_pull_request_workflows_stay_read_only(self):
        for name, text in self.files.items():
            if "pull_request" not in events(text):
                continue
            with self.subTest(workflow=name):
                self.assertEqual(write_scopes(top_permissions(text)), [])
                for job, body in jobs(text).items():
                    if "permissions:" not in body or not write_scopes(block(body, "permissions", indent=4)):
                        continue
                    # A job that writes, such as a failure report, must not run for pull requests.
                    self.assertRegex(body, r"(?m)^    if:.*github\.event_name != 'pull_request'", f"job {job}")

    def test_secrets_on_pull_requests_only_where_allowed(self):
        for name, text in self.files.items():
            if "pull_request" not in events(text):
                continue
            with self.subTest(workflow=name):
                if re.search(r"\bsecrets\b", text, re.IGNORECASE):
                    self.assertIn(name, SECRETS_ON_PR_ALLOWED)
                for action in local_actions(text):
                    self.assertTrue(action.is_file(), action)
                    self.assertNotRegex(action.read_text(), r"(?i)\bsecrets\b", action)

    def test_ci_ok_waits_for_every_ci_job(self):
        ci = jobs(self.files["ci.yml"])
        gate = ci.pop("ci-ok")
        needs = re.search(r"(?m)^    needs:\s*\[([^\]]*)\]", gate)
        self.assertIsNotNone(needs, "keep ci-ok needs as an inline list")
        self.assertEqual({n.strip() for n in needs.group(1).split(",")}, set(ci))
        self.assertRegex(gate, r"(?m)^    if:\s*always\(\)\s*$")

    def test_job_names_are_unique(self):
        seen = {}
        for name, text in self.files.items():
            for job in re.findall(r"(?m)^    name:\s*(.+)$", text):
                with self.subTest(job=job):
                    self.assertNotIn(job, seen, f"{name} and {seen.get(job)}")
                seen[job] = name


class ParserTest(unittest.TestCase):
    def test_write_scopes(self):
        self.assertEqual(write_scopes("{}"), [])
        self.assertEqual(write_scopes("read-all"), [])
        self.assertEqual(write_scopes("write-all"), ["write-all"])
        self.assertEqual(write_scopes("\n  contents: read\n  issues: write  # report\n"), ["issues"])
        with self.assertRaises(AssertionError):
            write_scopes("\n  contents: maybe\n")

    def test_inline_on_is_refused(self):
        with self.assertRaises(AssertionError):
            events("on: [pull_request]\n")

    def test_jobs_and_events(self):
        text = "on:\n  pull_request:\n  push:\njobs:\n  a:\n    runs-on: x\n  b:\n    if: always()\n"
        self.assertEqual(events(text), {"pull_request", "push"})
        self.assertEqual(set(jobs(text)), {"a", "b"})
        self.assertIn("if: always()", jobs(text)["b"])


if __name__ == "__main__":
    unittest.main()
