@tool
extends Node
## The plugin's brain: account, lane and model, form values, price checks,
## generation, job polling and import. The dock only displays this state and
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
const Files := preload("res://addons/scenario/core/files.gd")
const Placer := preload("res://addons/scenario/editor/placer.gd")

const ESTIMATE_DEBOUNCE_S := 0.6
const POLL_INTERVAL_S := 3.0

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

var account := {"api_key": "", "source": ""}
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
## Per field: an upload in progress ("uploading") or its error text.
var uploads := {}

var _estimate_serial := 0
var _debounce: Timer
var _poll: Timer
var _polling := false
var _importing := {}


func setup(p_transport: Node, ledger_path: String, credentials_path: String) -> void:
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


func is_connected_account() -> bool:
	return client != null and client.has_credentials()


# --- Account ------------------------------------------------------------------

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
			disconnect_account()
		return false
	notified.emit("Connected to Scenario.", "info")
	return true


func disconnect_account() -> void:
	credentials.clear()
	client.set_credentials("", "")
	account = {"api_key": "", "source": ""}
	quotes.clear()
	_set_price(PRICE_IDLE, -1.0, "")
	changed.emit()


func _use_account(key: String, secret: String, source: String) -> void:
	client.set_credentials(key, secret)
	account = {"api_key": key, "source": source}
	quotes.clear()
	changed.emit()
	if model_id.is_empty():
		select_lane(lane_id)
	if not ledger.active().is_empty():
		_poll.start()
	if not ledger.unresolved().is_empty():
		check_unresolved()


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
	return models


func select_model(id: String) -> void:
	var keep_prompt: Variant = values.get("prompt")
	model_id = id
	fields = []
	values = {}
	uploads = {}
	model_loading = true
	_set_price(PRICE_IDLE, -1.0, "")
	changed.emit()
	var schema: Dictionary = schemas.get(id, {})
	if schema.is_empty() and is_connected_account():
		var result: Dictionary = await client.get_schema(id)
		if id != model_id:
			return  # the user picked another model meanwhile
		if not result["ok"]:
			model_loading = false
			_set_price(PRICE_ERROR, -1.0, result["error"]["message"])
			changed.emit()
			return
		schema = result["value"]
		schemas[id] = schema
	model_loading = false
	fields = Form.fields_from_schema(schema, Lanes.RESTRICT)
	values = Form.initial_values(fields, Lanes.presets(id))
	if keep_prompt != null and _has_field("prompt"):
		values["prompt"] = keep_prompt
	changed.emit()
	schedule_estimate()


func set_value(name: String, value: Variant) -> void:
	if value == null or (value is String and value.is_empty()):
		values.erase(name)
	else:
		values[name] = value
	schedule_estimate()
	changed.emit()


func payload() -> Dictionary:
	return Form.payload(fields, values)


func fingerprint() -> String:
	return Quote.fingerprint(model_id, payload())


# --- Price --------------------------------------------------------------------

func schedule_estimate() -> void:
	problems = Form.validate(fields, values)
	if not uploads.is_empty():
		_set_price(PRICE_INVALID, -1.0, "Waiting for the reference upload.")
	elif not problems.is_empty():
		_set_price(PRICE_INVALID, -1.0, problems[0])
	elif not auto_estimates:
		_set_price(PRICE_OFF, -1.0, "Automatic price checks are off for this session.")
	elif ledger.blocks(fingerprint()):
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
	if ledger.blocks(fp):
		return {"ok": false, "message": "This exact request may already be running."}
	if float(quote["cu"]) > confirm_above_cu and not confirmed:
		return {"needs_confirm": float(quote["cu"])}
	quote = quotes.consume(fp, _now())
	var request := payload()
	var local_id := ledger.add_intent(lane_id, model_id, request, fp, float(quote["cu"]), _now())
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
		var result: Dictionary = await client.get_job(row["job_id"])
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
	var result: Dictionary = await client.cancel_job(row["job_id"])
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
	await select_model(row["model_id"])
	for key in row["parameters"]:
		values[key] = row["parameters"][key]
	schedule_estimate()
	changed.emit()


