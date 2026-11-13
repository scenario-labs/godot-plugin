@tool
extends RefCounted
## Anonymous usage data, off until the person opts in.
##
## While it is on, a random install ID (not linked to the Scenario account)
## tags a small allowlisted set of events, which wait in a bounded queue until
## the next batch. Turning it off drops the queue and deletes the ID. Prompts,
## file paths, asset, job, model, team and project IDs are never recorded: an
## event keeps only the properties listed in EVENTS, with the values allowed
## there. The batch shape is a contract with tools/site_proxy/middleware.ts.

const Errors := preload("res://addons/scenario/core/errors.gd")
const Client := preload("res://addons/scenario/core/mcp_client.gd")

const RELAY := "https://godot.scenario.com/telemetry/v1/"
const MAX_QUEUE := 500
const MAX_BATCH := 100
## A batch goes out when this many events wait, else on the reporter's timer.
const FLUSH_AT := 50
const LANES := ["image", "model3d", "material", "skybox", "sound"]
const REQUESTS := ["price_check", "generate", "cancel", "import", "upload_reference", "recommend",
	"list_teams", "check_unknown", "model_settings"]
const ERROR_KINDS := [Errors.AUTH, Errors.FORBIDDEN, Errors.QUOTA, Errors.MODERATED, Errors.RATE_LIMIT,
	Errors.NOT_FOUND, Errors.INVALID, Errors.TRANSPORT, Errors.TIMEOUT, Errors.HTTP_5XX, Errors.PROTOCOL,
	Errors.LOCAL, Errors.ESTIMATE_JOB, Errors.SCENARIO]
## A generation's end. Unknown is not one: it may still resolve to one of these.
const FINISHED := ["success", "failed", "blocked", "canceled", "rejected", "dismissed"]
## event -> {property: allowed values, or TYPE_INT / TYPE_FLOAT for a number}
const EVENTS := {
	"extension_started": {},
	"connected": {"method": ["sign_in", "api_key", "environment"]},
	"scenario_request": {"request": REQUESTS, "outcome": ["ok", "error"], "error_kind": ERROR_KINDS, "duration_ms": TYPE_INT},
	"generation_sent": {"lane": LANES, "cu": TYPE_FLOAT},
	"generation_finished": {"lane": LANES, "state": FINISHED, "cu": TYPE_FLOAT},
}

## The state file in the editor config folder, never under res://:
## {"asked": bool, "install_id": "32 hex"}
var state_path := ""
var enabled := false
var queue: Array = []


func _init(p_state_path: String = "") -> void:
	state_path = p_state_path


## Whether the dock already asked (or the person chose in Editor Settings).
func asked() -> bool:
	return bool(_read().get("asked", false))


func mark_asked() -> void:
	var state := _read()
	state["asked"] = true
	_write(state)


## On: keeps (or creates) the install ID. Off: drops the queue and deletes the ID.
func set_enabled(on: bool) -> void:
	enabled = on
	var state := _read()
	if on and not _is_id(str(state.get("install_id", ""))):
		state["install_id"] = new_id()
		_write(state)
	elif not on:
		queue.clear()
		if state.has("install_id"):
			state.erase("install_id")
			_write(state)


## "" while sharing is off.
func install_id() -> String:
	return str(_read().get("install_id", "")) if enabled else ""


## Queues an allowlisted event; anything else, or any other property, is dropped.
## Returns whether it was queued.
func record(event: String, properties: Dictionary = {}) -> bool:
	if not enabled or not EVENTS.has(event) or queue.size() >= MAX_QUEUE:
		return false
	var kept := {}
	var allowed: Dictionary = EVENTS[event]
	for name in allowed:
		var rule: Variant = allowed[name]
		if properties.has(name) and _allowed(rule, properties[name]):
			kept[name] = int(properties[name]) if rule is int and rule == TYPE_INT else properties[name]
	queue.append({"event": event, "timestamp": Time.get_datetime_string_from_system(true) + "Z", "properties": kept})
	return true


func should_flush() -> bool:
	return queue.size() >= FLUSH_AT


## The next batch to send, taken off the queue ({} when there is nothing to send).
## A batch that fails to send is not retried.
func take_batch() -> Dictionary:
	var id := install_id()
	if id.is_empty() or queue.is_empty():
		return {}
	var events := queue.slice(0, MAX_BATCH)
	queue = queue.slice(MAX_BATCH)
	return {"install_id": id, "context": context(), "events": events}


## Where the plugin runs, sent with every batch and with feedback.
static func context() -> Dictionary:
	var engine := Engine.get_version_info()
	return {
		"plugin_version": Client.VERSION,
		"godot_version": "%d.%d.%d" % [engine["major"], engine["minor"], engine["patch"]],
		"os": OS.get_name(),
		"arch": Engine.get_architecture_name(),
	}


## The relay endpoint ("events" or "feedback"); SCENARIO_TELEMETRY_URL replaces the base for development.
static func relay_url(endpoint: String) -> String:
	var base := OS.get_environment("SCENARIO_TELEMETRY_URL").strip_edges()
	if base.is_empty():
		base = RELAY
	return base.trim_suffix("/") + "/" + endpoint


static func new_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


static func _is_id(text: String) -> bool:
	if text.length() != 32:
		return false
	for c in text:
		if not "0123456789abcdef".contains(c):
			return false
	return true


static func _allowed(rule: Variant, value: Variant) -> bool:
	if rule is Array:
		return value is String and value in rule
	if rule == TYPE_INT:
		return (value is int or (value is float and value == floorf(value))) and value >= 0 and value <= 3600000
	return (value is int or value is float) and is_finite(float(value)) and value >= 0 and value <= 1000000


func _read() -> Dictionary:
	if state_path.is_empty() or not FileAccess.file_exists(state_path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(state_path)) != OK or not json.data is Dictionary:
		return {}
	return json.data


func _write(state: Dictionary) -> void:
	if state_path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(state_path.get_base_dir())
	var file := FileAccess.open(state_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(state, "\t"))
		file.close()
