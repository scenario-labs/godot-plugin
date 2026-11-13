@tool
extends RefCounted
## One-shot HTTP listener on 127.0.0.1 for the sign-in redirect.
##
## Port 0 lets the system pick a free port: the provider matches loopback
## redirect URIs on scheme, host and path only (RFC 8252, 7.3), so no port is
## ever busy. The caller polls it until it is done; only a request to
## /callback carrying the expected state ends it. Query strings carry the code:
## they are never logged.

const MAX_REQUEST_BYTES := 16384
const PEER_TIMEOUT_MS := 5000
const PAGE := """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Scenario for Godot</title><style>body{font:16px -apple-system,Segoe UI,sans-serif;background:#0b0b0c;color:#f2f2f2;display:grid;place-items:center;height:100vh;margin:0}
main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:1.25rem;margin:0 0 .5rem}p{color:#b8b8bc;margin:0}</style></head>
<body><main><h1>%s</h1><p>%s</p></main></body></html>"""

var state := ""
var code := ""
## The provider's error, when the person declined or the request was refused.
var error := ""
var done := false
var _server := TCPServer.new()
var _peers: Array = []


## Starts listening. Returns the port, or 0 when no local port could be opened.
func start(p_state: String) -> int:
	state = p_state
	if _server.listen(0, "127.0.0.1") != OK:
		return 0
	return _server.get_local_port()


## Accepts and answers what has arrived. True once the redirect came back.
func poll() -> bool:
	while not done and _server.is_listening() and _server.is_connection_available():
		_peers.append({"peer": _server.take_connection(), "data": PackedByteArray(), "since": Time.get_ticks_msec()})
	for entry in _peers.duplicate():
		var peer: StreamPeerTCP = entry["peer"]
		peer.poll()
		var available := peer.get_available_bytes() if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED else 0
		if available > 0:
			var got: Array = peer.get_data(available)
			if got[0] == OK:
				entry["data"].append_array(got[1])
		var text: String = entry["data"].get_string_from_utf8()
		if text.contains("\r\n\r\n") or entry["data"].size() >= MAX_REQUEST_BYTES:
			_answer(peer, text.get_slice("\r\n", 0))
			_peers.erase(entry)
		elif peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - int(entry["since"]) > PEER_TIMEOUT_MS:
			peer.disconnect_from_host()
			_peers.erase(entry)
	return done


func stop() -> void:
	for entry in _peers:
		entry["peer"].disconnect_from_host()
	_peers.clear()
	_server.stop()


## request_line: "GET /callback?code=...&state=... HTTP/1.1"
func _answer(peer: StreamPeerTCP, request_line: String) -> void:
	var target := request_line.get_slice(" ", 1)
	var path := target.get_slice("?", 0)
	if not request_line.begins_with("GET ") or path != "/callback" or done:
		_reply(peer, 404, "Not found", "")
		return
	var query := parse_query(target.substr(path.length() + 1) if target.contains("?") else "")
	if not same_text(str(query.get("state", "")), state):
		_reply(peer, 400, "Sign-in not completed", "This page did not come from the sign-in Godot started. Start again from the Scenario dock.")
		return
	if query.has("error"):
		error = str(query.get("error_description", query["error"])).substr(0, 200)
		_reply(peer, 200, "Sign-in not completed", "Scenario reported: " + error)
	elif str(query.get("code", "")).is_empty():
		error = "the sign-in page returned no code"
		_reply(peer, 400, "Sign-in not completed", "The sign-in page returned no code. Start again from the Scenario dock.")
	else:
		code = str(query["code"])
		_reply(peer, 200, "Signed in to Scenario", "You can close this tab and go back to Godot.")
	done = true


static func _reply(peer: StreamPeerTCP, status: int, title: String, body: String) -> void:
	var html := (PAGE % [_escape(title), _escape(body)]).to_utf8_buffer()
	var reason: String = {200: "OK", 400: "Bad Request", 404: "Not Found"}.get(status, "OK")
	var head := "HTTP/1.1 %d %s\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [status, reason, html.size()]
	peer.put_data(head.to_utf8_buffer())
	peer.put_data(html)
	peer.disconnect_from_host()


static func parse_query(query: String) -> Dictionary:
	var out := {}
	for pair in query.split("&", false):
		var key := pair.get_slice("=", 0).replace("+", " ").uri_decode()
		var value := pair.substr(pair.find("=") + 1).replace("+", " ").uri_decode() if pair.contains("=") else ""
		out[key] = value
	return out


## Compares without stopping at the first difference, so timing reveals nothing about the state.
static func same_text(a: String, b: String) -> bool:
	var left := a.to_utf8_buffer()
	var right := b.to_utf8_buffer()
	var diff := left.size() ^ right.size()
	for i in mini(left.size(), right.size()):
		diff |= left[i] ^ right[i]
	return diff == 0 and not b.is_empty()


static func _escape(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
