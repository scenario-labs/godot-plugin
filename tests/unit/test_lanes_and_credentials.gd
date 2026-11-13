extends GutTest

const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Credentials := preload("res://addons/scenario/core/credentials.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")

var config_path := ""


func before_each() -> void:
	config_path = "res://tests/tmp_output/credentials-%d/credentials.json" % randi()
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


func test_lanes_accept_only_files_they_can_place() -> void:
	assert_true(Lanes.accepts("image", "png"))
	assert_false(Lanes.accepts("image", "glb"))
	assert_true(Lanes.accepts("image", "exr"), "HDR textures load as Texture2D")
	assert_true(Lanes.accepts("model3d", "glb"))
	assert_true(Lanes.accepts("model3d", "png"), "3D previews")
	assert_true(Lanes.accepts("skybox", "hdr"))
	assert_true(Lanes.accepts("sound", "mp3"))
	assert_false(Lanes.accepts("sound", "png"))
	assert_false(Lanes.accepts("nope", "png"))
	for id in Lanes.ids():
		assert_true(Lanes.ACCEPTS.has(Lanes.lane(id)["importer"]), id)


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
		# The permission bits (0777 mask): only the owner reads and writes the file.
		var mode := FileAccess.get_unix_permissions(ProjectSettings.globalize_path(config_path)) & 0x1FF
		assert_eq(mode, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


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


const ISSUER := "https://idp.example.test"


func test_session_round_trip_in_the_file_store() -> void:
	var store := _store()
	store.save_credentials("api_abc", "sec_123")
	var saved := store.save_session(ISSUER, "client_godot", "rt_1")
	assert_true(saved["ok"])
	assert_eq(saved["store"], "file")
	assert_eq(store.load_credentials()["api_key"], "", "one way of signing in at a time")
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "rt_1")
	assert_true(store.save_refresh_token(ISSUER, "client_godot", "rt_1", "rt_2"))
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "rt_2")
	assert_false(store.save_refresh_token(ISSUER, "client_godot", "rt_1", "rt_9"), "the saved token moved on: another editor's")
	assert_false(store.save_refresh_token(ISSUER, "client_dev", "rt_2", "rt_9"), "another application's session")
	assert_false(store.save_refresh_token("https://dev.example.test", "client_godot", "rt_2", "rt_9"), "another issuer's session")
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "rt_2")
	if OS.get_name() != "Windows":
		var mode := FileAccess.get_unix_permissions(ProjectSettings.globalize_path(config_path)) & 0x1FF
		assert_eq(mode, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)


func test_session_of_another_application_is_not_resumed() -> void:
	var store := _store()
	store.save_session(ISSUER, "client_godot", "rt_1")
	assert_eq(store.load_session(ISSUER, "client_other")["refresh_token"], "")
	assert_eq(store.load_session("https://other.example.test", "client_godot")["refresh_token"], "")


func test_workspace_stays_with_the_same_application_only() -> void:
	var store := _store()
	store.save_session(ISSUER, "client_godot", "rt_1")
	var workspace := {"team_id": "team_a", "team_name": "A", "project_id": "proj_a1", "project_name": "Game"}
	assert_true(store.save_workspace(workspace))
	store.save_session(ISSUER, "client_godot", "rt_2")
	assert_eq(store.load_session(ISSUER, "client_godot")["workspace"], workspace, "signing in again keeps the project")
	store.save_session(ISSUER, "client_dev", "rt_3")
	assert_eq(store.load_session(ISSUER, "client_dev")["workspace"], {}, "another application's ids mean nothing here")


func test_a_refused_token_is_forgotten_but_not_a_newer_one() -> void:
	var store := _store()
	store.save_session(ISSUER, "client_godot", "rt_1")
	var workspace := {"team_id": "team_a", "team_name": "A", "project_id": "proj_a1", "project_name": "Game"}
	store.save_workspace(workspace)
	store.forget_session("rt_0")
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "rt_1", "a token saved since stays")
	store.forget_session("rt_1")
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "")
	store.save_session(ISSUER, "client_godot", "rt_2")
	assert_eq(store.load_session(ISSUER, "client_godot")["workspace"], workspace, "the project stays for the next sign-in")


