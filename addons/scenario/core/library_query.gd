@tool
extends RefCounted
## The Library and History in the dock: search arguments, and the rows read
## back from Scenario's search and jobs_list. No editor API, unit-tested.
##
## The Library lists the project's assets newest first through `search`
## (assets_list strips thumbnails); History lists its jobs through jobs_list.
## Both are free reads.

const Lanes := preload("res://addons/scenario/core/lanes.gd")

const PAGE_SIZE := 24
const HISTORY_PAGE_SIZE := 30
## The kinds the dock can place, by filter. "all" is every placeable kind.
const KINDS := {
	"all": ["image", "image-hdr", "3d", "audio"],
	"image": ["image", "image-hdr"],
	"3d": ["3d"],
	"audio": ["audio"],
}
const SOURCES := ["all", "generated", "uploaded"]


## Arguments for the `search` tool: one page of the project's assets, newest
## first. query searches names, prompts and captions.
static func search_args(kind: String, source: String, query: String, offset: int, limit: int = PAGE_SIZE) -> Dictionary:
	var kinds: Array = KINDS.get(kind, KINDS["all"])
	var parts := PackedStringArray()
	parts.append("kind = \"%s\"" % kinds[0] if kinds.size() == 1 else "kind IN [%s]" % ", ".join(kinds.map(func(k: String) -> String: return "\"%s\"" % k)))
	# Generated assets carry the model that made them; uploads do not.
	if source == "generated":
		parts.append("modelId EXISTS")
	elif source == "uploaded":
		parts.append("NOT modelId EXISTS")
	var args := {
		"target": "assets", "filter": " AND ".join(parts), "limit": clampi(limit, 1, 100),
		"offset": maxi(offset, 0), "include_urls": true,
	}
	query = query.strip_edges()
	if query.is_empty():
		args["sort_by"] = ["createdAt:desc"]  # a text search ranks by relevance instead
	else:
		args["query"] = query
	return args


## {"assets": [row], "total": int, "offset": int} from a search reply.
## total is -1 when the reply gives none: a full page then means more may follow.
static func parse_page(value: Variant) -> Dictionary:
	var page := {"assets": [], "total": -1, "offset": 0, "hits": 0}
	if not value is Dictionary:
		return page
	var hits: Variant = value.get("assets", value.get("hits", []))
	for hit in hits if hits is Array else []:
		page["hits"] += 1
		var row := asset_row(hit)
		if not row.is_empty():
			page["assets"].append(row)
	for key in ["estimatedTotalHits", "totalHits"]:
		if value.get(key) is float or value.get(key) is int:
			page["total"] = int(value[key])
			break
	page["offset"] = int(value.get("offset", 0)) if value.get("offset") != null else 0
	return page


## One asset as the dock shows it, or {} for a hit without an id:
## {"id", "kind", "name", "prompt", "model_id", "mime", "created_at", "thumbnail", "generated"}
static func asset_row(hit: Variant) -> Dictionary:
	if not hit is Dictionary or text(hit.get("id")).is_empty():
		return {}
	var metadata: Dictionary = hit.get("metadata") if hit.get("metadata") is Dictionary else {}
	var model_id := text(hit.get("modelId", metadata.get("modelId")))
	var prompt := text(hit.get("prompt", metadata.get("prompt")))
	var name := text(hit.get("name"))
	if name.is_empty():
		name = prompt if not prompt.is_empty() else text(hit["id"])
	return {
		"id": text(hit["id"]), "kind": text(hit.get("kind")), "name": name, "prompt": prompt,
		"model_id": model_id, "mime": text(hit.get("mimeType")), "created_at": text(hit.get("createdAt")),
		"thumbnail": thumbnail_url(hit), "generated": not model_id.is_empty(),
	}


## A reply's optional string: "" for a missing or null value (str(null) is "<null>").
static func text(value: Variant) -> String:
	return "" if value == null else str(value)


## The hit's thumbnail URL ("" if none). Images without a thumbnail use the
## file itself; 3D and audio have no picture then.
static func thumbnail_url(hit: Dictionary) -> String:
	var thumbnail: Variant = hit.get("thumbnail")
	if thumbnail is Dictionary:
		thumbnail = thumbnail.get("url", "")
	if thumbnail is String and thumbnail.begins_with("https://"):
		return thumbnail
	var url: Variant = hit.get("url")
	if url is String and url.begins_with("https://") and str(hit.get("kind", "")) == "image":
		return url
	return ""


## The lane that places one asset on its own, by its kind or MIME type ("" when
## the dock cannot place it). A material or a 3D model needs the job's other
## files, so a map or a preview image goes to the Image lane; a skybox model's
## panorama still goes to the sky.
static func lane_for(model_id: String, kind: String, mime: String = "") -> String:
	var by_kind := ""
	if kind == "3d" or mime.begins_with("model/"):
		by_kind = "model3d"
	elif kind == "audio" or mime.begins_with("audio/"):
		by_kind = "sound"
	elif kind == "image-hdr" or mime in ["image/x-exr", "image/vnd.radiance"]:
		by_kind = "skybox"
	elif kind == "image" or mime.begins_with("image/"):
		by_kind = "image"
	return "skybox" if by_kind == "image" and model_lane(model_id) == "skybox" else by_kind


## The lane that places a whole job: its model's, else from all its outputs
## (a 3D job lists a preview image before the model).
static func lane_for_job(model_id: String, mimes: Array) -> String:
	if not model_lane(model_id).is_empty():
		return model_lane(model_id)
	var lanes: Array = mimes.map(func(mime: String) -> String: return lane_for("", "", mime))
	for preferred in ["model3d", "sound", "skybox", "image"]:
		if preferred in lanes:
			return preferred
	return ""


## The lane listing this model, or "".
static func model_lane(model_id: String) -> String:
	for lane in Lanes.LANES:
		for model in lane["models"]:
			if model["id"] == model_id and not model_id.is_empty():
				return lane["id"]
	return ""


## {"jobs": [row], "next": token} from a jobs_list reply. A row:
## {"job_id", "model_id", "prompt", "status", "created_at", "finished"}.
## Only generations are kept: uploads and other jobs without a model are not
## results to import.
static func parse_history(value: Variant) -> Dictionary:
	var page := {"jobs": [], "next": ""}
	if not value is Dictionary:
		return page
	var jobs: Variant = value.get("jobs", [])
	for job in jobs if jobs is Array else []:
		if not job is Dictionary or text(job.get("jobId")).is_empty() or text(job.get("modelId")).is_empty():
			continue
		var status := text(job.get("status"))
		page["jobs"].append({
			"job_id": text(job["jobId"]), "model_id": text(job["modelId"]), "prompt": text(job.get("prompt")),
			"status": status, "created_at": text(job.get("createdAt")),
			"finished": status.to_lower() in ["success", "succeeded", "completed"],
		})
	page["next"] = text(value.get("nextPaginationToken"))
	return page


## The lane list's name for a model, else its id without the "model_" prefix.
static func model_name(model_id: String) -> String:
	for lane in Lanes.LANES:
		for model in lane["models"]:
			if model["id"] == model_id:
				return model["name"]
	return model_id.trim_prefix("model_")


## "2026-11-13 14:05" from an ISO date (UTC, as Scenario stores it).
static func date_text(iso: String) -> String:
	return iso.substr(0, 16).replace("T", " ") if iso.length() >= 16 else iso
