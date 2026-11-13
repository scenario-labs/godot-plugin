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
	if scene == null:
		return {"ok": false, "failures": failures}

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

	# The lane lists the project's ready workflows, then public ones.
	await controller.select_lane("workflow")
	var ids: Array = controller.lane_models().map(func(m: Dictionary) -> String: return m["id"])
	check("ready workflows listed, drafts left out", ids == ["workflow_prop3d", "workflow_pubsfx", "workflow_pubbatch"])
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
	row = controller.ledger.find(sent.get("local_id", ""))
	var model: Node = null
	for child in scene.get_children():
		if child.scene_file_path.ends_with(".glb"):
			model = child
	check("GLB output instanced in the scene", placed.get("ok", false) and model != null and model.owner == scene)
	check("image next to the GLB kept as a file, not placed", row.get("files", []).any(func(f: String) -> bool: return f.ends_with(".png"))
		and _first_of(scene, "Sprite3D") == null)
	check("files under the workflow folder", row.get("files", []).all(func(f: String) -> bool: return f.contains("/scenario/workflow/")))

	# A sound workflow: placed as a player.
	await controller.select_model("workflow_pubsfx")
	controller.set_value("prompt", "door creak")
	await controller.estimate_now()
	var sound: Dictionary = await controller.generate()
	await controller.poll()
	await controller.import_job(sound.get("local_id", ""))
	check("sound output placed as a player", _first_of(scene, "AudioStreamPlayer3D") != null or _first_of(scene, "AudioStreamPlayer") != null)

	# An input the dock cannot fill: no price, nothing sent.
	var estimates_before := fake.estimates
	await controller.select_model("workflow_pubbatch")
	controller.set_value("prompt", "slimes")
	await controller.estimate_now()
	check("unfillable input blocks the price", controller.price_state == Controller.PRICE_INVALID
		and controller.price_message.contains("run this workflow on Scenario") and fake.estimates == estimates_before)

	# SCENARIO_NO_SPEND: priced, never run.
	await controller.select_model("workflow_prop3d")
	controller.set_value("objectPrompt", "a copper kettle")
	await controller.estimate_now()
	controller.client.spending_disabled = true
	var refused: Dictionary = await controller.generate()
	check("no-spend refuses the run", not refused.get("ok", true) and fake.paid_calls.size() == 2)
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


static func _first_of(node: Node, type: String) -> Node:
	var found := node.find_children("*", type, true, false)
	return found[0] if not found.is_empty() else null


func open_scratch_scene(path: String) -> Node:
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
