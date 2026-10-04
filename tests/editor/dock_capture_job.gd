extends "res://addons/agentkit/agent_job.gd"
## Renders the dock in three states against the fake backend (0 CU) into one
## image: sign-in, image lane after a finished job, material lane with its
## settings open and a queued job. Needs a windowed editor run (headless draws
## nothing): python3 tools/capture_dock.py.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/dock-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var theme := EditorInterface.get_editor_theme()
	var scale := EditorInterface.get_editor_scale()
	var panel := Vector2(320, 720) * scale
	var gap := 12.0 * scale

	var vp := SubViewport.new()
	vp.size = Vector2i(int(panel.x * 3 + gap * 4), int(panel.y + gap * 2))
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var stage := Panel.new()
	stage.theme = theme
	stage.size = Vector2(vp.size)
	vp.add_child(stage)

	var controllers: Array = []
	var uis: Array = []
	for i in 3:
		var frame := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = theme.get_color("base_color", "Editor")
		style.set_content_margin_all(8.0 * scale)
		frame.add_theme_stylebox_override("panel", style)
		frame.position = Vector2(gap + i * (panel.x + gap), gap)
		frame.size = panel
		stage.add_child(frame)
		var controller := Controller.new()
		root.add_child(controller)
		controller.setup(Fake.new(), run_dir + "/jobs-%d.json" % i, run_dir + "/credentials-%d.json" % i)
		controller.credentials.use_keychain = false
		controller.auto_import = false
		var ui := DockUI.new()
		frame.add_child(ui)
		ui.bind(controller)
		controllers.append(controller)
		uis.append(ui)

	# 1: not connected (the setup found no credentials).
	# 2: image lane, one finished job, a fresh price on the button.
	var image: Controller = controllers[1]
	_connect(image)
	await image.select_lane("image")
	image.set_value("prompt", "a wooden treasure chest with brass trim, game prop")
	await image.estimate_now()
	await image.generate()
	await image.poll()
	image.set_value("prompt", "a wooden treasure chest with brass trim, game prop, isometric")
	await image.estimate_now()
	# 3: material lane, settings open, a queued job.
	var material: Controller = controllers[2]
	_connect(material)
	await material.select_lane("material")
	material.set_value("prompt", "mossy cobblestone floor")
	await material.estimate_now()
	await material.generate()
	material.set_value("prompt", "mossy cobblestone floor, wet")
	await material.estimate_now()
	uis[2]._settings.folded = false

	await wait_frames(6)
	await RenderingServer.frame_post_draw
	var shot := vp.get_texture().get_image()
	var out := str(arg("out", ProjectSettings.globalize_path(out_path("captures/dock.png"))))
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var saved := shot.save_png(out)
	var states := {
		"connect_visible": uis[0]._connect_box.visible and not uis[0]._main_box.visible,
		"image_button": uis[1]._generate_button.text,
		"material_button": uis[2]._generate_button.text,
		"image_jobs": uis[1]._jobs_box.get_child_count(),
		"material_jobs": uis[2]._jobs_box.get_child_count(),
	}
	for c in controllers:
		c.queue_free()
	vp.queue_free()
	return {"ok": saved == OK and not shot.is_empty(), "out": out, "size": [shot.get_width(), shot.get_height()],
		"scale": scale, "states": states}


func _connect(controller: Controller) -> void:
	controller.client.set_credentials("api_demo", "sec_demo")
	controller.account = {"api_key": "api_demo", "source": "test"}
	controller.changed.emit()