func test_api_key_replaces_the_session_and_clear_forgets_all() -> void:
	var store := _store()
	store.save_session(ISSUER, "client_godot", "rt_1")
	store.save_credentials("api_abc", "sec_123")
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "")
	assert_false(store.save_workspace({"project_id": "p"}), "no project without a session")
	store.save_session(ISSUER, "client_godot", "rt_1")
	store.clear()
	assert_eq(store.load_session(ISSUER, "client_godot")["refresh_token"], "")
	assert_false(store.save_session(ISSUER, "client_godot", "")["ok"], "a session needs a refresh token")


func test_system_store_per_platform() -> void:
	var expected := {"macOS": Credentials.KEYCHAIN, "Windows": Credentials.CREDENTIAL_MANAGER}
	if OS.get_name() in expected:
		assert_eq(Credentials.detect_store(), expected[OS.get_name()])
	else:
		assert_true(Credentials.detect_store() in [Credentials.SECRET_SERVICE, ""])


func test_secret_tool_never_gets_the_secret_as_an_argument() -> void:
	assert_eq(Credentials.secret_tool_arguments("store", "oauth:client_godot"), PackedStringArray([
		"store", "--label=Scenario Godot Plugin", "service", "Scenario Godot Plugin", "account", "oauth:client_godot"]))
	assert_eq(Credentials.secret_tool_arguments("lookup", "api_abc"), PackedStringArray([
		"lookup", "service", "Scenario Godot Plugin", "account", "api_abc"]))
	assert_eq(Credentials.secret_tool_arguments("clear", "api_abc")[0], "clear")
	var bounded := Credentials._bounded("/usr/bin/secret-tool", PackedStringArray(["lookup"]), Credentials.UNLOCK_TIMEOUT_S)
	assert_eq(bounded, PackedStringArray([Credentials._timeout_tool(), "120", "/usr/bin/secret-tool", "lookup"]), "time to answer the unlock prompt")
	if Credentials._timeout_tool().is_empty():
		assert_ne(Credentials.detect_store(), Credentials.SECRET_SERVICE, "never an unbounded secret-tool call")


func test_credential_manager_script_names_the_target_and_reads_base64() -> void:
	var key := "api_x\u2019); Remove-Item C:\\ -Recurse; ('"  # a pasted key with a smart quote
	var arguments := Credentials.windows_arguments(Credentials._WINDOWS_WRITE, key)
	assert_eq(arguments[arguments.size() - 2], "-EncodedCommand")
	var script := Marshalls.base64_to_raw(arguments[arguments.size() - 1]).get_string_from_utf16()
	assert_false(script.contains("Remove-Item"), "the key reaches the script only as base64")
	assert_string_contains(script, "FromBase64String('%s')" % Marshalls.raw_to_base64(("Scenario Godot Plugin/" + key).to_utf8_buffer()))
	assert_string_contains(script, "CredWriteW")
	assert_string_contains(script, "OpenStandardInput", "the secret comes on stdin")
	assert_eq(Credentials.windows_secret(Marshalls.raw_to_base64("sec_é1".to_utf8_buffer()) + "\r\n"), "sec_é1")
	assert_eq(Credentials.windows_secret(""), "")


func test_a_store_this_machine_does_not_offer_is_not_read() -> void:
	var store := _store()
	store.save_credentials("api_abc", "sec_123")
	var data := JSON.parse_string(FileAccess.get_file_as_string(config_path)) as Dictionary
	data["secret_store"] = "some-other-store"
	data.erase("api_secret")
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()
	assert_eq(store.load_credentials()["source"], "", "nothing to read: the dock asks to sign in again")


func test_signed_in_messages() -> void:
	assert_string_contains(Errors.message_for(Errors.AUTH, "", true), "Sign in again")
	assert_string_contains(Errors.message_for(Errors.AUTH), "API key")
	assert_string_contains(Errors.message_for(Errors.QUOTA, "", true), "Creative Units")
