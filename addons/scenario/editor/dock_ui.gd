@tool
extends VBoxContainer
## The Scenario dock. Built in code; it reads the controller's state on every
## "changed" signal and forwards clicks. No logic lives here.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Form := preload("res://addons/scenario/core/schema_form.gd")

const KEYS_URL := "https://app.scenario.com"
const DOCS_URL := "https://docs.scenario.com"

var controller: Controller

var _connect_box: VBoxContainer
var _key_edit: LineEdit
var _secret_edit: LineEdit
var _connect_button: Button
var _main_box: VBoxContainer
var _lane_buttons := {}
var _lane_hint: Label
var _model_option: OptionButton
var _model_note: Label
var _fields_box: VBoxContainer
var _settings: FoldableContainer
var _settings_box: VBoxContainer
var _problem_label: Label
var _generate_button: Button
var _jobs_box: VBoxContainer
var _account_label: Label
var _confirm: ConfirmationDialog
var _file_dialog: EditorFileDialog
var _file_field := ""
var _built_for := ""
var _field_widgets := {}


func _init() -> void:
	name = "Scenario"
	size_flags_vertical = SIZE_EXPAND_FILL


func bind(p_controller: Controller) -> void:
	controller = p_controller
	_build()
	controller.changed.connect(_refresh)
	controller.notified.connect(_on_notified)
	_refresh()


# --- Build --------------------------------------------------------------------

func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_connect_box = VBoxContainer.new()
	content.add_child(_connect_box)
	_connect_box.add_child(_wrap_label("Connect your Scenario API key to generate images, 3D models, materials, skyboxes and sounds into this project."))
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "API key (api_...)"
	_connect_box.add_child(_key_edit)
	_secret_edit = LineEdit.new()
	_secret_edit.placeholder_text = "API secret"
	_secret_edit.secret = true
	_connect_box.add_child(_secret_edit)
	_connect_button = Button.new()
	_connect_button.text = "Connect"
	_connect_button.pressed.connect(_on_connect)
	_connect_box.add_child(_connect_button)
	var keys_link := LinkButton.new()
	keys_link.text = "Create an API key in Scenario"
	keys_link.uri = KEYS_URL
	_connect_box.add_child(keys_link)
	_connect_box.add_child(_dim_label("The secret is stored in your system keychain (or your editor settings folder), never in the project."))

	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", 6)
	content.add_child(_main_box)
	var lanes_row := HFlowContainer.new()
	var group := ButtonGroup.new()
	for lane in Lanes.LANES:
		var button := Button.new()
		button.text = lane["title"]
		button.toggle_mode = true
		button.button_group = group
		button.pressed.connect(controller.select_lane.bind(lane["id"]))
		lanes_row.add_child(button)
		_lane_buttons[lane["id"]] = button
	_main_box.add_child(lanes_row)
	_lane_hint = _dim_label("")
	_main_box.add_child(_lane_hint)

	var model_row := HBoxContainer.new()
	_model_option = OptionButton.new()
	_model_option.size_flags_horizontal = SIZE_EXPAND_FILL
	_model_option.fit_to_longest_item = false
	_model_option.item_selected.connect(_on_model_selected)
	model_row.add_child(_model_option)
	var more := Button.new()
	more.text = "More"
	more.tooltip_text = "Ask Scenario which models fit this prompt best."
	more.pressed.connect(controller.load_recommendations)
	model_row.add_child(more)
	_main_box.add_child(model_row)
	_model_note = _dim_label("")
	_main_box.add_child(_model_note)

	_fields_box = VBoxContainer.new()
	_main_box.add_child(_fields_box)
	_settings = FoldableContainer.new()
	_settings.title = "Settings"
	_settings.folded = true
	_settings_box = VBoxContainer.new()
	_settings.add_child(_settings_box)
	_main_box.add_child(_settings)

	_problem_label = _wrap_label("")
	_problem_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	_main_box.add_child(_problem_label)
	_generate_button = Button.new()
	_generate_button.custom_minimum_size.y = 34
	_generate_button.pressed.connect(_on_generate)
	_main_box.add_child(_generate_button)

	_main_box.add_child(HSeparator.new())
	var jobs_title := Label.new()
	jobs_title.text = "Jobs"
	_main_box.add_child(jobs_title)
	_jobs_box = VBoxContainer.new()
	_main_box.add_child(_jobs_box)

	_main_box.add_child(HSeparator.new())
	var footer := HBoxContainer.new()
	_account_label = _dim_label("")
	_account_label.size_flags_horizontal = SIZE_EXPAND_FILL
	footer.add_child(_account_label)
	var menu := MenuButton.new()
	menu.text = "..."
	menu.flat = false
	menu.get_popup().add_item("Disconnect", 0)
	menu.get_popup().add_item("Open Scenario", 1)
	menu.get_popup().add_item("Check unknown jobs", 2)
	menu.get_popup().id_pressed.connect(_on_menu)
	footer.add_child(menu)
	_main_box.add_child(footer)

	_confirm = ConfirmationDialog.new()
	_confirm.title = "Confirm spend"
	_confirm.confirmed.connect(func() -> void: controller.generate(true))
	add_child(_confirm)
	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_file_dialog.file_selected.connect(func(path: String) -> void: controller.attach_file(_file_field, path))
	add_child(_file_dialog)


