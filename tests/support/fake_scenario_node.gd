extends Node
## A fake Scenario backend for editor tests: routes MCP tools by name, serves
## downloads from tests/assets, and counts every paid call. Answers the
## identity provider's OAuth endpoints too (any URL with /oauth/). Same
## interface as addons/scenario/editor/http_transport.gd.

const Loopback := preload("res://addons/scenario/core/loopback.gd")
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

## What teams_list returns.
var teams: Array = [
	{"id": "team_a", "name": "Team A", "projects": [{"id": "proj_a1", "name": "Game A"}, {"id": "proj_a2", "name": "Game B"}]},
	{"id": "team_b", "name": "Team B", "projects": [{"id": "proj_b1", "name": "Jam"}]},
]
## What models_list (privacy private, status trained) returns, three per page.
## Shaped like the MCP's records: heavy fields stripped.
var project_models: Array = [
	{"id": "model_projhero01", "name": "Hero Character", "type": "flux.1-lora", "privacy": "private", "status": "trained",
		"capabilities": ["txt2img", "img2img"], "compliantModelIds": ["flux.1-dev"], "shortDescription": "A character LoRA"},
	{"id": "model_projprop01", "name": "Prop Generator", "type": "custom", "privacy": "private", "status": "trained",
		"capabilities": ["txt2img"]},
	{"id": "model_projclip01", "name": "Clip Maker", "type": "custom", "privacy": "private", "status": "trained",
		"capabilities": ["txt2video"]},
	{"id": "model_projstyl01", "name": "Studio Style", "type": "flux.1-composition", "privacy": "private", "status": "trained",
		"capabilities": ["txt2img"], "compliantModelIds": ["flux.1-dev"]},
	{"id": "model_projsdxl01", "name": "Old SDXL LoRA", "type": "sd-xl-lora", "privacy": "private", "status": "trained",
		"capabilities": ["txt2img"]},
]
## Polls of the device grant answered "authorization_pending" before the tokens.
var device_pending := 0
## Every tool call: {"tool", "arguments", "authorization"}.
var calls: Array = []
## Every OAuth request: {"endpoint": "token" | "device" | "revoke", "form"}.
var oauth_requests: Array = []
var revoked: Array = []
var refresh_token := ""
var _token_count := 0

var paid_calls: Array = []
var uploads := 0
var puts: Array = []
var estimates := 0
var tool_log: Array = []
## jobs_list answers per project: {project_id: [job, ...]}.
var listed := {}
var _jobs := {}


func post(url: String, headers: PackedStringArray, body: String, _timeout_s: float) -> Dictionary:
	if url.contains("/oauth/"):
		return _oauth(url, Loopback.parse_query(body))
	var payload: Dictionary = JSON.parse_string(body)
	var method := str(payload.get("method", ""))
	if method == "initialize":
		return _reply(payload["id"], {"protocolVersion": "2025-03-26", "capabilities": {}})
	if method == "notifications/initialized":
		return {"status": 202, "headers": {}, "body": "", "error": ""}
	var tool: String = payload["params"]["name"]
	var args: Dictionary = payload["params"]["arguments"]
	tool_log.append(tool)
	var authorization := ""
	for line in headers:
		if line.begins_with("Authorization: "):
			authorization = line.substr(15)
	calls.append({"tool": tool, "arguments": args, "authorization": authorization})
	match tool:
		"teams_list":
			return _reply(payload["id"], _tool({"teams": teams}))
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
			return _reply(payload["id"], _tool({"jobs": listed.get(str(args.get("project_id", "")), [])}))
		"models_list":
			var start := 3 if str(args.get("page_token", "")) == "page2" else 0
			var page := {"models": project_models.slice(start, start + 3)}
			if start + 3 < project_models.size():
				page["nextPaginationToken"] = "page2"
			return _reply(payload["id"], _tool(page))
		"asset_get":
			var output := _output(str(args["asset_id"]))
			return _reply(payload["id"], _tool({"asset": {"id": args["asset_id"], "mimeType": output["mime"], "metadata": {"type": output["type"]}}}))
		"asset_download":
			return _reply(payload["id"], _tool({"url": "https://cdn.cloud.scenario.com/test/" + str(args["asset_id"])}))
		"upload_asset":
			uploads += 1
			return _reply(payload["id"], _tool({"upload_id": "up_%d" % uploads, "part_size": 5242880, "parts": [
				{"part_number": 1, "upload_url": "https://bucket.s3-accelerate.amazonaws.com/up_%d" % uploads, "content_length": args["file_size"]}]}))
		"upload_asset_complete":
			return _reply(payload["id"], _tool({"asset_id": "asset_upl%03d" % uploads, "status": "imported"}))
		"recommend":
			# Shape of a real reply, 2026-10-04 (txt2img, "a wooden treasure chest").
			return _reply(payload["id"], _tool({"specialty": {"model_id": "model_TiL9mAQVWbaC9ythxHsLKzwK", "name": "Boxes & Crates 2.0"},
				"ranked": [{"model_id": "model_openai-gpt-image-2-5-sunburst", "name": "GPT Image 2.5 Sunburst", "rank": 1, "cost_summary": "11 CU per asset"}],
				"next_step": {"type": "ask_user"}}))
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


