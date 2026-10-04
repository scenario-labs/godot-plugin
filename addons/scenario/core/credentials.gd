@tool
extends RefCounted
## Where the Scenario API key and secret live. Never in the project folder:
## a project is usually in git, and a committed secret leaks.
##
## Read order: environment (SCENARIO_API_KEY / SCENARIO_API_SECRET), then the
## per-user config file, whose secret is either in the macOS Keychain or, where
## no Keychain is available, in the file itself with 0600 permissions.
## The secret is sent to /usr/bin/security on stdin, never as an argument.

const KEYCHAIN_SERVICE := "Scenario Godot Plugin"
const SECURITY := "/usr/bin/security"
## Characters that survive security -i double-quoted tokens without escaping.
const _SAFE := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.=+/:@"

var config_path := ""
## Off in tests so the real Keychain is never touched.
var use_keychain := OS.get_name() == "macOS" and FileAccess.file_exists(SECURITY)


func _init(p_config_path: String = "") -> void:
	config_path = p_config_path


## {"api_key", "api_secret", "source": "environment" | "keychain" | "file" | ""}
func load_credentials() -> Dictionary:
	var env_key := OS.get_environment("SCENARIO_API_KEY").strip_edges()
	var env_secret := OS.get_environment("SCENARIO_API_SECRET").strip_edges()
	if not env_key.is_empty() and not env_secret.is_empty():
		return {"api_key": env_key, "api_secret": env_secret, "source": "environment"}
	var data := _read_config()
	var key := str(data.get("api_key", ""))
	if key.is_empty():
		return {"api_key": "", "api_secret": "", "source": ""}
	if data.get("secret_store") == "keychain":
		var secret := _keychain_read(key)
		return {"api_key": key, "api_secret": secret, "source": "keychain" if not secret.is_empty() else ""}
	return {"api_key": key, "api_secret": str(data.get("api_secret", "")), "source": "file"}


## Saves the pair. Returns {"ok": bool, "store": "keychain" | "file", "message"}.
func save_credentials(key: String, secret: String) -> Dictionary:
	key = key.strip_edges()
	secret = secret.strip_edges()
	if key.is_empty() or secret.is_empty():
		return {"ok": false, "store": "", "message": "Enter both the API key and the secret."}
	if key.contains(" ") or secret.contains(" "):
		return {"ok": false, "store": "", "message": "The key and secret cannot contain spaces."}
	if use_keychain and _safe(key) and _safe(secret) and _keychain_write(key, secret):
		var saved := _write_config({"api_key": key, "secret_store": "keychain"})
		return {"ok": saved, "store": "keychain", "message": "" if saved else "Could not save the settings file."}
	var ok := _write_config({"api_key": key, "secret_store": "file", "api_secret": secret})
	return {"ok": ok, "store": "file", "message": "" if ok else "Could not save the settings file."}


func clear() -> void:
	var data := _read_config()
	var key := str(data.get("api_key", ""))
	if data.get("secret_store") == "keychain" and not key.is_empty() and use_keychain:
		OS.execute(SECURITY, ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", key], [], true)
	if FileAccess.file_exists(config_path):
		_write_config({})


func _read_config() -> Dictionary:
	if config_path.is_empty() or not FileAccess.file_exists(config_path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(config_path)) != OK or not json.data is Dictionary:
		return {}
	return json.data


func _write_config(data: Dictionary) -> bool:
	if config_path.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(config_path.get_base_dir())
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	if OS.get_name() != "Windows":
		OS.execute("/bin/chmod", ["600", ProjectSettings.globalize_path(config_path)], [], true)
	return true


func _keychain_read(account: String) -> String:
	if not use_keychain:
		return ""
	var output: Array = []
	var code := OS.execute(SECURITY, ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"], output, true)
	if code != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


func _keychain_write(account: String, secret: String) -> bool:
	var info := OS.execute_with_pipe(SECURITY, ["-i"], false)
	if info.is_empty():
		return false
	var io: FileAccess = info["stdio"]
	io.store_string('add-generic-password -U -s "%s" -a "%s" -w "%s"\n' % [KEYCHAIN_SERVICE, account, secret])
	io.flush()
	io.close()
	var pid: int = info["pid"]
	var waited := 0
	while OS.is_process_running(pid) and waited < 50:
		OS.delay_msec(100)
		waited += 1
	return _keychain_read(account) == secret


static func _safe(text: String) -> bool:
	for c in text:
		if not _SAFE.contains(c):
			return false
	return true
