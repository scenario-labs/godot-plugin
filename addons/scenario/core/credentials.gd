@tool
extends RefCounted
## Where the sign-in lives: a signed-in session's refresh token and chosen
## team and project, or an API key and secret. Never in the project folder: a
## project is usually in git, and a committed secret leaks.
##
## Read order for a key: environment (SCENARIO_API_KEY / SCENARIO_API_SECRET),
## then the per-user config file. Secrets (the API secret, the refresh token)
## are in the system credential store: the macOS Keychain, Windows Credential
## Manager, or the Secret Service on Linux (secret-tool). Where none accepts
## them, they are in the file itself, with 0600 permissions outside Windows.
## A secret reaches the store's tool on stdin, never as an argument, and the
## config file records which store holds it. One way of signing in is kept at
## a time.

const KEYCHAIN_SERVICE := "Scenario Godot Plugin"
const SECURITY := "/usr/bin/security"
## Characters that survive security -i double-quoted tokens without escaping.
const _SAFE := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.=+/:@"
## The stores, as the config file records them.
const KEYCHAIN := "keychain"
const CREDENTIAL_MANAGER := "credential-manager"
const SECRET_SERVICE := "secret-service"
const FILE := "file"
## Credential Manager's limit for one secret.
const CREDENTIAL_MANAGER_MAX_BYTES := 2560
## A store tool that has not answered by then is stopped; the secret goes to the file.
const STORE_TIMEOUT_S := 10
## A Secret Service read waits this long: time to answer the keyring's unlock
## prompt at editor start, without hanging when nobody can.
const UNLOCK_TIMEOUT_S := 120
## Windows PowerShell 5.1 calls the Credential Manager API (advapi32). The
## script comes as -EncodedCommand; a secret comes on stdin and goes back as
## base64 on stdout. Generic credentials, target "<service>/<account>".
const _WINDOWS_API := """$ErrorActionPreference = 'Stop'
Add-Type -Namespace ScenarioGodot -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
	public int Flags; public int Type; public string TargetName; public string Comment;
	public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
	public int CredentialBlobSize; public IntPtr CredentialBlob; public int Persist;
	public int AttributeCount; public IntPtr Attributes; public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredWriteW(ref CREDENTIAL credential, int flags);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredReadW(string target, int type, int flags, out IntPtr credential);
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredDeleteW(string target, int type, int flags);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr credential);
'@
$target = {target}
$account = {account}
"""
const _WINDOWS_WRITE := """$stdin = [Console]::OpenStandardInput()
$buffer = New-Object IO.MemoryStream
$stdin.CopyTo($buffer)
$bytes = $buffer.ToArray()
$credential = New-Object ScenarioGodot.Cred+CREDENTIAL
$credential.Type = 1
$credential.TargetName = $target
$credential.UserName = $account
$credential.Persist = 2
$credential.CredentialBlobSize = $bytes.Length
$credential.CredentialBlob = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
[Runtime.InteropServices.Marshal]::Copy($bytes, 0, $credential.CredentialBlob, $bytes.Length)
$ok = [ScenarioGodot.Cred]::CredWriteW([ref]$credential, 0)
[Runtime.InteropServices.Marshal]::FreeHGlobal($credential.CredentialBlob)
if (-not $ok) { exit 1 }
"""
const _WINDOWS_READ := """$pointer = [IntPtr]::Zero
if (-not [ScenarioGodot.Cred]::CredReadW($target, 1, 0, [ref]$pointer)) { exit 2 }
$credential = [Runtime.InteropServices.Marshal]::PtrToStructure($pointer, [type][ScenarioGodot.Cred+CREDENTIAL])
$bytes = New-Object byte[] $credential.CredentialBlobSize
[Runtime.InteropServices.Marshal]::Copy($credential.CredentialBlob, $bytes, 0, $bytes.Length)
[ScenarioGodot.Cred]::CredFree($pointer)
[Console]::Out.Write([Convert]::ToBase64String($bytes))
"""
const _WINDOWS_DELETE := """if (-not [ScenarioGodot.Cred]::CredDeleteW($target, 1, 0)) { exit 2 }
"""

var config_path := ""
## Off in tests so no real credential store is touched.
var use_keychain := true
## The store this machine offers: KEYCHAIN, CREDENTIAL_MANAGER, SECRET_SERVICE or "".
var store := detect_store()


