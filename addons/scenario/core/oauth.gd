@tool
extends RefCounted
## Sign in with Scenario: OAuth 2.0 against Scenario's identity provider, as
## Godot's registered public application (a fixed client id, no secret).
##
## Browser: authorization code with PKCE S256. The code comes back to a
## one-shot listener on a free 127.0.0.1 port (loopback.gd): the provider
## matches loopback redirects without their port. Another device: the device
## authorization grant, for a browser that cannot reach this machine.
##
## The transport is the MCP client's: post(url, headers, body, timeout_s).
## Replies never go into messages or logs: they carry tokens.

const Errors := preload("res://addons/scenario/core/errors.gd")

const PRODUCTION_ISSUER := "https://clerk.scenario.com"
## Godot's application on the production identity provider (a public client:
## the id is not a secret).
const PRODUCTION_CLIENT_ID := "rafDBLBE2tDRLLZo"
## The fewest scopes the provider accepts: who the user is, and a refresh token.
const SCOPE := "openid offline_access"
const DEVICE_GRANT := "urn:ietf:params:oauth:grant-type:device_code"
const TIMEOUT_S := 30.0

var transport: Object
var issuer := PRODUCTION_ISSUER
var client_id := PRODUCTION_CLIENT_ID


func _init(p_transport: Object = null, p_issuer: String = PRODUCTION_ISSUER, p_client_id: String = PRODUCTION_CLIENT_ID) -> void:
	transport = p_transport
	issuer = p_issuer.rstrip("/")
	client_id = p_client_id


## Production, or the development instance named by both SCENARIO_OAUTH_ISSUER
## (HTTPS) and SCENARIO_OAUTH_CLIENT_ID. ok({"issuer", "client_id"})
static func selected_app() -> Dictionary:
	var env_issuer := OS.get_environment("SCENARIO_OAUTH_ISSUER").strip_edges().rstrip("/")
	var env_client := OS.get_environment("SCENARIO_OAUTH_CLIENT_ID").strip_edges()
	if env_issuer.is_empty() and env_client.is_empty():
		return Errors.ok({"issuer": PRODUCTION_ISSUER, "client_id": PRODUCTION_CLIENT_ID})
	if env_issuer.is_empty() or env_client.is_empty() or not env_issuer.begins_with("https://"):
		return Errors.fail(Errors.LOCAL, "Set SCENARIO_OAUTH_ISSUER (HTTPS) and SCENARIO_OAUTH_CLIENT_ID together, or neither.")
	return Errors.ok({"issuer": env_issuer, "client_id": env_client})


## {"verifier", "challenge"}: S256 PKCE.
static func pkce_pair() -> Dictionary:
	var verifier := base64url(Crypto.new().generate_random_bytes(48))
	return {"verifier": verifier, "challenge": base64url(verifier.sha256_buffer())}


static func random_state() -> String:
	return base64url(Crypto.new().generate_random_bytes(24))


