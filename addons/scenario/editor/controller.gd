@tool
extends Node
## The plugin's brain: sign-in, team and project, lane and model, form
## values, price checks, generation, job polling and import. The dock only displays this state and
## forwards clicks, so this node is testable headless with a fake transport.

signal changed
signal notified(text: String, level: String)

const Client := preload("res://addons/scenario/core/mcp_client.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")
const Quote := preload("res://addons/scenario/core/quote.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Form := preload("res://addons/scenario/core/schema_form.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Credentials := preload("res://addons/scenario/core/credentials.gd")
const OAuth := preload("res://addons/scenario/core/oauth.gd")
const OAuthSession := preload("res://addons/scenario/core/oauth_session.gd")
const Loopback := preload("res://addons/scenario/core/loopback.gd")
const Files := preload("res://addons/scenario/core/files.gd")
const ProjectModels := preload("res://addons/scenario/core/project_models.gd")
const Placer := preload("res://addons/scenario/editor/placer.gd")

const ESTIMATE_DEBOUNCE_S := 0.6
const POLL_INTERVAL_S := 3.0
const SIGN_IN_TIMEOUT_S := 300.0

# Sign-in states shown by the dock.
const SIGN_IN_IDLE := "idle"
const SIGN_IN_BROWSER := "browser"
const SIGN_IN_DEVICE := "device"
const SIGN_IN_FINISHING := "finishing"

# Price states shown on the Generate button.
const PRICE_IDLE := "idle"
const PRICE_INVALID := "invalid"
const PRICE_CHECKING := "checking"
const PRICE_READY := "ready"
const PRICE_ERROR := "error"
const PRICE_BLOCKED := "blocked"
const PRICE_OFF := "off"

var transport: Node
var client: Client
var ledger: Ledger
var quotes := Quote.new()
var credentials: Credentials
var placer := Placer.new()

## method: "oauth" (signed in), "api_key" or "" (signed out).
var account := {"api_key": "", "source": "", "method": ""}
## {"state": SIGN_IN_*, plus "user_code", "verification_uri", "verification_uri_complete" for a device}
var sign_in := {"state": SIGN_IN_IDLE}
## The account's teams with their projects, for the picker.
var teams: Array = []
var teams_loading := false
var teams_error := ""
## The team and project picker is open.
var picking := false
## Opens a page in the browser. Tests replace it.
var open_url := func(url: String) -> void: OS.shell_open(url)
var lane_id := "image"
var model_id := ""
var model_loading := false
var fields: Array = []
var values := {}
var problems: PackedStringArray = []
var price_state := PRICE_IDLE
var price_cu := -1.0
var price_message := ""
var submitting := false
var auto_estimates := true
var auto_import := true
var confirm_above_cu := 100.0
## Where results land in the project.
var output_root := Files.ROOT
## Per model: the schema, fetched once per session.
var schemas := {}
## Per lane: extra models from Scenario's recommend, [{id, name, note}].
var recommended := {}
## The project's own models, listed under each lane's.
var project_models := ProjectModels.new()
## How the picked project model runs on its base (ProjectModels.plan); {} otherwise.
## model_id is then the base, the model every call goes to.
var trained := {}
## Per field: an upload in progress ("uploading") or its error text.
var uploads := {}

var _estimate_serial := 0
var _model_serial := 0
var _reference_serial := 0
var _debounce: Timer
var _poll: Timer
var _polling := false
var _importing := {}
var _sign_in_serial := 0
var _receiver: Loopback


## Disabling the plugin or closing the editor ends a sign-in under way and its local listener.
func _exit_tree() -> void:
	if sign_in["state"] != SIGN_IN_IDLE:
		cancel_sign_in()


func setup(p_transport: Node, ledger_path: String, credentials_path: String, resume: bool = true) -> void:
	transport = p_transport
	if transport.get_parent() == null:
		add_child(transport)
	credentials = Credentials.new(credentials_path)
	ledger = Ledger.new(ledger_path)
	ledger.load_from_disk()
	client = Client.new(transport)
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = ESTIMATE_DEBOUNCE_S
	_debounce.timeout.connect(_run_estimate)
	add_child(_debounce)
	_poll = Timer.new()
	_poll.wait_time = POLL_INTERVAL_S
	_poll.timeout.connect(poll)
	add_child(_poll)
	var saved := credentials.load_credentials()
	if not saved["api_secret"].is_empty():
		_use_account(saved["api_key"], saved["api_secret"], saved["source"])
	elif resume:
		_resume_session()


## Signed in with a project to work in: calls to Scenario can go out.
func is_connected_account() -> bool:
	return is_signed_in() and (client.session == null or client.session.has_project())


func is_signed_in() -> bool:
	return client != null and client.has_credentials()


func is_oauth() -> bool:
	return client != null and client.signed_in()


# --- Sign in with Scenario ----------------------------------------------------

## Browser sign-in: PKCE, with the code coming back to a free 127.0.0.1 port.
func sign_in_browser() -> void:
	var app := OAuth.selected_app()
	if not app["ok"]:
		notified.emit(app["error"]["message"], "error")
		return
	var serial := _begin_sign_in(SIGN_IN_BROWSER)
	var oauth := OAuth.new(transport, app["value"]["issuer"], app["value"]["client_id"])
	var pkce := OAuth.pkce_pair()
	var state := OAuth.random_state()
	var receiver := Loopback.new()
	_receiver = receiver
	var port := receiver.start(state)
	if port == 0:
		_fail_sign_in(serial, "Could not open a local port for the sign-in. Use Sign in on another device, or an API key.")
		return
	var redirect := OAuth.redirect_uri(port)
	open_url.call(oauth.authorize_url(redirect, state, pkce["challenge"]))
	var deadline := _now() + SIGN_IN_TIMEOUT_S
	while not receiver.poll():
		if serial != _sign_in_serial or _now() > deadline:
			break
		await get_tree().create_timer(0.1).timeout
	receiver.stop()
	if serial != _sign_in_serial:
		return  # cancelled, or another sign-in started
	if not receiver.done:
		_fail_sign_in(serial, "Sign-in timed out. Start again, or use Sign in on another device.")
		return
	if not receiver.error.is_empty():
		_fail_sign_in(serial, "Sign-in was not completed: " + receiver.error)
		return
	sign_in = {"state": SIGN_IN_FINISHING}
	changed.emit()
	await _finish_sign_in(serial, app["value"], await oauth.exchange_code(receiver.code, redirect, pkce["verifier"]))


## Device sign-in: shows a code to enter on any device's browser, then waits.
func sign_in_device() -> void:
	var app := OAuth.selected_app()
	if not app["ok"]:
		notified.emit(app["error"]["message"], "error")
		return
	var serial := _begin_sign_in(SIGN_IN_DEVICE)
	var oauth := OAuth.new(transport, app["value"]["issuer"], app["value"]["client_id"])
	var started: Dictionary = await oauth.start_device()
	if serial != _sign_in_serial:
		return
	if not started["ok"]:
		_fail_sign_in(serial, started["error"]["message"])
		return
	var device: Dictionary = started["value"]
	sign_in = {
		"state": SIGN_IN_DEVICE, "user_code": device["user_code"],
		"verification_uri": device["verification_uri"], "verification_uri_complete": device["verification_uri_complete"],
	}
	changed.emit()
	var interval: float = device["interval"]
	while _now() < float(device["expires_at"]):
		await get_tree().create_timer(interval).timeout
		if serial != _sign_in_serial:
			return
		var polled: Dictionary = await oauth.poll_device(device["device_code"])
		if serial != _sign_in_serial:
			return
		if polled["ok"]:
			sign_in = {"state": SIGN_IN_FINISHING}
			changed.emit()
			await _finish_sign_in(serial, app["value"], polled)
			return
		var error: Dictionary = polled["error"]
		if error.get("slow_down", false):
			interval += 5.0
		if not error.get("pending", false) and not error["kind"] in [Errors.TRANSPORT, Errors.TIMEOUT]:
			_fail_sign_in(serial, error["message"])
			return
	_fail_sign_in(serial, "The sign-in code expired. Start again.")


## Opens the device sign-in page here, with the code filled in when the provider allows it.
func open_device_page() -> void:
	var url := str(sign_in.get("verification_uri_complete", ""))
	if url.is_empty():
		url = str(sign_in.get("verification_uri", ""))
	if not url.is_empty():
		open_url.call(url)


func cancel_sign_in() -> void:
	_sign_in_serial += 1
	if _receiver != null:
		_receiver.stop()  # nothing answers on that port any more
	sign_in = {"state": SIGN_IN_IDLE}
	changed.emit()


## Reads the account's teams and projects (free), then keeps the saved
## project if it still exists, takes the only one, or opens the picker.
func load_teams() -> void:
	var session := client.session
	if session == null or teams_loading:
		return
	teams_loading = true
	teams_error = ""
	changed.emit()
	var result: Dictionary = await client.list_teams()
	teams_loading = false
	if client.session != session:
		return  # signed out meanwhile
	if not result["ok"]:
		teams_error = result["error"]["message"]
		picking = picking or not session.has_project()
		changed.emit()
		return
	teams = result["value"]
	if session.has_project():
		var saved := OAuthSession.find_workspace(teams, session.project_id)
		if saved.is_empty():
			notified.emit("The saved Scenario project is no longer available. Choose a project.", "warning")
			_set_workspace({}, {})
		else:
			_set_workspace(saved["team"], saved["project"])  # names may have changed
	if not session.has_project():
		var only := OAuthSession.only_workspace(teams)
		if only.is_empty():
			picking = true
		else:
			choose_project(str(only["team"]["id"]), str(only["project"]["id"]))
	changed.emit()


## Opens the picker on fresh teams ("Change team or project").
func open_picker() -> void:
	if not is_oauth():
		return
	picking = true
	changed.emit()
	await load_teams()


## Closes the picker, when a project is already chosen.
func close_picker() -> void:
	if is_oauth() and client.session.has_project():
		picking = false
		changed.emit()


func choose_project(team_id: String, project_id: String) -> void:
	var found := OAuthSession.find_workspace(teams, project_id)
	if not is_oauth() or found.is_empty() or str(found["team"]["id"]) != team_id:
		return
	var changed_project := client.session.project_id != project_id
	_set_workspace(found["team"], found["project"])
	picking = false
	if changed_project:
		quotes.clear()
		_set_price(PRICE_IDLE, -1.0, "")
		_drop_references()
		_forget_project_models()
		notified.emit("Generations now go to %s." % client.session.workspace_label(), "info")
	changed.emit()
	_start_work()


func sign_out() -> void:
	_sign_in_serial += 1
	var session := client.session
	credentials.clear()
	client.set_credentials("", "")
	_reset_account()
	if session != null:
		await session.oauth.revoke(session.refresh_token())  # best effort: the token is already forgotten here


func _resume_session() -> void:
	var app := OAuth.selected_app()
	if not app["ok"]:
		return
	var saved := credentials.load_session(app["value"]["issuer"], app["value"]["client_id"])
	if saved["refresh_token"].is_empty():
		return
	var session := _new_session(app["value"], {"access_token": "", "refresh_token": saved["refresh_token"], "expires_at": 0.0})
	var workspace: Dictionary = saved["workspace"]
	session.set_workspace({"id": workspace.get("team_id", ""), "name": workspace.get("team_name", "")},
		{"id": workspace.get("project_id", ""), "name": workspace.get("project_name", "")})
	_use_session(session, saved["source"])
	load_teams()  # the saved project may be gone


func _begin_sign_in(state: String) -> int:
	_sign_in_serial += 1
	sign_in = {"state": state}
	changed.emit()
	return _sign_in_serial


func _fail_sign_in(serial: int, message: String) -> void:
	if serial != _sign_in_serial:
		return
	sign_in = {"state": SIGN_IN_IDLE}
	notified.emit(message, "error")
	changed.emit()


func _finish_sign_in(serial: int, app: Dictionary, tokens: Dictionary) -> void:
	if serial != _sign_in_serial:
		return
	if not tokens["ok"]:
		_fail_sign_in(serial, tokens["error"]["message"])
		return
	var saved := credentials.save_session(app["issuer"], app["client_id"], tokens["value"]["refresh_token"])
	if not saved["ok"]:
		_fail_sign_in(serial, saved["message"])
		return
	var session := _new_session(app, tokens["value"])
	var workspace: Dictionary = credentials.load_session(app["issuer"], app["client_id"])["workspace"]
	session.set_workspace({"id": workspace.get("team_id", ""), "name": workspace.get("team_name", "")},
		{"id": workspace.get("project_id", ""), "name": workspace.get("project_name", "")})
	sign_in = {"state": SIGN_IN_IDLE}
	_use_session(session, saved["store"])
	notified.emit("Signed in to Scenario.", "info")
	await load_teams()


func _new_session(app: Dictionary, tokens: Dictionary) -> OAuthSession:
	var session := OAuthSession.new(OAuth.new(transport, app["issuer"], app["client_id"]), tokens)
	session.on_rotate = _save_rotated.bind(session)
	session.load_saved = func() -> String: return credentials.load_session(app["issuer"], app["client_id"])["refresh_token"]
	session.ended.connect(_on_session_ended.bind(session))
	return session


## Saves a rotated refresh token only for the session in use: a refresh that
## finishes after a sign-out or another sign-in must not replace the saved one.
func _save_rotated(previous: String, refresh_token: String, session: OAuthSession) -> void:
	if client.session == session:
		credentials.save_refresh_token(session.oauth.issuer, session.oauth.client_id, previous, refresh_token)


func _use_session(session: OAuthSession, source: String) -> void:
	client.set_session(session)
	account = {"api_key": "", "source": source, "method": "oauth"}
	teams = []
	teams_error = ""
	picking = false
	quotes.clear()
	_forget_project_models()
	changed.emit()
	if session.has_project():
		_start_work()


## The provider refused the refresh token: it is forgotten, so the next start
## does not resume it. The saved team and project stay for the next sign-in.
func _on_session_ended(dead_token: String, session: OAuthSession) -> void:
	if client.session != session:
		return
	credentials.forget_session(dead_token)
	client.set_credentials("", "")
	_reset_account()
	notified.emit("Your Scenario sign-in ended. Sign in again.", "warning")


func _set_workspace(team: Dictionary, project: Dictionary) -> void:
	var session := client.session
	session.set_workspace(team, project)
	credentials.save_workspace({
		"team_id": session.team_id, "team_name": session.team_name,
		"project_id": session.project_id, "project_name": session.project_name,
	})


func _reset_account() -> void:
	account = {"api_key": "", "source": "", "method": ""}
	sign_in = {"state": SIGN_IN_IDLE}
	teams = []
	teams_error = ""
	picking = false
	quotes.clear()
	_forget_project_models()
	_set_price(PRICE_IDLE, -1.0, "")
	changed.emit()


## Starts what needs a project: the form's model, polling, unknown jobs.
func _start_work() -> void:
	if model_id.is_empty():
		select_lane(lane_id)
	elif fields.is_empty():
		select_model(picked_model())
	else:
		schedule_estimate()
	if not project_models.loaded and not project_models.loading:
		_load_project_models()
	if not ledger.active().is_empty():
		_poll.start()
	if not ledger.unresolved().is_empty():
		check_unresolved()


# --- API key ------------------------------------------------------------------

## Saves the key pair, then checks it with a free call. Returns true when Scenario accepts it.
func connect_account(key: String, secret: String) -> bool:
	var saved := credentials.save_credentials(key, secret)
	if not saved["ok"]:
		notified.emit(saved["message"], "error")
		return false
	_use_account(key.strip_edges(), secret.strip_edges(), saved["store"])
	var check: Dictionary = await client.list_jobs(1)
	if not check["ok"]:
		notified.emit(check["error"]["message"], "error")
		if check["error"]["kind"] in [Errors.AUTH, Errors.FORBIDDEN]:
			sign_out()
		return false
	notified.emit("Connected to Scenario.", "info")
	return true


func _use_account(key: String, secret: String, source: String) -> void:
	_sign_in_serial += 1
	client.set_credentials(key, secret)
	account = {"api_key": key, "source": source, "method": "api_key"}
	sign_in = {"state": SIGN_IN_IDLE}
	teams = []
	picking = false
	quotes.clear()
	_forget_project_models()
	changed.emit()
	_start_work()


# --- Lane, model, values ------------------------------------------------------

func select_lane(id: String) -> void:
	if Lanes.lane(id).is_empty():
		return
	lane_id = id
	await select_model(Lanes.default_model(id))


func lane_models() -> Array:
	var models: Array = Lanes.lane(lane_id)["models"].duplicate(true)
	var known := models.map(func(m: Dictionary) -> String: return m["id"])
	for extra in recommended.get(lane_id, []):
		if not extra["id"] in known:
			models.append(extra)
	return models + project_models.for_lane(lane_id)


func select_model(id: String) -> void:
	var keep_prompt := prompt_text()
	_model_serial += 1
	var serial := _model_serial
	model_id = id
	trained = {}
	fields = []
	values = {}
	uploads = {}
	model_loading = true
	_set_price(PRICE_IDLE, -1.0, "")
	changed.emit()
	var schema: Dictionary = schemas.get(id, {})
	if schema.is_empty() and is_connected_account():
		var result: Dictionary = await client.get_schema(id)
		if serial != _model_serial:
			return  # a newer pick, of another model or this one again, owns the form now
		if not result["ok"]:
			model_loading = false
			_set_price(PRICE_ERROR, -1.0, result["error"]["message"])
			changed.emit()
			return
		schema = result["value"]
		schemas[id] = schema
	model_loading = false
	trained = ProjectModels.plan(id, schema)
	model_id = trained.get("base", id)
	fields = Form.fields_from_schema(ProjectModels.form_schema(schema, trained), Lanes.RESTRICT)
	values = Form.initial_values(fields, Lanes.presets(id))
	if not keep_prompt.is_empty() and not Form.prompt_name(fields).is_empty():
		values[Form.prompt_name(fields)] = keep_prompt
	changed.emit()
	schedule_estimate()


## The text of the model's prompt field, whatever it is called ("" if none).
func prompt_text() -> String:
	var name := Form.prompt_name(fields)
	return str(values.get(name, "")) if not name.is_empty() else ""


func set_value(name: String, value: Variant) -> void:
	if value == null or (value is String and value.is_empty()):
		values.erase(name)
	else:
		values[name] = value
	schedule_estimate()
	changed.emit()


func payload() -> Dictionary:
	return ProjectModels.run_payload(trained, Form.payload(fields, values))


## The model picked in the list: a trained model's own id, not its base.
func picked_model() -> String:
	return str(trained.get("id", model_id))


## The quote is bound to the project too: a price checked in one project is
## never spent in another.
func fingerprint() -> String:
	return Quote.fingerprint(model_id, payload(), client.session.project_id if is_oauth() else "")


# --- Price --------------------------------------------------------------------

func schedule_estimate() -> void:
	problems = Form.validate(fields, values)
	if fields.is_empty() and not model_loading:
		_set_price(PRICE_INVALID, -1.0, "Scenario gives no settings to run this model with here. Pick another one.")
	elif not uploads.is_empty():
		_set_price(PRICE_INVALID, -1.0, "Waiting for the reference upload.")
	elif not problems.is_empty():
		_set_price(PRICE_INVALID, -1.0, problems[0])
	elif not auto_estimates:
		_set_price(PRICE_OFF, -1.0, "Automatic price checks are off for this session.")
	elif _blocked():
		_set_price(PRICE_BLOCKED, -1.0, "This exact request may already be running. Check the job marked Unknown first.")
	else:
		var quote := quotes.usable(fingerprint(), _now())
		if not quote.is_empty():
			_set_price(PRICE_READY, float(quote["cu"]), "")
		else:
			_set_price(PRICE_CHECKING, -1.0, "")
			if _debounce != null and is_inside_tree():
				_debounce.start()
	changed.emit()


## Runs the price check now (the debounce timer calls this).
func _run_estimate() -> void:
	if price_state != PRICE_CHECKING or not is_connected_account():
		return
	_estimate_serial += 1
	var serial := _estimate_serial
	var fp := fingerprint()
	var request := payload()
	var result: Dictionary = await client.estimate(model_id, request)
	if serial != _estimate_serial or fp != fingerprint():
		return  # the form changed while the check ran
	if result["ok"]:
		quotes.store(fp, result["value"]["cu"], result["value"]["discount"], _now())
		_set_price(PRICE_READY, result["value"]["cu"], "")
	elif result["error"]["kind"] == Errors.ESTIMATE_JOB:
		auto_estimates = false
		_set_price(PRICE_ERROR, -1.0, result["error"]["message"])
		notified.emit(result["error"]["message"], "error")
	else:
		_set_price(PRICE_ERROR, -1.0, result["error"]["message"])
	changed.emit()


func estimate_now() -> void:
	auto_estimates = true
	schedule_estimate()
	if price_state == PRICE_CHECKING:
		_debounce.stop()
		await _run_estimate()


# --- Generate -----------------------------------------------------------------

## Paid. Returns {"needs_confirm": cu} when the price is above the threshold
## and confirmed is false, {"ok": false, "message"} when nothing was sent, or
## {"ok": true, "local_id"}.
func generate(confirmed: bool = false) -> Dictionary:
	if submitting:
		return {"ok": false, "message": "A request is already being sent."}
	var fp := fingerprint()
	var quote := quotes.usable(fp, _now())
	if quote.is_empty() or price_state != PRICE_READY:
		return {"ok": false, "message": "Wait for the price check to finish."}
	if _blocked():
		return {"ok": false, "message": "This exact request may already be running."}
	if float(quote["cu"]) > confirm_above_cu and not confirmed:
		return {"needs_confirm": float(quote["cu"])}
	quote = quotes.consume(fp, _now())
	var request := payload()
	var label := prompt_text() if not prompt_text().is_empty() else _model_name(model_id)
	var scope: Dictionary = client.session.workspace() if is_oauth() else {}
	var local_id := ledger.add_intent(lane_id, model_id, request, fp, float(quote["cu"]), _now(), label, scope)
	submitting = true
	_set_price(PRICE_IDLE, -1.0, "Sending...")
	changed.emit()
	var result: Dictionary = await client.submit(model_id, request)
	submitting = false
	if result["ok"]:
		ledger.mark_submitted(local_id, result["value"]["job_id"], result["value"]["status"], _now())
		_poll.start()
		notified.emit("Generating with %s for %s CU." % [_model_name(model_id), Form.number_text(quote["cu"])], "info")
	elif result["error"].get("ambiguous", false):
		ledger.mark_unknown(local_id, result["error"]["message"], _now())
		notified.emit(result["error"]["message"], "warning")
		check_unresolved()
	else:
		ledger.mark_rejected(local_id, result["error"]["message"], _now())
		notified.emit(result["error"]["message"], "error")
	schedule_estimate()  # a new single-use quote for the next run
	changed.emit()
	return {"ok": result["ok"], "local_id": local_id}


# --- Jobs ---------------------------------------------------------------------

func poll() -> void:
	if _polling or not is_connected_account():
		return
	_polling = true
	for row in ledger.active():
		var result: Dictionary = await client.get_job(row["job_id"], _row_scope(row))
		if result["ok"]:
			var updated := ledger.apply_job(result["value"], _now())
			if updated.get("state") == Ledger.SUCCESS and auto_import and not updated["imported"]:
				import_job(updated["local_id"])
			elif updated.get("state") in [Ledger.FAILED, Ledger.BLOCKED]:
				notified.emit("%s: %s" % [_model_name(updated["model_id"]), _failure_text(updated)], "error")
	_polling = false
	if ledger.active().is_empty():
		_poll.stop()
	changed.emit()


func cancel(local_id: String) -> void:
	var row := ledger.find(local_id)
	if row.is_empty() or str(row["job_id"]).is_empty():
		return
	var result: Dictionary = await client.cancel_job(row["job_id"], _row_scope(row))
	if result["ok"]:
		ledger.mark_cancel_requested(local_id, _now())
		notified.emit("Cancel requested. The job stops when Scenario confirms it.", "info")
	else:
		notified.emit(result["error"]["message"], "error")
	changed.emit()


## Puts a finished job's model and settings back in the form. Never sends anything.
func rerun(local_id: String) -> void:
	var row := ledger.find(local_id)
	if row.is_empty():
		return
	lane_id = row["lane"]
	var again := ProjectModels.rerun_of(row["model_id"], row["parameters"])
	await select_model(again["model_id"])
	# References are assets of the row's project: another project cannot use them.
	var other_project := is_oauth() and str(row.get("project_id", "")) != client.session.project_id
	for key in again["values"]:
		if not (other_project and _field(key).get("type", "") in ["file", "files"]):
			values[key] = again["values"][key]
	schedule_estimate()
	changed.emit()


## Looks for unknown requests on Scenario and links the ones that match, each
## in the project it was sent to.
func check_unresolved() -> void:
	if ledger.unresolved().is_empty() or not is_connected_account():
		return
	var session := client.session
	var scopes := {}  # project_id ("" with an API key) -> the scope to list it in
	for row in ledger.unresolved():
		var scope := _row_scope(row)
		if is_oauth() and scope.is_empty():
			continue  # sent with an API key: its project is unknown here
		scopes[str(scope.get("project_id", ""))] = scope
	var linked := 0
	for project_id in scopes:
		var result: Dictionary = await client.list_jobs(50, scopes[project_id])
		if client.session != session:
			return  # signed out or in again meanwhile
		if result["ok"]:
			linked += ledger.reconcile(result["value"], _now(), project_id)
	if linked > 0:
		notified.emit("Found %d job(s) that were sent before the connection dropped." % linked, "info")
		_poll.start()
	schedule_estimate()
	changed.emit()


func dismiss(local_id: String) -> void:
	ledger.dismiss(local_id, _now())
	schedule_estimate()
	changed.emit()


## Downloads every output of a finished job and places it in the scene.
func import_job(local_id: String) -> Dictionary:
	if _importing.has(local_id):
		return {"ok": false, "message": "Already importing."}
	var row := ledger.find(local_id)
	if row.is_empty() or row["state"] != Ledger.SUCCESS:
		return {"ok": false, "message": "Only finished jobs can be imported."}
	_importing[local_id] = true
	changed.emit()
	var lane := Lanes.lane(row["lane"])
	var files: Array = []
	var assets: Array = []
	var problem := ""
	var pending := ""  # a download not yet moved into the project
	var date := Files.today()
	for asset_id in row["asset_ids"]:
		var asset_result: Dictionary = await client.get_asset(asset_id, _row_scope(row))
		if not asset_result["ok"]:
			problem = asset_result["error"]["message"]
			break
		var asset: Dictionary = asset_result["value"]
		var role := Files.role_for(asset)
		var url_result: Dictionary = await client.download_url(asset_id, str(lane.get("download_format", "")), _row_scope(row))
		if not url_result["ok"]:
			problem = url_result["error"]["message"]
			break
		var temp := "%s/%s.download" % [Files.DOWNLOADS, asset_id]
		var downloaded: Dictionary = await transport.download(url_result["value"], temp)
		if not downloaded["ok"]:
			problem = downloaded["error"]
			break
		pending = temp
		var head := Files.head(temp)
		var ext := Files.sniff_extension(head)
		if ext.is_empty():
			ext = Files.extension_for_mime(str(asset.get("mimeType", "")))
		if not ext in Files.IMPORTABLE:
			problem = "Scenario returned a file Godot cannot import (%s)." % str(asset.get("mimeType", "unknown type"))
			break
		if not Lanes.accepts(row["lane"], ext):
			problem = "%s returned a %s file, which the %s lane cannot place. Pick one of the lane's own models." % [
				_model_name(str(row["model_id"])), ext.to_upper(), lane["title"]]
			break
		if lane["importer"] == "model3d" and ext in ["png", "jpg", "webp"]:
			role = "preview"  # 3D models come with a thumbnail next to the GLB
		var base := Files.base_path(row["lane"], row["prompt"], asset_id, role, date, output_root)
		var final_path := base + "." + ext
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(final_path.get_base_dir()))
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), ProjectSettings.globalize_path(final_path)) != OK:
			problem = "Could not move the download into " + final_path
			break
		pending = ""
		files.append({"path": final_path, "role": role})
		assets.append({"asset_id": asset_id, "role": role, "path": final_path, "mime": asset.get("mimeType", "")})
	if problem.is_empty() and files.is_empty():
		problem = "The job finished without output files."
	if problem.is_empty() and lane["importer"] == "model3d" and files.all(func(f: Dictionary) -> bool: return f["role"] == "preview"):
		problem = "%s returned no GLB or glTF model, which the 3D lane needs. Pick one of the lane's own models." % _model_name(str(row["model_id"]))
	if not problem.is_empty():
		# A failed import keeps nothing: neither the files already moved nor the pending download.
		for item in files:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(item["path"]))
		if not pending.is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(pending))
		_importing.erase(local_id)
		ledger.set_error(local_id, problem, _now())
		notified.emit(problem, "error")
		changed.emit()
		return {"ok": false, "message": problem}
	Files.write_provenance(row, assets, files[0]["path"].get_basename() + ".scenario.json", "Scenario Godot Plugin " + Client.VERSION)
	await placer.import_files(row["lane"], files)
	var placed := placer.place(row["lane"], files, Files.node_name(row["prompt"]))
	var paths: Array = files.map(func(f: Dictionary) -> String: return f["path"])
	for extra in placed["resource_paths"]:
		if not extra in paths:
			paths.append(extra)
	ledger.mark_imported(local_id, paths, _now())
	_importing.erase(local_id)
	notified.emit(placed["message"], "info" if placed["ok"] else "error")
	changed.emit()
	return placed


