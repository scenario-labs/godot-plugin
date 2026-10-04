# Changelog

## 0.1.1 (2026-10-04)

- The dock opens in its own column right of the Inspector. As a fourth tab next to Inspector, Signals and Groups it was hidden behind the tab overflow (found in the first hands-on try).
- On the first enable in a project, the dock is brought to the front even if a saved layout puts it in a tab group.

## 0.1.0 (2026-10-04)

First version.

- Scenario dock for the Godot 4.7 editor, built from each model's live schema.
- Five lanes, each placing its result in the open scene through the editor's undo system: Image (sprite or texture), 3D (GLB instance), Material (`StandardMaterial3D` with PBR maps), Skybox (`PanoramaSkyMaterial` on the WorldEnvironment), Sound (audio player).
- Price shown on the Generate button from a free price check; each price is used once; paid requests are never retried; uncertain requests are marked Unknown and block the same request until checked; confirmation above 100 CU; `SCENARIO_NO_SPEND=1` switch.
- Durable job list with resume after restart, cancel, re-run, and import.
- References from project files or the editor's 3D view, uploaded to Scenario.
- Recommendations from Scenario ("More") on the Image, 3D and Sound lanes.
- Provenance `.scenario.json` next to every result.
- Secret stored in the macOS Keychain, or in a user-only file in the editor settings folder; environment variables for CI.
- Tests: 85 unit tests, a 69-check headless editor test against a fake backend, a free live contract check, and a paid live acceptance run (7 runs, 173 CU, every charge equal to its quote).
