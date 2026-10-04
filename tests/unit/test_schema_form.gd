extends GutTest

const Form := preload("res://addons/scenario/core/schema_form.gd")
const Sse := preload("res://addons/scenario/core/sse.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")


func _schema(name: String) -> Dictionary:
	var text := FileAccess.get_file_as_string("res://tests/fixtures/%s.sse" % name)
	return Sse.parse(text, "text/event-stream", 2)["value"]["result"]["structuredContent"]


func _by_name(fields: Array) -> Dictionary:
	var out := {}
	for field in fields:
		out[field["name"]] = field
	return out


func test_patina_field_types() -> void:
	var fields := _by_name(Form.fields_from_schema(_schema("schema_patina")))
	assert_eq(fields["prompt"]["type"], "prompt")
	assert_eq(fields["image"]["type"], "file")
	assert_eq(fields["imageStrength"]["type"], "number")
	assert_eq(fields["width"]["type"], "integer")
	assert_eq(fields["maps"]["type"], "multi")
	assert_eq(fields["upscaleFactor"]["type"], "enum")
	assert_eq(fields["tilingMode"]["type"], "enum")
	assert_eq(fields["enablePromptExpansion"]["type"], "boolean")
	assert_eq(fields["seed"]["type"], "integer")
	assert_eq(fields["numOutputs"]["type"], "integer")


func test_flare_field_types() -> void:
	var fields := _by_name(Form.fields_from_schema(_schema("schema_flare")))
	assert_eq(fields["referenceImages"]["type"], "files")
	assert_eq(fields["referenceImages"]["max_items"], 10)
	assert_eq(fields["quality"]["options"], ["auto", "low", "medium", "high", "xhigh", "max"])
	assert_eq(fields["prompt"]["max_length"], 32000)


func test_prompt_comes_first() -> void:
	var fields := Form.fields_from_schema(_schema("schema_patina"))
	assert_eq(fields[0]["name"], "prompt")


func test_required_fields_follow_the_prompt() -> void:
	var schema := {"parameters": [
		{"name": "seed", "type": "number"},
		{"name": "image", "type": "file", "required": true},
		{"name": "prompt", "type": "string", "prompt": true},
	]}
	var names := Form.fields_from_schema(schema).map(func(f: Dictionary) -> String: return f["name"])
	assert_eq(names, ["prompt", "image", "seed"])


func test_initial_values_use_defaults_then_presets() -> void:
	var fields := Form.fields_from_schema(_schema("schema_patina"))
	var values := Form.initial_values(fields, {"width": 512})
	assert_eq(values["width"], 512)
	assert_eq(values["height"], 1024.0)
	assert_false(values.has("prompt"))


func test_validate_required_and_ranges() -> void:
	var fields := Form.fields_from_schema(_schema("schema_patina"))
	var problems := Form.validate(fields, {"width": 4096})
	assert_true(problems.has("Prompt: required."))
	assert_true(problems.has("Width must be at most 2048."))
	assert_eq(Form.validate(fields, {"prompt": "moss", "width": 512}).size(), 0)
	assert_eq(Form.validate(fields, {"prompt": "   "}).size(), 1, "blank prompt counts as missing")


func test_validate_enum_numbers_and_strings() -> void:
	var fields := Form.fields_from_schema(_schema("schema_patina"))
	assert_eq(Form.validate(fields, {"prompt": "x", "upscaleFactor": 2.0}).size(), 0)
	assert_eq(Form.validate(fields, {"prompt": "x", "upscaleFactor": 3}).size(), 1)
	assert_eq(Form.validate(fields, {"prompt": "x", "tilingMode": "diagonal"}).size(), 1)


func test_payload_types_and_empty_values() -> void:
	var fields := Form.fields_from_schema(_schema("schema_patina"))
	var payload := Form.payload(fields, {
		"prompt": "  mossy stone  ", "width": 512.0, "imageStrength": 0.5, "image": "", "seed": null,
		"maps": PackedStringArray(["basecolor", "normal"]), "enablePromptExpansion": false, "unknownField": 1,
	})
	assert_eq(payload["prompt"], "mossy stone")
	assert_eq(typeof(payload["width"]), TYPE_INT)
	assert_eq(payload["imageStrength"], 0.5)
	assert_eq(payload["maps"], ["basecolor", "normal"])
	assert_eq(payload["enablePromptExpansion"], false)
	assert_false(payload.has("image"))
	assert_false(payload.has("seed"))
	assert_false(payload.has("unknownField"))


func test_single_file_into_a_list_field_becomes_a_list() -> void:
	var fields := Form.fields_from_schema(_schema("schema_flare"))
	assert_eq(Form.payload(fields, {"prompt": "p", "referenceImages": "asset_1"})["referenceImages"], ["asset_1"])


func test_restrict_limits_options_to_importable_formats() -> void:
	var schema := {"parameters": [{"name": "audioFormat", "type": "string", "default": "aac", "allowed_values": ["aac", "mp3", "wav", "flac"]}]}
	var field: Dictionary = Form.fields_from_schema(schema, Lanes.RESTRICT)[0]
	assert_eq(field["options"], ["mp3", "wav"])
	assert_eq(field["default"], "mp3")


func test_humanize() -> void:
	assert_eq(Form.humanize("imageStrength"), "Image strength")
	assert_eq(Form.humanize("numOutputs"), "Num outputs")
	assert_eq(Form.humanize("TAPose"), "Tapose")
	assert_eq(Form.humanize("audio_format"), "Audio format")
	assert_eq(Form.humanize("prompt"), "Prompt")


func test_prompt_name_follows_the_prompt_flag() -> void:
	# ElevenLabs Sound Effects 2 calls its prompt "text" (schema of 2026-10-04).
	var eleven := Form.fields_from_schema({"parameters": [
		{"name": "text", "type": "string", "required": true, "prompt": true},
		{"name": "loop", "type": "boolean"},
	]})
	assert_eq(Form.prompt_name(eleven), "text")
	assert_eq(Form.prompt_name(Form.fields_from_schema(_schema("schema_flare"))), "prompt")
	# Hunyuan 3D image-to-3D: an image, no text.
	var hunyuan := Form.fields_from_schema({"parameters": [{"name": "image", "type": "file", "required": true, "kind": "image"}]})
	assert_eq(Form.prompt_name(hunyuan), "")


func test_truthy_accepts_what_schemas_send() -> void:
	assert_true(Form.truthy(true))
	assert_true(Form.truthy(1))
	assert_true(Form.truthy(" True "))
	assert_false(Form.truthy(null))
	assert_false(Form.truthy("false"))
	assert_false(Form.truthy(0.0))
	assert_false(Form.truthy({}))
	# A boolean field with no default does not break the form or the payload.
	var fields := Form.fields_from_schema({"parameters": [{"name": "prompt", "type": "string", "required": true},
		{"name": "loop", "type": "boolean", "required": null}]})
	var values := Form.initial_values(fields, {})
	values["prompt"] = "coin"
	values["loop"] = "true"
	assert_eq(Form.payload(fields, values).get("loop"), true)