## Looks for unknown requests on Scenario and links the ones that match.
func check_unresolved() -> void:
	if ledger.unresolved().is_empty() or not is_connected_account():
		return
	var result: Dictionary = await client.list_jobs(50)
	if result["ok"]:
		var linked := ledger.reconcile(result["value"], _now())
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
	var date := Files.today()
	for asset_id in row["asset_ids"]:
		var asset_result: Dictionary = await client.get_asset(asset_id)
		if not asset_result["ok"]:
			problem = asset_result["error"]["message"]
			break
		var asset: Dictionary = asset_result["value"]
		var role := Files.role_for(asset)
		var url_result: Dictionary = await client.download_url(asset_id, str(lane.get("download_format", "")))
		if not url_result["ok"]:
			problem = url_result["error"]["message"]
			break
		var temp := "%s/%s.download" % [Files.DOWNLOADS, asset_id]
		var downloaded: Dictionary = await transport.download(url_result["value"], temp)
		if not downloaded["ok"]:
			problem = downloaded["error"]
			break
		var head := _head(temp)
		var ext := Files.sniff_extension(head)
		if ext.is_empty():
			ext = Files.extension_for_mime(str(asset.get("mimeType", "")))
		if not ext in Files.IMPORTABLE:
			problem = "Scenario returned a file Godot cannot import (%s)." % str(asset.get("mimeType", "unknown type"))
			break
		var base := Files.base_path(row["lane"], row["prompt"], asset_id, role, date, output_root)
		var final_path := base + "." + ext
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(final_path.get_base_dir()))
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), ProjectSettings.globalize_path(final_path)) != OK:
			problem = "Could not move the download into " + final_path
			break
		files.append({"path": final_path, "role": role})
		assets.append({"asset_id": asset_id, "role": role, "path": final_path, "mime": asset.get("mimeType", "")})
	if problem.is_empty() and files.is_empty():
		problem = "The job finished without output files."
	if not problem.is_empty():
		_importing.erase(local_id)
		ledger.set_error(local_id, problem, _now())
		notified.emit(problem, "error")
		changed.emit()
		return {"ok": false, "message": problem}
	_write_provenance(row, assets, files[0]["path"].get_basename() + ".scenario.json")
	await placer.import_files(row["lane"], files)
	var placed := placer.place(row["lane"], files, "Scenario" + Files.slug(row["prompt"], 24).capitalize().replace(" ", ""))
	var paths: Array = files.map(func(f: Dictionary) -> String: return f["path"])
	paths.append_array(placed["resource_paths"])
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
	if not problem.is_empty():
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
	var prompt := str(values.get("prompt", lane["hint"]))
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
	return id.trim_prefix("model_")


func _failure_text(row: Dictionary) -> String:
	if row["state"] == Ledger.BLOCKED:
		return Errors.message_for(Errors.MODERATED)
	return str(row["error"]) if not str(row["error"]).is_empty() else "the job failed on Scenario."


func _write_provenance(row: Dictionary, assets: Array, path: String) -> void:
	var record := {
		"generator": "Scenario Godot Plugin " + Client.VERSION,
		"job_id": row["job_id"], "model_id": row["model_id"], "lane": row["lane"],
		"prompt": row["prompt"], "parameters": row["parameters"],
		"quoted_cu": row["quoted_cu"], "charged_cu": row["charged_cu"],
		"assets": assets, "imported_at": Time.get_datetime_string_from_system(true) + "Z",
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(record, "\t"))
		file.close()


static func _head(path: String) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var head := file.get_buffer(16)
	file.close()
	return head


static func _now() -> float:
	return Time.get_unix_time_from_system()
