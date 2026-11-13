@tool
extends EditorPlugin
## Scenario for Godot: a dock that generates images, 3D models, PBR materials,
## skyboxes and sound effects with Scenario and places them in the open scene.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const HttpTransport := preload("res://addons/scenario/editor/http_transport.gd")
const UsageReporter := preload("res://addons/scenario/editor/usage_reporter.gd")

const LEDGER_PATH := "res://.godot/scenario/jobs.json"
const SETTING_CONFIRM := "scenario/confirm_above_cu"
const SETTING_AUTO_IMPORT := "scenario/auto_import"
const SETTING_SHARE_USAGE := "scenario/share_anonymous_usage_data"

var controller: Controller
var reporter: UsageReporter
var dock: EditorDock
var ui: DockUI


func _enter_tree() -> void:
	_register_settings()
	controller = Controller.new()
	controller.name = "ScenarioController"
	add_child(controller)
	var config_dir := EditorInterface.get_editor_paths().get_config_dir()
	controller.setup(HttpTransport.new(), LEDGER_PATH, config_dir.path_join("scenario/credentials.json"))
	reporter = UsageReporter.new()
	add_child(reporter)
	reporter.setup(controller, controller.transport, config_dir.path_join("scenario/usage.json"))
	reporter.sharing_chosen.connect(func(share: bool) -> void:
		EditorInterface.get_editor_settings().set_setting(SETTING_SHARE_USAGE, share))
	_apply_settings()
	reporter.start()
	EditorInterface.get_editor_settings().settings_changed.connect(_apply_settings)

	ui = DockUI.new()
	ui.reporter = reporter
	ui.bind(controller)
	dock = EditorDock.new()
	dock.title = "Scenario"
	dock.layout_key = "scenario"
	# Its own column right of the Inspector: as a 4th tab next to Inspector,
	# Signals and Groups it hid behind the tab overflow (2026-10-04, first GUI try).
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UR
	dock.add_child(ui)
	add_dock(dock)
	# First enable in a project: bring the dock to the front even when a saved
	# layout put it in a tab group.
	var settings := EditorInterface.get_editor_settings()
	if not settings.get_project_metadata("scenario", "dock_shown", false):
		dock.make_visible.call_deferred()
		settings.set_project_metadata("scenario", "dock_shown", true)


func _exit_tree() -> void:
	var settings := EditorInterface.get_editor_settings()
	if settings.settings_changed.is_connected(_apply_settings):
		settings.settings_changed.disconnect(_apply_settings)
	if dock != null:
		remove_dock(dock)
		dock.queue_free()
		dock = null
	if reporter != null:
		reporter.queue_free()
		reporter = null
	if controller != null:
		controller.queue_free()
		controller = null


func _register_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_CONFIRM):
		settings.set_setting(SETTING_CONFIRM, 100.0)
	settings.set_initial_value(SETTING_CONFIRM, 100.0, false)
	settings.add_property_info({"name": SETTING_CONFIRM, "type": TYPE_FLOAT, "hint": PROPERTY_HINT_RANGE, "hint_string": "0,10000,1"})
	if not settings.has_setting(SETTING_AUTO_IMPORT):
		settings.set_setting(SETTING_AUTO_IMPORT, true)
	settings.set_initial_value(SETTING_AUTO_IMPORT, true, false)
	settings.add_property_info({"name": SETTING_AUTO_IMPORT, "type": TYPE_BOOL})
	# Off until the person opts in: the dock asks once after the first connection.
	if not settings.has_setting(SETTING_SHARE_USAGE):
		settings.set_setting(SETTING_SHARE_USAGE, false)
	settings.set_initial_value(SETTING_SHARE_USAGE, false, false)
	settings.add_property_info({"name": SETTING_SHARE_USAGE, "type": TYPE_BOOL})


func _apply_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	controller.confirm_above_cu = float(settings.get_setting(SETTING_CONFIRM))
	controller.auto_import = bool(settings.get_setting(SETTING_AUTO_IMPORT))
	var share := bool(settings.get_setting(SETTING_SHARE_USAGE))
	if share != reporter.usage.enabled:
		reporter.set_sharing(share)
