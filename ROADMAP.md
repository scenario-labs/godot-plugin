# Roadmap

## Next for Godot

- Windows and Linux runs; Windows secret storage (DPAPI), Linux Secret Service.
- Viewport reference verified in a full editor session; 2D viewport capture.
- Godot Asset Library submission, GitHub releases with the zip.
- Prompt Spark: rewrite a short prompt into an on-model one before pricing.
- Asset library browser: earlier results and team assets as references.
- Sign-in with a Scenario account (OAuth) and team or project selection.

## Later

- Video lane, workflows, and mesh operations (remesh, rig, retexture).
- An agent bridge: a local Scenario MCP endpoint inside the editor, so a coding agent can generate and place assets through the same spending rules.

## Other engines

The same contract (price first, single-use price, no paid retry, Unknown state, provenance, secret outside the project) carries over:

1. **Unity** next: an EditorWindow (UI Toolkit), `UnityWebRequest`, `AssetDatabase` import into `Assets/Scenario/`, glTFast for GLB, a UPM git package.
2. **Unreal** after: a Slate tab, `FHttpModule`, Interchange import into `/Game/Scenario/`, a code plugin for Fab.
