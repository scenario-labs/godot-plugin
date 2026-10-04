@tool
extends RefCounted
## Durable job ledger: survives editor restarts.
##
## The intent is written with state "submitting" BEFORE the paid request is
## sent. A row still "submitting" when the ledger loads means the editor
## stopped mid-request: it becomes "unknown" and blocks the same request until
## it is matched to a Scenario job or dismissed by the user.

const Errors := preload("res://addons/scenario/core/errors.gd")

const SUBMITTING := "submitting"
const QUEUED := "queued"
const RUNNING := "running"
const SUCCESS := "success"
const FAILED := "failed"
const BLOCKED := "blocked"
const CANCEL_REQUESTED := "cancel_requested"
const CANCELED := "canceled"
const UNKNOWN := "unknown"
const REJECTED := "rejected"
const DISMISSED := "dismissed"

const ACTIVE_STATES := [QUEUED, RUNNING, CANCEL_REQUESTED]
const UNRESOLVED_STATES := [SUBMITTING, UNKNOWN]
const FINAL_STATES := [SUCCESS, FAILED, BLOCKED, CANCELED, REJECTED, DISMISSED]
const MAX_ROWS := 200
## A server job counts as the match of an unknown row if created this close after the intent.
const RECONCILE_WINDOW_S := 180.0
const FORMAT_VERSION := 1

var path := ""
var jobs: Array = []
var _counter := 0


func _init(p_path: String = "") -> void:
	path = p_path


