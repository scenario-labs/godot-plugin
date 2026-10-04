extends RefCounted
## In-memory transport for the MCP client. Answers initialize and the
## initialized notification by itself (unless auto_init is false) and serves
## queued replies to tools/call in order.
##
## A queued reply is one of:
##   {"result": {...}}                  a JSON-RPC result, sent as SSE
##   {"rpc_error": {...}}               a JSON-RPC error object
##   {"fixture": "estimate"}            tests/fixtures/<name>.sse with the id rewritten
##   {"http": 503, "body": "...", "headers": {...}}
##   {"error": "timeout" | "transport"}

const FIXTURES := "res://tests/fixtures/"

var auto_init := true
var session := "sess-1"
var replies: Array = []
var requests: Array = []
var sleeps: Array = []
var init_count := 0


func post(url: String, headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary:
	var payload: Variant = JSON.parse_string(body)
	requests.append({"url": url, "headers": headers, "payload": payload, "timeout": timeout_s})
	var method := str(payload.get("method", ""))
	if auto_init and method == "initialize":
		init_count += 1
		return _sse(payload["id"], {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "fake"}})
	if auto_init and method == "notifications/initialized":
		return {"status": 202, "headers": {"mcp-session-id": session}, "body": "", "error": ""}
	if replies.is_empty():
		return {"status": 500, "headers": {}, "body": "no reply queued", "error": ""}
	var reply: Dictionary = replies.pop_front()
	if reply.has("error"):
		return {"status": 0, "headers": {}, "body": "", "error": reply["error"]}
	if reply.has("http"):
		return {"status": reply["http"], "headers": reply.get("headers", {}), "body": reply.get("body", ""), "error": ""}
	if reply.has("fixture"):
		var text := FileAccess.get_file_as_string(FIXTURES + reply["fixture"] + ".sse")
		text = text.replace("\"id\":2}", "\"id\":%d}" % int(payload["id"]))
		return {"status": 200, "headers": {"content-type": "text/event-stream", "mcp-session-id": session}, "body": text, "error": ""}
	if reply.has("rpc_error"):
		var message := {"jsonrpc": "2.0", "id": payload["id"], "error": reply["rpc_error"]}
		return {"status": 200, "headers": {"content-type": "text/event-stream"}, "body": "event: message\ndata: %s\n\n" % JSON.stringify(message), "error": ""}
	return _sse(payload["id"], reply["result"])


func sleep(seconds: float) -> void:
	sleeps.append(seconds)


## Requests whose JSON-RPC method is tools/call.
func tool_calls() -> Array:
	return requests.filter(func(r: Dictionary) -> bool: return r["payload"].get("method") == "tools/call")


static func tool_result(structured: Dictionary) -> Dictionary:
	return {"result": {"content": [{"type": "text", "text": JSON.stringify(structured)}], "structuredContent": structured}}


static func tool_error(text: String) -> Dictionary:
	return {"result": {"content": [{"type": "text", "text": text}], "isError": true}}


func _sse(id: Variant, result: Dictionary) -> Dictionary:
	var message := {"jsonrpc": "2.0", "id": id, "result": result}
	return {
		"status": 200,
		"headers": {"content-type": "text/event-stream", "mcp-session-id": session},
		"body": "event: message\ndata: %s\n\n" % JSON.stringify(message),
		"error": "",
	}
