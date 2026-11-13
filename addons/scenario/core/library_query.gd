@tool
extends RefCounted
## The Library and History in the dock: assets_list and jobs_list arguments,
## the rows read back, and the filters applied to them. No editor API,
## unit-tested.
##
## The Library pages through the project's assets newest first with
## assets_list (a catalog tool, run through scenario_tool_execute_read).
## `search` is not used: it counts and pages across every project of the team,
## then narrows each page to one project, so a project's pages come back short
## or empty. Kind, source and text are filtered here, over the rows read, as
## the Photoshop plugin does. History lists jobs with jobs_list. Free reads.

const Lanes := preload("res://addons/scenario/core/lanes.gd")

## Placeable rows to show before Show more.
const PAGE_SIZE := 24
## assets_list rows per request, and requests per Show more at most.
const LIST_LIMIT := 50
const MAX_LIST_PAGES := 5
const HISTORY_PAGE_SIZE := 30
## Thumbnail width asked of Scenario's image transform.
const THUMBNAIL_WIDTH := 192
## A thumbnail larger than this, in bytes or decoded pixels, is not shown: a
## collaborator's upload could otherwise be a tiny file that decodes to gigabytes.
const MAX_THUMBNAIL_BYTES := 4 * 1024 * 1024
const MAX_THUMBNAIL_PIXELS := 4096 * 4096
const KINDS := ["all", "image", "3d", "audio"]
const SOURCES := ["all", "generated", "uploaded"]
## The kinds the dock can place.
const PLACEABLE := ["image", "image-hdr", "3d", "audio"]


## scenario_tool_execute_read arguments for one assets_list page. scope: the
## team and project ({} with an API key); the executor passes on only its
## `parameters`, so they carry it.
static func list_args(page_token: String, scope: Dictionary, limit: int = LIST_LIMIT) -> Dictionary:
	var parameters := {"limit": clampi(limit, 1, 100), "include_urls": true}
	parameters.merge(scope)
	if not page_token.is_empty():
		parameters["page_token"] = page_token
	return {"name": "assets_list", "parameters": parameters}


## {"assets": [row], "next": token} from an assets_list reply; rows the dock
## cannot place (prompt texts, videos, documents) are left out.
static func parse_assets(value: Variant) -> Dictionary:
	var page := {"assets": [], "next": ""}
	if not value is Dictionary:
		return page
	var items: Variant = value.get("assets", [])
	for item in items if items is Array else []:
		var row := asset_row(item)
		if not row.is_empty() and row["kind"] in PLACEABLE:
			page["assets"].append(row)
	page["next"] = text(value.get("nextPaginationToken"))
	return page


## One asset as the dock shows it, or {} without an id:
## {"id", "kind", "name", "prompt", "model_id", "mime", "created_at", "thumbnail", "generated", "uploaded"}
static func asset_row(item: Variant) -> Dictionary:
	if not item is Dictionary or text(item.get("id")).is_empty():
		return {}
	var mime := text(item.get("mimeType"))
	var kind := text(item.get("kind"))
	if kind.is_empty():
		kind = kind_for_mime(mime)
	var model_id := text(item.get("modelId"))
	var prompt := text(item.get("prompt"))
	if prompt.begins_with("asset_"):
		prompt = ""  # the prompt was kept as a text asset: its id says nothing
	var name := text(item.get("name"))
	for fallback in [text(item.get("description")), prompt, text(item["id"])]:
		if name.is_empty():
			name = fallback
	return {
		"id": text(item["id"]), "kind": kind, "name": name, "prompt": prompt, "model_id": model_id, "mime": mime,
		"created_at": text(item.get("createdAt")), "thumbnail": thumbnail_url(item, kind),
		"generated": not model_id.is_empty(), "uploaded": text(item.get("source")).begins_with("uploaded"),
	}


## True when the row passes the dock's filters; query matches its name,
## caption or prompt.
static func matches(row: Dictionary, kind: String, source: String, query: String) -> bool:
	if kind == "image" and not row["kind"] in ["image", "image-hdr"]:
		return false
	if kind in ["3d", "audio"] and row["kind"] != kind:
		return false
	if (source == "generated" and not row["generated"]) or (source == "uploaded" and not row["uploaded"]):
		return false
	query = query.strip_edges().to_lower()
	return query.is_empty() or (str(row["name"]) + " " + str(row["prompt"])).to_lower().contains(query)


