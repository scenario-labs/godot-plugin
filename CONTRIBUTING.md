# Contributing to Scenario for Godot

Thanks for helping. This guide covers what a pull request needs; the commands,
rules and code map live in [AGENTS.md](AGENTS.md), which humans and coding
agents both follow.

## Before you start

- For anything larger than a small fix, open a change request first
  ([issue chooser](https://github.com/scenario-labs/godot-plugin/issues/new/choose))
  so the approach can be agreed before you write it.
- Read the spending rules in `AGENTS.md`: price check first, single-use quotes,
  paid calls sent once, `SCENARIO_NO_SPEND=1` honored. Every change keeps them.

## Set up

- Godot 4.7, as `godot` on the PATH or with `GODOT` pointing to the editor binary.
- Python 3 and git. `make toolkit` fetches the test toolkit pinned in
  `tools/toolkit.py` into `.toolkit/`.
- [uv](https://docs.astral.sh/uv/) for `make lint` and `make agents`.
- Node.js (the version in `.nvmrc`) and pnpm for commit lint: `pnpm install`.

## Run the checks

`make toolkit`, then `make test` (unit tests and the headless editor test
against a fake backend, 0 CU), `make zip` for packaging changes and `make lint`.
AGENTS.md lists every check CI runs. Live checks against Scenario need a test
key; the paid one (`make smoke`) spends Creative Units and needs authorization
for the project and budget first.

## Commits and pull requests

- Branch from `main`. Pull requests are squash-merged: the PR title becomes the
  commit header and the changelog line, so it follows Conventional Commits with
  a scope from `commitlint.config.mjs`, for example
  `fix(editor): keep the selection after placing a material`.
- Keep one concern per pull request and fill the template briefly: the checks
  you ran, any action needed after merge and any known gap. Tick only what you
  ran.
- Do not edit versions or `CHANGELOG.md`: release-please does.
- Show UI changes with before/after screenshots of the dock, attached to the
  pull request rather than committed.

## Coding agents

Agents follow AGENTS.md. Name the harness in the pull request and keep accurate
co-author trailers on commits and in the squash message. A human reviews the
complete diff before merge.

## Licensing

The repository is under the [MIT License](LICENSE). By contributing, you agree
that your contributions are licensed under the same terms. Code or assets
adopted from elsewhere keep their compatible license and attribution.
