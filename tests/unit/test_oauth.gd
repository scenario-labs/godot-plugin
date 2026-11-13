extends GutTest

const OAuth := preload("res://addons/scenario/core/oauth.gd")
const OAuthSession := preload("res://addons/scenario/core/oauth_session.gd")
const Loopback := preload("res://addons/scenario/core/loopback.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")
const Fake := preload("res://tests/support/fake_transport.gd")

var fake: Fake
var oauth: OAuth


func before_each() -> void:
	fake = Fake.new()
	oauth = OAuth.new(fake, "https://idp.example.test/", "client_godot")
	OS.unset_environment("SCENARIO_OAUTH_ISSUER")
	OS.unset_environment("SCENARIO_OAUTH_CLIENT_ID")


func after_each() -> void:
	OS.unset_environment("SCENARIO_OAUTH_ISSUER")
	OS.unset_environment("SCENARIO_OAUTH_CLIENT_ID")


func _json(status: int, data: Dictionary) -> Dictionary:
	return {"http": status, "body": JSON.stringify(data)}


func _form(index: int) -> Dictionary:
	return Loopback.parse_query(fake.requests[index]["payload"]["form"])


func test_production_application_by_default() -> void:
	var app := OAuth.selected_app()
	assert_true(app["ok"])
	assert_eq(app["value"], {"issuer": "https://clerk.scenario.com", "client_id": "rafDBLBE2tDRLLZo"})


func test_development_application_needs_both_variables_and_https() -> void:
	OS.set_environment("SCENARIO_OAUTH_ISSUER", "https://dev.example.test/")
	assert_false(OAuth.selected_app()["ok"], "issuer alone")
	OS.set_environment("SCENARIO_OAUTH_CLIENT_ID", "dev_client")
	assert_eq(OAuth.selected_app()["value"], {"issuer": "https://dev.example.test", "client_id": "dev_client"})
	OS.set_environment("SCENARIO_OAUTH_ISSUER", "http://dev.example.test")
	assert_false(OAuth.selected_app()["ok"], "plain HTTP issuer")


func test_pkce_pair_is_s256_of_a_long_verifier() -> void:
	var pair := OAuth.pkce_pair()
	assert_eq(pair["verifier"].length(), 64)
	assert_eq(pair["challenge"], OAuth.base64url(pair["verifier"].sha256_buffer()))
	for text in [pair["verifier"], pair["challenge"], OAuth.random_state()]:
		assert_false(text.contains("+") or text.contains("/") or text.contains("="), text)
	assert_ne(OAuth.pkce_pair()["verifier"], pair["verifier"])


func test_authorize_url_has_pkce_state_and_no_resource() -> void:
	var url := oauth.authorize_url(OAuth.redirect_uri(51234), "st_1", "ch_1")
	assert_true(url.begins_with("https://idp.example.test/oauth/authorize?"), url)
	var query := Loopback.parse_query(url.get_slice("?", 1))
	assert_eq(query, {
		"response_type": "code", "client_id": "client_godot", "redirect_uri": "http://127.0.0.1:51234/callback",
		"state": "st_1", "code_challenge": "ch_1", "code_challenge_method": "S256", "scope": "openid offline_access",
	})


func test_exchange_code_posts_the_verifier() -> void:
	fake.replies.append(_json(200, {"access_token": "at", "refresh_token": "rt", "expires_in": 3600}))
	var result: Dictionary = await oauth.exchange_code("code_1", "http://127.0.0.1:5/callback", "ver_1")
	assert_true(result["ok"])
	assert_eq(result["value"]["access_token"], "at")
	assert_eq(result["value"]["refresh_token"], "rt")
	assert_almost_eq(float(result["value"]["expires_at"]), Time.get_unix_time_from_system() + 3600.0, 5.0)
	assert_eq(fake.requests[0]["url"], "https://idp.example.test/oauth/token")
	assert_eq(_form(0), {"grant_type": "authorization_code", "code": "code_1", "redirect_uri": "http://127.0.0.1:5/callback",
		"client_id": "client_godot", "code_verifier": "ver_1"})


