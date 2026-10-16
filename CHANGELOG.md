# Changelog

## [0.2.1](https://github.com/scenario-labs/godot-plugin/compare/godot-plugin-v0.2.0...godot-plugin-v0.2.1) (2026-10-16)


### Bug Fixes

* **editor:** keep the form when an older schema load finishes last ([#66](https://github.com/scenario-labs/godot-plugin/issues/66)) ([c585676](https://github.com/scenario-labs/godot-plugin/commit/c58567629e8a08da8de97381d4f53f76d1eb4bf6)), closes [#64](https://github.com/scenario-labs/godot-plugin/issues/64)


### Documentation

* **agents:** fold llms.txt into AGENTS.md ([#27](https://github.com/scenario-labs/godot-plugin/issues/27)) ([9be0404](https://github.com/scenario-labs/godot-plugin/commit/9be040433eed913af3265929db5badd91b63b8c2))
* **agents:** keep PR descriptions, commits and doc edits brief, as in the Blender plugin ([#23](https://github.com/scenario-labs/godot-plugin/issues/23)) ([15a4f6e](https://github.com/scenario-labs/godot-plugin/commit/15a4f6edd7a9791269f31a3dd3e0268867f36b6c))
* move the known issues from BUGS.md to Bug issues ([#63](https://github.com/scenario-labs/godot-plugin/issues/63)) ([b381cc0](https://github.com/scenario-labs/godot-plugin/commit/b381cc0e2fa40cf767c70bff4d3394d5c8869885))
* move the roadmap from ROADMAP.md to issues and milestones ([#54](https://github.com/scenario-labs/godot-plugin/issues/54)) ([470453d](https://github.com/scenario-labs/godot-plugin/commit/470453d5eb7f44de88437efaa0ace547029d8cc0))


### Miscellaneous Chores

* **docs:** count website visits with Vercel Web Analytics ([#57](https://github.com/scenario-labs/godot-plugin/issues/57)) ([d3e48d6](https://github.com/scenario-labs/godot-plugin/commit/d3e48d60f7930b835b2fc825454a509d70f39b00))
* **repo:** ignore .env.local ([#55](https://github.com/scenario-labs/godot-plugin/issues/55)) ([81a5a0b](https://github.com/scenario-labs/godot-plugin/commit/81a5a0b9bd7d4363f7147694cac411bfa6e39b6f))


### Continuous Integration

* **ci:** open scheduled-check failure issues as Tasks ([#24](https://github.com/scenario-labs/godot-plugin/issues/24)) ([123c6b9](https://github.com/scenario-labs/godot-plugin/commit/123c6b915d33e53b94e595ab9e8cf6330e704f19))
* describe the commits check as required, like ci-ok and pr-title ([#26](https://github.com/scenario-labs/godot-plugin/issues/26)) ([4141587](https://github.com/scenario-labs/godot-plugin/commit/41415879d4fdff4fd55bc9166ffd405da4c6b599))
* name the paid run smoke and use the test key names, as in blender-plugin ([#56](https://github.com/scenario-labs/godot-plugin/issues/56)) ([4dbc045](https://github.com/scenario-labs/godot-plugin/commit/4dbc0451bd78c0364a40ee12a90808e087b0b462))
* run the tests and zip check on the Godot .NET build ([#28](https://github.com/scenario-labs/godot-plugin/issues/28)) ([7157a5b](https://github.com/scenario-labs/godot-plugin/commit/7157a5b1f20182c678a101bcb4b3c4d0362062c4))
* title each smoke run with its budget, lanes, commit and author ([#58](https://github.com/scenario-labs/godot-plugin/issues/58)) ([81b2f0d](https://github.com/scenario-labs/godot-plugin/commit/81b2f0d5e032f671e4a0132d1682ce4115ec8c8a))

## [0.2.0](https://github.com/scenario-labs/godot-plugin/compare/godot-plugin-v0.1.1...godot-plugin-v0.2.0) (2026-10-16)


### Features

* **mcp:** send the Godot version and OS in the User-Agent ([#9](https://github.com/scenario-labs/godot-plugin/issues/9)) ([97caa4b](https://github.com/scenario-labs/godot-plugin/commit/97caa4b0e7601b77ab8e52834556ad5f51d27de0))


### Bug Fixes

* **editor:** import results written while the editor is already scanning ([#6](https://github.com/scenario-labs/godot-plugin/issues/6)) ([bba43bc](https://github.com/scenario-labs/godot-plugin/commit/bba43bc928a2940981713686d816d9e055b067c7))


### Documentation

* **docs:** add the Scenario logo, badges and quick links to the README ([#18](https://github.com/scenario-labs/godot-plugin/issues/18)) ([27f9944](https://github.com/scenario-labs/godot-plugin/commit/27f9944df8d0bf561f162059c31955eb9b7542d3))
* **docs:** give the website the look of the Blender plugin's site ([#20](https://github.com/scenario-labs/godot-plugin/issues/20)) ([e79e0dd](https://github.com/scenario-labs/godot-plugin/commit/e79e0ddbc0767e3adda8362a5bb4873fa898f2eb))
* point the README download and website links at godot.scenario.com ([#22](https://github.com/scenario-labs/godot-plugin/issues/22)) ([8346e3a](https://github.com/scenario-labs/godot-plugin/commit/8346e3acd5805adcc01e374c98d02eb3c74aec77))


### Miscellaneous Chores

* **agents:** add the shared PR summary, squash and comment skills ([#2](https://github.com/scenario-labs/godot-plugin/issues/2)) ([75cdd58](https://github.com/scenario-labs/godot-plugin/commit/75cdd580c7f0a7cae7c52bd297307b51f1107cf9))
* **repo:** add bug and change request issue forms ([#3](https://github.com/scenario-labs/godot-plugin/issues/3)) ([30a6d07](https://github.com/scenario-labs/godot-plugin/commit/30a6d079203cb032170bf065d82947b845b15db3))
* **repo:** add contributing, security, support and conduct guides ([#10](https://github.com/scenario-labs/godot-plugin/issues/10)) ([ef0e489](https://github.com/scenario-labs/godot-plugin/commit/ef0e48930c26f0507eca20dca3ee8b115c3dcd32))


### Continuous Integration

* add Godot CI, commit lint and a pinned test toolkit ([#4](https://github.com/scenario-labs/godot-plugin/issues/4)) ([3265eff](https://github.com/scenario-labs/godot-plugin/commit/3265effe73a6dab2bd5d32751a2ed766d8c27570))
* add ready pull requests to the Plugins project as In review ([#17](https://github.com/scenario-labs/godot-plugin/issues/17)) ([9fd9de5](https://github.com/scenario-labs/godot-plugin/commit/9fd9de5ddf1d387e9d5ec5610d3f5d144d9e9912))
* add scheduled contract, OS and link checks, and a gated live run ([#7](https://github.com/scenario-labs/godot-plugin/issues/7)) ([dd3f822](https://github.com/scenario-labs/godot-plugin/commit/dd3f822009c587cf291ea8e2286d36de1950bd67))
* **deps:** Bump astral-sh/setup-uv ([#15](https://github.com/scenario-labs/godot-plugin/issues/15)) ([795f881](https://github.com/scenario-labs/godot-plugin/commit/795f881ee0d99823957a065a47161eaf37408971))
* **docs:** publish the user guide as a website and count zip downloads ([#8](https://github.com/scenario-labs/godot-plugin/issues/8)) ([ea7cbba](https://github.com/scenario-labs/godot-plugin/commit/ea7cbbab121b6dba227ecd1d95035b47580e96fa))
* leave the generated changelog out of the link check ([#21](https://github.com/scenario-labs/godot-plugin/issues/21)) ([b88771d](https://github.com/scenario-labs/godot-plugin/commit/b88771d258206ad89902b19833eb92f6bb3c7d2f))
* **release:** let release-please bump the version in the README and user guide ([#19](https://github.com/scenario-labs/godot-plugin/issues/19)) ([b32e235](https://github.com/scenario-labs/godot-plugin/commit/b32e23522cdc7722e5b6dfafe31e890908c33f0e))
* **release:** release with release-please and verified, attested zips ([#13](https://github.com/scenario-labs/godot-plugin/issues/13)) ([6231607](https://github.com/scenario-labs/godot-plugin/commit/6231607435dfb97938ac916f2cb773f98a8e3ecd))

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