# --- Refresh ------------------------------------------------------------------

func _refresh() -> void:
	if controller == null:
		return
	var connected := controller.is_connected_account()
	_connect_box.visible = not connected
	_main_box.visible = connected
	if not connected:
		return
	for id in _lane_buttons:
		_lane_buttons[id].set_pressed_no_signal(id == controller.lane_id)
	_lane_hint.text = Lanes.lane(controller.lane_id)["hint"]
	_refresh_models()
	var form_key := "%s|%d" % [controller.model_id, controller.fields.size()]
	if form_key != _built_for:
		_build_fields()
		_built_for = form_key
	_sync_field_values()
	_refresh_price()
	_refresh_jobs()
	var key: String = controller.account["api_key"]
	_account_label.text = "Key %s...%s (%s)" % [key.substr(0, 8), key.right(4), controller.account["source"]] if key.length() > 12 else "Connected"


func _refresh_models() -> void:
	var models := controller.lane_models()
	_model_option.clear()
	var note := ""
	for i in models.size():
		_model_option.add_item(models[i]["name"], i)
		_model_option.set_item_metadata(i, models[i]["id"])
		if models[i]["id"] == controller.model_id:
			_model_option.select(i)
			note = models[i].get("note", "")
	_model_note.text = "Loading the model's settings..." if controller.model_loading else note


func _refresh_price() -> void:
	var state := controller.price_state
	_problem_label.text = controller.price_message if state in [Controller.PRICE_INVALID, Controller.PRICE_ERROR, Controller.PRICE_BLOCKED, Controller.PRICE_OFF] else ""
	_problem_label.visible = not _problem_label.text.is_empty()
	match state:
		Controller.PRICE_READY:
			_generate_button.text = "Generate  ·  %s CU" % Form.number_text(controller.price_cu)
			_generate_button.disabled = controller.submitting
		Controller.PRICE_CHECKING:
			_generate_button.text = "Checking price..."
			_generate_button.disabled = true
		Controller.PRICE_OFF, Controller.PRICE_ERROR:
			_generate_button.text = "Check price"
			_generate_button.disabled = false
		_:
			_generate_button.text = "Sending..." if controller.submitting else "Generate"
			_generate_button.disabled = true


func _refresh_jobs() -> void:
	for child in _jobs_box.get_children():
		child.queue_free()
	var shown := 0
	for row in controller.ledger.jobs:
		if row["state"] == Ledger.DISMISSED:
			continue
		_jobs_box.add_child(_job_row(row))
		shown += 1
		if shown >= 12:
			break
	if shown == 0:
		_jobs_box.add_child(_dim_label("Nothing generated yet."))


func _job_row(row: Dictionary) -> Control:
	var box := VBoxContainer.new()
	var top := HBoxContainer.new()
	var status := Label.new()
	status.text = _state_text(row)
	status.add_theme_color_override("font_color", _state_color(row["state"]))
	top.add_child(status)
	var title := Label.new()
	title.text = "%s  %s" % [_short_model(row["model_id"]), str(row["prompt"]).left(48)]
	title.clip_text = true
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	title.tooltip_text = str(row["prompt"])
	top.add_child(title)
	box.add_child(top)
	var actions := HBoxContainer.new()
	var local_id: String = row["local_id"]
	match row["state"]:
		Ledger.SUCCESS:
			if controller.is_importing(local_id):
				actions.add_child(_dim_label("Importing..."))
			elif not row["imported"]:
				actions.add_child(_action("Import", controller.import_job.bind(local_id)))
			else:
				actions.add_child(_action("Show", _show_files.bind(row["files"])))
			actions.add_child(_action("Re-run", controller.rerun.bind(local_id)))
		Ledger.QUEUED, Ledger.RUNNING:
			actions.add_child(_action("Cancel", controller.cancel.bind(local_id)))
		Ledger.UNKNOWN, Ledger.SUBMITTING:
			actions.add_child(_action("Check Scenario", controller.check_unresolved))
			actions.add_child(_action("Dismiss", controller.dismiss.bind(local_id)))
		_:
			actions.add_child(_action("Re-run", controller.rerun.bind(local_id)))
	if not str(row["error"]).is_empty():
		box.tooltip_text = str(row["error"])
	box.add_child(actions)
	return box


