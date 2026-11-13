@tool
extends VBoxContainer
## The Scenario dock. Built in code; it reads the controller's state on every
## "changed" signal and forwards clicks. No logic lives here.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Form := preload("res://addons/scenario/core/schema_form.gd")
const Workflows := preload("res://addons/scenario/core/workflows.gd")
const Library := preload("res://addons/scenario/editor/library.gd")
const LibraryUI := preload("res://addons/scenario/editor/library_ui.gd")

## The dock's views: generate in a lane, or browse the project's assets or jobs.
const VIEWS := [["generate", "Generate"], ["library", "Library"], ["history", "History"]]
const KEYS_URL := "https://app.scenario.com"
const DOCS_URL := "https://docs.scenario.com"

# Footer menu items.
const MENU_SIGN_OUT := 0
const MENU_OPEN := 1
const MENU_CHECK := 2
const MENU_PROJECT := 3

var controller: Controller
## The Library and History state, created with the dock.
var library: Library
## "generate", "library" or "history"
var view := "generate"

var _connect_box: VBoxContainer
var _sign_in_box: VBoxContainer
var _sign_in_button: Button
var _waiting_box: VBoxContainer
var _waiting_label: Label
var _code_edit: LineEdit
var _device_buttons: HBoxContainer
var _key_box: VBoxContainer
var _key_edit: LineEdit
var _secret_edit: LineEdit
var _connect_button: Button
var _picker_box: VBoxContainer
var _picker_label: Label
var _team_option: OptionButton
var _project_option: OptionButton
var _use_project_button: Button
var _retry_teams_button: Button
var _picker_cancel_button: Button
var _picker_team := ""
var _picker_project := ""
var _menu: MenuButton
var _main_box: VBoxContainer
var _view_buttons := {}
var _generate_box: VBoxContainer
var _library_ui: LibraryUI
var _lane_buttons := {}
var _lane_hint: Label
var _model_option: OptionButton
var _model_note: Label
var _more_button: Button
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
	library = Library.new()
	library.name = "ScenarioLibrary"
	add_child(library)
	library.bind(controller)
	_build()
	_library_ui.bind(library)
	controller.changed.connect(_refresh)
	controller.notified.connect(_on_notified)
	_refresh()


func _show_view(p_view: String) -> void:
	view = p_view
	for id in _view_buttons:
		_view_buttons[id].set_pressed_no_signal(id == view)
	_generate_box.visible = view == "generate"
	_library_ui.visible = view != "generate"
	if view != "generate":
		_library_ui.show_view(view)


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

	_build_connect(content)
	_build_picker(content)

	_main_box = VBoxContainer.new()
	_main_box.add_theme_constant_override("separation", 6)
	content.add_child(_main_box)
	var views := HBoxContainer.new()
	var view_group := ButtonGroup.new()
	for view in VIEWS:
		var button := Button.new()
		button.text = view[1]
		button.toggle_mode = true
		button.button_group = view_group
		button.size_flags_horizontal = SIZE_EXPAND_FILL
		button.button_pressed = view[0] == "generate"
		button.pressed.connect(_show_view.bind(view[0]))
		views.add_child(button)
		_view_buttons[view[0]] = button
	_main_box.add_child(views)
	_generate_box = VBoxContainer.new()
	_generate_box.add_theme_constant_override("separation", 6)
	_main_box.add_child(_generate_box)
	_library_ui = LibraryUI.new()
	_library_ui.visible = false
	_main_box.add_child(_library_ui)
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
	_generate_box.add_child(lanes_row)
	_lane_hint = _dim_label("")
	_generate_box.add_child(_lane_hint)

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
	_more_button = more
	_generate_box.add_child(model_row)
	_model_note = _dim_label("")
	_generate_box.add_child(_model_note)

	_fields_box = VBoxContainer.new()
	_generate_box.add_child(_fields_box)
	_settings = FoldableContainer.new()
	_settings.title = "Settings"
	_settings.folded = true
	_settings_box = VBoxContainer.new()
	_settings.add_child(_settings_box)
	_generate_box.add_child(_settings)

	_problem_label = _wrap_label("")
	_problem_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	_generate_box.add_child(_problem_label)
	_generate_button = Button.new()
	_generate_button.custom_minimum_size.y = _px(34)
	_generate_button.pressed.connect(_on_generate)
	_generate_box.add_child(_generate_button)

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
	_menu = MenuButton.new()
	_menu.text = "..."
	_menu.flat = false
	_menu.get_popup().add_item("Change team or project", MENU_PROJECT)
	_menu.get_popup().add_item("Open Scenario", MENU_OPEN)
	_menu.get_popup().add_item("Check unknown jobs", MENU_CHECK)
	_menu.get_popup().add_item("Sign out", MENU_SIGN_OUT)
	_menu.get_popup().id_pressed.connect(_on_menu)
	footer.add_child(_menu)
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


