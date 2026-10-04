extends GutTest

const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Credentials := preload("res://addons/scenario/core/credentials.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")

var config_path := ""


func before_each() -> void:
	config_path = "user://test_credentials_%d/credentials.json" % randi()
	OS.unset_environment("SCENARIO_API_KEY")
	OS.unset_environment("SCENARIO_API_SECRET")


func after_each() -> void:
	if FileAccess.file_exists(config_path):
		DirAccess.remove_absolute(config_path)
	DirAccess.remove_absolute(config_path.get_base_dir())
	OS.unset_environment("SCENARIO_API_KEY")
	OS.unset_environment("SCENARIO_API_SECRET")


func test_every_lane_is_complete() -> void:
	for id in Lanes.ids():
		var lane := Lanes.lane(id)
		assert_false(lane["models"].is_empty(), id)
		assert_true(lane["importer"] in ["image", "model3d", "material", "skybox", "audio"], id)
		assert_true(str(Lanes.default_model(id)).begins_with("model_"), id)
	assert_eq(Lanes.lane("nope"), {})


func test_presets_are_copies() -> void:
	var preset := Lanes.presets("model_rodin-hyper3d-v2-5-text-to-3d")
	preset["material"] = "None"
	assert_eq(Lanes.presets("model_rodin-hyper3d-v2-5-text-to-3d")["material"], "PBR")


func _store() -> Credentials:
	var store := Credentials.new(config_path)
	store.use_keychain = false
	return store


func test_file_store_round_trip_and_permissions() -> void:
	var store := _store()
	var saved := store.save_credentials(" api_abc ", " sec_123 ")
	assert_true(saved["ok"])
	assert_eq(saved["store"], "file")
	var loaded := store.load_credentials()
	assert_eq(loaded, {"api_key": "api_abc", "api_secret": "sec_123", "source": "file"})
	if OS.get_name() != "Windows":
		var output: Array = []
		OS.execute("/usr/bin/stat", ["-f", "%Lp", ProjectSettings.globalize_path(config_path)], output)
		assert_eq(str(output[0]).strip_edges(), "600")


func test_environment_wins() -> void:
	var store := _store()
	store.save_credentials("api_file", "sec_file")
	OS.set_environment("SCENARIO_API_KEY", "api_env")
	OS.set_environment("SCENARIO_API_SECRET", "sec_env")
	assert_eq(store.load_credentials()["source"], "environment")
	assert_eq(store.load_credentials()["api_key"], "api_env")


func test_rejects_empty_or_spaced_values() -> void:
	var store := _store()
	assert_false(store.save_credentials("", "x")["ok"])
	assert_false(store.save_credentials("api x", "y")["ok"])


func test_clear_forgets_the_pair() -> void:
	var store := _store()
	store.save_credentials("api_abc", "sec_123")
	store.clear()
	assert_eq(store.load_credentials()["api_key"], "")


func test_error_classification() -> void:
	assert_eq(Errors.classify("Your request was flagged as sensitive content", 400), Errors.MODERATED)
	assert_eq(Errors.classify("Insufficient creative units", 400), Errors.QUOTA)
	assert_eq(Errors.classify("", 401), Errors.AUTH)
	assert_eq(Errors.classify("", 503), Errors.HTTP_5XX)
	assert_eq(Errors.classify("prompt is required", 422), Errors.INVALID)
	assert_eq(Errors.classify("something odd"), Errors.SCENARIO)
	assert_true(Errors.message_for(Errors.QUOTA, "need 80, have 12").contains("need 80"))
	assert_false(Errors.message_for(Errors.TRANSPORT, "socket").contains("socket"))
