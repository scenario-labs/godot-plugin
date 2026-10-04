# Roadmap

Direction from 0.2: steps on any asset. Start from anything, take the steps you want, stop at the finish level you want. Full proposal and open questions: [design notes](docs/design-notes/README.md).

## 0.2: steps on any asset

- Typed steps: image, 2D sheets, 3D model, rigged, animated, material, skybox, sound.
- "Next" on any selected asset, including your own files, with the price of each step.
- New steps: rig (humanoid and creature), add a move, retopology, restyle, 8 directions, run cycle sheet, multi-view to 3D.
- Finish level per run: file, Godot resource, placed node, playable.
- Asset history in `.scenario.json`, with a new version for every step.
- Presets: the 3D character path and the 2D character path.

## 0.3: "Make me…" and scale

- "Make me…": a sentence becomes a priced path through the same steps (Scenario LLM).
- Batches over folders and resources, priced once.
- Round trip with Blender, Aseprite and Krita: continue from your saved version.
- GDScript API for tool scripts and CI.
- Sign-in with a Scenario account (OAuth device flow), team and project selection.
- Asset library browser: earlier results and team assets as references or starting points.

## 0.4: style, teams and games

- Style per project: references or a team-trained model, applied to every step.
- Team models and Scenario workflows as steps.
- Access for coding agents: the same steps and spending rules through a local endpoint.
- "Make me a game": approach still open ([design note](docs/design-notes/2026-10-04-make-me-a-game.md)); game kits are the leading option.
- More presets: creature, prop kit, environment, UI kit, audio set.
- Video steps: frames to video, video lane.

## Platform work (any release)

- Windows and Linux runs; Windows secret storage (DPAPI), Linux Secret Service.
- Viewport reference verified in a full editor session; 2D viewport capture.
- Godot Asset Library submission, GitHub releases with the zip.
- Prompt Spark: rewrite a short prompt into an on-model one before pricing.

## Other engines

The same contract (price first, single-use price, no paid retry, Unknown state, provenance, secret outside the project) carries over:

1. **Unity** next: an EditorWindow (UI Toolkit), `UnityWebRequest`, `AssetDatabase` import into `Assets/Scenario/`, glTFast for GLB, a UPM git package.
2. **Unreal** after: a Slate tab, `FHttpModule`, Interchange import into `/Game/Scenario/`, a code plugin for Fab.
