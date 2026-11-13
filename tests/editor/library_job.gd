extends "res://addons/agentkit/agent_job.gd"
## Headless editor test of the dock's Library and History, against the fake
## backend: browse newest first, page, filter, search, thumbnails, import and
## place an image and a 3D model, use an image as a reference, list and import
## a finished job without a second Jobs row, and drop everything on a project
## switch and on sign-out. Nothing here spends.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const OAuth := preload("res://addons/scenario/core/oauth.gd")
const Query := preload("res://addons/scenario/core/library_query.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")

const FLARE := "model_openai-gpt-image-2-5-flare"

var failures: Array = []
var checks := 0


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/library-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var scene_path := run_dir + "/library_scene.tscn"
	DirAccess.copy_absolute(ProjectSettings.globalize_path("res://main.tscn"), ProjectSettings.globalize_path(scene_path))
	EditorInterface.get_resource_filesystem().update_file(scene_path)
	var scene := await open_scratch_scene(scene_path)
	check("scratch scene open", scene != null)

	var fake := Fake.new()
	root.add_child(fake)
	fake.library["proj_a1"] = _assets()
	fake.library["proj_a2"] = [Fake.library_hit("asset_other", "image", "image/png", "2026-11-12T08:00:00.000Z", "other.png")]
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.credentials.use_keychain = false
	controller.output_root = run_dir + "/scenario"
	controller.auto_import = false
	_sign_in(controller, fake)
	await _until(func() -> bool: return not controller.fields.is_empty())
	var ui := DockUI.new()
	root.add_child(ui)
	ui.bind(controller)
	var library := ui.library
	var library_ui := ui._library_ui

	# Browse: newest first, one page, then the next.
	ui._show_view("library")
	await _until(func() -> bool: return library.loaded and not library.loading)
	await wait_frames(1)
	var search := _last_call(fake, "search")
	check("library read through search in the project", search.get("arguments", {}).get("project_id") == "proj_a1"
		and search["arguments"].get("sort_by") == ["createdAt:desc"] and search["arguments"].get("include_urls") == true)
	check("first page: newest first", library.assets.size() == Query.PAGE_SIZE and library.total == 28 and library.assets[0]["id"] == "asset_gen24")
	check("dock shows the cards and Show more", ui._generate_box.visible == false and library_ui._cards.get_child_count() == Query.PAGE_SIZE and library_ui._more_button.visible)
	await library.load_more()
	check("next page appended", library.assets.size() == 28 and not library.can_load_more())
	await _until(func() -> bool: return library._thumbnail_queue.is_empty() and not library._thumbnails_running)
	check("thumbnails for images, none for audio", library.thumbnails.has("asset_gen00") and library.thumbnails.has("asset_upl_logo")
		and not library.thumbnails.has("asset_snd001") and library.thumbnails["asset_gen00"].get_width() <= 96)

	# Filters and search.
	await library.set_filter("3d", "all", "")
	check("kind filter", library.assets.map(func(a: Dictionary) -> String: return a["id"]) == ["asset_glb001"])
	await library.set_filter("all", "uploaded", "")
	check("uploads only", library.assets.map(func(a: Dictionary) -> String: return a["id"]) == ["asset_upl_logo"])
	await library.set_filter("all", "all", "gem 7")
	check("search by prompt", library.assets.size() == 1 and library.assets[0]["id"] == "asset_gen07" and not _last_call(fake, "search")["arguments"].has("sort_by"))
	await library.set_filter("all", "all", "")
	await library.load_more()  # the oldest assets are on the second page

	# Import and place an image, then a 3D model.
	var logo := _asset(library, "asset_upl_logo")
	var placed: Dictionary = await library.import_asset(logo)
	var logo_row := _row_with(controller, "asset_upl_logo")
	check("image imported and placed", placed.get("ok", false) and logo_row.get("imported") == true and logo_row.get("source") == "library"
		and logo_row.get("lane") == "image" and logo_row.get("project_id") == "proj_a1")
	check("the import read the asset in its project", _last_call(fake, "asset_download").get("arguments", {}).get("project_id") == "proj_a1")
	var rows_before := controller.ledger.jobs.size()
	await library.import_asset(logo)
	check("importing it again adds no second Jobs row", controller.ledger.jobs.size() == rows_before)
	var crate: Dictionary = await library.import_asset(_asset(library, "asset_glb001"))
	check("3D model imported as a GLB", crate.get("ok", false) and _row_with(controller, "asset_glb001").get("lane") == "model3d"
		and _last_call(fake, "asset_download")["arguments"].get("format") == "glb")
	await wait_frames(1)
	check("imported rows are listed without Re-run", ui._jobs_box.get_child_count() > 0 and not _has_button(ui._jobs_box, "Re-run"))
	var preview := Fake.library_hit("asset_glbprv", "image", "image/png", "2026-10-02T09:00:00.000Z", "", "model_rodin-hyper3d-v2-5-text-to-3d", "a crate")
	var preview_import: Dictionary = await library.import_asset(Query.asset_row(preview))
	check("a 3D model's preview alone imports as an image", preview_import.get("ok", false) and _row_with(controller, "asset_glbprv").get("lane") == "image")

	# An image of the project as a reference: no upload.
	var fields: Array = library.reference_fields()
	check("flare offers two reference fields", fields.map(func(f: Dictionary) -> String: return f["name"]) == ["referenceImages", "mask"])
	library.use_as_reference(_asset(library, "asset_gen03"), "referenceImages")
	library.use_as_reference(_asset(library, "asset_gen04"), "referenceImages")
	library.use_as_reference(_asset(library, "asset_gen04"), "referenceImages")
	check("references set without uploading", controller.values.get("referenceImages") == ["asset_gen03", "asset_gen04"] and fake.uploads == 0)
	check("audio is never a reference", not library.use_as_reference(_asset(library, "asset_snd001"), "mask"))

	# History: pages of the project's jobs, import a finished one once.
	var now := Time.get_unix_time_from_system()
	fake.listed["proj_a1"] = _jobs(now)
	fake.add_job("job_h01", "model3d")
	fake.add_job("job_team3d", "model3d")
	var lost := controller.ledger.add_intent("image", FLARE, {"prompt": "a lantern"}, "fp_lantern", 2.0, now - 2.0, "a lantern", controller.client.session.workspace())
	controller.ledger.mark_unknown(lost, "dropped", now)
	controller.ledger.adopt("image", FLARE, "already here", "job_h02", ["asset_img001"], Time.get_unix_time_from_system(), controller.client.session.workspace())
	controller.ledger.mark_imported(controller.ledger.find_by_job("job_h02")["local_id"], [], Time.get_unix_time_from_system())
	ui._show_view("history")
	await _until(func() -> bool: return library.history_loaded and not library.history_loading)
	await wait_frames(1)
	check("history: first page, uploads left out", library.history.size() == Query.HISTORY_PAGE_SIZE - 2 and library_ui._older_button.visible
		and library.history.all(func(j: Dictionary) -> bool: return not str(j["job_id"]).begins_with("job_up")))
	await library.load_history(true)
	check("history: older page", library.history.size() == 36 and library.history_next.is_empty())
	await wait_frames(1)
	check("history: a job already in Jobs is not offered again", _row_text(library_ui, 2).contains("In the Jobs list"))
	check("history: a running job cannot be imported", _row_text(library_ui, 3).contains("In Progress"))
	rows_before = controller.ledger.jobs.size()
	var from_history: Dictionary = await library.import_job(library.history[1])
	var job_row := controller.ledger.find_by_job("job_h01")
	check("history: job imported with its lane and cost", from_history.get("ok", false) and job_row.get("lane") == "model3d"
		and job_row.get("charged_cu") == 2.0 and job_row.get("imported") == true and controller.ledger.jobs.size() == rows_before + 1)
	await library.import_job(library.history[1])
	check("history: no second row for the same job", controller.ledger.jobs.size() == rows_before + 1)
	var refused: Dictionary = await library.import_job(library.history[0])
	check("history: a job an Unknown row may stand for waits for that row", not refused.get("ok", true)
		and controller.ledger.find_by_job("job_h00").is_empty() and controller.ledger.find(lost).get("state") == Ledger.UNKNOWN
		and controller.ledger.jobs.size() == rows_before + 1)
	await controller.check_unresolved()
	check("Check Scenario links the row to the job", controller.ledger.find(lost).get("job_id") == "job_h00")
	var after_check: Dictionary = await library.import_job(library.history[0])
	check("history: then imports the linked row's outputs, no new row", after_check.get("ok", false)
		and controller.ledger.find(lost).get("imported") == true and controller.ledger.jobs.size() == rows_before + 1)
	var unlisted: Dictionary = await library.import_job(library.history[4])
	check("history: an unlisted model's 3D job goes to the 3D lane", unlisted.get("ok", false)
		and controller.ledger.find_by_job("job_team3d").get("lane") == "model3d")

	# Another project: everything read for the first one is dropped.
	controller.choose_project("team_a", "proj_a2")
	check("project switch clears the caches", library.assets.is_empty() and library.history.is_empty() and library.thumbnails.is_empty())
	await _until(func() -> bool: return library.history_loaded and not library.history_loading)
	check("history read again in the new project", _last_call(fake, "jobs_list")["arguments"].get("project_id") == "proj_a2" and library.history.is_empty())
	ui._show_view("library")
	await _until(func() -> bool: return library.loaded and not library.loading)
	check("library read again in the new project", library.assets.size() == 1 and library.assets[0]["id"] == "asset_other")
	await controller.sign_out()
	check("sign-out clears the caches", library.assets.is_empty() and not library.loaded)

	ui.queue_free()
	controller.queue_free()
	return {"ok": failures.is_empty(), "checks": checks, "failures": failures, "paid_calls": fake.paid_calls.size() + fake.uploads}


