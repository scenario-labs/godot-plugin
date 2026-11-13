extends "res://addons/agentkit/agent_job.gd"
## Touches this machine's credential store (macOS Keychain, Windows Credential
## Manager, Linux Secret Service) with dummy secrets only, no Scenario call:
## save puts the secret in the store and only the key id in the settings file,
## load reads it back, a session's refresh token rotates in place, and clear
## (Disconnect, Sign out) removes the store items.
## Run: python3 -c "import sys; sys.path.insert(0, '<godot-expert>/scripts'); import gd_run;
##      print(gd_run.run_script('.', 'res://tests/live/keychain_check_job.gd')['result'])"

const Credentials := preload("res://addons/scenario/core/credentials.gd")

const KEY := "api_godotkeychaincheck"
const SECRET := "sec_dummy_not_a_real_secret_42"
const ISSUER := "https://idp.example.test"
const CLIENT := "client_storecheck"


func run() -> Dictionary:
	var kind := Credentials.detect_store()
	if kind.is_empty():
		return {"ok": true, "skipped": "no credential store on %s" % OS.get_name()}
	OS.unset_environment("SCENARIO_API_KEY")
	OS.unset_environment("SCENARIO_API_SECRET")
	var path := "res://tests/tmp_output/keychain-check-%d/credentials.json" % Time.get_ticks_usec()
	var store := Credentials.new(path)
	var started := Time.get_ticks_msec()
	var saved := store.save_credentials(KEY, SECRET)
	var file_text := FileAccess.get_file_as_string(path)
	var loaded := store.load_credentials()
	var session := store.save_session(ISSUER, CLIENT, "rt_dummy_1")
	var rotated := store.save_refresh_token(ISSUER, CLIENT, "rt_dummy_1", "rt_dummy_2")
	var session_text := FileAccess.get_file_as_string(path)
	var resumed := store.load_session(ISSUER, CLIENT)
	var key_left := store._store_read(kind, KEY)
	store.clear()
	var token_left := store._store_read(kind, "oauth:" + CLIENT)
	var after := store.load_credentials()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var checks := {
		"saved_to_store": saved.get("store") == kind,
		"secret_not_in_file": not file_text.contains(SECRET) and file_text.contains(KEY),
		"read_back": loaded.get("source") == kind and loaded.get("api_secret") == SECRET,
		"session_in_store": session.get("store") == kind and rotated and not session_text.contains("rt_dummy"),
		"rotation_read_back": resumed.get("refresh_token") == "rt_dummy_2" and resumed.get("source") == kind,
		"sign_in_removed_the_key": key_left.is_empty(),
		"clear_removes_the_session": token_left.is_empty(),
		"nothing_after_clear": str(after.get("api_key", "")).is_empty(),
	}
	return {"ok": checks.values().all(func(v: bool) -> bool: return v), "store": kind, "checks": checks,
		"elapsed_ms": Time.get_ticks_msec() - started}