func is_importing(local_id: String) -> bool:
	return _importing.has(local_id)


# --- References ---------------------------------------------------------------

## Uploads a project file as a reference for a file field. Free (no CU).
func attach_file(field_name: String, path: String) -> void:
	var field := _field(field_name)
	if field.is_empty():
		return
	var type := Files.upload_type(path)
	if type.is_empty():
		notified.emit("This file type cannot be used as a reference: " + path.get_file(), "error")
		return
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		notified.emit("Could not read " + path, "error")
		return
	uploads[field_name] = "uploading"
	schedule_estimate()
	var serial := _reference_serial
	var start: Dictionary = await client.upload_start(path.get_file(), type["mime"], type["kind"], bytes.size())
	var asset_id := ""
	var problem := ""
	if not start["ok"]:
		problem = start["error"]["message"]
	else:
		var part_size := int(start["value"].get("part_size", bytes.size()))
		for part in start["value"].get("parts", []):
			var index := int(part.get("part_number", 1)) - 1
			var chunk := bytes.slice(index * part_size, mini((index + 1) * part_size, bytes.size()))
			var put: Dictionary = await transport.put_bytes(str(part.get("upload_url", "")), chunk)
			if not put["ok"]:
				problem = put["error"]
				break
		if problem.is_empty():
			var done: Dictionary = await client.upload_complete({"upload_id": start["value"].get("upload_id", "")})
			if done["ok"] and str(done["value"].get("asset_id", "")).begins_with("asset_"):
				asset_id = done["value"]["asset_id"]
			else:
				problem = done["error"]["message"] if not done["ok"] else "Scenario did not finish the upload."
	uploads.erase(field_name)
	if serial != _reference_serial:
		pass  # the project changed during the upload: the asset is in the earlier one
	elif not problem.is_empty():
		notified.emit(problem, "error")
	elif field["type"] == "files":
		var current: Array = values.get(field_name, []).duplicate()
		current.append(asset_id)
		values[field_name] = current
	else:
		values[field_name] = asset_id
	schedule_estimate()
	changed.emit()