func put_bytes(url: String, bytes: PackedByteArray, _timeout_s: float = 300.0) -> Dictionary:
	puts.append({"url": url, "size": bytes.size()})
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
	# Trained models, as model_schema_get answers: the base's inputs and how to run on it.
	if model_id in ["model_projhero01", "model_projstyl01"]:
		var lora := model_id == "model_projhero01"
		return {"model_id": model_id, "parameters": [
			{"name": "prompt", "type": "string", "required": true, "prompt": true},
			{"name": "seed", "type": "number"},
			{"name": "loras", "type": "model_array", "model_types": ["flux.1-lora"]},
			{"name": "lorasScale", "type": "number_array", "min": -1, "max": 2},
			{"name": "modelId", "type": "model", "model_types": ["flux.1-composition"]},
		], "parameters_inherited_from": "model_bfl-flux-1-dev", "runs_as": "lora" if lora else "composition",
			"run_with": {"tool": "model_run", "required_arguments": {"model_id": "model_bfl-flux-1-dev",
				"parameters": {"loras": [model_id]} if lora else {"modelId": model_id}}}}
	if model_id == "model_projsdxl01":
		return {"model_id": model_id, "parameters": []}  # no base the MCP knows
	if model_id == "model_elevenlabs-sound-effects-v2":
		return {"model_id": model_id, "parameters": [
			{"name": "text", "type": "string", "required": true, "prompt": true},
			{"name": "loop", "type": "boolean"},
		]}
	if not fixture.is_empty():
		var text := FileAccess.get_file_as_string(FIXTURES + fixture + ".sse")
		for line in text.split("\n"):
			if line.begins_with("data:"):
				return JSON.parse_string(line.substr(5))["result"]["structuredContent"]
	return {"model_id": model_id, "parameters": [
		{"name": "prompt", "type": "string", "required": true, "prompt": true},
		{"name": "seed", "type": "number"},
	]}


func _oauth(url: String, form: Dictionary) -> Dictionary:
	if url.ends_with("/oauth/device_authorization"):
		oauth_requests.append({"endpoint": "device", "form": form})
		return _json(200, {"device_code": "dev_1", "user_code": "WDJB-MJHT", "interval": 1, "expires_in": 600,
			"verification_uri": "https://accounts.example.test/device",
			"verification_uri_complete": "https://accounts.example.test/device?user_code=WDJB-MJHT"})
	if url.ends_with("/oauth/token/revoke"):
		oauth_requests.append({"endpoint": "revoke", "form": form})
		revoked.append(form.get("token", ""))
		return {"status": 200, "headers": {}, "body": "", "error": ""}  # empty, as the provider answers
	oauth_requests.append({"endpoint": "token", "form": form})
	match str(form.get("grant_type", "")):
		"authorization_code":
			if form.get("code") != "code_ok" or str(form.get("code_verifier", "")).length() < 43:
				return _json(400, {"error": "invalid_grant"})
		"refresh_token":
			if form.get("refresh_token") != refresh_token or form.get("refresh_token") in revoked:
				return _json(400, {"error": "invalid_grant"})
		"urn:ietf:params:oauth:grant-type:device_code":
			if device_pending > 0:
				device_pending -= 1
				return _json(400, {"error": "authorization_pending"})
		_:
			return _json(400, {"error": "unsupported_grant_type"})
	_token_count += 1
	refresh_token = "rt_%d" % _token_count
	return _json(200, {"access_token": "at_%d" % _token_count, "refresh_token": refresh_token,
		"token_type": "Bearer", "expires_in": 3600})


static func _json(status: int, data: Dictionary) -> Dictionary:
	return {"status": status, "headers": {"content-type": "application/json"}, "body": JSON.stringify(data), "error": ""}


static func _tool(structured: Dictionary) -> Dictionary:
	return {"content": [{"type": "text", "text": JSON.stringify(structured)}], "structuredContent": structured}


static func _reply(id: Variant, result: Dictionary) -> Dictionary:
	var message := {"jsonrpc": "2.0", "id": id, "result": result}
	return {"status": 200, "headers": {"content-type": "text/event-stream", "mcp-session-id": "s"},
		"body": "event: message\ndata: %s\n\n" % JSON.stringify(message), "error": ""}
