@tool
extends RefCounted
## Transfers for the controller: a finished job's outputs downloaded into the
## project, named and typed (a failure keeps nothing: neither the files already
## moved nor the pending download), and a reference file uploaded to Scenario.

const Files := preload("res://addons/scenario/core/files.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Workflows := preload("res://addons/scenario/core/workflows.gd")


## row: the ledger row; scope: the project its job ran in; model_name: for
## messages. Returns {"files": [{path, role}], "assets": [...], "problem": ""}.
static func fetch(client: Object, transport: Object, row: Dictionary, scope: Dictionary, output_root: String, model_name: String) -> Dictionary:
	var lane := Lanes.lane(row["lane"])
	var files: Array = []
	var assets: Array = []
	var problem := ""
	var pending := ""  # a download not yet moved into the project
	var date := Files.today()
	for asset_id in row["asset_ids"]:
		var asset_result: Dictionary = await client.get_asset(asset_id, scope)
		if not asset_result["ok"]:
			problem = asset_result["error"]["message"]
			break
		var asset: Dictionary = asset_result["value"]
		var role := Files.role_for(asset)
		# A workflow's lane is known per file: its 3D outputs are asked for as GLB, like the 3D lane's.
		var format: String = Workflows.download_format(asset) if row["lane"] == Lanes.WORKFLOW else str(lane.get("download_format", ""))
		var url_result: Dictionary = await client.download_url(asset_id, format, scope)
		if not url_result["ok"]:
			problem = url_result["error"]["message"]
			break
		var temp := "%s/%s.download" % [Files.DOWNLOADS, asset_id]
		var downloaded: Dictionary = await transport.download(url_result["value"], temp)
		if not downloaded["ok"]:
			problem = downloaded["error"]
			break
		pending = temp
		var ext := Files.sniff_extension(Files.head(temp))
		if ext.is_empty():
			ext = Files.extension_for_mime(str(asset.get("mimeType", "")))
		if not ext in Files.IMPORTABLE:
			problem = "Scenario returned a file Godot cannot import (%s)." % str(asset.get("mimeType", "unknown type"))
			break
		if not Lanes.accepts(row["lane"], ext):
			problem = "%s returned a %s file, which the %s lane cannot place. Pick one of the lane's own models." % [model_name, ext.to_upper(), lane["title"]]
			break
		if lane["importer"] == "model3d" and ext in ["png", "jpg", "webp"]:
			role = "preview"  # 3D models come with a thumbnail next to the GLB
		var final_path := Files.base_path(row["lane"], row["prompt"], asset_id, role, date, output_root) + "." + ext
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
		problem = "%s returned no GLB or glTF model, which the 3D lane needs. Pick one of the lane's own models." % model_name
	if not problem.is_empty():
		for item in files:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(item["path"]))
		if not pending.is_empty():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(pending))
		files = []
	return {"files": files, "assets": assets, "problem": problem}


## Uploads a reference file in the parts Scenario asks for. Free (no CU).
## type: Files.upload_type(). Returns {"asset_id", "problem"}; one is empty.
static func upload(client: Object, transport: Object, file_name: String, type: Dictionary, bytes: PackedByteArray) -> Dictionary:
	var start: Dictionary = await client.upload_start(file_name, type["mime"], type["kind"], bytes.size())
	if not start["ok"]:
		return {"asset_id": "", "problem": start["error"]["message"]}
	var part_size := int(start["value"].get("part_size", bytes.size()))
	for part in start["value"].get("parts", []):
		var index := int(part.get("part_number", 1)) - 1
		var chunk := bytes.slice(index * part_size, mini((index + 1) * part_size, bytes.size()))
		var put: Dictionary = await transport.put_bytes(str(part.get("upload_url", "")), chunk)
		if not put["ok"]:
			return {"asset_id": "", "problem": put["error"]}
	var done: Dictionary = await client.upload_complete({"upload_id": start["value"].get("upload_id", "")})
	if done["ok"] and str(done["value"].get("asset_id", "")).begins_with("asset_"):
		return {"asset_id": done["value"]["asset_id"], "problem": ""}
	return {"asset_id": "", "problem": done["error"]["message"] if not done["ok"] else "Scenario did not finish the upload."}
