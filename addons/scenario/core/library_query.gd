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
static func parse_page(value: Variant) -> Dictionary:
	var page := {"assets": [], "total": 0, "offset": 0}
	if not value is Dictionary:
		return page
	for hit in value.get("assets", value.get("hits", [])):
		var row := asset_row(hit)
		if not row.is_empty():
			page["assets"].append(row)
	page["total"] = int(value.get("estimatedTotalHits", value.get("totalHits", page["assets"].size())))
	page["offset"] = int(value.get("offset", 0))
	return page


## One asset as the dock shows it, or {} for a hit without an id:
## {"id", "kind", "name", "prompt", "model_id", "mime", "created_at", "thumbnail", "generated"}
static func asset_row(hit: Variant) -> Dictionary:
	if not hit is Dictionary or str(hit.get("id", "")).is_empty():
		return {}
	var metadata: Dictionary = hit.get("metadata") if hit.get("metadata") is Dictionary else {}
	var model_id := str(hit.get("modelId", metadata.get("modelId", "")))
	var prompt := str(hit.get("prompt", metadata.get("prompt", "")))
	var name := str(hit.get("name", ""))
	if name.is_empty() or name == "<null>":
		name = prompt if not prompt.is_empty() else str(hit["id"])
	return {
		"id": str(hit["id"]), "kind": str(hit.get("kind", "")), "name": name, "prompt": prompt,
		"model_id": model_id, "mime": str(hit.get("mimeType", "")), "created_at": str(hit.get("createdAt", "")),
		"thumbnail": thumbnail_url(hit), "generated": not model_id.is_empty(),
	}


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


## The lane whose importer places this output: the lane of a known model,
## else by kind or MIME type ("" when the dock cannot place it). single: one
## asset on its own, which a material (a set of maps) cannot be built from.
static func lane_for(model_id: String, kind: String, mime: String = "", single: bool = false) -> String:
	for lane in Lanes.LANES:
		if single and lane["importer"] == "material":
			continue
		for model in lane["models"]:
			if model["id"] == model_id and not model_id.is_empty():
				return lane["id"]
	if kind == "3d" or mime.begins_with("model/"):
		return "model3d"
	if kind == "audio" or mime.begins_with("audio/"):
		return "sound"
	if kind == "image-hdr" or mime in ["image/x-exr", "image/vnd.radiance"]:
		return "skybox"
	if kind == "image" or mime.begins_with("image/"):
		return "image"
	return ""


## {"jobs": [row], "next": token} from a jobs_list reply. A row:
## {"job_id", "model_id", "prompt", "status", "created_at", "finished"}
static func parse_history(value: Variant) -> Dictionary:
	var page := {"jobs": [], "next": ""}
	if not value is Dictionary:
		return page
	for job in value.get("jobs", []):
		if not job is Dictionary or str(job.get("jobId", "")).is_empty():
			continue
		var status := str(job.get("status", ""))
		page["jobs"].append({
			"job_id": str(job["jobId"]), "model_id": str(job.get("modelId", "")), "prompt": str(job.get("prompt", "")),
			"status": status, "created_at": str(job.get("createdAt", "")),
			"finished": status.to_lower() in ["success", "succeeded", "completed"],
		})
	page["next"] = str(value.get("nextPaginationToken", ""))
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
