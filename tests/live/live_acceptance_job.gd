extends "res://addons/agentkit/agent_job.gd"
## PAID live acceptance: the real plugin controller and HTTP transport against
## Scenario. Credentials come from SCENARIO_API_KEY / SCENARIO_API_SECRET.
## One cheap run per lane plus a reference upload; fails when any charge
## differs from its quote or a result cannot be placed. Run through
## tools/live_acceptance.py, which enforces the budget and writes the ledger.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const HttpTransport := preload("res://addons/scenario/editor/http_transport.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

## lane, model, parameters (cheap settings, chosen from free estimates on 2026-10-04)
const RUNS := [
	["image", "model_openai-gpt-image-2-5-flare", {"prompt": "a wooden treasure chest with brass trim, game prop, isometric", "quality": "low", "width": 1024, "height": 1024, "background": "transparent"}],
	["image", "model_openai-gpt-image-2-5-flare", {"prompt": "the same chest made of ice crystals", "quality": "low", "width": 1024, "height": 1024}, "referenceImages"],
	["model3d", "model_rodin-hyper3d-v2-5-text-to-3d", {"prompt": "a wooden treasure chest with brass trim", "tier": "Gen-2.5-Extreme-Low", "material": "PBR", "qualityMeshOption": "4K Quad"}],
	["material", "model_patina-material", {"prompt": "mossy cobblestone floor", "width": 512, "height": 512}],
	["skybox", "model_scenario-skybox-gpt", {"prompt": "alpine valley at dawn, snowy peaks, warm light", "quality": "low"}],
	["sound", "model_sonilo-v1-1-text-to-sound-effects", {"prompt": "bright coin pickup chime", "duration": 2, "audioFormat": "wav"}],
]


func run() -> Dictionary:
	await wait_frames(3)
	var budget := float(arg("budget_cu", 200.0))
	var run_dir := "res://tests/tmp_output/live-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var scene_path := run_dir + "/live_scene.tscn"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://main.tscn"), ProjectSettings.globalize_path(scene_path))
	var scene := await open_scratch_scene(scene_path)

	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(HttpTransport.new(), run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.output_root = run_dir + "/scenario"
	controller.auto_import = false
	controller.confirm_above_cu = budget
	if not controller.is_connected_account():
		return {"ok": false, "error": "SCENARIO_API_KEY / SCENARIO_API_SECRET not set"}

	# A reference image for the upload run.
	var reference := run_dir + "/reference.png"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/assets/image.bin"), ProjectSettings.globalize_path(reference))

	var rows: Array = []
	var spent := 0.0
	var ok := true
	var only: String = arg("lanes", "")
	for spec in RUNS:
		if not only.is_empty() and not spec[0] in only.split(","):
			continue
		var lane: String = spec[0]
		var model: String = spec[1]
		var params: Dictionary = spec[2]
		var record := {"lane": lane, "model": model, "quoted": null, "charged": null, "job_id": "", "placed": false, "note": ""}
		controller.lane_id = lane
		await controller.select_model(model)
		for key in params:
			controller.values[key] = params[key]
		if spec.size() > 3:
			await controller.attach_file(spec[3], reference)
			record["note"] = "reference uploaded: %s" % str(controller.values.get(spec[3], "none"))
		EditorInterface.get_selection().clear()
		if lane == "material":
			EditorInterface.get_selection().add_node(scene.get_node("RefCube"))
		await controller.estimate_now()
		if controller.price_state != Controller.PRICE_READY:
			record["note"] += " price check failed: " + controller.price_message
			rows.append(record)
			ok = false
			continue
		record["quoted"] = controller.price_cu
		if spent + controller.price_cu > budget:
			record["note"] += " skipped: over budget"
			rows.append(record)
			continue
		var sent: Dictionary = await controller.generate(true)
		var local_id: String = sent.get("local_id", "")
		var row := controller.ledger.find(local_id)
		record["job_id"] = row.get("job_id", "")
		if not sent.get("ok", false):
			record["note"] += " generate failed: " + str(row.get("error", ""))
			rows.append(record)
			ok = false
			continue
		var deadline := Time.get_ticks_msec() + 600000
		while Time.get_ticks_msec() < deadline:
			await controller.poll()
			row = controller.ledger.find(local_id)
			if not row["state"] in Ledger.ACTIVE_STATES:
				break
			await wait_seconds(4.0)
		record["charged"] = row.get("charged_cu")
		spent += float(row.get("charged_cu", 0.0) if row.get("charged_cu") != null else 0.0)
		if row["state"] != Ledger.SUCCESS:
			record["note"] += " job ended %s: %s" % [row["state"], str(row.get("error", ""))]
			rows.append(record)
			ok = false
			continue
		var placed: Dictionary = await controller.import_job(local_id)
		record["placed"] = placed.get("ok", false)
		record["note"] += " " + str(placed.get("message", ""))
		record["files"] = controller.ledger.find(local_id).get("files", [])
		if not record["placed"] or record["charged"] != record["quoted"]:
			ok = false
		rows.append(record)

	# Lay results out for the capture, then save the scratch scene.
	var x := -3.0
	for child in scene.get_children():
		if child.name.begins_with("Scenario") and child is Node3D:
			child.position = Vector3(x, child.position.y if child is Sprite3D else 0.0, -1.0)
			if child is Sprite3D:
				child.position.y = 1.0
			x += 2.5
	EditorInterface.save_scene()
	controller.queue_free()
	return {"ok": ok, "spent_cu": spent, "runs": rows, "scene_path": scene_path, "run_dir": run_dir}


## Opens the scene and makes it the active tab (the editor may restore other
## scenes from its saved layout a few frames later).
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