func _init(p_config_path: String = "") -> void:
	config_path = p_config_path


static func detect_store() -> String:
	match OS.get_name():
		"macOS":
			return KEYCHAIN if FileAccess.file_exists(SECURITY) else ""
		"Windows":
			return CREDENTIAL_MANAGER if FileAccess.file_exists(_powershell()) else ""
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			# secret-tool needs a session bus to reach the Secret Service: the
			# address in the environment, or the standard socket GLib also finds.
			if not _secret_tool().is_empty() and not _timeout_tool().is_empty() and _session_bus():
				return SECRET_SERVICE
	return ""


static func _session_bus() -> bool:
	if not OS.get_environment("DBUS_SESSION_BUS_ADDRESS").is_empty():
		return true
	var runtime := OS.get_environment("XDG_RUNTIME_DIR")
	# A socket, which FileAccess.file_exists (regular files only) does not see.
	return not runtime.is_empty() and FileAccess.file_exists("/usr/bin/test") \
		and OS.execute("/usr/bin/test", ["-S", runtime.path_join("bus")]) == 0


## {"api_key", "api_secret", "source": "environment" | a store | "file" | ""}
func load_credentials() -> Dictionary:
	var env_key := OS.get_environment("SCENARIO_API_KEY").strip_edges()
	var env_secret := OS.get_environment("SCENARIO_API_SECRET").strip_edges()
	if not env_key.is_empty() and not env_secret.is_empty():
		return {"api_key": env_key, "api_secret": env_secret, "source": "environment"}
	var data := _read_config()
	var key := str(data.get("api_key", ""))
	if key.is_empty():
		return {"api_key": "", "api_secret": "", "source": ""}
	var kept := str(data.get("secret_store", FILE))
	if kept != FILE:
		var secret := _store_read(kept, key)
		return {"api_key": key, "api_secret": secret, "source": kept if not secret.is_empty() else ""}
	return {"api_key": key, "api_secret": str(data.get("api_secret", "")), "source": FILE}


## Saves the pair. Returns {"ok": bool, "store": a store | "file", "message"}.
func save_credentials(key: String, secret: String) -> Dictionary:
	key = key.strip_edges()
	secret = secret.strip_edges()
	if key.is_empty() or secret.is_empty():
		return {"ok": false, "store": "", "message": "Enter both the API key and the secret."}
	if key.contains(" ") or secret.contains(" "):
		return {"ok": false, "store": "", "message": "The key and secret cannot contain spaces."}
	var previous := _saved_accounts()
	if _store_write(key, secret):
		var saved := _write_config({"api_key": key, "secret_store": store})
		if saved:
			_delete_accounts(previous, key)
		return {"ok": saved, "store": store, "message": "" if saved else "Could not save the settings file."}
	var ok := _write_config({"api_key": key, "secret_store": FILE, "api_secret": secret})
	if ok:
		_delete_accounts(previous)
	return {"ok": ok, "store": FILE, "message": "" if ok else "Could not save the settings file."}


## The saved session of this application: {"refresh_token", "source", "workspace"}.
## A session saved for another issuer or client id (a development instance)
## is not resumed: its tokens mean nothing to this one.
func load_session(issuer: String, client_id: String) -> Dictionary:
	var empty := {"refresh_token": "", "source": "", "workspace": {}}
	var oauth: Variant = _read_config().get("oauth")
	if not oauth is Dictionary or oauth.get("issuer") != issuer or oauth.get("client_id") != client_id:
		return empty
	var kept := str(oauth.get("secret_store", FILE))
	var token := str(oauth.get("refresh_token", "")) if kept == FILE else _store_read(kept, _session_account(client_id))
	if token.is_empty():
		return empty
	var workspace: Variant = _read_config().get("workspace")
	return {"refresh_token": token, "source": kept, "workspace": workspace if workspace is Dictionary else {}}


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
	var replaced := _saved_accounts()
	var account := _session_account(client_id)
	var oauth := {"issuer": issuer, "client_id": client_id, "secret_store": FILE}
	if _store_write(account, refresh_token):
		oauth["secret_store"] = store
	else:
		oauth["refresh_token"] = refresh_token
	var ok := _write_config({"oauth": oauth, "workspace": workspace})
	if ok:
		_delete_accounts(replaced, account if oauth["secret_store"] != FILE else "")
	return {"ok": ok, "store": oauth["secret_store"], "message": "" if ok else "Could not save the settings file."}


