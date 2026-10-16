# Other engines

Status: proposal (2026-10-16). Moved from the roadmap, which now lives in issues and milestones. Not work for this repository: each engine gets its own plugin.

The same contract carries over to every engine: price first, single-use price, no paid retry, the Unknown state, provenance, and the secret kept outside the project.

1. **Unity** next: an EditorWindow (UI Toolkit), `UnityWebRequest`, `AssetDatabase` import into `Assets/Scenario/`, glTFast for GLB, a UPM git package.
2. **Unreal** after: a Slate tab, `FHttpModule`, Interchange import into `/Game/Scenario/`, a code plugin for Fab.
