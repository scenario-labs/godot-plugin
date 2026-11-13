@tool
extends RefCounted
## Scenario workflows as dock entries: a workflow id stands where a model id
## would, its inputs become the form, and its outputs are placed by file type.
##
## workflows_list rows -> {id, name, note} entries; workflow_get's
## inputs_definition -> a schema_form schema; finished outputs -> the lane
## whose importer places them.

const Form := preload("res://addons/scenario/core/schema_form.gd")

## Input types the dock has no widget for. An optional one is left to the
## workflow's default; a required one blocks the price check.
const UNSUPPORTED := ["inputs_array", "number_array", "model_array"]
## API input keys (camelCase) renamed to the schema_form ones.
const _KEYS := {"allowedValues": "allowed_values", "maxLength": "max_length", "costImpact": "cost_impact"}


static func is_workflow(id: String) -> bool:
	return id.begins_with("workflow_")


## Ready workflows from workflows_list rows, as model picker entries.
static func entries(rows: Array, public: bool = false) -> Array:
	var out: Array = []
	for row in rows:
		if not row is Dictionary or not is_workflow(str(row.get("id", ""))):
			continue
		var status := str(row.get("status", row.get("workflowStatus", "ready"))).to_lower()
		if status != "ready":
			continue  # a draft cannot run
		var note := str(row.get("description", "")).strip_edges().get_slice("\n", 0)
		if note.length() > 60:
			note = note.left(57) + "..."
		if public:
			note = "public" if note.is_empty() else "public, " + note
		out.append({"id": str(row["id"]), "name": str(row.get("name", row["id"])), "note": note})
	return out


## workflow_get's record -> {"parameters": [...]} for schema_form, plus
## "unsupported": the names of required inputs the dock cannot fill.
static func schema_from(record: Dictionary) -> Dictionary:
	var inputs: Variant = record.get("inputs_definition", record.get("inputs", []))
	if inputs is Dictionary:
		var listed: Array = []
		for name in inputs:
			if inputs[name] is Dictionary:
				var item: Dictionary = inputs[name].duplicate()
				item["name"] = name
				listed.append(item)
		inputs = listed
	var parameters: Array = []
	var unsupported: PackedStringArray = []
	var prompt_taken := false
	if not inputs is Array:
		inputs = []
	for input in inputs:
		if not input is Dictionary or str(input.get("name", "")).is_empty():
			continue
		var parameter := {}
		for key in input:
			parameter[_KEYS.get(key, key)] = input[key]
		var type := str(parameter.get("type", "string"))
		# truthy(): the API may send these flags as null or as strings.
		if type == "file" and Form.truthy(parameter.get("array")):
			parameter["type"] = "file_array"
		if type in UNSUPPORTED:
			if not Form.truthy(parameter.get("required")):
				continue
			unsupported.append(str(parameter["name"]))
			parameter["type"] = "unsupported"
		# The first text input named like a prompt is the prompt: it labels the job.
		if type == "string" and not prompt_taken and str(parameter["name"]).to_lower().contains("prompt") \
				and not parameter.has("allowed_values"):
			parameter["prompt"] = true
			prompt_taken = true
		parameters.append(parameter)
	return {"model_id": str(record.get("id", "")), "parameters": parameters, "unsupported": unsupported}


## A workflow's files by the lane that places them: a GLB or glTF on the 3D
## lane with the images as its previews (else the images on the Image lane),
## and sounds on the Sound lane. {lane_id: [file, ...]}
static func groups(files: Array) -> Dictionary:
	var models: Array = []
	var sounds: Array = []
	var images: Array = []
	for file in files:
		match str(file["path"]).get_extension().to_lower():
			"glb", "gltf":
				models.append(file)
			"wav", "mp3", "ogg":
				sounds.append(file)
			_:
				images.append(file)
	var out := {}
	if not models.is_empty():
		for image in images:
			image["role"] = "preview"
		out["model3d"] = models + images
	elif not images.is_empty():
		out["image"] = images
	if not sounds.is_empty():
		out["sound"] = sounds
	return out


## The download format to ask for: GLB for a 3D asset, as the 3D lane does;
## "" keeps the original.
static func download_format(asset: Dictionary) -> String:
	var metadata: Variant = asset.get("metadata")
	var type := str(metadata.get("type", "")) if metadata is Dictionary else ""
	return "glb" if str(asset.get("mimeType", "")).begins_with("model/") or type.contains("3d") else ""
