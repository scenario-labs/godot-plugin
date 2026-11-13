@tool
extends Node
## Opt-in usage data and feedback for the dock: watches the controller and the
## Scenario client, queues allowlisted events (core/usage.gd) while sharing is
## on, sends them in batches, and sends feedback on request (core/feedback.gd).
## Both go to the plugin website's relay, never with Scenario credentials.
## A headless editor (tests, CI, scripts) never sends anything.

## The person answered the dock's question; the plugin saves it in Editor Settings.
signal sharing_chosen(share: bool)
## Sharing was turned on or off (from the dock or Editor Settings): the dock refreshes.
signal sharing_changed

const Usage := preload("res://addons/scenario/core/usage.gd")
const Feedback := preload("res://addons/scenario/core/feedback.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const FLUSH_S := 60.0
const SEND_TIMEOUT_S := 10.0
## Tool -> what the dock was doing. Calls not listed (job polling, asset reads)
## are not recorded.
const REQUESTS := {
	"model_run": "generate", "job_cancel": "cancel", "asset_download": "import",
	"upload_asset": "upload_reference", "recommend": "recommend", "teams_list": "list_teams",
	"jobs_list": "check_unknown", "model_schema_get": "model_settings",
}

var usage: Usage
var feedback := Feedback.new()
## post(url, headers, body, timeout_s) -> {"status", "body", "error"}, as http_transport.gd.
var transport: Object
var controller: Node
## True in a headless editor: nothing is sent.
var offline := DisplayServer.get_name() == "headless"
var _timer: Timer
var _connected := false
## Job rows already seen, and those whose end was recorded (local_id -> true),
## so each generation counts once.
var _rows := {}
var _finished := {}
var _sending := false
var _started := false
## A connection is recorded once a Scenario call succeeds on it, so a key
## Scenario rejects is never counted.
var _verified := false
var _pending_connection := false


func setup(p_controller: Node, p_transport: Object, state_path: String) -> void:
	controller = p_controller
	transport = p_transport
	usage = Usage.new(state_path)
	_timer = Timer.new()
	_timer.wait_time = FLUSH_S
	_timer.timeout.connect(flush)
	add_child(_timer)
	_timer.start()
	_connected = controller.is_connected_account()
	for row in controller.ledger.jobs:
		_rows[row["local_id"]] = true
		if row["state"] in Usage.FINISHED:
			_finished[row["local_id"]] = true
	controller.changed.connect(_on_changed)
	controller.client.called.connect(_on_called)


## The editor setting changed (or the dock's answer was saved).
func set_sharing(on: bool) -> void:
	var was := usage.enabled
	if on:
		usage.mark_asked()  # chosen in Editor Settings: no need to ask
	usage.set_enabled(on)
	if on and not was and _started and _connected:
		_connection_seen()  # how the account in use connected, once sharing starts
	sharing_changed.emit()


## Called once the plugin applied the settings at startup.
func start() -> void:
	_started = true
	usage.record("extension_started")
	if _connected:
		_connection_seen()  # a session or key resumed at startup


## The dock asks once, after the first successful sign-in or key connection.
func should_ask() -> bool:
	return usage != null and not usage.enabled and not usage.asked() and controller.is_connected_account()


func choose(share: bool) -> void:
	usage.mark_asked()
	set_sharing(share)
	sharing_chosen.emit(share)


## Sends the next batch, if any. A failed batch is dropped, never retried.
func flush() -> void:
	if offline or _sending:
		return
	var batch := usage.take_batch()
	if batch.is_empty():
		return
	_sending = true
	await transport.post(Usage.relay_url("events"), PackedStringArray(["Content-Type: application/json"]), JSON.stringify(batch), SEND_TIMEOUT_S)
	_sending = false


## {"ok": true} or {"ok": false, "message"}. The dialog keeps the text until it succeeds.
func send_feedback(rating: int, message: String, email: String) -> Dictionary:
	var problem := Feedback.problem(rating, message, email)
	if not problem.is_empty():
		return {"ok": false, "message": problem}
	if offline:
		return {"ok": false, "message": "Feedback cannot be sent from a headless editor."}
	var body := feedback.payload(rating, message, email, usage.install_id())
	var response: Dictionary = await transport.post(Usage.relay_url("feedback"),
		PackedStringArray(["Content-Type: application/json"]), JSON.stringify(body), SEND_TIMEOUT_S)
	var status := int(response.get("status", 0))
	if str(response.get("error", "")).is_empty() and status == 200:
		feedback.sent()
		return {"ok": true}
	if status == 429:
		return {"ok": false, "message": "Too many messages for now. Try again in a minute; your text is kept."}
	return {"ok": false, "message": "Could not send the feedback (%s). Your text is kept: try again." % ("HTTP %d" % status if status > 0 else "no connection")}


func _on_called(tool: String, arguments: Dictionary, ok: bool, error_kind: String, duration_ms: int) -> void:
	if ok and _connected and not _verified:
		_verified = true
		if _pending_connection:
			_pending_connection = false
			_record_connected()
	if not REQUESTS.has(tool):
		return
	var request: String = REQUESTS[tool]
	if tool == "model_run" and bool(arguments.get("dry_run", false)):
		request = "price_check"
	elif tool == "jobs_list" and int(arguments.get("page_size", 0)) == 1:
		request = "check_key"  # connect_account's free check of a new key
	var properties := {"request": request, "outcome": "ok" if ok else "error", "duration_ms": duration_ms}
	if not ok:
		properties["error_kind"] = error_kind
	usage.record("scenario_request", properties)
	if usage.should_flush():
		flush()


func _on_changed() -> void:
	var connected: bool = controller.is_connected_account()
	if connected and not _connected:
		_verified = false
		_connection_seen()
	elif not connected:
		_verified = false
		_pending_connection = false
	_connected = connected
	for row in controller.ledger.jobs:
		var id: String = row["local_id"]
		if not _rows.has(id):
			_rows[id] = true
			usage.record("generation_sent", {"lane": row["lane"], "cu": row.get("quoted_cu", -1)})
		if row["state"] in Usage.FINISHED and not _finished.has(id):
			_finished[id] = true
			var properties := {"lane": row["lane"], "state": row["state"]}
			if row.get("charged_cu") != null:
				properties["cu"] = row["charged_cu"]
			usage.record("generation_finished", properties)
	if usage.should_flush():
		flush()


## Records the connection now if a call already succeeded on it, else at the first that does.
func _connection_seen() -> void:
	if _verified:
		_record_connected()
	else:
		_pending_connection = true


func _record_connected() -> void:
	var method := "sign_in" if controller.is_oauth() else ("environment" if controller.account.get("source") == "environment" else "api_key")
	usage.record("connected", {"method": method})