## Saves the refresh token the provider rotated from previous, where the
## session keeps it. Only over that same token of the same application: another
## editor may have signed in since (to another instance, or another account),
## and its session must not receive this one.
func save_refresh_token(issuer: String, client_id: String, previous: String, refresh_token: String) -> bool:
	var data := _read_config()
	var oauth: Variant = data.get("oauth")
	if not oauth is Dictionary or refresh_token.is_empty():
		return false
	var saved: String = load_session(issuer, client_id)["refresh_token"]
	# A system store that does not answer (a keyring prompt dismissed) reads as
	# "": the rotated token is kept rather than lost. Another editor's token
	# reads as itself, and a forgotten one leaves no store behind.
	var unreadable: bool = saved.is_empty() and oauth.get("issuer") == issuer and oauth.get("client_id") == client_id \
		and oauth.get("secret_store", FILE) != FILE
	if saved != previous and not unreadable:
		return false
	var account := _session_account(str(oauth.get("client_id", "")))
	var in_store: bool = oauth.get("secret_store", FILE) != FILE
	if in_store and _store_write(account, refresh_token):
		return true
	oauth["secret_store"] = FILE
	oauth["refresh_token"] = refresh_token
	data["oauth"] = oauth
	var ok := _write_config(data)
	if ok and in_store:
		_delete_accounts([account])
	return ok


## Forgets a refresh token the provider refused, so it is not resumed at the
## next start. The team and project stay for the next sign-in. A token saved
## since (by another editor) is kept.
func forget_session(refresh_token: String) -> void:
	var data := _read_config()
	var oauth: Variant = data.get("oauth")
	if not oauth is Dictionary or refresh_token.is_empty():
		return
	if load_session(str(oauth.get("issuer", "")), str(oauth.get("client_id", "")))["refresh_token"] != refresh_token:
		return
	var in_store: bool = oauth.get("secret_store", FILE) != FILE
	oauth.erase("refresh_token")
	oauth["secret_store"] = FILE
	data["oauth"] = oauth
	if _write_config(data) and in_store:
		_delete_accounts([_session_account(str(oauth.get("client_id", "")))])


## {"team_id", "team_name", "project_id", "project_name"}, kept with the session.
func save_workspace(workspace: Dictionary) -> bool:
	var data := _read_config()
	if not data.get("oauth") is Dictionary:
		return false
	data["workspace"] = workspace
	return _write_config(data)


func clear() -> void:
	var previous := _saved_accounts()
	if FileAccess.file_exists(config_path):
		_write_config({})
	_delete_accounts(previous)


## The store accounts the config file points to.
func _saved_accounts() -> PackedStringArray:
	var accounts := PackedStringArray()
	var data := _read_config()
	var key := str(data.get("api_key", ""))
	if data.get("secret_store", FILE) != FILE and not key.is_empty():
		accounts.append(key)
	var oauth: Variant = data.get("oauth")
	if oauth is Dictionary and oauth.get("secret_store", FILE) != FILE:
		accounts.append(_session_account(str(oauth.get("client_id", ""))))
	return accounts