## Signed out: Sign in with Scenario, on another device, or an API key.
func _build_connect(content: VBoxContainer) -> void:
	_connect_box = VBoxContainer.new()
	_connect_box.add_theme_constant_override("separation", 6)
	content.add_child(_connect_box)
	_connect_box.add_child(_wrap_label("Sign in with your Scenario account to generate images, 3D models, materials, skyboxes and sounds into this project."))

	_sign_in_box = VBoxContainer.new()
	_connect_box.add_child(_sign_in_box)
	_sign_in_button = Button.new()
	_sign_in_button.text = "Sign in with Scenario"
	_sign_in_button.custom_minimum_size.y = _px(34)
	_sign_in_button.pressed.connect(controller.sign_in_browser)
	_sign_in_box.add_child(_sign_in_button)
	var device_link := LinkButton.new()
	device_link.text = "Sign in on another device"
	device_link.tooltip_text = "Shows a code to enter in the browser of any device, for when this computer's browser cannot finish the sign-in."
	device_link.pressed.connect(controller.sign_in_device)
	_sign_in_box.add_child(device_link)
	var key_link := LinkButton.new()
	key_link.text = "Use an API key instead"
	key_link.pressed.connect(func() -> void: _key_box.visible = not _key_box.visible)
	_sign_in_box.add_child(key_link)

	_waiting_box = VBoxContainer.new()
	_connect_box.add_child(_waiting_box)
	_waiting_label = _wrap_label("")
	_waiting_box.add_child(_waiting_label)
	_code_edit = LineEdit.new()
	_code_edit.editable = false
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_edit.add_theme_font_size_override("font_size", int(_px(22)))
	_waiting_box.add_child(_code_edit)
	_device_buttons = HBoxContainer.new()
	_device_buttons.add_child(_action("Open the page here", controller.open_device_page))
	_device_buttons.add_child(_action("Copy code", func() -> void: DisplayServer.clipboard_set(_code_edit.text)))
	_waiting_box.add_child(_device_buttons)
	_waiting_box.add_child(_action("Cancel", controller.cancel_sign_in))

	_key_box = VBoxContainer.new()
	_key_box.visible = false
	_connect_box.add_child(_key_box)
	_key_edit = LineEdit.new()
	_key_edit.placeholder_text = "API key (api_...)"
	_key_box.add_child(_key_edit)
	_secret_edit = LineEdit.new()
	_secret_edit.placeholder_text = "API secret"
	_secret_edit.secret = true
	_key_box.add_child(_secret_edit)
	_connect_button = Button.new()
	_connect_button.text = "Connect"
	_connect_button.pressed.connect(_on_connect)
	_key_box.add_child(_connect_button)
	var keys_link := LinkButton.new()
	keys_link.text = "Create an API key in Scenario"
	keys_link.uri = KEYS_URL
	_key_box.add_child(keys_link)
	_connect_box.add_child(_dim_label("Your sign-in is stored in your system keychain (or your editor settings folder), never in the project."))