# --- Fields -------------------------------------------------------------------

func _build_fields() -> void:
	for child in _fields_box.get_children():
		child.queue_free()
	for child in _settings_box.get_children():
		child.queue_free()
	_field_widgets.clear()
	for field in controller.fields:
		var main: bool = field["type"] in ["prompt", "file", "files"] or field["required"]
		var target := _fields_box if main else _settings_box
		var label := Label.new()
		label.text = field["label"] + (" *" if field["required"] else "") + ("  (affects price)" if field["cost_impact"] else "")
		label.tooltip_text = field["description"]
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		target.add_child(label)
		var widget := _widget_for(field)
		widget.tooltip_text = field["description"]
		target.add_child(widget)
		_field_widgets[field["name"]] = widget
	_settings.visible = _settings_box.get_child_count() > 0


func _widget_for(field: Dictionary) -> Control:
	var name: String = field["name"]
	match field["type"]:
		"prompt":
			var text := TextEdit.new()
			text.custom_minimum_size.y = 72
			text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
			text.placeholder_text = "Describe what you want..."
			text.text_changed.connect(func() -> void: controller.set_value(name, text.text))
			return text
		"enum":
			var option := OptionButton.new()
			for i in field["options"].size():
				option.add_item(str(field["options"][i]), i)
			option.item_selected.connect(func(i: int) -> void: controller.set_value(name, field["options"][i]))
			return option
		"boolean":
			var check := CheckBox.new()
			check.text = "On"
			check.toggled.connect(func(on: bool) -> void: controller.set_value(name, on))
			return check
		"number", "integer":
			if field["default"] == null and field["min"] == null:
				var line := LineEdit.new()
				line.placeholder_text = "random" if name.to_lower().contains("seed") else "default"
				line.text_changed.connect(func(t: String) -> void:
					controller.set_value(name, null if not t.strip_edges().is_valid_float() else (int(t) if field["type"] == "integer" else t.to_float())))
				return line
			var spin := SpinBox.new()
			spin.step = 1.0 if field["type"] == "integer" else (float(field["step"]) if field["step"] != null else 0.01)
			spin.min_value = float(field["min"]) if field["min"] != null else -1.0e9
			spin.max_value = float(field["max"]) if field["max"] != null else 1.0e9
			spin.value_changed.connect(func(v: float) -> void: controller.set_value(name, int(v) if field["type"] == "integer" else v))
			return spin
		"multi":
			var flow := HFlowContainer.new()
			for option in field["options"]:
				var box := CheckBox.new()
				box.text = str(option)
				box.set_meta("option", option)
				box.toggled.connect(func(_on: bool) -> void: controller.set_value(name, _multi_values(flow)))
				flow.add_child(box)
			return flow
		"file", "files":
			var row := HBoxContainer.new()
			var status := Label.new()
			status.name = "Status"
			status.size_flags_horizontal = SIZE_EXPAND_FILL
			status.clip_text = true
			row.add_child(status)
			row.add_child(_action("File...", _pick_file.bind(name, str(field["kind"]))))
			if str(field["kind"]) in ["image", ""]:
				row.add_child(_action("Viewport", controller.attach_viewport.bind(name)))
			row.add_child(_action("Clear", controller.clear_field.bind(name)))
			return row
		_:
			var line_edit := LineEdit.new()
			line_edit.text_changed.connect(func(t: String) -> void: controller.set_value(name, t))
			return line_edit


func _sync_field_values() -> void:
	for field in controller.fields:
		var widget: Control = _field_widgets.get(field["name"])
		if widget == null:
			continue
		var value: Variant = controller.values.get(field["name"])
		match field["type"]:
			"prompt":
				if widget.text != str(value if value != null else ""):
					widget.text = str(value if value != null else "")
			"enum":
				var index: int = field["options"].find(value)
				if index == -1 and value != null:
					for i in field["options"].size():
						if str(field["options"][i]) == str(value):
							index = i
				if index != -1 and widget.selected != index:
					widget.select(index)
			"boolean":
				widget.set_pressed_no_signal(bool(value))
			"number", "integer":
				if widget is SpinBox and value != null and widget.value != float(value):
					widget.set_value_no_signal(float(value))
			"multi":
				for box in widget.get_children():
					box.set_pressed_no_signal(value is Array and box.get_meta("option") in value)
			"file", "files":
				var status: Label = widget.get_node("Status")
				if controller.uploads.has(field["name"]):
					status.text = "Uploading..."
				elif value is Array and not value.is_empty():
					status.text = "%d reference(s)" % value.size()
				elif value is String and not value.is_empty():
					status.text = "Reference ready"
				else:
					status.text = "None"