## Saves the editor's 3D viewport as a PNG and attaches it. Needs a rendering editor.
func attach_viewport(field_name: String) -> void:
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport == null or viewport.get_texture() == null:
		notified.emit("The 3D viewport is not available.", "error")
		return
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		notified.emit("The 3D viewport could not be captured.", "error")
		return
	var path := "res://.godot/scenario/captures/viewport-%d.png" % int(_now())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	image.save_png(path)
	await attach_file(field_name, path)


func clear_field(field_name: String) -> void:
	values.erase(field_name)
	schedule_estimate()
	changed.emit()


func load_recommendations() -> void:
	var lane := Lanes.lane(lane_id)
	if not lane.get("recommend", true):
		return
	var prompt := prompt_text() if not prompt_text().is_empty() else str(lane["hint"])
	var result: Dictionary = await client.recommend(lane["capability"], prompt, 8)
	if not result["ok"]:
		notified.emit(result["error"]["message"], "error")
		return
	var extra: Array = []
	for entry in result["value"].get("ranked", []):
		extra.append({"id": entry["model_id"], "name": entry.get("name", entry["model_id"]), "note": str(entry.get("cost_summary", ""))})
	var specialty: Variant = result["value"].get("specialty")
	if specialty is Dictionary and specialty.has("model_id"):
		extra.push_front({"id": specialty["model_id"], "name": specialty.get("name", specialty["model_id"]), "note": "specialist"})
	recommended[lane_id] = extra
	notified.emit("Added Scenario's recommendations for this prompt.", "info")
	changed.emit()


