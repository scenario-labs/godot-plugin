extends "res://addons/agentkit/agent_job.gd"
## Headless editor test of Sign in with Scenario, against the fake backend.
##
## Browser sign-in through the real loopback listener, the team and project
## picker in the dock, a generation that carries the chosen project, a job read
## back in its own project after a switch, a restart that resumes the session,
## a saved project that is gone, the only project taken without asking, sign
## out with revocation, a session the provider ends, and the device grant.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Loopback := preload("res://addons/scenario/core/loopback.gd")
const OAuth := preload("res://addons/scenario/core/oauth.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")

var failures: Array = []
var checks := 0
var run_dir := ""
var opened: Array = []


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func run() -> Dictionary:
	await wait_frames(3)
	run_dir = "res://tests/tmp_output/sign-in-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var fake := Fake.new()
	root.add_child(fake)  # outlives the controllers, which restart around it
	var controller := _controller(fake)
	var ui := DockUI.new()
	root.add_child(ui)
	ui.bind(controller)
	check("signed out: the dock shows sign-in", ui._connect_box.visible and not ui._main_box.visible and ui._sign_in_box.visible)

	# Browser sign-in: the redirect comes back to the loopback listener.
	controller.sign_in_browser()
	await _until(func() -> bool: return not opened.is_empty())
	var query := Loopback.parse_query(str(opened[0]).get_slice("?", 1))
	check("authorize URL: production app, PKCE, no resource", str(opened[0]).begins_with(OAuth.PRODUCTION_ISSUER + "/oauth/authorize?")
		and query.get("client_id") == OAuth.PRODUCTION_CLIENT_ID and query.get("code_challenge_method") == "S256"
		and not query.has("resource") and query.get("scope") == "openid offline_access")
	await wait_frames(1)
	check("dock waits for the browser", ui._waiting_box.visible and not ui._sign_in_box.visible)
	var page := await _redirect(str(query["redirect_uri"]), "code=code_ok&state=" + str(query["state"]).uri_encode())
	check("browser page says signed in", page.contains("Signed in to Scenario"))
	await _until(func() -> bool: return controller.is_signed_in() and not controller.teams_loading)
	var exchange: Dictionary = fake.oauth_requests[0]["form"]
	check("code exchanged with its verifier and redirect", exchange.get("grant_type") == "authorization_code"
		and exchange.get("redirect_uri") == query["redirect_uri"] and str(exchange.get("code_verifier", "")).length() == 64)
	check("refresh token saved outside the project", controller.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["refresh_token"] == "rt_1")
	check("teams read without a project", fake.calls[0]["tool"] == "teams_list" and fake.calls[0]["arguments"] == {} and fake.calls[0]["authorization"] == "Bearer at_1")
	await wait_frames(1)
	check("several projects: the picker opens", controller.picking and ui._picker_box.visible and not ui._main_box.visible)
	check("picker lists the first team's projects", ui._team_option.item_count == 2 and ui._project_option.item_count == 2)
	check("nothing priced before a project is chosen", fake.estimates == 0)

	# Choosing a project from the dock.
	ui._team_option.select(0)
	ui._project_option.select(1)
	ui._project_option.item_selected.emit(1)
	controller.changed.emit()  # polling and price checks refresh the dock while the picker is open
	check("a refresh keeps the project picked", ui._project_option.selected == 1)
	ui._use_project_button.pressed.emit()
	await wait_frames(1)
	check("project chosen", controller.client.session.project_id == "proj_a2" and not controller.picking and ui._main_box.visible)
	check("footer shows team and project", ui._account_label.text == "Team A / Game B")

	# A generation goes to the chosen project, and so does its price check.
	await _until(func() -> bool: return not controller.fields.is_empty())
	controller.set_value("prompt", "a chest")
	await controller.estimate_now()
	var priced: Dictionary = _last_call(fake, "model_run")
	check("price check carries the project", priced.get("arguments", {}).get("project_id") == "proj_a2" and priced["arguments"].get("team_id") == "team_a")
	var sent: Dictionary = await controller.generate(true)
	check("one paid call, to the chosen project", fake.paid_calls.size() == 1 and fake.paid_calls[0].get("project_id") == "proj_a2")
	var row := controller.ledger.find(sent.get("local_id", ""))
	check("ledger row keeps the project", row.get("project_id") == "proj_a2" and row.get("team_id") == "team_a")

	# Another project: the quote does not follow, and the job is read where it ran.
	controller.set_value("prompt", "a second chest")
	await controller.estimate_now()
	var reference := ""
	for field in controller.fields:
		if field["type"] in ["file", "files"]:
			reference = field["name"]
	controller.values[reference] = ["asset_in_a2"]
	await controller.open_picker()
	check("picker reopens with a Cancel", controller.picking and ui._picker_cancel_button.visible)
	controller.choose_project("team_b", "proj_b1")
	check("quotes are dropped on a switch", controller.quotes.usable(controller.fingerprint(), Time.get_unix_time_from_system()).is_empty())
	check("references of the earlier project are dropped", not reference.is_empty() and not controller.values.has(reference))
	await controller.poll()
	check("job read back in its own project", _last_call(fake, "job_get").get("arguments", {}).get("project_id") == "proj_a2")
	var imported: Dictionary = await controller.import_job(row.get("local_id", ""))
	check("import reads assets in the job's project", imported.get("ok", false) and _last_call(fake, "asset_download").get("arguments", {}).get("project_id") == "proj_a2")

	# An unknown send is looked for in the project it went to, not the current one.
	var now := Time.get_unix_time_from_system()
	var lost := controller.ledger.add_intent("image", controller.model_id, controller.payload(), "fp_lost", 1.0, now, "lost", {"team_id": "team_a", "project_id": "proj_a2"})
	controller.ledger.mark_unknown(lost, "dropped", now)
	fake.listed["proj_a2"] = [{"jobId": "job_lost", "modelId": controller.model_id, "status": "queued",
		"createdAt": Time.get_datetime_string_from_unix_time(int(now) + 1) + "Z"}]
	await controller.check_unresolved()
	check("unknown send reconciled in its own project", _last_call(fake, "jobs_list").get("arguments", {}).get("project_id") == "proj_a2"
		and controller.ledger.find(lost).get("job_id") == "job_lost")
	# An unknown send made with an API key (no project) blocks the same request signed in.
	var keyed := controller.ledger.add_intent("image", controller.model_id, controller.payload(), "fp_key", 1.0, now, "key", {})
	controller.ledger.mark_unknown(keyed, "dropped", now)
	check("an API-key unknown send blocks the same request", controller._blocked())
	controller.dismiss(keyed)
	check("dismissed: no longer blocked", not controller._blocked())
	ui.queue_free()
	controller.queue_free()

	# A restart resumes the session and keeps the project, with a refresh.
	var resumed := _controller(fake)
	await _until(func() -> bool: return not resumed.teams_loading and resumed.is_connected_account())
	check("restart: signed in to the same project", resumed.is_oauth() and resumed.client.session.project_id == "proj_b1" and not resumed.picking)
	check("restart: the token was refreshed", fake.oauth_requests.back()["form"].get("grant_type") == "refresh_token")
	var headless := Controller.new()
	root.add_child(headless)
	headless.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json", false)
	check("a headless editor does not resume the saved sign-in", not headless.is_signed_in())
	headless.queue_free()
	check("restart: the rotated token was saved", resumed.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["refresh_token"] == fake.refresh_token)
	resumed.queue_free()

	# The saved project is gone: forgotten, and the picker comes back.
	fake.teams = [fake.teams[0]]
	var stale := _controller(fake)
	await _until(func() -> bool: return stale.is_signed_in() and not stale.teams_loading and stale.picking)
	check("stale project: forgotten and picker shown", stale.picking and not stale.client.session.has_project())
	check("stale project: the saved one is cleared too", stale.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["workspace"].get("project_id") == "")
	stale.queue_free()

	# One project in the account: taken without asking.
	fake.teams = [{"id": "team_solo", "name": "Solo", "projects": [{"id": "proj_solo", "name": "Only"}]}]
	var solo := _controller(fake)
	await _until(func() -> bool: return solo.is_connected_account())
	check("only project taken", solo.client.session.project_id == "proj_solo" and not solo.picking)

	# Sign out forgets everything locally and revokes the refresh token.
	var token := solo.client.session.refresh_token()
	await solo.sign_out()
	check("sign out: revoked", token in fake.revoked)
	check("sign out: nothing saved", solo.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["refresh_token"] == "" and not solo.is_signed_in())

	# Device grant: a code to enter elsewhere, then the same picker path.
	fake.device_pending = 1
	solo.sign_in_device()
	await _until(func() -> bool: return not str(solo.sign_in.get("user_code", "")).is_empty())
	var device_ui := DockUI.new()
	root.add_child(device_ui)
	device_ui.bind(solo)
	check("device: code shown in the dock", device_ui._code_edit.visible and device_ui._code_edit.text == "WDJB-MJHT")
	opened.clear()
	solo.open_device_page()
	check("device: page opens with the code", opened == ["https://accounts.example.test/device?user_code=WDJB-MJHT"])
	await _until(func() -> bool: return solo.is_connected_account(), 10.0)
	check("device: signed in after one pending poll", solo.is_connected_account() and fake.device_pending == 0)

	# The provider ends the session: back to sign-in, with a notice.
	var notices: Array = []
	solo.notified.connect(func(text: String, _level: String) -> void: notices.append(text))
	fake.revoked.append(fake.refresh_token)
	var ended_session = solo.client.session
	ended_session.tokens["expires_at"] = 1.0
	await solo.client.get_job("job_x")
	await wait_frames(1)
	check("ended session: signed out with a notice", not solo.is_signed_in() and notices.any(func(t: String) -> bool: return t.contains("Sign in again")))
	var kept: Dictionary = solo.credentials._read_config()
	check("ended session: the dead token is forgotten, the project kept", solo.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["refresh_token"] == ""
		and kept.get("workspace", {}).get("project_id") == "proj_solo")
	ended_session.on_rotate.call("", "rt_late")
	check("a replaced session's late rotation is not saved", solo.credentials.load_session(OAuth.PRODUCTION_ISSUER, OAuth.PRODUCTION_CLIENT_ID)["refresh_token"] == "")
	check("ended session: the dock shows sign-in", device_ui._connect_box.visible)

	# A cancelled browser sign-in closes its listener.
	opened.clear()
	solo.sign_in_browser()
	await _until(func() -> bool: return not opened.is_empty())
	var redirect := str(Loopback.parse_query(str(opened[0]).get_slice("?", 1))["redirect_uri"])
	solo.cancel_sign_in()
	var late := await _redirect(redirect, "code=code_ok&state=x")
	check("cancelled: the listener is closed", late.is_empty() and not solo.is_signed_in())

	device_ui.queue_free()
	solo.queue_free()
	return {"ok": failures.is_empty(), "checks": checks, "failures": failures, "paid_calls": fake.paid_calls.size()}