static func _multi_values(flow: Node) -> Array:
	var out: Array = []
	for box in flow.get_children():
		if box.button_pressed:
			out.append(box.get_meta("option"))
	return out


# --- Events -------------------------------------------------------------------

func _on_connect() -> void:
	_connect_button.disabled = true
	_connect_button.text = "Connecting..."
	var ok: bool = await controller.connect_account(_key_edit.text, _secret_edit.text)
	_connect_button.disabled = false
	_connect_button.text = "Connect"
	if ok:
		_secret_edit.text = ""


func _on_model_selected(index: int) -> void:
	controller.select_model(str(_model_option.get_item_metadata(index)))


func _on_generate() -> void:
	if controller.price_state in [Controller.PRICE_OFF, Controller.PRICE_ERROR]:
		controller.estimate_now()
		return
	var result: Dictionary = await controller.generate(false)
	if result.has("needs_confirm"):
		_confirm.dialog_text = "This run costs %s CU, above your %s CU confirmation threshold. Generate?" % [
			Form.number_text(result["needs_confirm"]), Form.number_text(controller.confirm_above_cu)]
		_confirm.popup_centered()


func _on_menu(id: int) -> void:
	match id:
		0:
			controller.disconnect_account()
		1:
			OS.shell_open(KEYS_URL)
		2:
			controller.check_unresolved()


func _on_notified(text: String, level: String) -> void:
	var toaster := EditorInterface.get_editor_toaster()
	if toaster != null:
		var severity := EditorToaster.SEVERITY_INFO
		if level == "warning":
			severity = EditorToaster.SEVERITY_WARNING
		elif level == "error":
			severity = EditorToaster.SEVERITY_ERROR
		toaster.push_toast("Scenario: " + text, severity)


func _pick_file(field_name: String, kind: String) -> void:
	_file_field = field_name
	_file_dialog.clear_filters()
	match kind:
		"3d":
			_file_dialog.add_filter("*.glb", "glTF binary")
		"audio":
			_file_dialog.add_filter("*.wav, *.mp3, *.ogg", "Audio")
		_:
			_file_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp", "Images")
	_file_dialog.popup_file_dialog()


func _show_files(paths: Array) -> void:
	if paths.is_empty():
		return
	EditorInterface.get_file_system_dock().navigate_to_path(paths[0])


# --- Small widgets ------------------------------------------------------------

func _action(text: String, callable: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callable)
	return button


func _wrap_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 120
	return label


func _dim_label(text: String) -> Label:
	var label := _wrap_label(text)
	label.modulate = Color(1, 1, 1, 0.65)
	return label


static func _state_text(row: Dictionary) -> String:
	var cu: Variant = row.get("charged_cu")
	var cu_text := (" · %s CU" % Form.number_text(cu)) if cu != null else ""
	match row["state"]:
		Ledger.SUCCESS:
			return "Done" + cu_text
		Ledger.QUEUED:
			return "Queued"
		Ledger.RUNNING:
			return "Running"
		Ledger.CANCEL_REQUESTED:
			return "Cancelling"
		Ledger.CANCELED:
			return "Canceled"
		Ledger.FAILED:
			return "Failed"
		Ledger.BLOCKED:
			return "Blocked"
		Ledger.REJECTED:
			return "Not sent"
		Ledger.UNKNOWN, Ledger.SUBMITTING:
			return "Unknown"
	return str(row["state"])


static func _state_color(state: String) -> Color:
	match state:
		Ledger.SUCCESS:
			return Color(0.45, 0.85, 0.5)
		Ledger.FAILED, Ledger.BLOCKED, Ledger.REJECTED:
			return Color(1.0, 0.5, 0.45)
		Ledger.UNKNOWN, Ledger.SUBMITTING:
			return Color(1.0, 0.8, 0.35)
	return Color(0.75, 0.8, 0.95)


static func _short_model(id: String) -> String:
	for lane in Lanes.LANES:
		for model in lane["models"]:
			if model["id"] == id:
				return model["name"]
	return id.trim_prefix("model_")
