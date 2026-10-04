@tool
extends Node
## Network for the editor: one HTTPRequest per call, freed when done.
##
## Downloads only come from Scenario's CDN and uploads only go to the presigned
## storage host Scenario returns; neither carries the API credentials.

const DOWNLOAD_HOSTS := ["cdn.cloud.scenario.com", "cdn.scenario.com"]
const UPLOAD_HOST_SUFFIX := ".amazonaws.com"


func post(url: String, headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary:
	var request := _request(timeout_s)
	if request.request(url, headers, HTTPClient.METHOD_POST, body) != OK:
		request.queue_free()
		return {"status": 0, "headers": {}, "body": "", "error": "transport"}
	var reply: Array = await request.request_completed
	request.queue_free()
	return _response(reply)


## PUTs one upload part. ok when the storage host answers 2xx.
func put_bytes(url: String, bytes: PackedByteArray, timeout_s: float = 300.0) -> Dictionary:
	if not url.begins_with("https://") or not host_of(url).ends_with(UPLOAD_HOST_SUFFIX):
		return {"ok": false, "error": "Refused to upload to an unexpected host."}
	var request := _request(timeout_s)
	if request.request_raw(url, PackedStringArray(), HTTPClient.METHOD_PUT, bytes) != OK:
		request.queue_free()
		return {"ok": false, "error": "Could not start the upload."}
	var reply: Array = await request.request_completed
	request.queue_free()
	var response := _response(reply)
	var status := int(response["status"])
	if not str(response["error"]).is_empty() or status < 200 or status >= 300:
		return {"ok": false, "error": "Upload failed (HTTP %d)." % status}
	return {"ok": true}


## Downloads to dest_path through a .part file. {"ok", "path", "error"}
func download(url: String, dest_path: String, timeout_s: float = 600.0) -> Dictionary:
	if not url.begins_with("https://") or not host_of(url) in DOWNLOAD_HOSTS:
		return {"ok": false, "path": "", "error": "Refused to download from an unexpected host."}
	var absolute := ProjectSettings.globalize_path(dest_path)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var part := absolute + ".part"
	var request := _request(timeout_s)
	request.download_file = part
	if request.request(url) != OK:
		request.queue_free()
		return {"ok": false, "path": "", "error": "Could not start the download."}
	var reply: Array = await request.request_completed
	request.queue_free()
	var response := _response(reply)
	var status := int(response["status"])
	if not str(response["error"]).is_empty() or status != 200 or not FileAccess.file_exists(part):
		if FileAccess.file_exists(part):
			DirAccess.remove_absolute(part)
		return {"ok": false, "path": "", "error": "Download failed (HTTP %d)." % status}
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)
	if DirAccess.rename_absolute(part, absolute) != OK:
		return {"ok": false, "path": "", "error": "Could not save the downloaded file."}
	return {"ok": true, "path": dest_path, "error": ""}


func sleep(seconds: float) -> void:
	await get_tree().create_timer(maxf(seconds, 0.0)).timeout


static func host_of(url: String) -> String:
	var rest := url.substr(url.find("://") + 3) if url.contains("://") else url
	for separator in ["/", "?", "#"]:
		var at := rest.find(separator)
		if at != -1:
			rest = rest.substr(0, at)
	if rest.contains("@"):
		rest = rest.substr(rest.rfind("@") + 1)
	if rest.contains(":"):
		rest = rest.substr(0, rest.find(":"))
	return rest.to_lower()


func _request(timeout_s: float) -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = timeout_s
	request.use_threads = true
	add_child(request)
	return request


static func _response(reply: Array) -> Dictionary:
	var result: int = reply[0]
	var headers := {}
	for line in reply[2]:
		var at := str(line).find(":")
		if at > 0:
			headers[str(line).substr(0, at).strip_edges().to_lower()] = str(line).substr(at + 1).strip_edges()
	var error := ""
	if result == HTTPRequest.RESULT_TIMEOUT:
		error = "timeout"
	elif result != HTTPRequest.RESULT_SUCCESS:
		error = "transport"
	var body: PackedByteArray = reply[3]
	return {"status": int(reply[1]), "headers": headers, "body": body.get_string_from_utf8(), "error": error}