func _controller(fake: Fake) -> Controller:
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	# The test's settings file says where each secret is, so setup never reads
	# the Keychain; from here on nothing writes to it either.
	controller.credentials.use_keychain = false
	controller.open_url = func(url: String) -> void: opened.append(url)
	controller.auto_import = false
	controller.output_root = run_dir + "/scenario"
	return controller


## What the browser does after the provider's redirect: one GET to the loopback.
func _redirect(redirect_uri: String, query: String) -> String:
	var port := int(redirect_uri.get_slice(":", 2).get_slice("/", 0))
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", port)
	var sent := false
	var reply := PackedByteArray()
	for i in 200:
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED and not sent:
			peer.put_data(("GET /callback?%s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n" % query).to_utf8_buffer())
			sent = true
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			reply.append_array(peer.get_data(peer.get_available_bytes())[1])
		if status in [StreamPeerTCP.STATUS_NONE, StreamPeerTCP.STATUS_ERROR]:
			break
		await root.get_tree().process_frame
	return reply.get_string_from_utf8()


static func _last_call(fake: Fake, tool: String) -> Dictionary:
	for i in range(fake.calls.size() - 1, -1, -1):
		if fake.calls[i]["tool"] == tool:
			return fake.calls[i]
	return {}


func _until(condition: Callable, seconds: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return
		await root.get_tree().process_frame
