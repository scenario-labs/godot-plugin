extends GutTest

const Client := preload("res://addons/scenario/core/mcp_client.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")
const Fake := preload("res://tests/support/fake_transport.gd")

var fake: Fake
var client: Client


func before_each() -> void:
	fake = Fake.new()
	client = Client.new(fake, "api_key_1", "secret_1")
	client.spending_disabled = false


func _header(request: Dictionary, name: String) -> String:
	for line in request["headers"]:
		if line.to_lower().begins_with(name.to_lower() + ":"):
			return line.substr(line.find(":") + 1).strip_edges()
	return ""


func test_first_call_initializes_then_calls_the_tool() -> void:
	fake.replies.append({"fixture": "job"})
	var result: Dictionary = await client.get_job("job_LTkgP2UzQQdFtTVgYFSiE7na")
	assert_true(result["ok"])
	assert_eq(result["value"]["status"], "success")
	var methods := fake.requests.map(func(r: Dictionary) -> String: return r["payload"]["method"])
	assert_eq(methods, ["initialize", "notifications/initialized", "tools/call"])


func test_basic_auth_protocol_and_session_headers() -> void:
	fake.replies.append({"fixture": "job"})
	await client.get_job("job_1")
	var call: Dictionary = fake.tool_calls()[0]
	assert_eq(_header(call, "Authorization"), "Basic " + Marshalls.utf8_to_base64("api_key_1:secret_1"))
	assert_eq(_header(call, "MCP-Protocol-Version"), "2025-03-26")
	assert_eq(_header(call, "Mcp-Session-Id"), "sess-1")
	assert_eq(_header(call, "Accept"), "application/json, text/event-stream")


func test_initializes_once_for_many_calls() -> void:
	fake.replies.append({"fixture": "job"})
	fake.replies.append({"fixture": "job"})
	await client.get_job("a")
	await client.get_job("b")
	assert_eq(fake.init_count, 1)


func test_estimate_reads_the_price() -> void:
	fake.replies.append({"fixture": "estimate"})
	var result: Dictionary = await client.estimate("model_openai-gpt-image-2-5-flare", {"prompt": "chest"})
	assert_true(result["ok"])
	assert_eq(result["value"]["cu"], 11.0)
	var arguments: Dictionary = fake.tool_calls()[0]["payload"]["params"]["arguments"]
	assert_eq(arguments["dry_run"], true)


func test_estimate_that_returns_a_job_is_an_alarm() -> void:
	fake.replies.append(Fake.tool_result({"creativeUnitsCost": 5, "job_id": "job_surprise"}))
	var result: Dictionary = await client.estimate("model_x", {"prompt": "p"})
	assert_false(result["ok"])
	assert_eq(result["error"]["kind"], Errors.ESTIMATE_JOB)
	assert_eq(result["error"]["job_id"], "job_surprise")


func test_estimate_with_nested_job_id_is_an_alarm() -> void:
	fake.replies.append(Fake.tool_result({"creativeUnitsCost": 5, "job": {"jobId": "job_nested"}}))
	var result: Dictionary = await client.estimate("model_x", {"prompt": "p"})
	assert_eq(result["error"]["kind"], Errors.ESTIMATE_JOB)


func test_estimate_without_price_fails() -> void:
	fake.replies.append(Fake.tool_result({"dry_run": true, "job": {}}))
	var result: Dictionary = await client.estimate("model_x", {"prompt": "p"})
	assert_eq(result["error"]["kind"], Errors.PROTOCOL)


func test_submit_sends_once_without_waiting() -> void:
	fake.replies.append(Fake.tool_result({"model_id": "m", "job_id": "job_1", "status": "queued"}))
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_true(result["ok"])
	assert_eq(result["value"]["job_id"], "job_1")
	var arguments: Dictionary = fake.tool_calls()[0]["payload"]["params"]["arguments"]
	assert_eq(arguments["wait"], false)
	assert_false(arguments.has("dry_run"))


func test_submit_timeout_is_ambiguous_and_never_retried() -> void:
	fake.replies.append({"error": "timeout"})
	fake.replies.append(Fake.tool_result({"job_id": "job_should_not_be_used"}))
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_false(result["ok"])
	assert_true(result["error"]["ambiguous"])
	assert_eq(fake.tool_calls().size(), 1)


func test_submit_server_error_is_ambiguous_and_never_retried() -> void:
	fake.replies.append({"http": 502, "body": "bad gateway"})
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_true(result["error"]["ambiguous"])
	assert_eq(fake.tool_calls().size(), 1)


func test_submit_with_no_job_id_is_ambiguous() -> void:
	fake.replies.append(Fake.tool_result({"status": "queued"}))
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_true(result["error"]["ambiguous"])


func test_submit_clear_refusal_is_not_ambiguous() -> void:
	fake.replies.append({"http": 400, "body": "{\"error\":\"prompt is required\"}"})
	var result: Dictionary = await client.submit("m", {})
	assert_false(result["error"]["ambiguous"])
	assert_eq(result["error"]["kind"], Errors.INVALID)


