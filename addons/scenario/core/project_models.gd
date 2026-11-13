@tool
extends RefCounted
## The project's own models (private, trained) for the dock's model lists.
##
## Read once per project with models_list and kept until the project changes.
## A model runs by its own id when its schema has parameters. A LoRA or a
## composition never does: model_schema_get names its base model (run_with),
## and the request goes to that base with the wiring merged in, plus the LoRA
## weight the person sets.

## The lanes a project model joins, by the capabilities it lists.
const LANE_CAPABILITIES := {
	"image": ["txt2img", "img2img"],
	"model3d": ["txt23d", "img23d"],
	"sound": ["txt2audio"],
}
## Base-model inputs the wiring sets: not shown in the form.
const WIRING := ["loras", "lorasScale", "modelId"]
## The form field for a LoRA's weight, sent as lorasScale.
const WEIGHT_FIELD := "lora_weight"
const DEFAULT_WEIGHT := 0.75

## [{"id", "name", "note", "lanes"}]
var entries: Array = []
var loading := false
var loaded := false
var error := ""
var _serial := 0


func clear() -> void:
	_serial += 1  # a read still running is dropped
	entries = []
	loading = false
	loaded = false
	error = ""


## Reads the list. client: the MCP client (its session picks the project).
func load(client: Object) -> void:
	_serial += 1
	var serial := _serial
	loading = true
	error = ""
	var result: Dictionary = await client.list_project_models()
	if serial != _serial:
		return
	loading = false
	loaded = true
	if not result["ok"]:
		error = str(result["error"]["message"])
		return
	entries = []
	for record in result["value"]:
		var entry := entry_for(record)
		if not entry.is_empty():
			entries.append(entry)


func for_lane(lane_id: String) -> Array:
	return entries.filter(func(e: Dictionary) -> bool: return lane_id in e["lanes"])


## A list row from a models_list record, {} when no lane can use it.
static func entry_for(record: Variant) -> Dictionary:
	if not record is Dictionary or not str(record.get("id", "")).begins_with("model_"):
		return {}
	var capabilities: Array = record.get("capabilities") if record.get("capabilities") is Array else []
	var lanes: Array = []
	for lane_id in LANE_CAPABILITIES:
		if LANE_CAPABILITIES[lane_id].any(func(c: String) -> bool: return c in capabilities):
			lanes.append(lane_id)
	if lanes.is_empty():
		return {}
	var type := str(record.get("type", ""))
	var note := "project model"
	if type.ends_with("-lora"):
		note = "project LoRA"
	elif type.ends_with("-composition"):
		note = "project composition"
	return {"id": str(record["id"]), "name": str(record.get("name", record["id"])), "note": note, "lanes": lanes}


## How a model runs, from its model_schema_get reply: {} when by its own id,
## else {"id", "base", "runs_as", "wiring"} to send to the base instead.
static func plan(id: String, schema: Dictionary) -> Dictionary:
	var run_with: Variant = schema.get("run_with")
	if not run_with is Dictionary or not run_with.get("required_arguments") is Dictionary:
		return {}
	var required: Dictionary = run_with["required_arguments"]
	var base := str(required.get("model_id", ""))
	if base.is_empty():
		return {}
	var wiring: Variant = required.get("parameters", {})
	return {"id": id, "base": base, "runs_as": str(schema.get("runs_as", "lora")),
		"wiring": wiring if wiring is Dictionary else {}}


## The schema the form shows: the wiring inputs left out and, for a LoRA, a
## weight in their place (with the base's lorasScale limits when it has them).
static func form_schema(schema: Dictionary, run: Dictionary) -> Dictionary:
	if run.is_empty():
		return schema
	var parameters: Array = []
	var scale := {}
	for parameter in schema.get("parameters", []):
		if parameter is Dictionary and str(parameter.get("name", "")) in WIRING:
			if parameter["name"] == "lorasScale":
				scale = parameter
			continue
		parameters.append(parameter)
	if run["runs_as"] == "lora":
		parameters.append({"name": WEIGHT_FIELD, "label": "LoRA weight", "type": "number", "default": DEFAULT_WEIGHT, "step": 0.05,
			"min": scale.get("min", 0.0), "max": scale.get("max", 2.0),
			"description": "How strongly the LoRA shapes the result."})
	var out := schema.duplicate()
	out["parameters"] = parameters
	return out


## What a rerun puts back in the form: the trained model's own id (read from
## the wiring sent to its base) and the values, the weight back from lorasScale.
static func rerun_of(model_id: String, parameters: Dictionary) -> Dictionary:
	var values := parameters.duplicate()
	var id := model_id
	var loras: Variant = values.get("loras")
	if loras is Array and loras.size() == 1:
		id = str(loras[0])
		var scale: Variant = values.get("lorasScale")
		if scale is Array and scale.size() == 1:
			values[WEIGHT_FIELD] = scale[0]
	elif values.get("modelId") is String:
		id = values["modelId"]
	if id != model_id:
		for name in WIRING:
			values.erase(name)
	return {"model_id": id, "values": values}


## The model_run parameters: the form's values with the wiring merged in and
## the weight sent as lorasScale. form_payload is returned as is without a run.
static func run_payload(run: Dictionary, form_payload: Dictionary) -> Dictionary:
	if run.is_empty():
		return form_payload
	var out := form_payload.duplicate()
	var weight: Variant = out.get(WEIGHT_FIELD)
	out.erase(WEIGHT_FIELD)
	out.merge(run["wiring"], true)
	if run["runs_as"] == "lora" and weight != null:
		out["lorasScale"] = [float(weight)]
	return out
