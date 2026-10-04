@tool
extends RefCounted
## Reads a Scenario MCP HTTP reply, plain JSON or a server-sent event stream,
## and returns the final JSON-RPC message that answers one request id.

const Errors := preload("res://addons/scenario/core/errors.gd")


## Returns ok(envelope) where envelope holds "result" or "error", or a
## protocol failure. A notification (request_id == null) with an empty body is ok({}).
static func parse(body: String, content_type: String, request_id: Variant) -> Dictionary:
	var source := body.trim_prefix("﻿")
	if source.strip_edges().is_empty():
		if request_id == null:
			return Errors.ok({})
		return Errors.fail(Errors.PROTOCOL, "Scenario sent an empty reply.")
	var messages: Array = []
	var trimmed := source.strip_edges(true, false)
	var is_stream := content_type.to_lower().contains("text/event-stream") \
		or trimmed.begins_with("data:") or trimmed.begins_with("event:") or trimmed.begins_with(":")
	if is_stream:
		messages = _stream_messages(source)
	else:
		var payload: Variant = _json(source)
		if payload == null:
			return Errors.fail(Errors.PROTOCOL, "Scenario returned invalid JSON.")
		messages = payload if payload is Array else [payload]
	if request_id == null:
		return Errors.ok({})
	var found: Variant = null
	for message in messages:
		if message is Dictionary and message.has("id") and _same_id(message["id"], request_id) \
				and (message.has("result") or message.has("error")):
			found = message  # the last matching message wins (progress first, result last)
	if found == null:
		return Errors.fail(Errors.PROTOCOL, "Scenario did not return a complete reply for this request.")
	return Errors.ok(found)


static func _stream_messages(source: String) -> Array:
	var messages: Array = []
	var data_lines: PackedStringArray = []
	var lines := source.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	lines.append("")
	for line in lines:
		if line.is_empty():
			if not data_lines.is_empty():
				var value := "\n".join(data_lines)
				if value.strip_edges() != "[DONE]":
					var parsed: Variant = _json(value)
					if parsed != null:
						messages.append(parsed)  # a malformed progress event must not hide a later result
				data_lines.clear()
		elif line.begins_with("data:"):
			data_lines.append(line.substr(5).trim_prefix(" "))
	return messages


static func _json(text: String) -> Variant:
	var json := JSON.new()
	if json.parse(text) != OK:
		return null
	return json.data


static func _same_id(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return int(a) == int(b)
	return str(a) == str(b)
