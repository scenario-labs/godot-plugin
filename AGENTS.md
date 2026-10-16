# godot-plugin: agent instructions

Root `AGENTS.md` is the repository rulebook; `.claude/CLAUDE.md` links here.
[README.md](README.md) describes the plugin for users.

## What this repository is

A Godot 4.7 editor plugin, GDScript only, in `addons/scenario/`. It generates
images, 3D models, PBR materials, skyboxes and sound effects through the
Scenario MCP server (`https://mcp.scenario.com/mcp`: JSON-RPC 2.0 over HTTP,
SSE replies, Basic auth with an API key and secret) and places them in the open
scene. The repository root is a small demo project that hosts the addon and its
tests. `addons/gut/` (GUT) and `addons/agentkit/` (from the toolkit below) serve
the tests only: the release zip holds `addons/scenario/` alone.

## Code map

In `addons/scenario/`:

- `plugin.gd`: the `EditorPlugin`; editor settings `scenario/confirm_above_cu`
  and `scenario/auto_import`; creates the controller and the dock.
- `core/` (no editor API, unit-tested):
  - `mcp_client.gd`: Scenario MCP calls, session init and re-init, error kinds,
    retry policy (reads only), estimate and submit.
  - `sse.gd`: parses SSE or JSON replies, keeps the message matching the request id.
  - `quote.gd`: canonical JSON, fingerprint (model + parameters), single-use
    quote store.
  - `job_ledger.gd`: durable job list (`res://.godot/scenario/jobs.json`),
    states, reconciles Unknown rows with `jobs_list`.
  - `schema_form.gd`: model schema to form fields, validation, payload;
    `prompt_name()` finds the prompt field by its flag.
  - `lanes.gd`: the five lanes, their models, presets and restrictions.
  - `credentials.gd`: environment, macOS Keychain (`security -i` over stdin),
    or a 0600 file in the editor config folder.
  - `files.gd`: output names, roles from asset metadata, file type from bytes.
  - `errors.gd`: error kinds and user messages.
- `editor/`:
  - `controller.gd`: state and actions (price, generate, poll, import,
    references, recommendations); emits `changed`.
  - `dock_ui.gd`: the dock, built in code, no logic.
  - `placer.gd`: import with `.import` sidecars, then placement per lane
    through `EditorUndoRedoManager`.
  - `http_transport.gd`: `HTTPRequest` wrapper; uploads only to
    `*.amazonaws.com`, downloads only from Scenario CDN hosts.

Tests: GUT unit tests in `tests/unit/`, the headless editor test
`tests/editor/editor_flow_job.gd`, both against the fake backend
`tests/support/fake_scenario_node.gd`.

## Spending rules

Every change keeps them.

1. A price check is `model_run` with `dry_run: true`; if it returns a job id,
   automatic checks stop.
2. Generate needs an unused quote whose fingerprint matches the form now; it
   consumes it.
3. A paid call (`model_run` without dry_run, `workflow_run`, uploads) is sent
   once. A transport failure on it marks the job Unknown, which blocks the same
   fingerprint until reconciled.
4. The intent row is written to the ledger before the paid request.
5. `SCENARIO_NO_SPEND=1` refuses paid calls and uploads before any request;
   `job_cancel` still goes out.