static func base64url(bytes: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func redirect_uri(port: int) -> String:
	return "http://127.0.0.1:%d/callback" % port


func authorize_url(redirect: String, state: String, challenge: String) -> String:
	return issuer + "/oauth/authorize?" + _form({
		"response_type": "code", "client_id": client_id, "redirect_uri": redirect, "state": state,
		"code_challenge": challenge, "code_challenge_method": "S256", "scope": SCOPE,
	})


## ok({"access_token", "refresh_token", "expires_at"})
func exchange_code(code: String, redirect: String, verifier: String) -> Dictionary:
	var reply: Dictionary = await _post_form(issuer + "/oauth/token", {
		"grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
		"client_id": client_id, "code_verifier": verifier,
	})
	return _tokens(reply, "Sign-in")


## A refused refresh token fails with "session_ended": sign in again. A reply
## without a new refresh token keeps the old one.
func refresh(refresh_token: String) -> Dictionary:
	var reply: Dictionary = await _post_form(issuer + "/oauth/token", {
		"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": client_id,
	})
	var result := _tokens(reply, "Session refresh")
	if result["ok"] and str(result["value"]["refresh_token"]).is_empty():
		result["value"]["refresh_token"] = refresh_token
	return result


## ok({"device_code", "user_code", "verification_uri", "verification_uri_complete", "interval", "expires_at"})
func start_device() -> Dictionary:
	var reply: Dictionary = await _post_form(issuer + "/oauth/device_authorization", {"client_id": client_id, "scope": SCOPE})
	if not reply["ok"]:
		return reply
	var data: Dictionary = reply["value"]["data"]
	if reply["value"]["status"] != 200 or str(data.get("device_code", "")).is_empty() or str(data.get("user_code", "")).is_empty():
		var code := str(data.get("error", ""))
		if code in ["unauthorized_client", "unsupported_grant_type", "invalid_client"]:
			return Errors.fail(Errors.LOCAL, "Sign in on another device is not available yet. Sign in in this computer's browser, or use an API key.")
		return Errors.fail(Errors.PROTOCOL, "Sign in on another device could not start (HTTP %d, %s)." % [reply["value"]["status"], _oauth_error(data)])
	var uri := str(data.get("verification_uri", ""))
	var complete := str(data.get("verification_uri_complete", ""))
	if not uri.begins_with("https://") or not (complete.is_empty() or complete.begins_with("https://")):
		return Errors.fail(Errors.PROTOCOL, "Sign in on another device sent a link that is not HTTPS.")
	return Errors.ok({
		"device_code": str(data["device_code"]), "user_code": str(data["user_code"]),
		"verification_uri": uri, "verification_uri_complete": complete,
		"interval": maxf(1.0, float(data.get("interval", 5))),
		"expires_at": _now() + float(data.get("expires_in", 600)),
	})


## One poll of the device grant: ok(tokens), or a failure whose "pending" or
## "slow_down" says to ask again later.
func poll_device(device_code: String) -> Dictionary:
	var reply: Dictionary = await _post_form(issuer + "/oauth/token", {
		"grant_type": DEVICE_GRANT, "device_code": device_code, "client_id": client_id,
	})
	if not reply["ok"]:
		return reply
	var data: Dictionary = reply["value"]["data"]
	match str(data.get("error", "")):
		"authorization_pending":
			return Errors.fail(Errors.LOCAL, "Waiting for approval.", {"pending": true})
		"slow_down":
			return Errors.fail(Errors.LOCAL, "Waiting for approval.", {"pending": true, "slow_down": true})
		"access_denied":
			return Errors.fail(Errors.AUTH, "Sign-in was declined in the browser.")
		"expired_token":
			return Errors.fail(Errors.AUTH, "The sign-in code expired. Start again.")
	return _tokens(reply, "Sign in on another device")


## Best effort: offline, sign-out still forgets the token.
func revoke(token: String) -> bool:
	if token.is_empty():
		return false
	var reply: Dictionary = await _post_form(issuer + "/oauth/token/revoke", {
		"token": token, "token_type_hint": "refresh_token", "client_id": client_id,
	})
	return reply["ok"] and int(reply["value"]["status"]) in [200, 204]


# --- Internals ----------------------------------------------------------------

## ok({"status", "data"}); a transport failure fails.
func _post_form(url: String, fields: Dictionary) -> Dictionary:
	var headers := PackedStringArray(["Content-Type: application/x-www-form-urlencoded", "Accept: application/json"])
	var response: Dictionary = await transport.post(url, headers, _form(fields), TIMEOUT_S)
	var error := str(response.get("error", ""))
	if error == "timeout":
		return Errors.fail(Errors.TIMEOUT, "Scenario's sign-in service took too long to answer.")
	if not error.is_empty():
		return Errors.fail(Errors.TRANSPORT, "Could not reach Scenario's sign-in service. Check the connection and try again.")
	# JSON.new().parse(), not JSON.parse_string(): the revoke reply has an empty
	# body, and parse_string would log an engine error for it.
	var json := JSON.new()
	var parsed := json.parse(str(response.get("body", ""))) == OK and json.data is Dictionary
	return Errors.ok({"status": int(response.get("status", 0)), "data": json.data if parsed else {}})


func _tokens(reply: Dictionary, what: String) -> Dictionary:
	if not reply["ok"]:
		return reply
	var status: int = reply["value"]["status"]
	var data: Dictionary = reply["value"]["data"]
	if status != 200 or str(data.get("access_token", "")).is_empty():
		if status in [400, 401] and str(data.get("error", "")) in ["invalid_grant", "invalid_client", "unauthorized_client"]:
			return Errors.fail(Errors.AUTH, "%s was refused (%s). Sign in again." % [what, _oauth_error(data)], {"session_ended": true})
		return Errors.fail(Errors.PROTOCOL, "%s failed (HTTP %d, %s)." % [what, status, _oauth_error(data)])
	var expires_in := float(data.get("expires_in", 0))
	return Errors.ok({
		"access_token": str(data["access_token"]),
		"refresh_token": str(data.get("refresh_token", "")),
		"expires_at": _now() + expires_in if expires_in > 0.0 else 0.0,
	})


static func _oauth_error(data: Dictionary) -> String:
	var text := str(data.get("error_description", data.get("error", "unknown error")))
	return text.substr(0, 200)


static func _form(fields: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in fields:
		if not str(fields[key]).is_empty():
			parts.append("%s=%s" % [str(key).uri_encode(), str(fields[key]).uri_encode()])
	return "&".join(parts)


static func _now() -> float:
	return Time.get_unix_time_from_system()