## Removes these store items, except keep (the account just written). Called
## once the config file no longer points to them, so a failed save keeps them.
func _delete_accounts(accounts: PackedStringArray, keep: String = "") -> void:
	if not use_keychain:
		return
	for account in accounts:
		if account == keep:
			continue
		match store:
			KEYCHAIN:
				OS.execute(SECURITY, ["delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account], [], true)
			CREDENTIAL_MANAGER:
				OS.execute(_powershell(), windows_arguments(_WINDOWS_DELETE, account), [], true)
			SECRET_SERVICE:
				var command := _bounded(_secret_tool(), secret_tool_arguments("clear", account), STORE_TIMEOUT_S)
				OS.execute(command[0], command.slice(1), [], true)


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


## The secret kept for account in the store the config names ("" if none).
func _store_read(kept: String, account: String) -> String:
	if not use_keychain or kept != store:
		return ""
	var output: Array = []
	match store:
		KEYCHAIN:
			if OS.execute(SECURITY, ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"], output, true) != 0:
				return ""
			return str(output[0]).strip_edges() if not output.is_empty() else ""
		CREDENTIAL_MANAGER:
			if OS.execute(_powershell(), windows_arguments(_WINDOWS_READ, account), output) != 0 or output.is_empty():
				return ""
			return windows_secret(str(output[0]))
		SECRET_SERVICE:
			var command := _bounded(_secret_tool(), secret_tool_arguments("lookup", account), UNLOCK_TIMEOUT_S)
			if OS.execute(command[0], command.slice(1), output) != 0 or output.is_empty():
				return ""
			return str(output[0])
	return ""


## Puts the secret in this machine's store and reads it back. False means the
## file keeps it: no store, a store that refused or did not answer, or a
## secret the store cannot hold.
func _store_write(account: String, secret: String) -> bool:
	if not use_keychain or store.is_empty():
		return false
	var path := ""
	var arguments := PackedStringArray()
	var input := ""
	match store:
		KEYCHAIN:
			if not (_safe(account) and _safe(secret)):
				return false
			path = SECURITY
			arguments = PackedStringArray(["-i"])
			input = 'add-generic-password -U -s "%s" -a "%s" -w "%s"\n' % [KEYCHAIN_SERVICE, account, secret]
		CREDENTIAL_MANAGER:
			if secret.to_utf8_buffer().size() > CREDENTIAL_MANAGER_MAX_BYTES:
				return false
			path = _powershell()
			arguments = windows_arguments(_WINDOWS_WRITE, account)
			input = secret
		SECRET_SERVICE:
			path = _secret_tool()
			arguments = secret_tool_arguments("store", account)
			input = secret
	var info := OS.execute_with_pipe(path, arguments, false)
	if info.is_empty():
		return false
	var io: FileAccess = info["stdio"]
	io.store_string(input)
	io.flush()
	io.close()
	var pid: int = info["pid"]
	var waited := 0
	while OS.is_process_running(pid) and waited < STORE_TIMEOUT_S * 1000:
		OS.delay_msec(50)
		waited += 50
	if OS.is_process_running(pid):
		OS.kill(pid)  # a locked store waiting for a prompt nobody answers
		return false
	return _store_read(store, account) == secret


## powershell.exe arguments running one Credential Manager script for account.
static func windows_arguments(script: String, account: String) -> PackedStringArray:
	var head := _WINDOWS_API.replace("{target}", _ps_text("%s/%s" % [KEYCHAIN_SERVICE, account])).replace("{account}", _ps_text(account))
	return PackedStringArray(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand",
		Marshalls.raw_to_base64((head + script).to_utf16_buffer())])


## The secret from the read script's base64 output.
static func windows_secret(output: String) -> String:
	var text := output.strip_edges()
	return "" if text.is_empty() else Marshalls.base64_to_raw(text).get_string_from_utf8()


## secret-tool arguments: store (secret on stdin), lookup or clear.
static func secret_tool_arguments(action: String, account: String) -> PackedStringArray:
	var arguments := PackedStringArray([action])
	if action == "store":
		arguments.append("--label=" + KEYCHAIN_SERVICE)
	arguments.append_array(["service", KEYCHAIN_SERVICE, "account", account])
	return arguments


## A PowerShell expression for text, which comes from the user (an API key):
## base64 inside the quotes, so no character of it can end the string.
## (Doubling ' is not enough: PowerShell also closes a string on smart quotes.)
static func _ps_text(text: String) -> String:
	return "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))" % Marshalls.raw_to_base64(text.to_utf8_buffer())


static func _powershell() -> String:
	var root := OS.get_environment("SystemRoot")
	return (root if not root.is_empty() else "C:\\Windows") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"


static func _secret_tool() -> String:
	return _first_existing(["/usr/bin/secret-tool", "/usr/local/bin/secret-tool", "/bin/secret-tool"])


## timeout(1), which bounds every secret-tool call: without it the Secret
## Service is not used, since a locked keyring could hold the editor forever.
static func _timeout_tool() -> String:
	return _first_existing(["/usr/bin/timeout", "/bin/timeout", "/usr/local/bin/timeout"])


static func _first_existing(paths: Array) -> String:
	for path in paths:
		if FileAccess.file_exists(path):
			return path
	return ""


## [timeout, seconds, path, arguments...]: a locked keyring can wait for a
## prompt nobody answers.
static func _bounded(path: String, arguments: PackedStringArray, seconds: int) -> PackedStringArray:
	var command := PackedStringArray([_timeout_tool(), str(seconds), path])
	command.append_array(arguments)
	return command


static func _safe(text: String) -> bool:
	for c in text:
		if not _SAFE.contains(c):
			return false
	return true
