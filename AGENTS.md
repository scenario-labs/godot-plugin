# godot-plugin: agent instructions

Root `AGENTS.md` is the repository rulebook; `.claude/CLAUDE.md` links here.
Read [llms.txt](llms.txt) first: it maps the code and lists the rules any change
must keep. [README.md](README.md) describes the plugin for users.

## What this repository is

A Godot 4.7 editor plugin, GDScript only, in `addons/scenario/`. The repository
root is a small demo project that hosts the addon and its tests. `addons/gut/`
(GUT) and `addons/agentkit/` (from the toolkit below) serve the tests only: the
release zip holds `addons/scenario/` alone.

## Commands

Godot 4.7 is found through `$GODOT`, then `godot` on the PATH. The test tools
drive it with the scenario-godot-expert toolkit from scenario-labs/skills, at
the commit pinned in `tools/toolkit.py`.

```sh
make toolkit   # the pinned toolkit into .toolkit/; addons/agentkit must match it
make test      # GUT unit tests and the headless editor test (fake backend, 0 CU)
make zip       # release zip, then a clean install into a blank project
make lint      # gdlint on addons/scenario and tests, ruff on tools (needs uv)
make agents    # shared agent skills valid and linked (needs uv)
```

CI (`.github/workflows/ci.yml`) runs all five on Linux; `ci-ok` requires every
job. `tools/contract_check.py` is free but needs `SCENARIO_API_KEY` and
`SCENARIO_API_SECRET`. `make live` (`tools/live_acceptance.py`) spends Creative
Units: never run it without explicit authorization for the project and budget.

## Rules

- The spending rules in `llms.txt` hold for every change: price check first,
  single-use quotes, paid calls sent once, `SCENARIO_NO_SPEND=1` honored.
- Commit the `.uid` file Godot writes next to every new script. CI fails when
  the import or the tests add or change any file in the checkout.
- Tests write only to ignored folders (`.agent_out/`, `tests/tmp_output/`, `.godot/`).
- Do not edit `addons/gut/` or `addons/agentkit/` by hand. AgentKit follows the
  toolkit pin: bump `REF` in `tools/toolkit.py`, then `make toolkit`,
  `python3 tools/toolkit.py sync` and `make test`.
- `.agents/skills/` holds skills shared by every Scenario repository
  (`skills-lock.json`); change them upstream. `.claude/skills/` links to them.
- No em dashes, in code, docs, commit messages and PR titles.

## Commits and pull requests

- Branch from `main`; PRs are squash-merged, so the PR title becomes the commit
  header and the changelog line. Titles follow Conventional Commits with a scope
  from `commitlint.config.mjs`; the `pr-title` check enforces it.
- Fill `.github/pull_request_template.md`; tick only what you ran.
