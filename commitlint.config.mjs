// Single source of truth for commit headers and PR titles. CI installs
// commitlint from pnpm-lock.yaml (.github/workflows/pr-name.yml and
// commitlint.yml). The same check locally, with the Node version in .nvmrc:
//
//   pnpm install --frozen-lockfile
//   printf '%s\n' "feat(lanes): my title" | pnpm exec commitlint --verbose

// U+2014 written as a code point so that this file contains no em dash itself.
const EM_DASH = String.fromCharCode(0x2014);

/** @type {import('@commitlint/types').Plugin} */
const houseRules = {
  rules: {
    // House style: no em dashes anywhere, commit messages and PR titles included.
    "no-em-dash": ({ raw }) => [
      !(raw ?? "").includes(EM_DASH),
      "no em dashes in commit messages or PR titles (house style)",
    ],
  },
};

/** @type {import('@commitlint/types').UserConfig} */
export default {
  extends: ["@commitlint/config-conventional"],
  plugins: [houseRules],
  rules: {
    // Allow longer headers than the 100-character default (same as the sibling repos).
    "header-max-length": [2, "always", 120],
    // Off: long URLs and Co-Authored-By trailers exceed the 100-character default.
    "body-max-line-length": [0, "always", 200],
    "footer-max-line-length": [0, "always", 200],
    // Off: Godot, GUT, MCP, GLB and PBR start many subjects.
    "subject-case": [0],
    // Warn, never fail: the release-please PR is "chore: release X.Y.Z" with no scope.
    "scope-empty": [1, "never"],
    "scope-enum": [
      2,
      "always",
      [
        "core", // addons/scenario/core cross-cutting: errors, files, credentials
        "mcp", // mcp_client.gd and sse.gd: Scenario MCP calls, sessions, replies
        "quote", // quote.gd: prices, fingerprints, single-use quotes
        "jobs", // job_ledger.gd: durable job list, states, reconcile
        "schema", // schema_form.gd: model schema to form fields and payloads
        "lanes", // lanes.gd: the lanes, their models and presets
        "editor", // addons/scenario/plugin.gd and editor/: controller, placer, transport
        "ui", // editor/dock_ui.gd and the dock's look
        "tests", // test harness only; a test for a product area keeps the product scope
        "tools", // tools/ and the Makefile
        "docs", // README.md, docs/
        "ci", // .github/workflows, .github/actions, rulesets
        "deps", // pins: Godot, the toolkit, AgentKit, GUT, actions, npm
        "release", // release-please config and manifest, version fields, CHANGELOG plumbing
        "agents", // AGENTS.md, .agents/, .claude/
        "repo", // LICENSE, community files, templates, CODEOWNERS, editor and lint configs
      ],
    ],
    "no-em-dash": [2, "always"],
  },
};
