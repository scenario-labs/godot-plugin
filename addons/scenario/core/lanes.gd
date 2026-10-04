@tool
extends RefCounted
## Generation lanes and their default models.
##
## Defaults chosen on 2026-10-04 with Scenario's `recommend` (quality priority)
## and the newest models; the dock also lists live recommendations. Presets
## are applied on top of the schema defaults; "restrict" limits a field to
## values Godot can import.

const LANES := [
	{
		"id": "image", "title": "Image", "capability": "txt2img", "importer": "image",
		"hint": "Sprites, icons, concept art, UI pieces. Fills the selected Sprite2D, Sprite3D or TextureRect.",
		"models": [
			{"id": "model_openai-gpt-image-2-5-flare", "name": "GPT Image 2.5 Flare", "note": "fast, transparent backgrounds"},
			{"id": "model_openai-gpt-image-2-5-sunburst", "name": "GPT Image 2.5 Sunburst", "note": "best quality"},
			{"id": "model_google-gemini-3-1-flash", "name": "Gemini 3.1", "note": "up to 4K, many references"},
			{"id": "model_bytedance-seedream-5-0-pro", "name": "Seedream 5.0 Pro", "note": "consistent sets"},
		],
	},
	{
		"id": "model3d", "title": "3D", "capability": "txt23d", "importer": "model3d", "download_format": "glb",
		"hint": "Textured GLB models, instanced under the selected Node3D.",
		"models": [
			{"id": "model_rodin-hyper3d-v2-5-text-to-3d", "name": "Rodin Gen-2.5 (text)", "note": "PBR, quad topology"},
			{"id": "model_hunyuan-3d-pro-3-1-i23d", "name": "Hunyuan 3D 3.1 Pro (image)", "note": "from one image"},
			{"id": "model_tripo-v3-1-image-to-3d", "name": "Tripo 3.1 (image)", "note": "clean game topology"},
			{"id": "model_meshy-7-1-txt23d", "name": "Meshy 7.1 (text)", "note": "up to 8K PBR"},
			{"id": "model_meshy-7-1-img23d", "name": "Meshy 7.1 (image)", "note": "remesh to a polycount"},
			{"id": "model_tripo-p2-text-to-3d", "name": "Tripo P2 (text)", "note": "fast, stable topology"},
			{"id": "model_hitem-3d-3-0", "name": "Hitem3D 3.0 (image)", "note": "top fidelity, expensive"},
		],
	},
	{
		"id": "material", "title": "Material", "capability": "txt2img", "importer": "material",
		"hint": "Tileable PBR material, set on the selected MeshInstance3D.",
		"models": [
			{"id": "model_patina-material", "name": "PATINA Material", "note": "albedo, normal, roughness, metallic, height"},
			{"id": "model_scenario-texture", "name": "Scenario Texture", "note": "one tileable color map"},
		],
	},
	{
		"id": "skybox", "title": "Skybox", "capability": "txt2img", "importer": "skybox",
		"hint": "360 panorama, applied as the sky of the scene's WorldEnvironment.",
		"models": [
			{"id": "model_scenario-skybox-gpt", "name": "Scenario Skybox GPT", "note": "best quality"},
			{"id": "model_scenario-skybox-flux", "name": "Scenario Skybox Flux", "note": "21 styles"},
		],
	},
	{
		"id": "sound", "title": "Sound", "capability": "txt2audio", "importer": "audio",
		"hint": "Sound effects, added as an AudioStreamPlayer.",
		"models": [
			{"id": "model_sonilo-v1-1-text-to-sound-effects", "name": "Sonilo V1.1 SFX", "note": "1 CU, exact length"},
			{"id": "model_elevenlabs-sound-effects-v2", "name": "ElevenLabs Sound Effects 2", "note": "loops"},
			{"id": "model_mm-audio-2-t2a", "name": "MM Audio 2", "note": "negative prompt"},
		],
	},
]

## Values set on top of the schema defaults, per model.
const PRESETS := {
	"model_rodin-hyper3d-v2-5-text-to-3d": {"material": "PBR"},
	"model_hunyuan-3d-pro-3-1-i23d": {"enablePbr": true},
	"model_sonilo-v1-1-text-to-sound-effects": {"audioFormat": "wav", "duration": 2},
	"model_scenario-skybox-flux": {"numOutputs": 1},
}

## Field values Godot can import (it has no AAC or FLAC importer).
const RESTRICT := {
	"audioFormat": ["wav", "mp3", "ogg"],
}


static func lane(id: String) -> Dictionary:
	for item in LANES:
		if item["id"] == id:
			return item
	return {}


static func ids() -> PackedStringArray:
	var out: PackedStringArray = []
	for item in LANES:
		out.append(item["id"])
	return out


static func default_model(lane_id: String) -> String:
	var item := lane(lane_id)
	return item["models"][0]["id"] if not item.is_empty() else ""


static func presets(model_id: String) -> Dictionary:
	return PRESETS.get(model_id, {}).duplicate(true)