## Signed in: the team and project that pays for the generations.
func _build_picker(content: VBoxContainer) -> void:
	_picker_box = VBoxContainer.new()
	_picker_box.add_theme_constant_override("separation", 6)
	content.add_child(_picker_box)
	_picker_label = _wrap_label("")
	_picker_box.add_child(_picker_label)
	_team_option = OptionButton.new()
	_team_option.fit_to_longest_item = false
	_team_option.item_selected.connect(func(i: int) -> void:
		_picker_team = str(_team_option.get_item_metadata(i))
		_picker_project = ""
		_refresh_picker())
	_picker_box.add_child(_team_option)
	_project_option = OptionButton.new()
	_project_option.fit_to_longest_item = false
	_project_option.item_selected.connect(func(i: int) -> void:
		_picker_project = str(_project_option.get_item_metadata(i)))
	_picker_box.add_child(_project_option)
	_use_project_button = Button.new()
	_use_project_button.text = "Use this project"
	_use_project_button.pressed.connect(func() -> void:
		if _project_option.selected >= 0:
			controller.choose_project(_picker_team, str(_project_option.get_item_metadata(_project_option.selected))))
	_picker_box.add_child(_use_project_button)
	_retry_teams_button = _action("Try again", controller.load_teams)
	_picker_box.add_child(_retry_teams_button)
	_picker_cancel_button = _action("Cancel", controller.close_picker)
	_picker_box.add_child(_picker_cancel_button)
	var sign_out := LinkButton.new()
	sign_out.text = "Sign out"
	sign_out.pressed.connect(controller.sign_out)
	_picker_box.add_child(sign_out)


# --- Refresh ------------------------------------------------------------------

func _refresh() -> void:
	if controller == null:
		return
	var signed_in := controller.is_signed_in()
	var connected := controller.is_connected_account() and not controller.picking
	_connect_box.visible = not signed_in
	_picker_box.visible = signed_in and not connected
	_main_box.visible = connected
	if not _picker_box.visible:
		_picker_team = ""  # the next opening starts from the session's project
		_picker_project = ""
	if not signed_in:
		_refresh_sign_in()
		return
	if not connected:
		_refresh_picker()
		return
	for id in _lane_buttons:
		_lane_buttons[id].set_pressed_no_signal(id == controller.lane_id)
	_lane_hint.text = Lanes.lane(controller.lane_id)["hint"]
	var workflow_lane := controller.lane_id == Lanes.WORKFLOW
	_more_button.visible = Lanes.lane(controller.lane_id).get("recommend", true) or workflow_lane
	_more_button.text = "Refresh" if workflow_lane else "More"
	_more_button.tooltip_text = "List this project's workflows again." if workflow_lane else "Ask Scenario which models fit this prompt best."
	_refresh_models()
	var form_key := "%s|%d" % [controller.model_id, controller.fields.size()]
	if form_key != _built_for:
		_build_fields()
		_built_for = form_key
	_sync_field_values()
	_refresh_price()
	_refresh_jobs()
	var popup := _menu.get_popup()
	popup.set_item_disabled(popup.get_item_index(MENU_PROJECT), not controller.is_oauth())
	if controller.is_oauth():
		_account_label.text = controller.client.session.workspace_label()
		_account_label.tooltip_text = "Signed in with Scenario. Generations go to this team and project."
	else:
		var key: String = controller.account["api_key"]
		_account_label.text = "Key %s...%s (%s)" % [key.substr(0, 8), key.right(4), controller.account["source"]] if key.length() > 12 else "Connected"
		_account_label.tooltip_text = ""


func _refresh_sign_in() -> void:
	var state: String = controller.sign_in["state"]
	_sign_in_box.visible = state == Controller.SIGN_IN_IDLE
	_waiting_box.visible = not _sign_in_box.visible
	var code := str(controller.sign_in.get("user_code", ""))
	_code_edit.text = code
	_code_edit.visible = not code.is_empty()
	_device_buttons.visible = not code.is_empty()
	match state:
		Controller.SIGN_IN_BROWSER:
			_waiting_label.text = "Finish signing in in your browser, then come back here."
		Controller.SIGN_IN_DEVICE:
			_waiting_label.text = "Starting..." if code.is_empty() else "On any device, open %s and enter this code:" % controller.sign_in.get("verification_uri", "")
		Controller.SIGN_IN_FINISHING:
			_waiting_label.text = "Signing in..."


