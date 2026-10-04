extends "res://addons/agentkit/agent_job.gd"
## macOS only, touches the login Keychain with a dummy pair (no Scenario call):
## save puts the secret in the Keychain and only the key id in the settings
## file, load reads it back, clear (Disconnect) removes the Keychain item.
## Run: python3 -c "import sys; sys.path.insert(0, '<godot-expert>/scripts'); import gd_run;
##      print(gd_run.run_script('.', 'res://tests/live/keychain_check_job.gd')['result'])"

const Credentials := preload("res://addons/scenario/core/credentials.gd")

const KEY := "api_godotkeychaincheck"
const SECRET := "sec_dummy_not_a_real_secret_42"


func run() -> Dictionary:
	if OS.get_name() != "macOS":
		return {"ok": true, "skipped": "not macOS"}
	OS.unset_environment("SCENARIO_API_KEY")
	OS.unset_environment("SCENARIO_API_SECRET")
	var path := "user://keychain_check_%d/credentials.json" % Time.get_ticks_usec()
	var store := Credentials.new(path)
	var saved := store.save_credentials(KEY, SECRET)
	var file_text := FileAccess.get_file_as_string(path)
	var loaded := store.load_credentials()
	store.clear()
	var output: Array = []
	var still_there := OS.execute("/usr/bin/security", ["find-generic-password", "-s", Credentials.KEYCHAIN_SERVICE, "-a", KEY], output, true) == 0
	var after := store.load_credentials()
	var checks := {
		"saved_to_keychain": saved.get("store") == "keychain",
		"secret_not_in_file": not file_text.contains(SECRET) and file_text.contains(KEY),
		"read_back": loaded.get("source") == "keychain" and loaded.get("api_secret") == SECRET,
		"disconnect_removes_item": not still_there,
		"nothing_after_disconnect": str(after.get("api_key", "")).is_empty(),
	}
	return {"ok": checks.values().all(func(v: bool) -> bool: return v), "checks": checks}
