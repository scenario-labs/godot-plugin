# Scenario for Godot: user guide

Version 0.2.1. For installation see the [README](../README.md). <!-- x-release-please-version -->

## 1. Sign in

1. Enable the plugin (Project > Project Settings > Plugins > Scenario). The **Scenario** dock opens in its own column, right of the Inspector. Like any dock, you can drag its tab elsewhere; Godot remembers the layout per project.
2. Press **Sign in with Scenario**. Your browser opens Scenario's sign-in; approve "Scenario for Godot", then come back to Godot. When this computer's browser cannot finish (a remote machine, a locked-down browser), press **Sign in on another device** instead: the dock shows a code to enter at the address it gives, on any device.
3. Choose the team and project that pays for the generations, and press **Use this project**. An account with a single project skips this step. Jobs and their results stay in the project they were sent to.

The footer shows the team and project. The **...** menu holds **Change team or project**, **Open Scenario**, **Check unknown jobs**, **Send feedback** and **Sign out** (forgets the sign-in on this computer and tells Scenario to end it). The sign-in lasts across editor restarts; if Scenario ends it, the dock asks you to sign in again.

With an API key instead: press **Use an API key instead**, paste a key (`api_...`) and its secret from the Scenario web app ([app.scenario.com](https://app.scenario.com)), and press **Connect**. Generations go to the key's project, and the footer shows the key and where it came from (`keychain`, `credential-manager`, `secret-service`, `file` or `environment`).

## 2. Generate

1. Pick a **lane**: Image, 3D, Material, Skybox, Sound or Workflow.
2. Pick a **model**. Each lane opens on its default model; the line under the picker says what the model is good at. On the Image, 3D and Sound lanes, **More** adds Scenario's recommendations for your prompt, and the models trained in your Scenario project are listed under **Project models**. A trained LoRA or composition runs on the base model it was trained on (the price is that base's); a LoRA adds **LoRA weight** to Settings, 0.75 by default.
3. Write the **prompt**. Fields marked `*` are required.
4. Add **references** if the model takes them: **File...** picks an image from the project, **Viewport** captures the editor's 3D view, **Clear** removes it. References are uploaded to your Scenario project (free) and the price updates.
5. Open **Settings** for the rest of the model's options (size, quality, seed, mask...). Options marked "affects price" change the cost.
6. Wait for the price. The button reads `Checking price...`, then `Generate  ·  N CU`. A red line under the form explains anything that blocks it (a missing field, a failed price check); after a failed check the button reads **Check price** and tries again.
7. Press **Generate**. Above the confirmation threshold (100 CU by default) a dialog asks first.

The price is checked again after each change, so the button always shows what this exact request costs. One press sends one request; the next one needs a fresh price, which the dock fetches by itself.

## 3. Lanes

**Image.** Select a Sprite2D, Sprite3D, TextureRect, TextureButton or Decal first to replace its texture. With nothing selected, the image is added as a new node: a Sprite3D one metre tall in a 3D scene, a TextureRect in a UI scene, a Sprite2D otherwise. GPT Image 2.5 Flare can produce a transparent background (Settings > Background).

**3D.** Rodin Gen-2.5 makes a textured model with PBR materials from a prompt (80 CU at the cheapest tier on 2026-10-04). The image-to-3D models (Hunyuan 3D, Tripo 3.1, Meshy 7.1 image, Hitem3D) need an input image: add it with File... or Viewport. The GLB is imported and instanced under the selected Node3D, or 4 m in front of the editor camera. When the model also returns a thumbnail, it is saved next to the GLB as `-preview`.

**Material.** Select one or more meshes first. PATINA returns a color map plus normal, roughness, metallic and height maps; the dock builds a `StandardMaterial3D`, saves it as a `.tres` next to the textures and sets it as `material_override` on the selected meshes. With no mesh selected, the material is only saved: drag it onto a mesh later. The textures tile, so they suit floors, walls and terrain.

**Skybox.** Generates a 360 panorama and sets it as the sky of the scene's WorldEnvironment. If the scene has none, one is created with sky lighting and reflections.

**Sound.** Sonilo makes short effects of an exact length (1 CU for 2 s on 2026-10-04); ElevenLabs Sound Effects 2 can loop. The sound is added as an AudioStreamPlayer3D in a 3D scene, AudioStreamPlayer2D in a 2D scene, AudioStreamPlayer otherwise. Only WAV, MP3 and OGG are offered, the formats Godot imports.

**Workflow.** Runs a Scenario workflow: the picker lists the ready workflows of your project, then public ones (drafts cannot run). **Refresh** lists them again after you edit one on app.scenario.com. The form shows the workflow's inputs; one that takes a list of values or of models can only be set on Scenario, and a required one of those blocks the price. The price covers the whole run. Results are placed by type: a GLB as on the 3D lane (images next to it are kept as files), a 360 panorama as on the Skybox lane, PBR maps as on the Material lane, other images as on the Image lane, and a sound as on the Sound lane. A run that stops at an approval or a selection step waits until you answer it on app.scenario.com; the dock says so.

## 4. Jobs

Each request appears under **Jobs**, newest first. The list survives editor restarts; jobs still running when you closed Godot are followed again when you reopen it.

| State | Meaning | Actions |
|---|---|---|
| Queued, Running | Scenario is working on it | Cancel |
| Done · N CU | finished; N is what Scenario charged | Import (or Show once imported), Re-run |
| Cancelling, Canceled | a cancel was requested, then confirmed by Scenario | Re-run |
| Failed | Scenario reported an error (hover the row to read it) | Re-run |
| Blocked | the request was refused by moderation; it is never resent | Re-run after changing the prompt |
| Not sent | refused before Scenario started (bad parameters, not enough CU, spending switch) | Re-run |
| Unknown | the connection dropped while the request was being sent: it may or may not have started | Check Scenario, Dismiss |

**Import** downloads the results, imports them and places them as described above. With **Auto Import** on (the default), finished jobs are imported as soon as they are done. **Re-run** puts the job's model and settings back in the form; it never sends anything by itself.

**Unknown** jobs block the same request until resolved, so a dropped connection cannot make you pay twice. **Check Scenario** looks for the job among your recent Scenario jobs and links it when exactly one matches. **Dismiss** clears the row when you have checked yourself.

### Library and History

The buttons at the top of the dock switch between **Generate**, **Library** and **History**. Both read the project in the footer; nothing there costs CU.

- **Library** shows the project's images, 3D models and sounds, newest first, with thumbnails. Filter by kind, by Generated or Uploaded, or by words of the caption or prompt; filters apply to the assets read so far, and **Show more** reads older ones. **Import** downloads the file and places it like a result of its lane (an image on the selected node, a model in the scene, a sound as a player). **Reference** puts an image in one of the form's reference fields without uploading it again.
- **History** lists the project's jobs on Scenario, newest first, including those sent from the web app or another editor. **Import** brings a finished job's results in. **Load older** reads the next page.

Imports from either view join the **Jobs** list, once: importing the same asset or job again reuses its row. A History job that an **Unknown** row may stand for (same model, sent within three minutes) waits until you press **Check Scenario** or **Dismiss** on that row. The views are emptied when you change project or sign out.

## 5. Files

- Results: `res://scenario/<lane>/<date>-<prompt>-<asset>[-<map>].<ext>`.
- Provenance: a `.scenario.json` next to each result, with job id, model, prompt, parameters, quoted and charged CU, asset ids and import time. Commit it with the asset.
- Materials and skies: a `.tres` next to their textures.
- Job list: `res://.godot/scenario/jobs.json` (local to your machine).

## 6. Settings

Editor Settings > Scenario:

- **Confirm Above CU** (100): requests above this price ask for confirmation.
- **Auto Import** (on): import and place finished jobs automatically.
- **Share Anonymous Usage Data** (off): see [Usage data and feedback](#8-usage-data-and-feedback).

Environment variables, read when Godot starts:

- `SCENARIO_API_KEY`, `SCENARIO_API_SECRET`: use this key instead of the saved sign-in or key.
- `SCENARIO_OAUTH_ISSUER`, `SCENARIO_OAUTH_CLIENT_ID`, `SCENARIO_MCP_URL`: sign in to a development instance of Scenario (for Scenario developers; set the first two together).
- `SCENARIO_NO_SPEND=1`: refuse every paid request and upload inside the editor. Price checks, cancels and imports still work.
- `SCENARIO_TELEMETRY_URL`: send usage data and feedback to another relay (for Scenario developers).

## 7. Troubleshooting

| You see | What to do |
|---|---|
| "Wait for the price check to finish." | The form changed after the last price; wait a moment. |
| A price check error | Read the message under the form, then press **Check price**. |
| "Automatic price checks are off for this session." | Scenario answered a price check with a job, which should not happen. Check that job on Scenario (its id is in the message), then press **Check price** to turn checks back on. |
| Not sent: not enough Creative Units | Top up the Scenario project of the key, or pick cheaper settings. |
| "This exact request may already be running." | An Unknown job has the same settings: press Check Scenario first. |
| Material saved but not applied | No mesh was selected: drag the `.tres` onto a mesh. |
| "Open a scene to place it." | The result was imported but not placed: open a scene, press **Show** on the job and drag the file in. |
| An import error on a finished job | Press **Import** again; the job stays Done until its files are placed. |
| "Parameter current_window is null" in the Output panel while the editor starts | Godot's import progress dialog prints it; it is harmless. |

## 8. Usage data and feedback

**Share anonymous usage data** is off by default. After your first sign-in or key connection, the dock asks once; **No thanks** sends nothing. Change it any time in Editor Settings > Scenario.

While it is on, the plugin keeps a random install ID in the editor settings folder (`scenario/usage.json`), not linked to your Scenario account, and about once a minute sends:

- that the plugin started;
- that the dock is connected, and how (Sign in with Scenario, a saved key or environment variables), once Scenario accepts it: at startup, on each sign-in and when sharing starts;
- which Scenario requests the dock makes (price check, generate, cancel, import, reference upload, recommendations, team list, unknown-job check, key check, model settings), whether each worked, the error type and how long it took;
- each generation's lane, its quoted CU when sent, and its end state (done, failed, blocked, canceled, rejected or dismissed) and charged CU.

Each batch adds the plugin and Godot versions, the operating system and the processor type. It never sends prompts, file paths, scene or node names, model, asset, job, team or project IDs, or your key. Events go to `https://godot.scenario.com/telemetry/v1/events`, which adds the country Vercel derives from your address, drops any other event or field, and forwards the rest to Scenario's PostHog project without your address. Turning the setting off discards unsent events and deletes the ID. A headless editor (scripts, CI) never sends them.

**Send feedback**, in the dock's **...** menu, opens a dialog for a 1 to 5 rating, a message and an optional email address for a reply. Nothing is sent until you press **Send**, and it works whether or not usage data is shared. It sends what you entered with a random submission ID, the plugin and Godot versions, operating system and processor type, plus the install ID only while usage data is shared and you left the email empty, to `https://godot.scenario.com/telemetry/v1/feedback`, which records it, with the country and without your address, as a response to Scenario's feedback survey. A failed send is not retried; the dialog keeps your text, in memory only, until a send succeeds.