func _refresh_picker() -> void:
	var teams := controller.teams
	if controller.teams_loading:
		_picker_label.text = "Reading your Scenario teams..."
	elif not controller.teams_error.is_empty():
		_picker_label.text = controller.teams_error
	elif teams.is_empty():
		_picker_label.text = "This Scenario account has no team yet. Create one at app.scenario.com, then try again."
	else:
		_picker_label.text = "Choose the team and project that pays for the generations. Jobs and results stay in that project."
	# The team shown: the one picked here, else the session's, else the first.
	var team_ids: Array = teams.map(func(t: Dictionary) -> String: return str(t["id"]))
	if not _picker_team in team_ids:
		var current := controller.client.session.team_id if controller.is_oauth() else ""
		_picker_team = current if current in team_ids else (team_ids[0] if not team_ids.is_empty() else "")
	# The project shown: the one picked here (a refresh while the picker is open
	# must not undo it), else the session's.
	var project_id := _picker_project
	if project_id.is_empty() and controller.is_oauth():
		project_id = controller.client.session.project_id
	_team_option.clear()
	_project_option.clear()
	for team in teams:
		_team_option.add_item(str(team.get("name", team["id"])))
		_team_option.set_item_metadata(_team_option.item_count - 1, str(team["id"]))
		if str(team["id"]) == _picker_team:
			_team_option.select(_team_option.item_count - 1)
			for project in team.get("projects", []):
				_project_option.add_item(str(project.get("name", project["id"])))
				_project_option.set_item_metadata(_project_option.item_count - 1, str(project["id"]))
				if str(project["id"]) == project_id:
					_project_option.select(_project_option.item_count - 1)
	var ready := not controller.teams_loading and not teams.is_empty()
	_team_option.visible = ready
	_project_option.visible = ready
	_use_project_button.visible = ready
	_use_project_button.disabled = _project_option.item_count == 0
	_retry_teams_button.visible = not controller.teams_loading and (teams.is_empty() or not controller.teams_error.is_empty())
	_picker_cancel_button.visible = controller.is_oauth() and controller.client.session.has_project()


func _refresh_models() -> void:
	var models := controller.lane_models()
	_model_option.clear()
	var note := ""
	var picked := controller.picked_model()
	var grouped := false
	for model in models:
		if model.has("lanes") and not grouped:  # the project's own models follow
			_model_option.add_separator("Project models")
			grouped = true
		_model_option.add_item(model["name"])
		_model_option.set_item_metadata(_model_option.item_count - 1, model["id"])
		if model["id"] == picked:
			_model_option.select(_model_option.item_count - 1)
			note = model.get("note", "")
	if controller.project_models.loading:
		note += ("\n" if not note.is_empty() else "") + "Reading this project's models..."
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
	var origin := _short_model(row["model_id"]) if not str(row["model_id"]).is_empty() else "Library"
	if Workflows.is_workflow(row["model_id"]):
		origin = controller._model_name(row["model_id"])
	title.text = "%s  %s" % [origin, str(row["prompt"]).left(48)]
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
			if not str(row["model_id"]).is_empty():  # an asset from the Library has no model to run again
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
		# A mask only refines an input image: it waits in Settings unless required.
		var is_mask := str(field["name"]).to_lower().contains("mask")
		var main: bool = (field["type"] in ["prompt", "file", "files"] and not is_mask) or field["required"]
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
			text.custom_minimum_size.y = _px(72)
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
			status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			row.add_child(status)
			row.add_child(_action("File...", _pick_file.bind(name, str(field["kind"]))))
			if str(field["kind"]) in ["image", ""]:
				row.add_child(_action("Viewport", controller.attach_viewport.bind(name)))
			row.add_child(_action("Clear", controller.clear_field.bind(name)))
			return row
		"unsupported":
			return _dim_label("Set on Scenario only (a list of values or of models).")
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
				widget.set_pressed_no_signal(Form.truthy(value))
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
		MENU_SIGN_OUT:
			controller.sign_out()
		MENU_OPEN:
			OS.shell_open(KEYS_URL)
		MENU_CHECK:
			controller.check_unresolved()
		MENU_PROJECT:
			controller.open_picker()


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
	label.custom_minimum_size.x = _px(120)
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


## Pixels scaled to the editor's display scale (2x on Retina by default).
static func _px(value: float) -> float:
	return value * EditorInterface.get_editor_scale()
