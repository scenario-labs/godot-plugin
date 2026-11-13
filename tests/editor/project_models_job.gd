extends "res://addons/agentkit/agent_job.gd"
## Headless editor test of the project's own models, against the fake backend.
##
## The list is read page by page after connecting and shown under each lane's
## models; a LoRA and a composition run on their base with the wiring (a LoRA
## with its weight, which the fingerprint covers); a model with its own schema
## runs by its id; one with no base the MCP knows is refused before any price
## check; a rerun brings the LoRA back; a project switch forgets the list.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const OAuth := preload("res://addons/scenario/core/oauth.gd")
const ProjectModels := preload("res://addons/scenario/core/project_models.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")

const BASE := "model_bfl-flux-1-dev"

var failures: Array = []
var checks := 0


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/project-models-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var fake := Fake.new()
	root.add_child(fake)
	var c := Controller.new()
	root.add_child(c)
	c.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	c.credentials.use_keychain = false
	c.auto_import = false
	c.output_root = run_dir + "/scenario"
	var ui := DockUI.new()
	root.add_child(ui)
	ui.bind(c)

	# Connecting reads the list, every page.
	c._use_account("api_test", "sec_test", "test")
	await _until(func() -> bool: return c.project_models.loaded and not c.fields.is_empty())
	var listed := fake.calls.filter(func(call: Dictionary) -> bool: return call["tool"] == "models_list")
	check("list read on two pages, private and trained", listed.size() == 2 and listed[0]["arguments"].get("filters") == {"privacy": "private", "status": "trained"}
		and listed[1]["arguments"].get("page_token") == "page2")
	var image_ids: Array = c.lane_models().map(func(m: Dictionary) -> String: return m["id"])
	check("image lane lists the project's image models after its own", image_ids.slice(-4) == ["model_projhero01", "model_projprop01", "model_projstyl01", "model_projsdxl01"])
	check("a video model joins no lane", not "model_projclip01" in image_ids)
	await wait_frames(1)
	check("dock groups them under Project models", _has_separator(ui._model_option, "Project models"))

	# A LoRA runs on its base, with its weight.
	await c.select_model("model_projhero01")
	check("LoRA: calls go to the base", c.model_id == BASE and c.picked_model() == "model_projhero01")
	var names: Array = c.fields.map(func(f: Dictionary) -> String: return f["name"])
	check("LoRA: weight shown, wiring hidden", ProjectModels.WEIGHT_FIELD in names and not "loras" in names and not "modelId" in names)
	await wait_frames(1)
	check("dock shows the LoRA as picked", ui._model_option.get_item_metadata(ui._model_option.selected) == "model_projhero01")
	c.set_value("prompt", "a knight in silver armor")
	await c.estimate_now()
	var priced: Dictionary = _last(fake, "model_run")["arguments"]
	check("LoRA: price check on the base with the wiring", priced.get("dry_run") == true and priced.get("model_id") == BASE
		and priced["parameters"].get("loras") == ["model_projhero01"] and priced["parameters"].get("lorasScale") == [0.75])
	var quoted := c.fingerprint()
	c.set_value(ProjectModels.WEIGHT_FIELD, 0.5)
	check("LoRA: the weight is part of the fingerprint", c.fingerprint() != quoted)
	await c.estimate_now()
	var sent: Dictionary = await c.generate(true)
	check("LoRA: one paid call on the base", fake.paid_calls.size() == 1 and fake.paid_calls[0].get("model_id") == BASE
		and fake.paid_calls[0]["parameters"].get("lorasScale") == [0.5])
	var row := c.ledger.find(str(sent.get("local_id", "")))
	check("LoRA: the row keeps the base, so reconcile matches the job", row.get("model_id") == BASE)

	# A composition runs on its base without a weight.
	await c.select_model("model_projstyl01")
	names = c.fields.map(func(f: Dictionary) -> String: return f["name"])
	c.set_value("prompt", "a castle")
	await c.estimate_now()
	priced = _last(fake, "model_run")["arguments"]
	check("composition: modelId wiring, no weight", not ProjectModels.WEIGHT_FIELD in names and priced["parameters"].get("modelId") == "model_projstyl01")

	# A model with its own schema runs by its id; one without a base is refused.
	await c.select_model("model_projprop01")
	check("own schema: runs by its id", c.model_id == "model_projprop01" and c.trained.is_empty())
	var before := fake.estimates
	await c.select_model("model_projsdxl01")
	await c.estimate_now()
	check("no base: refused before any price check", c.price_state == Controller.PRICE_INVALID and fake.estimates == before)

	# A rerun brings the LoRA and its weight back.
	await c.rerun(str(sent.get("local_id", "")))
	check("rerun: the LoRA and its weight", c.picked_model() == "model_projhero01" and is_equal_approx(float(c.values.get(ProjectModels.WEIGHT_FIELD, 0.0)), 0.5))

	# Signed in: a project switch forgets the list and the LoRA picked from it.
	var app: Dictionary = OAuth.selected_app()["value"]
	var session = c._new_session(app, {"access_token": "at_test", "refresh_token": "rt_test", "expires_at": Time.get_unix_time_from_system() + 3600.0})
	session.set_workspace(fake.teams[0], fake.teams[0]["projects"][0])
	c._use_session(session, "file")
	await _until(func() -> bool: return c.project_models.loaded and not c.fields.is_empty())
	await c.select_model("model_projhero01")
	c.teams = fake.teams
	fake.project_models = []
	c.choose_project("team_a", "proj_a2")
	check("switch: the LoRA is dropped for the lane's default", c.picked_model() != "model_projhero01" and c.trained.is_empty())
	await _until(func() -> bool: return c.project_models.loaded)
	check("switch: the list is read again in the new project", _last(fake, "models_list")["arguments"].get("project_id") == "proj_a2"
		and c.project_models.entries.is_empty())
	c.sign_out()
	check("sign out: the list is forgotten", not c.project_models.loaded and c.project_models.entries.is_empty())

	ui.queue_free()
	c.queue_free()
	fake.queue_free()
	return {"ok": failures.is_empty(), "checks": checks, "failures": failures, "paid_calls": fake.paid_calls.size()}


static func _last(fake: Fake, tool: String) -> Dictionary:
	for i in range(fake.calls.size() - 1, -1, -1):
		if fake.calls[i]["tool"] == tool:
			return fake.calls[i]
	return {"arguments": {}}


static func _has_separator(option: OptionButton, text: String) -> bool:
	for i in option.item_count:
		if option.is_item_separator(i) and option.get_item_text(i) == text:
			return true
	return false


func _until(condition: Callable, seconds: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return
		await root.get_tree().process_frame
