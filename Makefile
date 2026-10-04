# Scenario Godot Plugin. Requires Godot 4.7 on PATH as `godot` and python3.
.PHONY: test unit editor zip dock live

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
