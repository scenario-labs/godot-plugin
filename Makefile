# Scenario Godot Plugin. Requires Godot 4.7 (`godot` on PATH, or $GODOT), python3,
# and the scenario-godot-expert toolkit: `make toolkit` fetches the pinned copy.
.PHONY: test unit editor zip dock live toolkit lint agents

test:
	python3 tools/run_tests.py all

unit:
	python3 tools/run_tests.py unit

editor:
	python3 tools/run_tests.py editor

# Release zip, then a clean install into a blank project.
zip:
	python3 tools/build_zip.py --verify

# Dock screenshot for the docs (fake backend, 0 CU; opens a small window).
dock:
	python3 tools/capture_dock.py

# Paid: spends Creative Units on the test key's project. Opt-in only.
live:
	python3 tools/live_acceptance.py

# The toolkit commit pinned in tools/toolkit.py, into .toolkit/; addons/agentkit must match it.
toolkit:
	python3 tools/toolkit.py fetch
	python3 tools/toolkit.py check

# GDScript and Python lint, the same versions as CI. Requires uv.
lint:
	uvx --from gdtoolkit==4.5.0 gdlint addons/scenario tests
	uvx ruff@0.16.10 check tools

# Shared agent skills: valid per the Agent Skills spec, and linked for Claude Code. Requires uv.
SKILLS_REF := git+https://github.com/agentskills/agentskills.git@69ef37e9424c0a7ea9dd2293b559e43ec8176379\#subdirectory=skills-ref
agents:
	@for d in .agents/skills/*/; do n=$$(basename "$$d"); \
		uvx --from "$(SKILLS_REF)" skills-ref validate "$$d" || exit 1; \
		[ "$$(readlink ".claude/skills/$$n")" = "../../.agents/skills/$$n" ] || { echo ".claude/skills/$$n must link to ../../.agents/skills/$$n"; exit 1; }; \
	done