func _sign_in(controller: Controller, fake: Fake) -> void:
	var app := {"issuer": OAuth.PRODUCTION_ISSUER, "client_id": OAuth.PRODUCTION_CLIENT_ID}
	controller.credentials.save_session(app["issuer"], app["client_id"], "rt_library")
	var session = controller._new_session(app, {"access_token": "at_library", "refresh_token": "rt_library", "expires_at": Time.get_unix_time_from_system() + 3600.0})
	controller._use_session(session, "file")
	controller.teams = fake.teams
	controller.choose_project("team_a", "proj_a1")


## 25 generated images, an uploaded logo, a 3D model and a sound, oldest first.
static func _assets() -> Array:
	var hits: Array = []
	for i in 25:
		hits.append(Fake.library_hit("asset_gen%02d" % i, "image", "image/png", "2026-11-%02dT10:00:00.000Z" % (i + 1),
			"", FLARE, "a gem %d" % i))
	hits.append(Fake.library_hit("asset_upl_logo", "image", "image/png", "2026-10-01T09:00:00.000Z", "logo.png"))
	hits.append(Fake.library_hit("asset_glb001", "3d", "model/gltf-binary", "2026-10-02T09:00:00.000Z", "crate.glb",
		"model_rodin-hyper3d-v2-5-text-to-3d", "a crate"))
	hits.append(Fake.library_hit("asset_snd001", "audio", "audio/mpeg", "2026-10-03T09:00:00.000Z", "hit.mp3",
		"model_sonilo-v1-1-text-to-sound-effects", "a hit"))
	return hits


