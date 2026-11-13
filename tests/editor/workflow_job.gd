extends "res://addons/agentkit/agent_job.gd"
## Headless editor test of the workflow lane, against the fake backend.
##
## The project's ready workflows are listed (drafts left out, public ones
## after), a workflow's inputs become the dock's form, its price comes from a
## dry run, Generate sends it once, the job is polled, a pause for a person is
## reported, and the outputs are placed by type (a GLB under the scene, a
## sound as a player). Also: an input the dock cannot fill blocks the price,
## SCENARIO_NO_SPEND refuses the run, and a project switch lists again.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")

var failures: Array = []
var checks := 0


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/workflow-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var scene_path := run_dir + "/workflow_scene.tscn"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://main.tscn"), ProjectSettings.globalize_path(scene_path))
	var scene := await open_scratch_scene(scene_path)
	check("scratch scene open", scene != null and scene.scene_file_path == scene_path)
	if scene == null or scene.scene_file_path != scene_path:
		return {"ok": false, "failures": failures}  # never place into, or save, another scene

	var fake := Fake.new()
	root.add_child(fake)
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.credentials.use_keychain = false
	controller.output_root = run_dir + "/scenario"
	controller.auto_import = false
	controller.client.set_credentials("api_test", "sec_test")
	controller.account = {"api_key": "api_test", "source": "test", "method": "api_key"}
	var notices: Array = []
	controller.notified.connect(func(text: String, _level: String) -> void: notices.append(text))
	var ui := DockUI.new()
	root.add_child(ui)
	ui.bind(controller)

	# Entering the lane from a priced model: nothing stays priced while the list loads.
	await controller.select_lane("image")
	controller.set_value("prompt", "a chest")
	await controller.estimate_now()
	var first_seen: Array = []
	var probe := func() -> void:
		if first_seen.is_empty():
			first_seen.append_array([controller.model_id, controller.price_state, controller.quotes.usable(controller.fingerprint(), Time.get_unix_time_from_system()).is_empty()])
	controller.changed.connect(probe)
	await controller.select_lane("workflow")
	controller.changed.disconnect(probe)
	check("previous form not priced while listing", first_seen == ["", Controller.PRICE_IDLE, true])

	# The lane lists the project's ready workflows, then public ones.
	var ids: Array = controller.lane_models().map(func(m: Dictionary) -> String: return m["id"])
	check("ready workflows listed, drafts left out", ids == ["workflow_prop3d", "workflow_kit", "workflow_pubsfx", "workflow_pubbatch"])
	check("first workflow selected", controller.model_id == "workflow_prop3d")
	await wait_frames(1)
	check("dock: Refresh in place of More", ui._more_button.visible and ui._more_button.text == "Refresh")
	check("dock: the workflow's inputs as fields", ui._field_widgets.get("objectPrompt") is TextEdit
		and ui._field_widgets.get("style") is OptionButton and ui._field_widgets.has("referenceImage"))

	# Price with a dry run, then one paid run.
	controller.set_value("objectPrompt", "a brass lantern")
	await controller.estimate_now()
	var priced := _last_call(fake, "workflow_run")
	check("price from a dry run", controller.price_state == Controller.PRICE_READY and controller.price_cu == 6.0
		and priced.get("arguments", {}).get("dry_run") == true)
	check("dry run carries the inputs", priced.get("arguments", {}).get("inputs", {}).get("objectPrompt") == "a brass lantern")
	var sent: Dictionary = await controller.generate()
	check("one paid run", sent.get("ok", false) and fake.paid_calls.size() == 1 and fake.paid_calls[0].get("workflow_id") == "workflow_prop3d"
		and not fake.paid_calls[0].has("dry_run"))
	var again: Dictionary = await controller.generate()
	check("no second run without a new quote", not again.get("ok", false) and fake.paid_calls.size() == 1)
	var row := controller.ledger.find(sent.get("local_id", ""))
	check("ledger row for the workflow", row.get("lane") == "workflow" and row.get("model_id") == "workflow_prop3d" and row.get("prompt") == "a brass lantern")

	# A pause for a person is reported once, then the run finishes.
	fake.awaiting[str(row.get("job_id", ""))] = 2
	await controller.poll()
	await controller.poll()
	check("pause reported once", notices.filter(func(t: String) -> bool: return t.contains("approval or a selection")).size() == 1
		and controller.ledger.find(sent.get("local_id", ""))["state"] == Ledger.RUNNING)
	await controller.poll()
	row = controller.ledger.find(sent.get("local_id", ""))
	check("run finished", row.get("state") == Ledger.SUCCESS and str(row.get("error", "")) == "")

	# Outputs placed by type: a GLB with its preview.
	EditorInterface.get_selection().clear()
	var placed: Dictionary = await controller.import_job(row.get("local_id", ""))
	scene = _edited(scene_path)  # an import can make the editor reload the open scene
	if scene == null:
		return _abort("scratch scene still open after the import")
	row = controller.ledger.find(sent.get("local_id", ""))
	var model: Node = null
	for child in scene.get_children():
		if child.scene_file_path.ends_with(".glb"):
			model = child
	check("GLB output instanced in the scene: " + str(placed.get("message", "")), placed.get("ok", false) and model != null and model.owner == scene)
	check("image next to the GLB kept as a file, not placed", row.get("files", []).any(func(f: String) -> bool: return f.ends_with(".png"))
		and _first_of(scene, "Sprite3D") == null)
	check("files under the workflow folder", row.get("files", []).all(func(f: String) -> bool: return f.contains("/scenario/workflow/")))

	# A sound workflow: placed as a player.
	await controller.select_model("workflow_pubsfx")
	controller.set_value("prompt", "door creak")
	await controller.estimate_now()
	var sound: Dictionary = await controller.generate()
	await controller.poll()
	var sound_placed: Dictionary = await controller.import_job(sound.get("local_id", ""))
	scene = _edited(scene_path)
	if scene == null:
		return _abort("scratch scene still open after the import")
	check("sound output placed as a player: " + str(sound_placed.get("message", "")), _first_of(scene, "AudioStreamPlayer3D") != null or _first_of(scene, "AudioStreamPlayer") != null)

	# Image, model and sound from one run: each placed by its lane, the model asked for as GLB.
	var players_before := scene.find_children("*", "AudioStreamPlayer3D", true, false).size()
	var models_before := _models(scene)
	await controller.select_model("workflow_kit")
	controller.set_value("prompt", "camp kit")
	await controller.estimate_now()
	var kit: Dictionary = await controller.generate()
	await controller.poll()
	EditorInterface.get_selection().clear()
	var kit_placed: Dictionary = await controller.import_job(kit.get("local_id", ""))
	scene = _edited(scene_path)
	if scene == null:
		return _abort("scratch scene still open after the import")
	check("mixed run: model and sound both placed: " + str(kit_placed.get("message", "")), kit_placed.get("ok", false) and _models(scene) == models_before + 1
		and scene.find_children("*", "AudioStreamPlayer3D", true, false).size() == players_before + 1)
	var glb_download := fake.calls.filter(func(c: Dictionary) -> bool: return c["tool"] == "asset_download" and c["arguments"]["asset_id"] == "asset_mixglb")
	check("mixed run: the model downloaded as GLB, the rest as is", glb_download.size() == 1 and glb_download[0]["arguments"].get("format") == "glb"
		and not _last_call(fake, "asset_download").get("arguments", {}).has("format"))

	# Refresh lists again and reads the chosen workflow's inputs again, keeping it chosen.
	var gets_before := fake.calls.filter(func(c: Dictionary) -> bool: return c["tool"] == "workflow_get").size()
	await controller.load_recommendations()
	check("Refresh re-reads the inputs and keeps the workflow", controller.model_id == "workflow_kit"
		and fake.calls.filter(func(c: Dictionary) -> bool: return c["tool"] == "workflow_get").size() == gets_before + 1)

	# Another account: its own workflows are listed, the old choice is dropped.
	var lists_before := fake.calls.filter(func(c: Dictionary) -> bool: return c["tool"] == "workflows_list").size()
	controller._use_account("api_other", "sec_other", "test")
	await wait_frames(5)
	check("another account lists again and starts from its first workflow", controller.model_id == "workflow_prop3d"
		and fake.calls.filter(func(c: Dictionary) -> bool: return c["tool"] == "workflows_list").size() > lists_before)

	# A project with no workflow: guidance, and no price check for an empty model.
	fake.no_workflows = true
	await controller.load_recommendations()
	var checks_before := fake.estimates
	await controller.estimate_now()
	check("no workflow: guidance stays, nothing priced", controller.model_id == "" and controller.price_message.contains("No ready workflow")
		and fake.estimates == checks_before)
	fake.no_workflows = false
	await controller.load_recommendations()

	# An input the dock cannot fill: no price, nothing sent.
	var estimates_before := fake.estimates
	await controller.select_model("workflow_pubbatch")
	controller.set_value("prompt", "slimes")
	await controller.estimate_now()
	check("unfillable input blocks the price", controller.price_state == Controller.PRICE_INVALID
		and controller.price_message.contains("run this workflow on Scenario") and fake.estimates == estimates_before)

	# A price check that returns a job stops automatic checks, and one already debounced sends nothing.
	await controller.select_model("workflow_prop3d")
	controller.set_value("objectPrompt", "a tin cup")
	fake.estimate_job = "job_surprise"
	await controller.estimate_now()
	check("a dry run returning a job stops automatic checks", not controller.auto_estimates and controller.price_state == Controller.PRICE_ERROR)
	var dry_runs_before := fake.estimates
	controller.price_state = Controller.PRICE_CHECKING  # as if debounced before the stop
	await controller._run_estimate()
	check("a debounced check after that sends nothing", fake.estimates == dry_runs_before and controller.price_state == Controller.PRICE_OFF)

	# SCENARIO_NO_SPEND: priced, never run.
	await controller.select_model("workflow_prop3d")
	controller.set_value("objectPrompt", "a copper kettle")
	await controller.estimate_now()
	controller.client.spending_disabled = true
	var paid_before := fake.paid_calls.size()
	var refused: Dictionary = await controller.generate()
	check("no-spend refuses the run", not refused.get("ok", true) and fake.paid_calls.size() == paid_before)
	controller.client.spending_disabled = false

	# A transport failure on the run: Unknown, and the same request is blocked.
	await controller.estimate_now()
	fake.drop_next_paid = true
	var lost: Dictionary = await controller.generate()
	check("lost run marked Unknown", controller.ledger.find(lost.get("local_id", "")).get("state") == Ledger.UNKNOWN)
	check("same request blocked until resolved", controller.price_state == Controller.PRICE_BLOCKED)

	EditorInterface.save_scene()
	ui.queue_free()
	controller.queue_free()
	fake.queue_free()
	return {"ok": failures.is_empty(), "checks": checks, "failures": failures, "paid_calls": fake.paid_calls.size()}


