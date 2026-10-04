@tool
extends RefCounted
## Scenario MCP client: JSON-RPC over HTTP with SSE replies, Basic auth.
##
## Money rules (spec section 3): a paid call is sent once and never retried; a
## transport failure on a paid call is "ambiguous" (Scenario may have started
## the job); an estimate that comes back with a job id is an alarm. Only the
## read tools below are retried.
##
## The transport is injected so the core runs without the editor. It must
## provide two coroutines:
##   post(url: String, headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary
##       {"status": int, "headers": Dictionary (lowercase keys), "body": String, "error": "" | "timeout" | "transport"}
##   sleep(seconds: float) -> void

const Errors := preload("res://addons/scenario/core/errors.gd")
const Sse := preload("res://addons/scenario/core/sse.gd")

const DEFAULT_ENDPOINT := "https://mcp.scenario.com/mcp?toolsets=full"
const PROTOCOL_VERSION := "2025-03-26"
const VERSION := "0.1.0"
const READ_ATTEMPTS := 3
const MAX_RETRY_AFTER_S := 30.0
const DEFAULT_TIMEOUT_S := 60.0

## Idempotent reads: the only calls ever retried.
const READ_TOOLS := [
	"model_schema_get", "models_list", "job_get", "jobs_list", "asset_get", "asset_download",
	"recommend", "search", "usage", "teams_list", "projects_list",
]
## Calls that can spend Creative Units or create something.
const SUBMIT_TOOLS := [
	"model_run", "prompt_spark", "upload_asset", "upload_asset_complete", "job_cancel", "workflow_run",
]

var endpoint := DEFAULT_ENDPOINT
var transport: Object
var api_key := ""
var api_secret := ""
## SCENARIO_NO_SPEND=1 refuses every paid call before any request is made.
var spending_disabled := OS.get_environment("SCENARIO_NO_SPEND") == "1"
var session_id := ""
var _initialized := false
var _next_id := 1


func _init(p_transport: Object = null, p_key: String = "", p_secret: String = "") -> void:
	transport = p_transport
	set_credentials(p_key, p_secret)


func set_credentials(key: String, secret: String) -> void:
	api_key = key.strip_edges()
	api_secret = secret.strip_edges()
	session_id = ""
	_initialized = false


func has_credentials() -> bool:
	return not api_key.is_empty() and not api_secret.is_empty()


static func is_submission(tool: String, arguments: Dictionary) -> bool:
	if tool == "model_run" or tool == "workflow_run":
		return not bool(arguments.get("dry_run", false))
	return tool in SUBMIT_TOOLS


static func is_retryable(tool: String, arguments: Dictionary) -> bool:
	if tool == "model_run" and bool(arguments.get("dry_run", false)):
		return true  # a free estimate is a read
	return tool in READ_TOOLS


## The job id carried by a reply, or "" (an estimate must carry none).
static func created_job_id(value: Variant) -> String:
	if not value is Dictionary:
		return ""
	for key in ["job_id", "jobId"]:
		if value.get(key):
			return str(value[key])
	for key in ["job", "inference"]:
		var inner: Variant = value.get(key)
		if inner is Dictionary:
			var inner_id: Variant = inner.get("id", inner.get("jobId", ""))
			if inner_id:
				return str(inner_id)
	return ""


# --- High-level calls ---------------------------------------------------------

## Free price check. ok({"cu": float, "discount": float})
func estimate(model_id: String, parameters: Dictionary) -> Dictionary:
	var result: Dictionary = await call_tool("model_run", {"model_id": model_id, "parameters": parameters, "dry_run": true})
	if not result["ok"]:
		return result
	var value: Dictionary = result["value"]
	if not value.has("creativeUnitsCost"):
		return Errors.fail(Errors.PROTOCOL, "Scenario returned no price for this request.")
	return Errors.ok({
		"cu": float(value["creativeUnitsCost"]),
		"discount": float(value.get("creativeUnitsDiscount", 0)),
	})


## Paid. Sent exactly once. ok({"job_id", "status"})
func submit(model_id: String, parameters: Dictionary) -> Dictionary:
	var result: Dictionary = await call_tool("model_run", {"model_id": model_id, "parameters": parameters, "wait": false})
	if not result["ok"]:
		return result
	var job_id := created_job_id(result["value"])
	if job_id.is_empty():
		return Errors.fail(Errors.PROTOCOL,
			"Scenario accepted the request but returned no job id. Check recent jobs before generating again.",
			{"ambiguous": true})
	return Errors.ok({"job_id": job_id, "status": str(result["value"].get("status", "queued"))})


func get_job(job_id: String) -> Dictionary:
	return _unwrap(await call_tool("job_get", {"job_id": job_id}), "job")


func list_jobs(page_size: int = 20) -> Dictionary:
	return _unwrap(await call_tool("jobs_list", {"page_size": clampi(page_size, 1, 100)}), "jobs")


func cancel_job(job_id: String) -> Dictionary:
	return await call_tool("job_cancel", {"job_id": job_id})


