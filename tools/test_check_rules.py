"""House rules: em dashes and action pins.

Run: python3 -m unittest discover -s tools (make tools-test).
"""
import unittest

import check_rules

SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"


class EmDashTest(unittest.TestCase):
    def test_reports_the_line(self):
        self.assertEqual(check_rules.em_dash_problems("README.md", "ok\nnot \u2014 ok\n"),
                         ["README.md:2: em dash; use a comma, a colon, parentheses or two sentences"])

    def test_exempts_the_changelog_and_recorded_replies(self):
        self.assertEqual(check_rules.em_dash_problems("CHANGELOG.md", "\u2014"), [])
        self.assertEqual(check_rules.em_dash_problems("tests/fixtures/schema.sse", "\u2014"), [])

    def test_allows_an_en_dash(self):
        self.assertEqual(check_rules.em_dash_problems("README.md", "1–2"), [])


class PinTest(unittest.TestCase):
    def check(self, line, path=".github/workflows/ci.yml"):
        return check_rules.pin_problems(path, f"steps:\n{line}\n")

    def test_accepts_a_sha_with_its_version(self):
        self.assertEqual(self.check(f"      - uses: actions/checkout@{SHA} # v7.0.1"), [])
        self.assertEqual(self.check(f"        uses: github/codeql-action/upload-sarif@{SHA} # v4"), [])

    def test_skips_local_actions_and_other_files(self):
        self.assertEqual(self.check("      - uses: ./.github/actions/setup-godot"), [])
        self.assertEqual(self.check("      - uses: actions/checkout@v7", path="docs/USER_GUIDE.md"), [])

    def test_reports_a_tag(self):
        self.assertEqual(self.check("      - uses: actions/checkout@v7"),
                         [".github/workflows/ci.yml:2: pin actions/checkout@v7 to a full commit SHA"])

    def test_reports_a_missing_version(self):
        self.assertEqual(self.check(f"      - uses: actions/checkout@{SHA}"),
                         [".github/workflows/ci.yml:2: add the version after the SHA, as `# vX.Y.Z`"])

    def test_reads_other_yaml_forms(self):
        self.assertEqual(len(self.check("      - uses : actions/checkout@v7")), 1)
        self.assertEqual(len(self.check("      - { name: x, uses: actions/checkout@v7 }")), 1)
        self.assertEqual(len(self.check("      - uses: 'actions/checkout@v7'")), 1)
        self.assertEqual(self.check(f"      - {{ uses: actions/checkout@{SHA} }} # v7.0.1"), [])

    def test_ignores_keys_that_only_end_in_uses(self):
        self.assertEqual(self.check("      refuses: actions/checkout@v7"), [])

    def test_reads_composite_actions(self):
        self.assertEqual(len(self.check("      uses: actions/cache@v5", path=".github/actions/setup-godot/action.yml")), 1)


if __name__ == "__main__":
    unittest.main()
