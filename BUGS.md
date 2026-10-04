# Known issues

## In the plugin

- **Tested on macOS only.** Windows and Linux are untested. On those systems the secret goes to the user-only settings file (no system keychain yet), and the `chmod 600` step is skipped on Windows.
- **Viewport references not run in a full editor session.** The Viewport button captures the editor's first 3D viewport; it is covered by code review only, not by an automated or manual run.
- **"More" recommendations can include models outside the lane's list** (for example a Flux LoRA for a prompt about chests). They are generated and placed like the lane's own models; their output was not checked for every possible model.
- **Godot 4.7.2 prints exit noise in headless runs** ("N resources still in use at exit", "RIDs ... leaked"). It comes from the engine, after the plugin's work is done.
- **A windowed editor run logs "Parameter current_window is null"** from Godot's import progress dialog while it starts. Engine-side, harmless.

## Reported upstream (Scenario models)

- **PATINA labels its roughness map "texture-smoothness".** The pixels are roughness (rough moss bright, polished stone dark, checked 2026-10-04), so the plugin wires that map to the roughness slot without inversion. If PATINA ever starts returning real smoothness, the map will need inverting.
- **Sonilo V1.1 returns MP3 when WAV is requested** (`audioFormat: wav`, 2026-10-04). The plugin names files from their bytes, not from the request, so the MP3 imports correctly.
- **Rodin returns a WEBP thumbnail before the GLB.** Not a bug, but the order is not documented; the plugin picks the GLB by its content and keeps the thumbnail as `-preview`.