static func _last_call(fake: Fake, tool: String) -> Dictionary:
	for i in range(fake.calls.size() - 1, -1, -1):
		if fake.calls[i]["tool"] == tool:
			return fake.calls[i]
	return {}


## Instanced GLB scenes anywhere under node (a placement goes under the selection).
static func _models(node: Node) -> int:
	return node.find_children("*", "Node3D", true, false).filter(func(n: Node) -> bool: return n.scene_file_path.ends_with(".glb")).size()


static func _first_of(node: Node, type: String) -> Node:
	var found := node.find_children("*", type, true, false)
	return found[0] if not found.is_empty() else null


func _abort(label: String) -> Dictionary:
	var current := EditorInterface.get_edited_scene_root()
	check("%s (editing %s, open: %s)" % [label, current.scene_file_path if current != null else "nothing",
		", ".join(EditorInterface.get_open_scenes())], false)
	return {"ok": false, "checks": checks, "failures": failures}


## The scene being edited now, if it is still the scratch scene (else null: checks fail).
static func _edited(path: String) -> Node:
	var current := EditorInterface.get_edited_scene_root()
	return current if current != null and current.scene_file_path == path else null


func open_scratch_scene(path: String) -> Node:
	# The editor reopens the scenes an earlier job left open and can switch back
	# to one of them during an import, so placements would land there: close them.
	for other in EditorInterface.get_open_scenes():
		if other != path and not other.is_empty():
			EditorInterface.open_scene_from_path(other)
			await wait_frames(2)
			EditorInterface.close_scene()
			await wait_frames(2)
	EditorInterface.get_resource_filesystem().update_file(path)
	for attempt in 30:
		EditorInterface.open_scene_from_path(path)
		await wait_frames(2)
		var current := EditorInterface.get_edited_scene_root()
		if current != null and current.scene_file_path == path:
			await wait_frames(2)
			current = EditorInterface.get_edited_scene_root()
			if current != null and current.scene_file_path == path:
				return current
	return EditorInterface.get_edited_scene_root()