func get_asset(asset_id: String) -> Dictionary:
	return _unwrap(await call_tool("asset_get", {"asset_id": asset_id}), "asset")


## ok(url). format converts 3D (glb, fbx, obj) and images; "" keeps the original.
func download_url(asset_id: String, format: String = "") -> Dictionary:
	var arguments := {"asset_id": asset_id}
	if not format.is_empty():
		arguments["format"] = format
	return _unwrap(await call_tool("asset_download", arguments), "url")


func get_schema(model_id: String) -> Dictionary:
	return await call_tool("model_schema_get", {"model_id": model_id})


func recommend(capability: String, prompt: String, limit: int = 8) -> Dictionary:
	return await call_tool("recommend", {"capability": capability, "prompt": prompt, "limit": clampi(limit, 1, 10)})


## Paid-class (creates an asset, costs no CU): starts a multipart upload.
func upload_start(file_name: String, content_type: String, kind: String, file_size: int) -> Dictionary:
	return await call_tool("upload_asset", {
		"file_name": file_name, "content_type": content_type, "kind": kind, "file_size": file_size,
	})


func upload_complete(arguments: Dictionary) -> Dictionary:
	return await call_tool("upload_asset_complete", arguments, 120.0)


# --- Tool call core -----------------------------------------------------------

func call_tool(tool: String, arguments: Dictionary = {}, timeout_s: float = DEFAULT_TIMEOUT_S) -> Dictionary:
	if not has_credentials():
		return Errors.fail(Errors.AUTH, "Connect a Scenario API key and secret first.")
	var submit_call := is_submission(tool, arguments)
	# Cancelling can only lower spend, so the switch lets it through.
	if submit_call and spending_disabled and tool != "job_cancel":
		return Errors.fail(Errors.LOCAL, "Spending is turned off (SCENARIO_NO_SPEND=1), so nothing was sent.")
	var attempts := READ_ATTEMPTS if is_retryable(tool, arguments) else 1
	var result: Dictionary = {}
	for attempt in attempts:
		result = await _call_once(tool, arguments, timeout_s, submit_call)
		if result["ok"]:
			if tool == "model_run" and bool(arguments.get("dry_run", false)):
				var job_id := created_job_id(result["value"])
				if not job_id.is_empty():
					return Errors.fail(Errors.ESTIMATE_JOB,
						"Scenario returned a job for a price check, so it may have started a paid run. Automatic price checks are off for this session. Check job %s." % job_id,
						{"job_id": job_id})
			return result
		var error: Dictionary = result["error"]
		if attempt + 1 < attempts and error["kind"] in Errors.RETRYABLE_KINDS:
			var delay := _retry_delay(attempt, float(error.get("retry_after", -1.0)))
			if delay >= 0.0:
				await transport.sleep(delay)
				continue
		return result
	return result


func _call_once(tool: String, arguments: Dictionary, timeout_s: float, submit_call: bool) -> Dictionary:
	var rpc: Dictionary = await _rpc("tools/call", {"name": tool, "arguments": arguments}, timeout_s)
	if not rpc["ok"]:
		if submit_call and rpc["error"]["kind"] in Errors.AMBIGUOUS_KINDS and not rpc["error"].get("not_sent", false):
			rpc["error"]["ambiguous"] = true
			rpc["error"]["message"] = "The request status is unknown: Scenario may have accepted it. Check recent jobs before sending it again."
		return rpc
	var result: Dictionary = rpc["value"]
	var structured: Variant = result.get("structuredContent")
	var content: Variant = result.get("content", [])
	if result.get("isError") == true:
		var detail := _first_text(content)
		if structured is Dictionary and not structured.is_empty():
			detail = JSON.stringify(structured)
		var kind := Errors.classify(detail)
		return Errors.fail(kind, Errors.message_for(kind, detail), {"detail": detail})
	if structured is Dictionary:
		if submit_call and structured.is_empty():
			return Errors.fail(Errors.PROTOCOL, "Scenario returned an empty reply.", {"ambiguous": true})
		return Errors.ok(structured)
	if content is Array:
		for item in content:
			if item is Dictionary and item.get("type") == "text":
				var json := JSON.new()
				if json.parse(str(item.get("text", ""))) == OK and json.data is Dictionary:
					if submit_call and json.data.is_empty():
						break
					return Errors.ok(json.data)
	return Errors.fail(Errors.PROTOCOL, "Scenario returned no usable result.", {"ambiguous": submit_call})


