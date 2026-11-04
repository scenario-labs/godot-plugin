"""Workflow policy: permissions, pull_request_target, secrets on pull requests, and the CI gate.

Run: make tools-test, which provides PyYAML. The workflows are read with a YAML parser,
so quoting, spacing and indentation cannot hide a key from these checks.
"""
import hashlib, pathlib, re, unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
# Adds pull requests to the Plugins project; it never checks out or runs their code. The file
# is pinned whole, version pins aside: a change to it fails here until the hash is updated
# in the same reviewed diff, since no list of banned commands can keep PR code out.
TARGET_ALLOWED = {"project.yml": "d2b51f53828ac03af71451bd630f20d2ec8c37b22273b424e8291cd4472c9bc7"}
# The only actions a pull_request_target workflow may use: no local action, no checkout.
TARGET_ACTIONS = {"actions/create-github-app-token"}
# The free contract check runs on pull requests that change core/; forks get no secrets.
SECRETS_ON_PR_ALLOWED = {"contract.yml"}
PR_EVENTS = {"pull_request", "pull_request_target"}


def load(text: str) -> dict:
    doc = yaml.safe_load(text)
    # YAML 1.1 reads an unquoted `on` key as true.
    if True in doc:
        doc["on"] = doc.pop(True)
    return doc


def events(doc: dict) -> set[str]:
    on = doc.get("on")
    if isinstance(on, str):
        return {on}
    if isinstance(on, (list, dict)):
        return set(on)
    raise AssertionError(f"unexpected `on`: {on!r}")


def write_scopes(permissions) -> list[str]:
    """Scopes a permissions value grants write on."""
    if permissions in ({}, "read-all"):
        return []
    if permissions == "write-all":
        return ["write-all"]
    if not isinstance(permissions, dict):
        raise AssertionError(f"unexpected permissions: {permissions!r}")
    for scope, level in permissions.items():
        if level not in ("read", "write", "none"):
            raise AssertionError(f"unexpected permissions entry: {scope}: {level}")
    return [scope for scope, level in permissions.items() if level == "write"]


def runs_on_pull_requests(job: dict, triggers=frozenset({"pull_request"})) -> bool:
    """False only when the job's `if:` is a plain `&&` chain excluding each pull request event the workflow has."""
    guard = job.get("if")
    if not isinstance(guard, str):
        return True
    expression = re.sub(r"^\$\{\{(.*)\}\}$", r"\1", guard.strip(), flags=re.DOTALL).strip()
    if "||" in expression:
        return True
    terms = {" ".join(term.split()) for term in expression.split("&&")}
    return not all(f"github.event_name != '{event}'" in terms for event in PR_EVENTS & set(triggers))


def pinned_hash(text: str) -> str:
    """SHA-256 of a workflow with its action version pins blanked, so Dependabot bumps keep it."""
    return hashlib.sha256(re.sub(r"(uses:\s*[\w./-]+)@\S+(\s*#.*)?", r"\1@pinned", text).encode()).hexdigest()


def steps(doc: dict) -> list[dict]:
    return [step for job in doc["jobs"].values() for step in job.get("steps", [])]


def local_actions(doc: dict) -> set[pathlib.Path]:
    refs = {step["uses"] for step in steps(doc) if str(step.get("uses", "")).startswith("./")}
    return {next((ROOT / ref / f for f in ("action.yml", "action.yaml") if (ROOT / ref / f).is_file()), ROOT / ref / "action.yml")
            for ref in refs}


