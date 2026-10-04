extends "res://addons/agentkit/agent_job.gd"
## Headless editor integration test (run with gd_run.run_script(editor=True)).
##
## Against a fake Scenario backend: the plugin's dock loads; each of the five
## lanes goes price check, generate, poll, import, place; the money rules hold
## in the real editor (one paid call per Generate, no second send without a new
## quote, the confirmation threshold); undo removes a placed node.

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
	var run_dir := "res://tests/tmp_output/run-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))

	# The plugin is enabled in project.godot: its controller and dock exist.
	check("plugin controller exists", root.find_child("ScenarioController", true, false) != null)
	check("dock exists", root.find_child("Scenario", true, false) != null)

	# A scratch copy of the demo scene, so the real one is never modified.
	var scene_path := run_dir + "/flow_scene.tscn"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://main.tscn"), ProjectSettings.globalize_path(scene_path))
	EditorInterface.get_resource_filesystem().update_file(scene_path)
	var scene := await open_scratch_scene(scene_path)
	check("scratch scene open", scene != null and scene.scene_file_path == scene_path)
	if scene == null:
		return {"ok": false, "failures": failures}

	var fake := Fake.new()
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.credentials.use_keychain = false
	controller.output_root = run_dir + "/scenario"
	controller.auto_import = false
	controller.client.set_credentials("api_test", "sec_test")
	controller.account = {"api_key": "api_test", "source": "test"}

	var ui := DockUI.new()
	root.add_child(ui)
	ui.bind(controller)

	var results := {}
	for lane in ["image", "model3d", "material", "skybox", "sound"]:
		EditorInterface.get_selection().clear()
		if lane == "material":
			EditorInterface.get_selection().add_node(scene.get_node("RefCube"))
		await controller.select_lane(lane)
		controller.set_value("prompt", "test %s" % lane)
		await controller.estimate_now()
		check(lane + ": price ready", controller.price_state == Controller.PRICE_READY and controller.price_cu == 2.0)
		if lane == "image":
			await wait_frames(1)
			check("dock shows the price on the button", ui._generate_button.text == "Generate  ·  2 CU" and not ui._generate_button.disabled)
			check("dock built the prompt field", ui._field_widgets.get("prompt") is TextEdit)
			check("dock built the quality option", ui._field_widgets.get("quality") is OptionButton)
		var paid_before := fake.paid_calls.size()
		var sent: Dictionary = await controller.generate()
		check(lane + ": generate ok", sent.get("ok", false))
		check(lane + ": exactly one paid call", fake.paid_calls.size() == paid_before + 1)
		var again: Dictionary = await controller.generate()
		check(lane + ": no second send without a new quote", not again.get("ok", false) and fake.paid_calls.size() == paid_before + 1)
		await controller.poll()
		var row := controller.ledger.find(sent.get("local_id", ""))
		check(lane + ": job succeeded", row.get("state") == Ledger.SUCCESS and row.get("charged_cu") == 2.0)
		var placed: Dictionary = await controller.import_job(row.get("local_id", ""))
		check(lane + ": placed", placed.get("ok", false))
		row = controller.ledger.find(sent.get("local_id", ""))
		check(lane + ": ledger marks imported", row.get("imported", false))
		var provenance := str(row["files"][0]).get_basename() + ".scenario.json"
		check(lane + ": provenance sidecar", FileAccess.file_exists(provenance))
		results[lane] = {"message": placed.get("message", ""), "files": row.get("files", [])}

	# What landed in the scene.
	var sprite := _first_of(scene, "Sprite3D")
	check("image: Sprite3D with texture, saved with the scene", sprite != null and sprite.texture != null and sprite.owner == scene)
	var model: Node = null
	for child in scene.get_children():
		if child.scene_file_path.ends_with(".glb"):
			model = child
	check("model3d: GLB instanced and owned", model != null and model.owner == scene)
	check("model3d: thumbnail kept as a preview file", results["model3d"]["files"].any(func(f: String) -> bool: return f.ends_with("-preview.png")))
	var cube: MeshInstance3D = scene.get_node("RefCube")
	var material := cube.material_override as StandardMaterial3D
	check("material: StandardMaterial3D applied", material != null and material.albedo_texture != null)
	check("material: normal, roughness, metallic, height wired", material != null and material.normal_enabled and material.normal_texture != null
		and material.roughness_texture != null and material.metallic_texture != null and material.heightmap_enabled)
	var normal_import := ""
	for path in results["material"]["files"]:
		if str(path).ends_with("-normal.png"):
			normal_import = FileAccess.get_file_as_string(str(path) + ".import")
	check("material: normal map imported as a normal map", normal_import.contains("compress/normal_map=1"))
	var world := _first_of(scene, "WorldEnvironment") as WorldEnvironment
	check("skybox: panorama sky on the WorldEnvironment", world != null and world.environment.sky != null
		and world.environment.sky.sky_material is PanoramaSkyMaterial and world.environment.sky.sky_material.panorama != null)
	var player := _first_of(scene, "AudioStreamPlayer3D") as AudioStreamPlayer3D
	check("sound: AudioStreamPlayer3D with the MP3", player != null and player.stream is AudioStreamMP3)

	# Undo the last placement (the sound), then redo it.
	var undo := EditorInterface.get_editor_undo_redo()
	var history := undo.get_history_undo_redo(undo.get_object_history_id(scene))
	history.undo()
	check("undo removes the sound player", _first_of(scene, "AudioStreamPlayer3D") == null)
	history.redo()
	check("redo puts it back", _first_of(scene, "AudioStreamPlayer3D") != null)

	# References: a file upload goes start, one PUT to S3, complete; no CU.
	await controller.select_lane("image")
	var reference := run_dir + "/reference.png"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://tests/assets/image.bin"), ProjectSettings.globalize_path(reference))
	await controller.attach_file("referenceImages", reference)
	check("upload: asset id in the form", controller.values.get("referenceImages") == ["asset_upl001"])
	check("upload: one PUT to S3 with the file bytes", fake.puts.size() == 1 and fake.puts[0]["url"].contains(".amazonaws.com/")
		and fake.puts[0]["size"] == FileAccess.get_file_as_bytes(reference).size())
	controller.clear_field("referenceImages")
	check("upload: cleared", not controller.values.has("referenceImages"))
	# "More": the specialist first, then the ranked models, after the lane's own.
	await controller.load_recommendations()
	var ids: Array = controller.lane_models().map(func(m: Dictionary) -> String: return m["id"])
	check("recommendations added to the picker", ids.has("model_TiL9mAQVWbaC9ythxHsLKzwK") and ids.has("model_openai-gpt-image-2-5-sunburst")
		and ids[0] == "model_openai-gpt-image-2-5-flare")
	await wait_frames(1)
	check("dock shows More on the image lane", ui._more_button.visible)
	await controller.select_lane("material")
	await wait_frames(1)
	check("dock hides More on the material lane", not ui._more_button.visible)
	var asked_before := fake.tool_log.count("recommend")
	await controller.load_recommendations()
	check("no recommendations asked for materials", fake.tool_log.count("recommend") == asked_before)

	# A model whose prompt field is called "text" keeps the prompt.
	await controller.select_lane("sound")
	controller.set_value("prompt", "coin pickup")
	await controller.select_model("model_elevenlabs-sound-effects-v2")
	check("prompt carried into ElevenLabs' text field", controller.values.get("text") == "coin pickup" and controller.prompt_text() == "coin pickup")
	await wait_frames(1)
	check("dock shows ElevenLabs' text as the prompt box", ui._field_widgets.get("text") is TextEdit)

	# Confirmation threshold: above it nothing is sent until confirmed.
	await controller.select_lane("image")
	controller.set_value("prompt", "expensive")
	await controller.estimate_now()
	controller.confirm_above_cu = 1.0
	var paid_before_confirm := fake.paid_calls.size()
	var asked: Dictionary = await controller.generate()
	check("above threshold asks first", asked.has("needs_confirm") and fake.paid_calls.size() == paid_before_confirm)
	var confirmed: Dictionary = await controller.generate(true)
	check("confirmed run is sent once", confirmed.get("ok", false) and fake.paid_calls.size() == paid_before_confirm + 1)

	check("six paid calls in total", fake.paid_calls.size() == 6)
	check("every paid call used wait=false", fake.paid_calls.all(func(a: Dictionary) -> bool: return a.get("wait") == false))
	# Lay the results out side by side and save the scratch scene for a windowed capture.
	if sprite != null:
		sprite.position = Vector3(-2.2, 1.0, 0.0)
	if model != null:
		model.position = Vector3(2.2, 0.35, 0.0)
	cube.position = Vector3(0.0, 0.5, 0.0)
	EditorInterface.save_scene()
	ui.queue_free()
	controller.queue_free()
	return {
		"scene_path": scene_path,
		"ok": failures.is_empty(), "checks": checks, "failures": failures, "results": results,
		"paid_calls": fake.paid_calls.size(), "estimates": fake.estimates, "run_dir": run_dir,
	}


static func _first_of(node: Node, type: String) -> Node:
	var found := node.find_children("*", type, true, false)
	return found[0] if not found.is_empty() else null


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
