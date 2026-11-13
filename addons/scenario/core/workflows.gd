@tool
extends RefCounted
## Scenario workflows as dock entries: a workflow id stands where a model id
## would, its inputs become the form, and its outputs are placed by file type.
##
## workflows_list rows -> {id, name, note} entries; workflow_get's
## inputs_definition -> a schema_form schema; finished outputs -> the lane
## whose importer places them.

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
		if type == "file" and bool(parameter.get("array", false)):
			parameter["type"] = "file_array"
		if type in UNSUPPORTED:
			if not bool(parameter.get("required", false)):
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


## The lane whose importer places a workflow's files: a GLB or glTF makes it
## 3D (images then are its previews), sound makes it audio, else images.
## Sets each file's role to match.
static func place_lane(files: Array) -> String:
	var exts: Array = files.map(func(f: Dictionary) -> String: return str(f["path"]).get_extension().to_lower())
	if exts.has("glb") or exts.has("gltf"):
		for file in files:
			if not str(file["path"]).get_extension().to_lower() in ["glb", "gltf"]:
				file["role"] = "preview"
		return "model3d"
	if exts.any(func(e: String) -> bool: return e in ["wav", "mp3", "ogg"]):
		return "sound"
	return "image"