## One JSON-RPC request. Initializes the MCP session first, and once more if the
## server reports the session expired (the request was not dispatched then).
func _rpc(method: String, params: Dictionary, timeout_s: float) -> Dictionary:
	if not _initialized:
		var init: Dictionary = await _initialize(timeout_s)
		if not init["ok"]:
			init["error"]["not_sent"] = true
			return init
	var request_id := _take_id()
	var reply: Dictionary = await _post(method, params, request_id, timeout_s)
	if not reply["ok"] and reply["error"].get("session_expired", false):
		session_id = ""
		_initialized = false
		var again: Dictionary = await _initialize(timeout_s)
		if not again["ok"]:
			again["error"]["not_sent"] = true
			return again
		reply = await _post(method, params, request_id, timeout_s)
	if not reply["ok"]:
		return reply
	var envelope: Dictionary = reply["value"]
	if envelope.has("error"):
		var rpc_error: Variant = envelope["error"]
		var detail := JSON.stringify(rpc_error) if not rpc_error is String else rpc_error
		var kind := Errors.classify(detail)
		return Errors.fail(kind, Errors.message_for(kind, detail), {"detail": detail})
	if not envelope.get("result") is Dictionary:
		return Errors.fail(Errors.PROTOCOL, "Scenario returned an unexpected reply structure.")
	return Errors.ok(envelope["result"])


func _initialize(timeout_s: float) -> Dictionary:
	var reply: Dictionary = await _post("initialize", {
		"protocolVersion": PROTOCOL_VERSION,
		"capabilities": {},
		"clientInfo": {"name": "scenario-godot-plugin", "version": VERSION},
	}, _take_id(), timeout_s, false)
	if not reply["ok"]:
		return reply
	if reply["value"].has("error"):
		var detail := JSON.stringify(reply["value"]["error"])
		var kind := Errors.classify(detail)
		return Errors.fail(kind, Errors.message_for(kind, detail))
	var notified: Dictionary = await _post("notifications/initialized", {}, null, timeout_s, false)
	if not notified["ok"]:
		return notified
	_initialized = true
	return Errors.ok()


func _post(method: String, params: Dictionary, request_id: Variant, timeout_s: float, allow_session_signal: bool = true) -> Dictionary:
	var payload := {"jsonrpc": "2.0", "method": method}
	if request_id != null:
		payload["id"] = request_id
	if not params.is_empty():
		payload["params"] = params
	var token := Marshalls.utf8_to_base64("%s:%s" % [api_key, api_secret])
	var headers := PackedStringArray([
		"Authorization: Basic " + token,
		"Content-Type: application/json",
		"Accept: application/json, text/event-stream",
		"MCP-Protocol-Version: " + PROTOCOL_VERSION,
		"User-Agent: ScenarioGodot/" + VERSION,
	])
	var session_used := session_id
	if not session_used.is_empty():
		headers.append("Mcp-Session-Id: " + session_used)
	var response: Dictionary = await transport.post(endpoint, headers, JSON.stringify(payload), clampf(timeout_s, 1.0, 180.0))
	var transport_error := str(response.get("error", ""))
	if transport_error == "timeout":
		return Errors.fail(Errors.TIMEOUT, Errors.message_for(Errors.TIMEOUT))
	if not transport_error.is_empty():
		return Errors.fail(Errors.TRANSPORT, Errors.message_for(Errors.TRANSPORT))
	var status := int(response.get("status", 0))
	var response_headers: Dictionary = response.get("headers", {})
	var body := str(response.get("body", ""))
	var new_session := str(response_headers.get("mcp-session-id", ""))
	if not new_session.is_empty():
		session_id = new_session
	if status < 200 or status >= 300:
		if allow_session_signal and (status == 400 or status == 404):
			# "session" covers "Mcp-Session-Id is required" and "No valid session ID";
			# a 404 on a request that carried a session id means it expired.
			if body.to_lower().contains("session") or (status == 404 and not session_used.is_empty()):
				return Errors.fail(Errors.PROTOCOL, "Session expired.", {"session_expired": true, "status": status})
		var kind := Errors.classify(body, status)
		return Errors.fail(kind, Errors.message_for(kind, body), {
			"status": status, "retry_after": _retry_after(response_headers), "detail": body,
		})
	return Sse.parse(body, str(response_headers.get("content-type", "")), request_id)


func _take_id() -> int:
	var value := _next_id
	_next_id += 1
	return value


func _retry_delay(attempt: int, retry_after: float) -> float:
	if retry_after >= 0.0:
		return -1.0 if retry_after > MAX_RETRY_AFTER_S else retry_after
	var base := minf(8.0, 0.5 * pow(2.0, attempt))
	return base * (0.5 + 0.5 * randf())


static func _retry_after(headers: Dictionary) -> float:
	var raw := str(headers.get("retry-after", "")).strip_edges()
	if raw.is_valid_float():
		return maxf(0.0, raw.to_float())
	return -1.0


static func _first_text(content: Variant) -> String:
	if content is Array:
		for item in content:
			if item is Dictionary and item.get("type") == "text":
				return str(item.get("text", ""))
	return ""


static func _unwrap(result: Dictionary, key: String) -> Dictionary:
	if not result["ok"]:
		return result
	var value: Variant = result["value"]
	if not value is Dictionary or not value.has(key):
		return Errors.fail(Errors.PROTOCOL, "Scenario's reply had no '%s'." % key)
	return Errors.ok(value[key])