# --- Internals ----------------------------------------------------------------

## An unknown send blocks the same request, also across an API key and a sign-in.
func _blocked() -> bool:
	return ledger.blocks(fingerprint()) or ledger.blocks_request(model_id, payload(), client.session.project_id if is_oauth() else "")


## Clears reference images: assets of the earlier project, unusable in the new one.
func _drop_references() -> void:
	for field in fields:
		if field["type"] in ["file", "files"]:
			values.erase(field["name"])
	_reference_serial += 1  # an upload still running finishes into the old project: dropped


func _load_project_models() -> void:
	await project_models.load(client)
	if not project_models.error.is_empty():
		notified.emit("Could not read this project's models: " + project_models.error, "warning")
	changed.emit()


## A project's models and their schemas belong to it: forgotten on a switch or
## sign-out, and a form on one of them goes back to the lane's default model.
func _forget_project_models() -> void:
	for entry in project_models.entries:
		schemas.erase(entry["id"])
	if project_models.entries.any(func(e: Dictionary) -> bool: return e["id"] == picked_model()):
		trained = {}
		model_id = ""
		fields = []
	project_models.clear()


## The team and project a row's job ran in, for its reads and cancel ({} with an API key).
func _row_scope(row: Dictionary) -> Dictionary:
	if not is_oauth() or str(row.get("project_id", "")).is_empty():
		return {}
	return {"team_id": str(row.get("team_id", "")), "project_id": str(row["project_id"])}


func _set_price(state: String, cu: float, message: String) -> void:
	price_state = state
	price_cu = cu
	price_message = message


func _has_field(name: String) -> bool:
	return not _field(name).is_empty()


func _field(name: String) -> Dictionary:
	for field in fields:
		if field["name"] == name:
			return field
	return {}


func _model_name(id: String) -> String:
	for lane in Lanes.LANES:
		for model in lane["models"]:
			if model["id"] == id:
				return model["name"]
	for extras in recommended.values() + [project_models.entries]:
		for model in extras:
			if model["id"] == id:
				return model["name"]
	return id.trim_prefix("model_")


func _failure_text(row: Dictionary) -> String:
	if row["state"] == Ledger.BLOCKED:
		return Errors.message_for(Errors.MODERATED)
	return str(row["error"]) if not str(row["error"]).is_empty() else "the job failed on Scenario."


static func _now() -> float:
	return Time.get_unix_time_from_system()
