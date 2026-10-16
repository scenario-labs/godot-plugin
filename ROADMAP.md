# Roadmap

Direction: steps on any asset. Start from anything, take the steps you want, stop at the finish level you want. Full proposal and open questions: [design notes](docs/design-notes/README.md).

Planned work lives in [issues](https://github.com/scenario-labs/godot-plugin/issues), typed Feature, Task or Bug, in three milestones taken in order:

1. [Steps on any asset](https://github.com/scenario-labs/godot-plugin/milestone/1): typed steps, "Next" on any asset, new steps (rig, moves, retopology, 2D sheets), finish levels, asset history, character presets.
2. [Make me… and scale](https://github.com/scenario-labs/godot-plugin/milestone/2): "Make me…", batches, round trips with Blender, Aseprite and Krita, a GDScript API, account sign-in, an asset browser.
3. [Style, teams and games](https://github.com/scenario-labs/godot-plugin/milestone/3): style per project, team models and workflows as steps, coding agents, "Make me a game", more presets, video.

Platform work, such as the Godot Asset Library listing and Windows and Linux support, has no milestone: see the open [Tasks](https://github.com/scenario-labs/godot-plugin/issues?q=is%3Aissue%20is%3Aopen%20type%3ATask) and [Features](https://github.com/scenario-labs/godot-plugin/issues?q=is%3Aissue%20is%3Aopen%20type%3AFeature%20no%3Amilestone). Defects are [Bugs](https://github.com/scenario-labs/godot-plugin/issues?q=is%3Aissue%20is%3Aopen%20type%3ABug), and engine or model quirks stay in [known issues](BUGS.md).

## Other engines

The same contract (price first, single-use price, no paid retry, Unknown state, provenance, secret outside the project) carries over:

1. **Unity** next: an EditorWindow (UI Toolkit), `UnityWebRequest`, `AssetDatabase` import into `Assets/Scenario/`, glTFast for GLB, a UPM git package.
2. **Unreal** after: a Slate tab, `FHttpModule`, Interchange import into `/Game/Scenario/`, a code plugin for Fab.
