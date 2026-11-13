@tool
extends Node
## The Library and History views: the project's assets and jobs read from
## Scenario, cached for the project in use and cleared when it changes or the
## account signs out. An import goes through the controller's, which
## downloads, places and records the files in the Jobs list. Free reads only.

signal changed
signal thumbnail_ready(asset_id: String)

const Controller := preload("res://addons/scenario/editor/controller.gd")
const Query := preload("res://addons/scenario/core/library_query.gd")
const Files := preload("res://addons/scenario/core/files.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const THUMBNAILS := "res://.godot/scenario/thumbnails"
const THUMBNAIL_PX := 96

var controller: Controller
var kind := "all"
var source := "all"
var query := ""
## Rows from LibraryQuery.asset_row, newest first.
var assets: Array = []
var total := 0
var loading := false
var loaded := false
var error := ""
## Rows from LibraryQuery.parse_history.
var history: Array = []
var history_next := ""
var history_loading := false
var history_loaded := false
var history_error := ""
## asset id -> Texture2D
var thumbnails := {}
## asset or job id -> true while it is being imported
var busy := {}
var _scope := ""  # the account and project the caches belong to
var _generation := 0  # bumped when the caches are dropped: late replies are ignored
var _page_serial := 0
var _thumbnail_queue: Array = []
var _thumbnails_running := false


func bind(p_controller: Controller) -> void:
	controller = p_controller
	_scope = _scope_key()
	controller.changed.connect(_on_controller_changed)


func set_filter(p_kind: String, p_source: String, p_query: String) -> void:
	kind = p_kind if Query.KINDS.has(p_kind) else "all"
	source = p_source if p_source in Query.SOURCES else "all"
	query = p_query.strip_edges()
	await refresh()


## The first page again, with the current filter.
func refresh() -> void:
	_page_serial += 1
	assets = []
	total = 0
	await _load_page(0)


func can_load_more() -> bool:
	return loaded and not loading and assets.size() < total


func load_more() -> void:
	if can_load_more():
		await _load_page(assets.size())


func load_history(more: bool = false) -> void:
	if history_loading or (more and history_next.is_empty()) or not controller.is_connected_account():
		return
	var generation := _generation
	history_loading = true
	history_error = ""
	changed.emit()
	var result: Dictionary = await controller.client.list_jobs_page(Query.HISTORY_PAGE_SIZE, history_next if more else "")
	if generation != _generation:
		return
	history_loading = false
	history_loaded = true
	if result["ok"]:
		var page := Query.parse_history(result["value"])
		if not more:
			history = []
		history.append_array(page["jobs"])
		history_next = page["next"]
	else:
		history_error = result["error"]["message"]
	changed.emit()


## The Jobs-list row of a history job, or {} when it is not there.
func ledger_row(job_id: String) -> Dictionary:
	return controller.ledger.find_by_job(job_id)


## Downloads the asset into the project and places it like its lane's output.
func import_asset(asset: Dictionary) -> Dictionary:
	var lane := Query.lane_for(str(asset["model_id"]), str(asset["kind"]), str(asset["mime"]), true)
	if lane.is_empty():
		return _fail("The dock cannot place this kind of file: " + str(asset["name"]))
	var id := str(asset["id"])
	if busy.has(id):
		return {"ok": false, "message": "Already importing."}
	var local_id := controller.ledger.adopt(lane, str(asset["model_id"]), str(asset["name"]), "", [id],
		Time.get_unix_time_from_system(), _workspace(), "library")
	return await _import(id, local_id)


## Imports a finished job's outputs. A job already in the Jobs list is
## imported from there, never added twice.
func import_job(job: Dictionary) -> Dictionary:
	var job_id := str(job["job_id"])
	if busy.has(job_id):
		return {"ok": false, "message": "Already importing."}
	var existing := ledger_row(job_id)
	if not existing.is_empty():
		if existing["state"] != Ledger.SUCCESS or existing["imported"]:
			return _fail("This job is already in the Jobs list.")
		return await _import(job_id, existing["local_id"])
	var generation := _generation
	busy[job_id] = true
	changed.emit()
	var read: Dictionary = await controller.client.get_job(job_id)
	var asset_ids: Array = read["value"].get("assetIds", []) if read["ok"] and read["value"].get("assetIds") is Array else []
	var mime := ""
	if read["ok"] and not asset_ids.is_empty():
		var first: Dictionary = await controller.client.get_asset(str(asset_ids[0]))
		mime = str(first["value"].get("mimeType", "")) if first["ok"] else ""
	busy.erase(job_id)
	if generation != _generation:
		return {"ok": false, "message": "The project changed."}
	if not read["ok"]:
		return _fail(read["error"]["message"])
	var lane := Query.lane_for(str(job["model_id"]), "", mime)
	if asset_ids.is_empty() or lane.is_empty():
		return _fail("This job has no output the dock can place.")
	var local_id := controller.ledger.adopt(lane, str(job["model_id"]), str(job["prompt"]), job_id, asset_ids,
		Time.get_unix_time_from_system(), _workspace(), "history")
	controller.ledger.apply_job(read["value"], Time.get_unix_time_from_system())
	return await _import(job_id, local_id)


## The form's file fields an image can go to: [{"name", "label", "multiple"}].
func reference_fields() -> Array:
	var found: Array = []
	for field in controller.fields:
		if field["type"] in ["file", "files"] and str(field.get("kind", "")) in ["", "image"]:
			found.append({"name": field["name"], "label": str(field.get("label", field["name"])), "multiple": field["type"] == "files"})
	return found


## Puts an image of the project in a file field of the form, as an upload would.
func use_as_reference(asset: Dictionary, field_name: String) -> bool:
	var field: Dictionary = {}
	for candidate in reference_fields():
		if candidate["name"] == field_name:
			field = candidate
	if field.is_empty() or str(asset["kind"]) != "image":
		return false
	if field["multiple"]:
		var current: Array = controller.values.get(field_name, []).duplicate()
		if not asset["id"] in current:
			current.append(asset["id"])
		controller.set_value(field_name, current)
	else:
		controller.set_value(field_name, asset["id"])
	controller.notified.emit("Added %s as a reference." % str(asset["name"]).left(40), "info")
	return true


func clear() -> void:
	_generation += 1
	_page_serial += 1
	assets = []
	total = 0
	loading = false
	loaded = false
	error = ""
	history = []
	history_next = ""
	history_loading = false
	history_loaded = false
	history_error = ""
	thumbnails = {}
	busy = {}
	_thumbnail_queue = []
	changed.emit()


func _load_page(offset: int) -> void:
	if not controller.is_connected_account():
		return
	var serial := _page_serial
	loading = true
	error = ""
	changed.emit()
	var result: Dictionary = await controller.client.search_assets(Query.search_args(kind, source, query, offset))
	if serial != _page_serial:
		return  # another filter or project since
	loading = false
	loaded = true
	if result["ok"]:
		var page := Query.parse_page(result["value"])
		var known: Array = assets.map(func(row: Dictionary) -> String: return row["id"])
		for row in page["assets"]:
			if not row["id"] in known:
				assets.append(row)
				if not row["thumbnail"].is_empty() and not thumbnails.has(row["id"]):
					_thumbnail_queue.append(row)
		total = maxi(page["total"], assets.size())
		_fetch_thumbnails()
	else:
		error = result["error"]["message"]
	changed.emit()


## One download at a time, in list order; the files stay out of the project.
func _fetch_thumbnails() -> void:
	if _thumbnails_running:
		return
	_thumbnails_running = true
	while not _thumbnail_queue.is_empty():
		var generation := _generation
		var row: Dictionary = _thumbnail_queue.pop_front()
		var path := "%s/%s.thumb" % [THUMBNAILS, row["id"]]
		var downloaded: Dictionary = await controller.transport.download(row["thumbnail"], path, 60.0)
		if downloaded["ok"] and generation == _generation:
			var texture := thumbnail_texture(FileAccess.get_file_as_bytes(path))
			if texture != null:
				thumbnails[row["id"]] = texture
				thumbnail_ready.emit(row["id"])
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_thumbnails_running = false


## A small texture from PNG, JPEG or WebP bytes, or null.
static func thumbnail_texture(bytes: PackedByteArray) -> Texture2D:
	var image := Image.new()
	var loaded_ok := ERR_FILE_UNRECOGNIZED
	match Files.sniff_extension(bytes.slice(0, 16)):
		"png":
			loaded_ok = image.load_png_from_buffer(bytes)
		"jpg":
			loaded_ok = image.load_jpg_from_buffer(bytes)
		"webp":
			loaded_ok = image.load_webp_from_buffer(bytes)
	if loaded_ok != OK or image.is_empty():
		return null
	var longest := maxi(image.get_width(), image.get_height())
	if longest > THUMBNAIL_PX:
		var ratio := float(THUMBNAIL_PX) / float(longest)
		image.resize(maxi(1, int(image.get_width() * ratio)), maxi(1, int(image.get_height() * ratio)), Image.INTERPOLATE_BILINEAR)
	return ImageTexture.create_from_image(image)


func _import(id: String, local_id: String) -> Dictionary:
	busy[id] = true
	changed.emit()
	var result: Dictionary = await controller.import_job(local_id)
	busy.erase(id)
	changed.emit()
	return result


func _fail(message: String) -> Dictionary:
	controller.notified.emit(message, "error")
	return {"ok": false, "message": message}


func _workspace() -> Dictionary:
	return controller.client.session.workspace() if controller.is_oauth() else {}


func _scope_key() -> String:
	if not controller.is_connected_account():
		return ""
	if controller.is_oauth():
		return "oauth:" + controller.client.session.project_id
	return "key:" + str(controller.account.get("api_key", ""))


func _on_controller_changed() -> void:
	var key := _scope_key()
	if key != _scope:
		_scope = key
		clear()
