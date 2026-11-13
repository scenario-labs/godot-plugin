@tool
extends RefCounted
## Where the sign-in lives: a signed-in session's refresh token and chosen
## team and project, or an API key and secret. Never in the project folder: a
## project is usually in git, and a committed secret leaks.
##
## Read order for a key: environment (SCENARIO_API_KEY / SCENARIO_API_SECRET),
## then the per-user config file. Secrets (the API secret, the refresh token)
## are in the macOS Keychain or, where no Keychain is available, in the file
## itself with 0600 permissions. A secret is sent to /usr/bin/security on
## stdin, never as an argument. One way of signing in is kept at a time.

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
	_forget_secrets()
	if use_keychain and _safe(key) and _safe(secret) and _keychain_write(key, secret):
		var saved := _write_config({"api_key": key, "secret_store": "keychain"})
		return {"ok": saved, "store": "keychain", "message": "" if saved else "Could not save the settings file."}
	var ok := _write_config({"api_key": key, "secret_store": "file", "api_secret": secret})
	return {"ok": ok, "store": "file", "message": "" if ok else "Could not save the settings file."}


## The saved session of this application: {"refresh_token", "source", "workspace"}.
## A session saved for another issuer or client id (a development instance)
## is not resumed: its tokens mean nothing to this one.
func load_session(issuer: String, client_id: String) -> Dictionary:
	var empty := {"refresh_token": "", "source": "", "workspace": {}}
	var oauth: Variant = _read_config().get("oauth")
	if not oauth is Dictionary or oauth.get("issuer") != issuer or oauth.get("client_id") != client_id:
		return empty
	var token := ""
	if oauth.get("secret_store") == "keychain":
		token = _keychain_read(_session_account(client_id))
	else:
		token = str(oauth.get("refresh_token", ""))
	if token.is_empty():
		return empty
	var workspace: Variant = _read_config().get("workspace")
	return {"refresh_token": token, "source": str(oauth.get("secret_store", "file")), "workspace": workspace if workspace is Dictionary else {}}


## Saves a new session in place of any key or earlier session. The chosen team
## and project are kept when the session comes from the same application.
## {"ok", "store", "message"}
func save_session(issuer: String, client_id: String, refresh_token: String) -> Dictionary:
	if refresh_token.is_empty():
		return {"ok": false, "store": "", "message": "Scenario returned no refresh token, so the sign-in would not last."}
	var data := _read_config()
	var previous: Variant = data.get("oauth")
	var workspace: Variant = data.get("workspace", {})
	if not previous is Dictionary or previous.get("issuer") != issuer or previous.get("client_id") != client_id:
		workspace = {}
	_forget_secrets()
	var oauth := {"issuer": issuer, "client_id": client_id, "secret_store": "file"}
	if use_keychain and _safe(refresh_token) and _keychain_write(_session_account(client_id), refresh_token):
		oauth["secret_store"] = "keychain"
	else:
		oauth["refresh_token"] = refresh_token
	var ok := _write_config({"oauth": oauth, "workspace": workspace})
	return {"ok": ok, "store": oauth["secret_store"], "message": "" if ok else "Could not save the settings file."}


## Saves the refresh token the provider rotated, where the session keeps it.
func save_refresh_token(refresh_token: String) -> bool:
	var data := _read_config()
	var oauth: Variant = data.get("oauth")
	if not oauth is Dictionary or refresh_token.is_empty():
		return false
	var account := _session_account(str(oauth.get("client_id", "")))
	if oauth.get("secret_store") == "keychain" and _safe(refresh_token) and _keychain_write(account, refresh_token):
		return true
	if oauth.get("secret_store") == "keychain" and use_keychain:
		OS.execute(SECURITY, ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], [], true)
	oauth["secret_store"] = "file"
	oauth["refresh_token"] = refresh_token
	data["oauth"] = oauth
	return _write_config(data)


## {"team_id", "team_name", "project_id", "project_name"}, kept with the session.
func save_workspace(workspace: Dictionary) -> bool:
	var data := _read_config()
	if not data.get("oauth") is Dictionary:
		return false
	data["workspace"] = workspace
	return _write_config(data)


func clear() -> void:
	_forget_secrets()
	if FileAccess.file_exists(config_path):
		_write_config({})


## Removes the secrets the config file points to from the Keychain.
func _forget_secrets() -> void:
	if not use_keychain:
		return
	var data := _read_config()
	var key := str(data.get("api_key", ""))
	if data.get("secret_store") == "keychain" and not key.is_empty():
		OS.execute(SECURITY, ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", key], [], true)
	var oauth: Variant = data.get("oauth")
	if oauth is Dictionary and oauth.get("secret_store") == "keychain":
		OS.execute(SECURITY, ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", _session_account(str(oauth.get("client_id", "")))], [], true)


static func _session_account(client_id: String) -> String:
	return "oauth:" + client_id


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
