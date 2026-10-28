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
    body = block(text, "on")
    # A block list (`- pull_request`) names events too, and either form may quote the name.
    keys = re.findall(r"""^  (['"]?)([\w-]+)\1:""", body, re.MULTILINE)
    items = re.findall(r"""^  -\s*(['"]?)([\w-]+)\1\s*(?:#.*)?$""", body, re.MULTILINE)
    return {name for _, name in keys + items}


def jobs(text: str) -> dict[str, str]:
    body = block(text, "jobs")
    names = []
    for key, rest in re.findall(r"^  ([^\s#][^:]*):(.*)$", body, re.MULTILINE):
        if rest.strip() and not rest.strip().startswith("#"):
            raise AssertionError(f"write job `{key}` as a block")
        names.append(key)
    return {name: block(body, name, indent=2) for name in names}


def runs_on_pull_requests(body: str) -> bool:
    """False only when the job's `if:` is a plain `&&` chain with the pull request exclusion as one term."""
    guard = re.search(r"(?m)^    if:\s*(.+)$", body)
    if guard is None:
        return True
    expression = guard.group(1).strip()
    expression = re.sub(r"^\$\{\{(.*)\}\}$", r"\1", expression).strip()
    # A comment could hold a fake term, so a guard carrying one does not count.
    if "||" in expression or re.search(r"\s#", expression):
        return True
    return "github.event_name != 'pull_request'" not in [term.strip() for term in expression.split("&&")]


def scalar(value: str) -> str:
    """A YAML scalar without its quotes or trailing comment."""
    value = value.strip()
    quoted = re.match(r"""^(['"])(.*?)\1""", value)
    if quoted:
        return quoted.group(2)
    return re.split(r"\s#", value, maxsplit=1)[0].strip()


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
    inline = re.search(r"^permissions:[ \t]*([^\s#][^#\n]*)", text, re.MULTILINE)
    return inline.group(1) if inline else block(text, "permissions")


def run_scripts(text: str) -> list[str]:
    """The text of every `run:` step, inline or block."""
    scripts = []
    for match in re.finditer(r"(?m)^(\s*)(?:-\s+)?run:[ \t]*(.*)$", text):
        indent, value = len(match.group(1)), match.group(2)
        if value.strip() and value.strip()[0] not in "|>":
            scripts.append(value)
            continue
        lines = []
        for line in text[match.end():].splitlines()[1:]:
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                break
            lines.append(line)
        scripts.append("\n".join(lines))
    return scripts


def local_actions(text: str) -> set[pathlib.Path]:
    refs = re.findall(r"uses:\s*['\"]?(\./\.github/actions/[\w-]+)", text)
    return {next((ROOT / ref / f for f in ("action.yml", "action.yaml") if (ROOT / ref / f).is_file()), ROOT / ref / "action.yml")
            for ref in refs}


class WorkflowPolicyTest(unittest.TestCase):
    def setUp(self):
        paths = sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])
        self.files = {path.name: path.read_text() for path in paths}
        self.assertTrue(self.files)

    def test_mapping_keys_are_plain(self):
        # The checks below read keys as written; "permissions": or permissions : would slip past them.
        for name, text in self.files.items():
            with self.subTest(workflow=name):
                self.assertNotRegex(text, r"""(?m)^\s*(?:-\s+)?(['"])[^'"\n]*\1\s*:(?:\s|$)""")
                self.assertNotRegex(text, r"(?m)^\s*(?:-\s+)?[\w-]+\s+:(?:\s|$)")

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
                # Pull request values reach a script only through env:, never spliced into its text.
                for script in run_scripts(text):
                    self.assertNotIn("${{", script)

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
                    self.assertFalse(runs_on_pull_requests(body), f"job {job}")

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

    def test_check_names_on_pull_requests_are_unique(self):
        # A job without `name` is checked under its id, so required checks such as pr-title stay unique.
        seen = {}
        for name, text in self.files.items():
            if "pull_request" not in events(text):
                continue
            for job, body in jobs(text).items():
                if not runs_on_pull_requests(body):
                    continue
                explicit = re.search(r"(?m)^    name:\s*(.+)$", body)
                check = scalar(explicit.group(1)) if explicit else job
                with self.subTest(check=check):
                    self.assertNotIn(check, seen, f"{name} and {seen.get(check)}")
                seen[check] = name


class ParserTest(unittest.TestCase):
    def test_write_scopes(self):
        self.assertEqual(write_scopes("{}"), [])
        self.assertEqual(write_scopes("read-all"), [])
        self.assertEqual(write_scopes("write-all"), ["write-all"])
        self.assertEqual(write_scopes("\n  contents: read\n  issues: write  # report\n"), ["issues"])
        with self.assertRaises(AssertionError):
            write_scopes("\n  contents: maybe\n")

    def test_list_events_are_read(self):
        self.assertEqual(events("on:\n  - pull_request\n  - push\n"), {"pull_request", "push"})
        self.assertEqual(events("on:\n  - \"pull_request\"\n  - 'push' # c\n"), {"pull_request", "push"})
        self.assertEqual(events("on:\n  \"pull_request\":\n"), {"pull_request"})

    def test_comment_after_permissions_reads_the_block(self):
        self.assertEqual(write_scopes(top_permissions("permissions: # c\n  issues: write\njobs:\n")), ["issues"])
        self.assertEqual(top_permissions("permissions: read-all # c\n").strip(), "read-all")

    def test_pull_request_guard(self):
        excluded = "    if: ${{ always() && github.event_name != 'pull_request' && needs.a.result == 'failure' }}\n"
        self.assertFalse(runs_on_pull_requests(excluded))
        self.assertTrue(runs_on_pull_requests("    if: github.event_name != 'pull_request' || always()\n"))
        self.assertTrue(runs_on_pull_requests("    if: !(github.event_name != 'pull_request')\n"))
        self.assertTrue(runs_on_pull_requests("    runs-on: x\n"))
        self.assertTrue(runs_on_pull_requests("    if: always() # && github.event_name != 'pull_request'\n"))

    def test_scalar(self):
        self.assertEqual(scalar("lint # explanation"), "lint")
        self.assertEqual(scalar('"lint"'), "lint")
        self.assertEqual(scalar("'lint' # c"), "lint")
        self.assertEqual(scalar("godot ${{ matrix.godot }}"), "godot ${{ matrix.godot }}")

    def test_run_scripts(self):
        text = "    steps:\n      - run: echo ${{ x }}\n      - name: b\n        run: |\n          echo a\n          echo ${{ y }}\n      - run: echo c\n"
        self.assertEqual(run_scripts(text), ["echo ${{ x }}", "          echo a\n          echo ${{ y }}", "echo c"])

    def test_inline_on_is_refused(self):
        with self.assertRaises(AssertionError):
            events("on: [pull_request]\n")

    def test_jobs_and_events(self):
        text = "on:\n  pull_request:\n  push:\njobs:\n  a:\n    runs-on: x\n  b:\n    if: always()\n"
        self.assertEqual(events(text), {"pull_request", "push"})
        self.assertEqual(set(jobs(text)), {"a", "b"})
        self.assertIn("if: always()", jobs(text)["b"])
        self.assertEqual(set(jobs("jobs:\n  slow: # comment\n    runs-on: x\n")), {"slow"})
        with self.assertRaises(AssertionError):
            jobs("jobs:\n  inline: {runs-on: x}\n")


if __name__ == "__main__":
    unittest.main()