func test_submit_when_session_setup_fails_is_not_ambiguous() -> void:
	fake.auto_init = false
	fake.replies.append({"error": "transport"})
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_false(result["error"]["ambiguous"], "the paid call was never sent")
	assert_eq(fake.tool_calls().size(), 0)


func test_reads_are_retried_with_backoff() -> void:
	fake.replies.append({"http": 503, "body": "busy"})
	fake.replies.append({"error": "transport"})
	fake.replies.append({"fixture": "job"})
	var result: Dictionary = await client.get_job("job_1")
	assert_true(result["ok"])
	assert_eq(fake.tool_calls().size(), 3)
	assert_eq(fake.sleeps.size(), 2)


func test_reads_give_up_after_three_attempts() -> void:
	for i in 4:
		fake.replies.append({"http": 503, "body": "busy"})
	var result: Dictionary = await client.get_job("job_1")
	assert_eq(result["error"]["kind"], Errors.HTTP_5XX)
	assert_eq(fake.tool_calls().size(), 3)


func test_retry_after_is_honoured_and_a_long_one_stops_retrying() -> void:
	fake.replies.append({"http": 429, "body": "slow down", "headers": {"retry-after": "2"}})
	fake.replies.append({"fixture": "job"})
	assert_true((await client.get_job("a"))["ok"])
	assert_eq(fake.sleeps, [2.0])
	fake.replies.append({"http": 429, "body": "slow down", "headers": {"retry-after": "120"}})
	var result: Dictionary = await client.get_job("b")
	assert_eq(result["error"]["kind"], Errors.RATE_LIMIT)


func test_estimates_are_retried_but_cancel_is_not() -> void:
	assert_true(Client.is_retryable("model_run", {"dry_run": true}))
	assert_false(Client.is_retryable("model_run", {}))
	assert_false(Client.is_retryable("job_cancel", {}))
	assert_true(Client.is_submission("model_run", {}))
	assert_false(Client.is_submission("model_run", {"dry_run": true}))
	assert_true(Client.is_submission("upload_asset", {}))


func test_expired_session_reinitializes_and_resends_once() -> void:
	fake.replies.append({"fixture": "job"})
	await client.get_job("a")
	fake.replies.append({"http": 404, "body": "Session not found"})
	fake.replies.append({"fixture": "job"})
	var result: Dictionary = await client.get_job("b")
	assert_true(result["ok"])
	assert_eq(fake.init_count, 2)


func test_moderation_error_is_blocked_kind() -> void:
	fake.replies.append(Fake.tool_error("Error: The prompt was flagged by content moderation."))
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_eq(result["error"]["kind"], Errors.MODERATED)
	assert_false(result["error"]["ambiguous"])


func test_auth_errors() -> void:
	fake.replies.append({"http": 401, "body": "Unauthorized"})
	var result: Dictionary = await client.get_job("a")
	assert_eq(result["error"]["kind"], Errors.AUTH)


func test_rpc_error_object() -> void:
	fake.replies.append({"rpc_error": {"code": -32602, "message": "Invalid params"}})
	var result: Dictionary = await client.get_job("a")
	assert_false(result["ok"])


func test_no_spend_mode_sends_nothing() -> void:
	client.spending_disabled = true
	var result: Dictionary = await client.submit("m", {"prompt": "p"})
	assert_eq(result["error"]["kind"], Errors.LOCAL)
	assert_eq(fake.requests.size(), 0)
	fake.replies.append({"fixture": "estimate"})
	assert_true((await client.estimate("m", {"prompt": "p"}))["ok"], "price checks still work")
	var sent_before := fake.requests.size()
	assert_eq((await client.upload_start("a.png", "image/png", "image", 10))["error"]["kind"], Errors.LOCAL)
	assert_eq(fake.requests.size(), sent_before, "uploads are refused too")
	fake.replies.append({"result": {"structuredContent": {"job_id": "job_1", "status": "canceled"}, "content": []}})
	await client.cancel_job("job_1")
	assert_eq(fake.requests.size(), sent_before + 1, "a cancel still goes out")


func test_missing_credentials_sends_nothing() -> void:
	client.set_credentials("", "")
	var result: Dictionary = await client.get_job("a")
	assert_eq(result["error"]["kind"], Errors.AUTH)
	assert_eq(fake.requests.size(), 0)


func test_text_content_without_structured_content() -> void:
	fake.replies.append({"result": {"content": [{"type": "text", "text": "{\"url\": \"https://cdn.cloud.scenario.com/x\"}"}]}})
	var result: Dictionary = await client.download_url("asset_1", "glb")
	assert_eq(result["value"], "https://cdn.cloud.scenario.com/x")
	assert_eq(fake.tool_calls()[0]["payload"]["params"]["arguments"]["format"], "glb")


func test_created_job_id_helper() -> void:
	assert_eq(Client.created_job_id({"job": {}}), "")
	assert_eq(Client.created_job_id({"jobId": "j"}), "j")
	assert_eq(Client.created_job_id("text"), "")
