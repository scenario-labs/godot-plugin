# Scenario Godot Plugin. Requires Godot 4.7 (`godot` on PATH, or $GODOT), python3,
# and the scenario-godot-expert toolkit: `make toolkit` fetches the pinned copy.
.PHONY: test unit editor zip archive dock site site-test smoke toolkit lint agents tools-test

test:
	python3 tools/run_tests.py all

unit:
	python3 tools/run_tests.py unit

editor:
	python3 tools/run_tests.py editor

# Release zip, then a clean install into a blank project.
zip:
	python3 tools/build_zip.py --verify

# The source archive (GitHub downloads, the Godot Asset Library) holds exactly the committed files of
# addons/scenario, plugin.cfg included: see .gitattributes.
archive:
	@t="$$(mktemp -d)"; \
	git ls-tree -r --name-only HEAD addons/scenario | sort > "$$t/want"; \
	git archive HEAD | tar -t | grep -v '/$$' | sort > "$$t/got"; \
	if grep -qx addons/scenario/plugin.cfg "$$t/got" && diff -u "$$t/want" "$$t/got"; then \
		echo "source archive: the $$(wc -l < "$$t/got" | tr -d ' ') files of addons/scenario"; rm -rf "$$t"; \
	else echo "The source archive must hold exactly the committed files of addons/scenario (- missing, + extra)."; rm -rf "$$t"; exit 1; fi

# Dock screenshot for the docs (fake backend, 0 CU; opens a small window).
dock:
	python3 tools/capture_dock.py

# The website (docs/USER_GUIDE.md as one page) into dist/site; requires uv. CI publishes it with the release zip.
site:
	rm -rf dist/site
	uv run --no-project --with markdown==3.10.3 python tools/build_site.py --output dist/site

# The download-counting proxy (tools/site_proxy), type-checked as Vercel builds it, and the guide search
# (docs/site/handbook-search.js), type-checked; then both tested. Requires pnpm install.
site-test:
	mkdir -p .no-types
	node_modules/.bin/tsc --noEmit --strict --target es2022 --lib es2022,dom --module nodenext --moduleResolution nodenext --typeRoots .no-types tools/site_proxy/middleware.ts
	node_modules/.bin/tsc --noEmit --strict --target es2022 --lib es2022,dom,dom.iterable --module nodenext --moduleResolution nodenext --allowJs --checkJs --typeRoots .no-types docs/site/handbook-search.js
	node --disable-warning=MODULE_TYPELESS_PACKAGE_JSON --test tests/site/middleware.test.ts tests/site/handbook-search.test.ts

# Paid: spends Creative Units on the test key's project. Opt-in only.
smoke:
	python3 tools/smoke.py

# The toolkit commit pinned in tools/toolkit.py, into .toolkit/; addons/agentkit must match it.
toolkit:
	python3 tools/toolkit.py fetch
	python3 tools/toolkit.py check

# Tests of the Python tools themselves (release draft recovery).
tools-test:
	python3 -m unittest discover -s tools

# GDScript and Python lint, the same versions as CI, then the house rules. Requires uv.
lint:
	uvx --from gdtoolkit==4.5.0 gdlint addons/scenario tests
	uvx ruff@0.16.10 check tools
	python3 tools/check_rules.py

# Shared agent skills: valid per the Agent Skills spec, and linked for Claude Code. Requires uv.
SKILLS_REF := git+https://github.com/agentskills/agentskills.git@69ef37e9424c0a7ea9dd2293b559e43ec8176379\#subdirectory=skills-ref
agents:
	@for d in .agents/skills/*/; do n=$$(basename "$$d"); \
		uvx --from "$(SKILLS_REF)" skills-ref validate "$$d" || exit 1; \
		[ "$$(readlink ".claude/skills/$$n")" = "../../.agents/skills/$$n" ] || { echo ".claude/skills/$$n must link to ../../.agents/skills/$$n"; exit 1; }; \
	done