6. The secret never goes under `res://`.

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
make archive   # the source archive holds addons/scenario alone
```

CI (`.github/workflows/ci.yml`) runs them on Linux, with `make tools-test`;
`ci-ok` requires every job. `tools/contract_check.py` is free but needs
`SCENARIO_API_KEY` and `SCENARIO_API_SECRET`. `make smoke`
(`tools/smoke.py`) spends Creative Units: never run it without
explicit authorization for the project and budget.

## Scheduled and manual checks

Informational, never required, and none spends unless noted. A failed
scheduled run opens or updates one Task issue per check
(`.github/actions/report-failure`).

| Workflow | When | What |
| --- | --- | --- |
| `contract.yml` | weekly, PRs changing `core/` | `tools/contract_check.py`, 0 CU (test key secrets) |
| `godot-os.yml` | weekly | tests and zip check on Linux, macOS, Windows, the .NET build (Linux), and the newest Godot build |
| `links.yml` | weekly, docs PRs | links in Markdown (except the generated `CHANGELOG.md`) |
| `dock.yml` | UI PRs | dock screenshot as an artifact |
| `scorecard.yml` | weekly, `main` | OpenSSF Scorecard |
| `smoke.yml` | manual | PAID `tools/smoke.py`, `smoke` environment with its own `SCENARIO_TEST_*` secrets, reviewer approval and a 200 CU cap per run (no total cap in CI) |

## Rules

- Commit the `.uid` file Godot writes next to every new script. CI fails when
  the import or the tests add or change any file in the checkout.
- Tests write only to ignored folders (`.agent_out/`, `tests/tmp_output/`, `.godot/`).
- Do not edit `addons/gut/` or `addons/agentkit/` by hand. AgentKit follows the
  toolkit pin: bump `REF` in `tools/toolkit.py`, then `make toolkit`,
  `python3 tools/toolkit.py sync` and `make test`.
- `.agents/skills/` holds skills shared by every Scenario repository
  (`skills-lock.json`); change them upstream. `.claude/skills/` links to them.
- No em dashes, in code, docs, commit messages and PR titles.
- This repository is public: no credentials, session IDs, personal paths,
  account or project records, or spend anecdotes in code, docs, commits or PRs.
  The exception is `tests/smoke/LEDGER.md`: `tools/smoke.py` records
  each authorized paid run there (job ID, CU) and reads it back for the cap.
- Keep doc edits in a feature PR to the prose the change makes wrong, in the
  fewest words that state current behavior. Test runs, platforms and review
  notes belong in the PR body, not in docs.

## Commits and pull requests

- Branch from `main`; PRs are squash-merged, so the PR title becomes the commit
  header and the changelog line. Titles follow Conventional Commits with a scope
  from `commitlint.config.mjs`; the `pr-title` check enforces it. Pick the type
  from the final diff: `fix` only for behavior users of the released plugin or
  the website saw; a correction to tooling, CI or infrastructure they do not run
  is `chore` (or `ci`, `build`, `docs`), and its issue is a Task, not a Bug.
- Fill `.github/pull_request_template.md`; tick only what you ran.
- Write PR descriptions, commit bodies and review replies briefly: what changed
  and why, the checks you ran (one line each), and any action needed after merge
  or known gap. Omit what the diff, CI or the template already shows; explain an
  unticked check only when the change needed it. Branch commit bodies are
  optional, a sentence or two. Pass multiline bodies from a file
  (`--body-file`, `-F`).
- `Closes #n` only for complete issue scope, `Refs #n` otherwise, saying what
  remains. Do not keep a reviewable PR in draft for untested edge cases: track
  them in the issue and link it.
- Screenshots of a visible change go in the PR description, never in a commit.
  GitHub has no command-line upload, so an agent saves them, numbered, in
  `.agent_out/pr-screenshots/<branch>/`, leaves a `[drop <file>]` placeholder
  per image in the description, and gives the person the folder's absolute
  path.
- After investigating a review comment, human or bot, reply in its thread with
  the pushed fix and evidence, or why no change is needed (`/pr-handle-comments`).
- Give every new issue the type its title implies: Bug for `fix`, Feature for
  `feat`, otherwise Task (`gh issue create --type <Type>`, gh 2.94 or later).
- Name the contributing agent in the PR and keep its co-author trailer on
  commits and in the squash message. Codex writes
  `Co-authored-by: Codex <model> <effort> <tier> <noreply@openai.com>` with the
  session's actual settings, leaving out unknown fields.
- `project.yml` adds each pull request, once ready for review, to the shared
  Plugins project (organization project 31) as "👀 In review".

## Releases

release-please keeps a release PR open on `main` (`release-please-config.json`).
Merging it drafts the GitHub release `godot-plugin-vX.Y.Z`; the workflow then
builds the zip from the release commit on the pinned Godot, installs it into a
blank project, attaches the zip, `SHA256SUMS` and a provenance bundle, publishes
the draft, and `publish-changelog.yml` posts the notes to scenario.com.

- Never edit versions or `CHANGELOG.md` by hand: release-please bumps
  `plugin.cfg`, `mcp_client.gd`, `README.md` and `docs/USER_GUIDE.md` (the
  `x-release-please` markers) and writes the changelog from the squashed PR
  titles.
- The source archive (GitHub downloads, the Godot Asset Library) holds
  `addons/scenario/` alone; `.gitattributes` allowlists it and `make archive`
  checks it.

## Website and download counts

`pages.yml` publishes `docs/USER_GUIDE.md` as one page (`tools/build_site.py`,
`docs/site/template.html`; `make site` builds it into `dist/site`) to GitHub
Pages, with the latest release zip once its checksum and build provenance
verify. The page has the look of the Blender plugin's site: `docs/site/site.css`
and the guide search `docs/site/handbook-search.js` come from there, so restyle
both sites together. `tools/site_proxy/` is a Vercel project in front of Pages
that counts zip downloads in PostHog (anonymous; `plugin: "godot"`, the Godot
version and OS from the editor's User-Agent); its Vercel Web Analytics counts
page visits and Download clicks, without cookies, from the script in
`docs/site/template.html`, served at a path of ours (`vercel.json`) because
blocker lists block Vercel's own. `make site-test` type-checks and
tests the proxy and the search. The page content comes from the guide: change
the guide, not the site.