func load_from_disk() -> void:
	jobs = []
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		push_warning("Scenario: the job ledger could not be read and was set aside: " + path)
		DirAccess.rename_absolute(path, path + ".unreadable")
		return
	var rows: Variant = json.data.get("jobs", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and row.has("local_id"):
				if row.get("state") == SUBMITTING:
					row["state"] = UNKNOWN
					row["error"] = "The editor closed while this request was being sent. It may have started on Scenario."
				jobs.append(row)


func save() -> bool:
	if path.is_empty():
		return true
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		push_warning("Scenario: could not write the job ledger: " + tmp)
		return false
	file.store_string(JSON.stringify({"version": FORMAT_VERSION, "jobs": jobs}, "\t"))
	file.close()
	return DirAccess.rename_absolute(tmp, path) == OK


func add_intent(lane: String, model_id: String, parameters: Dictionary, fingerprint: String,
		quoted_cu: float, now: float) -> String:
	_counter += 1
	var local_id := "local_%d_%d" % [int(now * 1000.0), _counter]
	var row := {
		"local_id": local_id, "job_id": "", "state": SUBMITTING, "lane": lane, "model_id": model_id,
		"prompt": str(parameters.get("prompt", "")), "parameters": parameters, "fingerprint": fingerprint,
		"quoted_cu": quoted_cu, "charged_cu": null, "asset_ids": [], "files": [], "imported": false,
		"error": "", "created_at": now, "updated_at": now,
	}
	jobs.push_front(row)
	_trim()
	save()
	return local_id


func mark_submitted(local_id: String, job_id: String, server_status: String, now: float) -> void:
	var row := find(local_id)
	if row.is_empty():
		return
	row["job_id"] = job_id
	row["state"] = state_for_status(server_status, "")
	row["updated_at"] = now
	save()


## Scenario answered with a clear refusal: nothing ran, nothing was charged.
func mark_rejected(local_id: String, message: String, now: float) -> void:
	_set_state(local_id, REJECTED, message, now)


func mark_unknown(local_id: String, message: String, now: float) -> void:
	_set_state(local_id, UNKNOWN, message, now)


func mark_cancel_requested(local_id: String, now: float) -> void:
	var row := find(local_id)
	if not row.is_empty() and row["state"] in ACTIVE_STATES:
		_set_state(local_id, CANCEL_REQUESTED, "", now)


func dismiss(local_id: String, now: float) -> void:
	_set_state(local_id, DISMISSED, "", now)


func mark_imported(local_id: String, files: Array, now: float) -> void:
	var row := find(local_id)
	if row.is_empty():
		return
	row["files"] = files
	row["imported"] = true
	row["updated_at"] = now
	save()


func set_error(local_id: String, message: String, now: float) -> void:
	var row := find(local_id)
	if row.is_empty():
		return
	row["error"] = message
	row["updated_at"] = now
	save()


## Applies a compact job row from job_get or jobs_wait. Returns the ledger row or {}.
func apply_job(job: Dictionary, now: float) -> Dictionary:
	var job_id := str(job.get("jobId", job.get("id", "")))
	var row := find_by_job(job_id)
	if row.is_empty():
		return {}
	var error_text := str(job.get("error", ""))
	var state := state_for_status(str(job.get("status", "")), error_text)
	if row["state"] == CANCEL_REQUESTED and state in [QUEUED, RUNNING]:
		state = CANCEL_REQUESTED  # the status changes only when Scenario reports it
	row["state"] = state
	if job.has("assetIds") and job["assetIds"] is Array:
		row["asset_ids"] = job["assetIds"]
	if job.has("cuCost"):
		row["charged_cu"] = float(job["cuCost"])
	elif job.get("billing") is Dictionary and job["billing"].has("cuCost"):
		row["charged_cu"] = float(job["billing"]["cuCost"])
	if not error_text.is_empty():
		row["error"] = error_text
	row["updated_at"] = now
	save()
	return row


## Links unresolved rows to jobs found on Scenario. Returns how many were linked.
## Only an unambiguous match (exactly one untracked job of the same model in the
## window after the intent) is linked; anything else stays for the user.
func reconcile(server_jobs: Array, now: float) -> int:
	var linked := 0
	for row in jobs:
		if not row["state"] in UNRESOLVED_STATES:
			continue
		var candidates: Array = []
		for job in server_jobs:
			if not job is Dictionary or str(job.get("modelId", "")) != row["model_id"]:
				continue
			var job_id := str(job.get("jobId", ""))
			if job_id.is_empty() or not find_by_job(job_id).is_empty():
				continue
			var created := iso_to_unix(str(job.get("createdAt", "")))
			if created < 0.0:
				continue
			var delta := created - float(row["created_at"])
			if delta >= -5.0 and delta <= RECONCILE_WINDOW_S:
				candidates.append(job)
		if candidates.size() == 1:
			row["job_id"] = str(candidates[0]["jobId"])
			row["error"] = ""
			row["state"] = state_for_status(str(candidates[0].get("status", "")), str(candidates[0].get("error", "")))
			row["updated_at"] = now
			linked += 1
	if linked > 0:
		save()
	return linked


func find(local_id: String) -> Dictionary:
	for row in jobs:
		if row["local_id"] == local_id:
			return row
	return {}


func find_by_job(job_id: String) -> Dictionary:
	if job_id.is_empty():
		return {}
	for row in jobs:
		if row["job_id"] == job_id:
			return row
	return {}


func active() -> Array:
	return jobs.filter(func(row: Dictionary) -> bool: return row["state"] in ACTIVE_STATES and not str(row["job_id"]).is_empty())


func unresolved() -> Array:
	return jobs.filter(func(row: Dictionary) -> bool: return row["state"] in UNRESOLVED_STATES)


## True when an unresolved row holds the same request: sending it again could pay twice.
func blocks(fingerprint: String) -> bool:
	for row in jobs:
		if row["state"] in UNRESOLVED_STATES and row["fingerprint"] == fingerprint:
			return true
	return false


static func state_for_status(status: String, error_text: String) -> String:
	match status.to_lower():
		"success", "succeeded", "completed":
			return SUCCESS
		"failure", "failed", "error":
			return BLOCKED if Errors.is_moderated(error_text) else FAILED
		"canceled", "cancelled":
			return CANCELED
		"queued", "pending":
			return QUEUED
		_:
			return RUNNING


## "2026-10-04T09:10:52.353Z" to Unix seconds, or -1.0.
static func iso_to_unix(text: String) -> float:
	if text.length() < 19:
		return -1.0
	var fraction := 0.0
	var dot := text.find(".")
	if dot != -1:
		var digits := ""
		for i in range(dot + 1, text.length()):
			if text[i].is_valid_int():
				digits += text[i]
			else:
				break
		if not digits.is_empty():
			fraction = ("0." + digits).to_float()
	var seconds := Time.get_unix_time_from_datetime_string(text.substr(0, 19))
	return float(seconds) + fraction


func _set_state(local_id: String, state: String, message: String, now: float) -> void:
	var row := find(local_id)
	if row.is_empty():
		return
	row["state"] = state
	row["error"] = message
	row["updated_at"] = now
	save()


func _trim() -> void:
	while jobs.size() > MAX_ROWS:
		var dropped := false
		for i in range(jobs.size() - 1, -1, -1):
			if jobs[i]["state"] in FINAL_STATES:
				jobs.remove_at(i)
				dropped = true
				break
		if not dropped:
			return