## A small picture of an image: Scenario's transform URL with a width (the
## signed policy covers any parameter after p=100), else the file itself,
## which the Library reads only within MAX_THUMBNAIL_BYTES and MAX_THUMBNAIL_PIXELS.
## 3D and audio have none.
static func thumbnail_url(item: Dictionary, kind: String) -> String:
	var url := text(item.get("url"))
	if not kind in ["image", "image-hdr"] or not url.begins_with("https://"):
		return ""
	if url.contains("/assets-transform/") and url.contains("?p=100"):
		return url + "&width=%d&height=auto" % THUMBNAIL_WIDTH
	return url


## An output's kind from its MIME type, else its metadata: Scenario can list a
## GLB as application/octet-stream with a 3D type (as Workflows.download_format reads it).
static func output_kind(asset: Dictionary) -> String:
	var kind := kind_for_mime(text(asset.get("mimeType")))
	var metadata: Variant = asset.get("metadata")
	if kind.is_empty() and metadata is Dictionary and text(metadata.get("type")).contains("3d"):
		return "3d"
	return kind


static func kind_for_mime(mime: String) -> String:
	if mime in ["image/x-exr", "image/vnd.radiance"]:
		return "image-hdr"
	if mime.begins_with("image/"):
		return "image"
	if mime.begins_with("model/"):
		return "3d"
	if mime.begins_with("audio/"):
		return "audio"
	return ""


## A reply's optional string: "" for a missing or null value (str(null) is "<null>").
static func text(value: Variant) -> String:
	return "" if value == null else str(value)


## The lane that places one asset on its own, by its kind or MIME type ("" when
## the dock cannot place it). A material or a 3D model needs the job's other
## files, so a map or a preview image goes to the Image lane; a skybox model's
## panorama still goes to the sky.
static func lane_for(model_id: String, kind: String, mime: String = "") -> String:
	if kind.is_empty():
		kind = kind_for_mime(mime)
	var by_kind: String = {"3d": "model3d", "audio": "sound", "image-hdr": "skybox", "image": "image"}.get(kind, "")
	return "skybox" if by_kind == "image" and model_lane(model_id) == "skybox" else by_kind


## The lane that places a whole job: its model's, else from all its outputs,
## the asset_get replies (a 3D job lists a preview image before the model).
static func lane_for_job(model_id: String, outputs: Array) -> String:
	if not model_lane(model_id).is_empty():
		return model_lane(model_id)
	var lanes: Array = outputs.map(func(asset: Dictionary) -> String: return lane_for("", output_kind(asset)))
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
		var prompt := text(job.get("prompt"))
		page["jobs"].append({
			"job_id": text(job["jobId"]), "model_id": text(job["modelId"]), "prompt": "" if prompt.begins_with("asset_") else prompt,
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


## Width and height read from a PNG, JPEG or WebP header, without decoding;
## Vector2i.ZERO when the header is not understood.
static func image_size(bytes: PackedByteArray) -> Vector2i:
	if bytes.size() >= 24 and bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[12] == 0x49:  # PNG, IHDR first
		return Vector2i(_be32(bytes, 16), _be32(bytes, 20))
	if bytes.size() >= 30 and bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		match bytes.slice(12, 16).get_string_from_ascii():
			"VP8 ":
				return Vector2i((bytes[26] | bytes[27] << 8) & 0x3FFF, (bytes[28] | bytes[29] << 8) & 0x3FFF)
			"VP8L":
				var bits := bytes[21] | bytes[22] << 8 | bytes[23] << 16 | bytes[24] << 24
				return Vector2i((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
			"VP8X":
				return Vector2i((bytes[24] | bytes[25] << 8 | bytes[26] << 16) + 1, (bytes[27] | bytes[28] << 8 | bytes[29] << 16) + 1)
		return Vector2i.ZERO
	if bytes.size() >= 4 and bytes[0] == 0xFF and bytes[1] == 0xD8:  # JPEG: the first start-of-frame
		var i := 2
		while i + 9 < bytes.size():
			if bytes[i] != 0xFF:
				return Vector2i.ZERO
			var marker := bytes[i + 1]
			if marker == 0xFF:
				i += 1  # fill byte
				continue
			if marker >= 0xD0 and marker <= 0xD9 or marker == 0x01:
				i += 2  # no length
				continue
			if marker >= 0xC0 and marker <= 0xCF and not marker in [0xC4, 0xC8, 0xCC]:
				return Vector2i(bytes[i + 7] << 8 | bytes[i + 8], bytes[i + 5] << 8 | bytes[i + 6])
			i += 2 + (bytes[i + 2] << 8 | bytes[i + 3])
	return Vector2i.ZERO


static func _be32(bytes: PackedByteArray, at: int) -> int:
	return bytes[at] << 24 | bytes[at + 1] << 16 | bytes[at + 2] << 8 | bytes[at + 3]
