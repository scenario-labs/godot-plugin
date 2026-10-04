extends Node
## A fake Scenario backend for editor tests: routes MCP tools by name, serves
## downloads from tests/assets, and counts every paid call. Same interface as
## addons/scenario/editor/http_transport.gd.

const FIXTURES := "res://tests/fixtures/"
const ASSETS := "res://tests/assets/"

## Price returned by every estimate.
var price := 2
## asset id -> {"file": tests/assets name, "mime": ..., "type": metadata.type}
const OUTPUTS := {
	"image": [{"id": "asset_img001", "file": "image.bin", "mime": "image/png", "type": "inference-txt2img"}],
	# Like Rodin: a thumbnail first, then the GLB (2026-10-04 live run).
	"model3d": [
		{"id": "asset_glbprv", "file": "image.bin", "mime": "image/png", "type": "inference-txt23d"},
		{"id": "asset_glb001", "file": "model.bin", "mime": "model/gltf-binary", "type": "inference-txt23d"},
	],
	"material": [
		{"id": "asset_pat000", "file": "patina_base.bin", "mime": "image/png", "type": "inference-txt2img-texture"},
		{"id": "asset_pat001", "file": "patina_albedo.bin", "mime": "image/png", "type": "texture-albedo"},
		{"id": "asset_pat002", "file": "patina_normal.bin", "mime": "image/png", "type": "texture-normal"},
		{"id": "asset_pat003", "file": "patina_smooth.bin", "mime": "image/png", "type": "texture-smoothness"},
		{"id": "asset_pat004", "file": "patina_metal.bin", "mime": "image/png", "type": "texture-metallic"},
		{"id": "asset_pat005", "file": "patina_height.bin", "mime": "image/png", "type": "texture-height"},
	],
	"skybox": [{"id": "asset_sky001", "file": "sky.bin", "mime": "image/jpeg", "type": "skybox-base-360"}],
	"sound": [{"id": "asset_snd001", "file": "sound.bin", "mime": "audio/mpeg", "type": "txt2audio"}],
}
const MODEL_LANE := {
	"model_openai-gpt-image-2-5-flare": "image",
	"model_rodin-hyper3d-v2-5-text-to-3d": "model3d",
	"model_patina-material": "material",
	"model_scenario-skybox-gpt": "skybox",
	"model_sonilo-v1-1-text-to-sound-effects": "sound",
}

var paid_calls: Array = []
var estimates := 0
var tool_log: Array = []
var _jobs := {}


func post(_url: String, _headers: PackedStringArray, body: String, _timeout_s: float) -> Dictionary:
	var payload: Dictionary = JSON.parse_string(body)
	var method := str(payload.get("method", ""))
	if method == "initialize":
		return _reply(payload["id"], {"protocolVersion": "2025-03-26", "capabilities": {}})
	if method == "notifications/initialized":
		return {"status": 202, "headers": {}, "body": "", "error": ""}
	var tool: String = payload["params"]["name"]
	var args: Dictionary = payload["params"]["arguments"]
	tool_log.append(tool)
	match tool:
		"model_schema_get":
			return _reply(payload["id"], _tool(_schema(str(args["model_id"]))))
		"model_run":
			if args.get("dry_run", false):
				estimates += 1
				return _reply(payload["id"], _tool({"dry_run": true, "model_id": args["model_id"], "job": {}, "creativeUnitsCost": price, "creativeUnitsDiscount": 0}))
			paid_calls.append(args)
			var job_id := "job_fake_%d" % paid_calls.size()
			_jobs[job_id] = MODEL_LANE.get(str(args["model_id"]), "image")
			return _reply(payload["id"], _tool({"model_id": args["model_id"], "job_id": job_id, "status": "queued"}))
		"job_get":
			var lane: String = _jobs.get(str(args["job_id"]), "image")
			var ids: Array = OUTPUTS[lane].map(func(o: Dictionary) -> String: return o["id"])
			return _reply(payload["id"], _tool({"job": {"jobId": args["job_id"], "status": "success", "progress": 1, "assetIds": ids, "cuCost": price}}))
		"jobs_list":
			return _reply(payload["id"], _tool({"jobs": []}))
		"asset_get":
			var output := _output(str(args["asset_id"]))
			return _reply(payload["id"], _tool({"asset": {"id": args["asset_id"], "mimeType": output["mime"], "metadata": {"type": output["type"]}}}))
		"asset_download":
			return _reply(payload["id"], _tool({"url": "https://cdn.cloud.scenario.com/test/" + str(args["asset_id"])}))
	return _reply(payload["id"], {"content": [{"type": "text", "text": "unknown tool " + tool}], "isError": true})


func download(url: String, dest_path: String, _timeout_s: float = 600.0) -> Dictionary:
	var asset_id := url.get_file()
	var output := _output(asset_id)
	var bytes := FileAccess.get_file_as_bytes(ASSETS + output["file"])
	var absolute := ProjectSettings.globalize_path(dest_path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file := FileAccess.open(absolute, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	return {"ok": true, "path": dest_path, "error": ""}


func put_bytes(_url: String, _bytes: PackedByteArray, _timeout_s: float = 300.0) -> Dictionary:
	return {"ok": true}


func sleep(_seconds: float) -> void:
	pass


func _output(asset_id: String) -> Dictionary:
	for lane in OUTPUTS:
		for output in OUTPUTS[lane]:
			if output["id"] == asset_id:
				return output
	return OUTPUTS["image"][0]


func _schema(model_id: String) -> Dictionary:
	var fixture := ""
	if model_id == "model_openai-gpt-image-2-5-flare":
		fixture = "schema_flare"
	elif model_id == "model_patina-material":
		fixture = "schema_patina"
	if not fixture.is_empty():
		var text := FileAccess.get_file_as_string(FIXTURES + fixture + ".sse")
		for line in text.split("\n"):
			if line.begins_with("data:"):
				return JSON.parse_string(line.substr(5))["result"]["structuredContent"]
	return {"model_id": model_id, "parameters": [
		{"name": "prompt", "type": "string", "required": true, "prompt": true},
		{"name": "seed", "type": "number"},
	]}


static func _tool(structured: Dictionary) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(structured)}], "structuredContent": structured}


static func _reply(id: Variant, result: Dictionary) -> Dictionary:
	var message := {"jsonrpc": "2.0", "id": id, "result": result}
	return {"status": 200, "headers": {"content-type": "text/event-stream", "mcp-session-id": "s"},
		"body": "event: message\ndata: %s\n\n" % JSON.stringify(message), "error": ""}
