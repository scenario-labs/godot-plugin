extends GutTest

const Client := preload("res://addons/scenario/core/mcp_client.gd")
const Fake := preload("res://tests/support/fake_transport.gd")
const ProjectModels := preload("res://addons/scenario/core/project_models.gd")
const Quote := preload("res://addons/scenario/core/quote.gd")

const LORA_SCHEMA := {
	"model_id": "model_hero", "runs_as": "lora", "parameters_inherited_from": "model_bfl-flux-1-dev",
	"parameters": [
		{"name": "prompt", "type": "string", "required": true, "prompt": true},
		{"name": "loras", "type": "model_array"},
		{"name": "lorasScale", "type": "number_array", "min": -1, "max": 2},
		{"name": "modelId", "type": "model"},
	],
	"run_with": {"tool": "model_run", "required_arguments": {"model_id": "model_bfl-flux-1-dev", "parameters": {"loras": ["model_hero"]}}},
}


func test_records_join_lanes_by_capability() -> void:
	var lora := ProjectModels.entry_for({"id": "model_hero", "name": "Hero", "type": "flux.1-lora", "capabilities": ["txt2img", "img2img"]})
	assert_eq(lora, {"id": "model_hero", "name": "Hero", "note": "project LoRA", "lanes": ["image"]})
	var mesh := ProjectModels.entry_for({"id": "model_mesh", "type": "custom", "capabilities": ["img23d"]})
	assert_eq(mesh["lanes"], ["model3d"])
	assert_eq(mesh["name"], "model_mesh", "the id stands in for a missing name")
	assert_eq(ProjectModels.entry_for({"id": "model_clip", "type": "custom", "capabilities": ["txt2video"]}), {}, "no lane takes video")
	assert_eq(ProjectModels.entry_for({"name": "no id", "capabilities": ["txt2img"]}), {})


func test_a_lora_runs_on_its_base_with_a_weight() -> void:
	var run := ProjectModels.plan("model_hero", LORA_SCHEMA)
	assert_eq(run, {"id": "model_hero", "base": "model_bfl-flux-1-dev", "runs_as": "lora", "wiring": {"loras": ["model_hero"]}})
	var shown: Array = ProjectModels.form_schema(LORA_SCHEMA, run)["parameters"].map(func(p: Dictionary) -> String: return p["name"])
	assert_eq(shown, ["prompt", ProjectModels.WEIGHT_FIELD], "the wiring inputs are not shown")
	var weight: Dictionary = ProjectModels.form_schema(LORA_SCHEMA, run)["parameters"][1]
	assert_eq([weight["default"], weight["min"], weight["max"]], [0.75, -1, 2], "the base's lorasScale limits")
	var sent := ProjectModels.run_payload(run, {"prompt": "a knight", ProjectModels.WEIGHT_FIELD: 0.5})
	assert_eq(sent, {"prompt": "a knight", "loras": ["model_hero"], "lorasScale": [0.5]})
	# The fingerprint covers the trained model and its weight.
	var other := ProjectModels.run_payload(run, {"prompt": "a knight", ProjectModels.WEIGHT_FIELD: 0.6})
	assert_ne(Quote.fingerprint(run["base"], sent), Quote.fingerprint(run["base"], other))


func test_a_composition_runs_on_its_base_without_a_weight() -> void:
	var schema := LORA_SCHEMA.duplicate(true)
	schema["runs_as"] = "composition"
	schema["run_with"]["required_arguments"]["parameters"] = {"modelId": "model_style"}
	var run := ProjectModels.plan("model_style", schema)
	var shown: Array = ProjectModels.form_schema(schema, run)["parameters"].map(func(p: Dictionary) -> String: return p["name"])
	assert_eq(shown, ["prompt"])
	assert_eq(ProjectModels.run_payload(run, {"prompt": "a castle"}), {"prompt": "a castle", "modelId": "model_style"})


func test_a_model_with_its_own_schema_runs_by_its_id() -> void:
	var schema := {"parameters": [{"name": "prompt", "type": "string", "prompt": true}]}
	assert_eq(ProjectModels.plan("model_prop", schema), {})
	assert_eq(ProjectModels.form_schema(schema, {}), schema)
	assert_eq(ProjectModels.run_payload({}, {"prompt": "a crate"}), {"prompt": "a crate"})


func test_rerun_finds_the_trained_model_and_its_weight() -> void:
	var lora := ProjectModels.rerun_of("model_bfl-flux-1-dev", {"prompt": "a knight", "loras": ["model_hero"], "lorasScale": [0.5]})
	assert_eq(lora, {"model_id": "model_hero", "values": {"prompt": "a knight", ProjectModels.WEIGHT_FIELD: 0.5}})
	var composition := ProjectModels.rerun_of("model_bfl-flux-1-dev", {"prompt": "a castle", "modelId": "model_style"})
	assert_eq(composition, {"model_id": "model_style", "values": {"prompt": "a castle"}})
	assert_eq(ProjectModels.rerun_of("model_flare", {"prompt": "a crate"}), {"model_id": "model_flare", "values": {"prompt": "a crate"}})


func test_the_list_is_read_page_by_page() -> void:
	var fake := Fake.new()
	var client := Client.new(fake, "api_key_1", "secret_1")
	fake.replies.append(Fake.tool_result({"models": [{"id": "model_a", "type": "custom", "capabilities": ["txt2img"]}], "nextPaginationToken": "t2"}))
	fake.replies.append(Fake.tool_result({"models": [{"id": "model_b", "type": "flux.1-lora", "capabilities": ["txt2img"]}]}))
	var models := ProjectModels.new()
	await models.load(client)
	assert_eq(models.entries.map(func(e: Dictionary) -> String: return e["id"]), ["model_a", "model_b"])
	assert_true(models.loaded and not models.loading)
	var calls := fake.tool_calls()
	assert_eq(calls[0]["payload"]["params"]["arguments"]["filters"], {"privacy": "private", "status": "trained"})
	assert_eq(calls[1]["payload"]["params"]["arguments"]["page_token"], "t2")
	assert_eq(models.for_lane("image").size(), 2)
	assert_eq(models.for_lane("sound"), [])
	models.clear()
	assert_true(models.entries.is_empty() and not models.loaded)