func test_refused_refresh_ends_the_session() -> void:
	fake.replies.append(_json(400, {"error": "invalid_grant"}))
	var result: Dictionary = await oauth.refresh("rt_old")
	assert_false(result["ok"])
	assert_eq(result["error"]["kind"], Errors.AUTH)
	assert_true(result["error"]["session_ended"])


func test_refresh_without_rotation_keeps_the_token() -> void:
	fake.replies.append(_json(200, {"access_token": "at_2", "expires_in": 60}))
	var result: Dictionary = await oauth.refresh("rt_1")
	assert_eq(result["value"]["refresh_token"], "rt_1")
	assert_eq(_form(0)["grant_type"], "refresh_token")


func test_device_grant_start_and_polls() -> void:
	fake.replies.append(_json(200, {"device_code": "dc", "user_code": "ABCD-EFGH", "interval": 0, "expires_in": 600,
		"verification_uri": "https://idp.example.test/device", "verification_uri_complete": "https://idp.example.test/device?c=1"}))
	var started: Dictionary = await oauth.start_device()
	assert_true(started["ok"])
	assert_eq(started["value"]["user_code"], "ABCD-EFGH")
	assert_eq(started["value"]["interval"], 1.0, "at least a second between polls")
	assert_eq(_form(0), {"client_id": "client_godot", "scope": "openid offline_access"})
	fake.replies.append(_json(400, {"error": "authorization_pending"}))
	fake.replies.append(_json(400, {"error": "slow_down"}))
	fake.replies.append(_json(400, {"error": "access_denied"}))
	fake.replies.append(_json(400, {"error": "expired_token"}))
	fake.replies.append(_json(200, {"access_token": "at", "refresh_token": "rt"}))
	var pending: Dictionary = await oauth.poll_device("dc")
	assert_true(pending["error"]["pending"])
	var slow: Dictionary = await oauth.poll_device("dc")
	assert_true(slow["error"]["slow_down"])
	var denied: Dictionary = await oauth.poll_device("dc")
	assert_false(denied["error"].get("pending", false))
	assert_string_contains(denied["error"]["message"], "declined")
	var expired: Dictionary = await oauth.poll_device("dc")
	assert_string_contains(expired["error"]["message"], "expired")
	var done: Dictionary = await oauth.poll_device("dc")
	assert_true(done["ok"])
	assert_eq(_form(1)["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")


func test_device_grant_off_and_plain_http_link() -> void:
	fake.replies.append(_json(400, {"error": "unauthorized_client"}))
	var off: Dictionary = await oauth.start_device()
	assert_string_contains(off["error"]["message"], "not available yet")
	fake.replies.append(_json(200, {"device_code": "dc", "user_code": "X", "verification_uri": "http://idp.example.test/device"}))
	var http: Dictionary = await oauth.start_device()
	assert_false(http["ok"])


func test_revoke_is_best_effort() -> void:
	fake.replies.append({"http": 200, "body": ""})  # the provider answers with an empty body
	assert_true(await oauth.revoke("rt_1"))
	assert_eq(fake.requests[0]["url"], "https://idp.example.test/oauth/token/revoke")
	assert_eq(_form(0), {"token": "rt_1", "token_type_hint": "refresh_token", "client_id": "client_godot"})
	fake.replies.append({"error": "transport"})
	assert_false(await oauth.revoke("rt_1"))
	assert_false(await oauth.revoke(""))


func test_session_refreshes_an_expired_token_and_saves_the_rotation() -> void:
	var saved: Array = []
	var session := OAuthSession.new(oauth, {"access_token": "", "refresh_token": "rt_1", "expires_at": 0.0})
	session.on_rotate = func(token: String) -> void: saved.append(token)
	fake.replies.append(_json(200, {"access_token": "at_2", "refresh_token": "rt_2", "expires_in": 3600}))
	var header: Dictionary = await session.authorization()
	assert_eq(header["value"], "Bearer at_2")
	assert_eq(saved, ["rt_2"])
	assert_eq(session.refresh_token(), "rt_2")
	# Fresh enough: no second refresh.
	assert_eq((await session.authorization())["value"], "Bearer at_2")
	assert_eq(fake.requests.size(), 1)
	# A paid call asks for more time left than the token has: it refreshes first.
	session.tokens["expires_at"] = Time.get_unix_time_from_system() + 120.0
	fake.replies.append(_json(200, {"access_token": "at_3", "refresh_token": "rt_3", "expires_in": 3600}))
	assert_eq((await session.authorization(300.0))["value"], "Bearer at_3")


func test_session_refreshes_from_the_token_another_editor_saved() -> void:
	var session := OAuthSession.new(oauth, {"access_token": "", "refresh_token": "rt_1", "expires_at": 0.0})
	session.load_saved = func() -> String: return "rt_5"
	fake.replies.append(_json(200, {"access_token": "at_6", "refresh_token": "rt_6", "expires_in": 3600}))
	assert_true((await session.authorization())["ok"])
	assert_eq(_form(0)["refresh_token"], "rt_5", "an old token would revoke the whole session")
	assert_eq(session.refresh_token(), "rt_6")


func test_session_ends_when_the_refresh_token_is_refused() -> void:
	var session := OAuthSession.new(oauth, {"access_token": "", "refresh_token": "rt_1", "expires_at": 0.0})
	watch_signals(session)
	fake.replies.append(_json(400, {"error": "invalid_grant"}))
	var header: Dictionary = await session.authorization()
	assert_false(header["ok"])
	assert_signal_emitted(session, "ended")
	assert_eq(session.refresh_token(), "")


func test_session_workspace() -> void:
	var session := OAuthSession.new(oauth, {})
	assert_eq(session.workspace(), {})
	session.set_workspace({"id": "team_1", "name": "Studio"}, {"id": "proj_1", "name": "Game"})
	assert_eq(session.workspace(), {"team_id": "team_1", "project_id": "proj_1"})
	assert_eq(session.workspace_label(), "Studio / Game")
	session.set_workspace({"id": "team_1"}, {})
	assert_false(session.has_project())
	assert_eq(session.team_id, "", "no team without a project")


func test_loopback_takes_the_code_only_with_the_right_state() -> void:
	var receiver := Loopback.new()
	var port := receiver.start("state_ok")
	assert_gt(port, 0)
	var stray := await _fetch(receiver, port, "/favicon.ico")
	assert_string_contains(stray, "404")
	var forged := await _fetch(receiver, port, "/callback?code=evil&state=other")
	assert_string_contains(forged, "400")
	assert_false(receiver.done)
	var good := await _fetch(receiver, port, "/callback?code=code%2B1&state=state_ok")
	assert_string_contains(good, "Signed in to Scenario")
	assert_true(receiver.done)
	assert_eq(receiver.code, "code+1")
	receiver.stop()


func test_loopback_reports_a_declined_sign_in() -> void:
	var receiver := Loopback.new()
	var port := receiver.start("s")
	var page := await _fetch(receiver, port, "/callback?error=access_denied&error_description=The+user+said+%3Cno%3E&state=s")
	assert_string_contains(page, "&lt;no&gt;", "escaped in the page")
	assert_true(receiver.done)
	assert_eq(receiver.error, "The user said <no>")
	assert_eq(receiver.code, "")
	receiver.stop()


func test_same_text() -> void:
	assert_true(Loopback.same_text("abc", "abc"))
	assert_false(Loopback.same_text("abc", "abd"))
	assert_false(Loopback.same_text("ab", "abc"))
	assert_false(Loopback.same_text("", ""), "an empty expected state never matches")


## Sends one GET to the receiver, polling it like the controller does, and returns the raw reply.
func _fetch(receiver: Loopback, port: int, target: String) -> String:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	var sent := false
	var reply := PackedByteArray()
	for i in 300:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and not sent:
			peer.put_data(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" % target).to_utf8_buffer())
			sent = true
		receiver.poll()
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			reply.append_array(peer.get_data(peer.get_available_bytes())[1])
		if sent and peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().process_frame
	return reply.get_string_from_utf8()
