@tool
extends RefCounted
## Downloads a finished job's outputs into the project, named and typed, for
## the controller's import. A failure keeps nothing: neither the files already
## moved nor the pending download.

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