class WorkflowPolicyTest(unittest.TestCase):
    def setUp(self):
        paths = sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])
        self.texts = {path.name: path.read_text() for path in paths}
        self.docs = {name: load(text) for name, text in self.texts.items()}
        self.assertTrue(self.docs)

    def test_every_workflow_declares_permissions(self):
        for name, doc in self.docs.items():
            with self.subTest(workflow=name):
                self.assertIn("permissions", doc)

    def test_pull_request_target_only_where_it_never_runs_pr_code(self):
        for name, doc in self.docs.items():
            if "pull_request_target" not in events(doc):
                continue
            with self.subTest(workflow=name):
                self.assertIn(name, TARGET_ALLOWED)
                self.assertEqual(pinned_hash(self.texts[name]), TARGET_ALLOWED[name], "review the change, then update the hash")
                # Property or index access alike: pull_request.head, pull_request['head'].
                self.assertNotRegex(self.texts[name], r"pull_request\W{0,3}head")
                for job_id, job in doc["jobs"].items():
                    # A reusable workflow would escape the action allowlist below.
                    self.assertNotIn("uses", job, f"job {job_id}")
                for step in steps(doc):
                    if "uses" in step:
                        self.assertIn(step["uses"].split("@")[0], TARGET_ACTIONS)
                    # Pull request values reach a script only through env:, never spliced into its text.
                    self.assertNotIn("${{", str(step.get("run", "")))

    def test_pull_request_workflows_stay_read_only(self):
        for name, doc in self.docs.items():
            if not PR_EVENTS & events(doc):
                continue
            with self.subTest(workflow=name):
                self.assertEqual(write_scopes(doc.get("permissions")), [])
                for job_id, job in doc["jobs"].items():
                    if write_scopes(job.get("permissions", {})):
                        # A job that writes, such as a failure report, must not run for pull requests.
                        self.assertFalse(runs_on_pull_requests(job, events(doc)), f"job {job_id}")

    def test_secrets_on_pull_requests_only_where_allowed(self):
        for name, doc in self.docs.items():
            if "pull_request" not in events(doc):
                continue
            with self.subTest(workflow=name):
                if re.search(r"\bsecrets\b", self.texts[name], re.IGNORECASE):
                    self.assertIn(name, SECRETS_ON_PR_ALLOWED)
                for action in local_actions(doc):
                    self.assertTrue(action.is_file(), action)
                    self.assertNotRegex(action.read_text(), r"(?i)\bsecrets\b", action)

    def test_ci_ok_waits_for_every_ci_job(self):
        jobs = dict(self.docs["ci.yml"]["jobs"])
        # A job or step that may fail without failing would read as success to the gate.
        for job_id, job in jobs.items():
            self.assertNotIn("continue-on-error", job, f"job {job_id}")
            for step in job.get("steps", []):
                self.assertNotIn("continue-on-error", step, f"job {job_id}")
        gate = jobs.pop("ci-ok")
        self.assertEqual(set(gate["needs"]), set(jobs))
        self.assertEqual(gate.get("if"), "always()")
        # The gate fails when any needed job did not succeed.
        [step] = gate["steps"]
        self.assertEqual(step["env"]["RESULTS"], "${{ join(needs.*.result, ' ') }}")
        self.assertIn('[ "$result" != success ]', step["run"])
        self.assertIn("exit 1", step["run"])

    def test_check_names_on_pull_requests_are_unique(self):
        # A job without `name` is checked under its id, so required checks such as pr-title stay unique.
        seen = {}
        for name, doc in self.docs.items():
            if not PR_EVENTS & events(doc):
                continue
            for job_id, job in doc["jobs"].items():
                if not runs_on_pull_requests(job, events(doc)):
                    continue
                check = str(job.get("name", job_id))
                with self.subTest(check=check):
                    self.assertNotIn(check, seen, f"{name} and {seen.get(check)}")
                seen[check] = name


class ParserTest(unittest.TestCase):
    def test_write_scopes(self):
        self.assertEqual(write_scopes({}), [])
        self.assertEqual(write_scopes("read-all"), [])
        self.assertEqual(write_scopes("write-all"), ["write-all"])
        self.assertEqual(write_scopes({"contents": "read", "issues": "write"}), ["issues"])
        with self.assertRaises(AssertionError):
            write_scopes({"contents": "maybe"})

    def test_events_in_every_form(self):
        self.assertEqual(events(load("on: push\n")), {"push"})
        self.assertEqual(events(load("on: [pull_request, push]\n")), {"pull_request", "push"})
        self.assertEqual(events(load("'on':\n    \"pull_request\" :\n      types: [opened]\n")), {"pull_request"})

    def test_spaced_and_quoted_keys(self):
        doc = load("on: pull_request\njobs:\n  a:\n    \"permissions\" : write-all\n")
        self.assertEqual(write_scopes(doc["jobs"]["a"]["permissions"]), ["write-all"])

    def test_pull_request_guard(self):
        excluded = "${{ always() && github.event_name != 'pull_request' && needs.a.result == 'failure' }}"
        self.assertFalse(runs_on_pull_requests({"if": excluded}))
        self.assertTrue(runs_on_pull_requests({"if": "github.event_name != 'pull_request' || always()"}))
        self.assertTrue(runs_on_pull_requests({"if": "!(github.event_name != 'pull_request')"}))
        self.assertTrue(runs_on_pull_requests({}))
        # On pull_request_target the event name differs, so each pull request trigger needs its own term.
        target = {"pull_request_target"}
        self.assertTrue(runs_on_pull_requests({"if": "github.event_name != 'pull_request'"}, target))
        self.assertFalse(runs_on_pull_requests({"if": "github.event_name != 'pull_request_target'"}, target))
        both = {"pull_request", "pull_request_target"}
        self.assertTrue(runs_on_pull_requests({"if": "github.event_name != 'pull_request'"}, both))
        # YAML drops a comment, so a guard written in one is no guard.
        self.assertTrue(runs_on_pull_requests(load("a:\n  if: always() # && github.event_name != 'pull_request'\n")["a"]))


if __name__ == "__main__":
    unittest.main()