## 38 jobs, newest first: a finished image sent just now (an Unknown row may
## stand for it), a finished 3D model, one already in the Jobs list, one
## running, a 3D job of a model the dock does not list, two uploads, then
## older finished ones.
static func _jobs(now: float) -> Array:
	var jobs: Array = [
		{"jobId": "job_h00", "status": "success", "modelId": FLARE, "prompt": "a lantern", "createdAt": Time.get_datetime_string_from_unix_time(int(now)) + "Z"},
		{"jobId": "job_h01", "status": "success", "modelId": "model_rodin-hyper3d-v2-5-text-to-3d", "prompt": "a barrel", "createdAt": "2026-11-13T11:00:00.000Z"},
		{"jobId": "job_h02", "status": "success", "modelId": FLARE, "prompt": "already here", "createdAt": "2026-11-13T10:00:00.000Z"},
		{"jobId": "job_h03", "status": "in-progress", "modelId": FLARE, "prompt": "still going", "createdAt": "2026-11-13T09:00:00.000Z"},
		{"jobId": "job_team3d", "status": "success", "modelId": "model_team-3d", "prompt": "a statue", "createdAt": "2026-11-13T08:00:00.000Z"},
		{"jobId": "job_up1", "jobType": "upload", "status": "success", "createdAt": "2026-11-13T07:00:00.000Z"},
		{"jobId": "job_up2", "jobType": "upload", "status": "success", "createdAt": "2026-11-13T06:00:00.000Z"},
	]
	for i in 31:
		jobs.append({"jobId": "job_old%02d" % i, "status": "success", "modelId": FLARE, "prompt": "old %d" % i, "createdAt": "2026-10-01T09:00:00.000Z"})
	return jobs


static func _asset(library: Node, id: String) -> Dictionary:
	for asset in library.assets:
		if asset["id"] == id:
			return asset
	return {}


static func _has_button(box: Node, text: String) -> bool:
	for node in box.find_children("*", "Button", true, false):
		if node.text == text and not node.is_queued_for_deletion():
			return true
	return false


static func _row_with(controller: Controller, asset_id: String) -> Dictionary:
	for row in controller.ledger.jobs:
		if asset_id in row["asset_ids"]:
			return row
	return {}


## The text of a history row's labels.
static func _row_text(library_ui: Node, index: int) -> String:
	var rows: Array = library_ui._history_rows.get_children().filter(func(n: Node) -> bool: return not n.is_queued_for_deletion())
	if index >= rows.size():
		return ""
	var text := ""
	for node in rows[index].find_children("*", "Label", true, false):
		text += node.text + " "
	return text


static func _last_call(fake: Fake, tool: String) -> Dictionary:
	for i in range(fake.calls.size() - 1, -1, -1):
		if fake.calls[i]["tool"] == tool:
			return fake.calls[i]
	return {}


## Opens a copy of the demo scene, so imports never touch the real one.
func open_scratch_scene(path: String) -> Node:
	EditorInterface.get_resource_filesystem().update_file(path)
	for attempt in 30:
		EditorInterface.open_scene_from_path(path)
		await wait_frames(2)
		var current := EditorInterface.get_edited_scene_root()
		if current != null and current.scene_file_path == path:
			return current
	return EditorInterface.get_edited_scene_root()


func _until(condition: Callable, seconds: float = 5.0) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return
		await root.get_tree().process_frame
