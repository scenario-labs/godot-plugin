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
	var agent := RegEx.create_from_string("^ScenarioGodot/" + Client.VERSION.replace(".", "\\.") + " \\(Godot \\d+\\.\\d+\\.\\d+-[a-z0-9]+; [A-Za-z]+\\)$")
	assert_not_null(agent.search(_header(call, "User-Agent")), _header(call, "User-Agent"))


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


func test_version_matches_plugin_cfg() -> void:
	# The User-Agent and the MCP clientInfo carry this version; release-please bumps both.
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("res://addons/scenario/plugin.cfg"), OK)
	assert_eq(Client.VERSION, cfg.get_value("plugin", "version"))


const OAuth := preload("res://addons/scenario/core/oauth.gd")
const OAuthSession := preload("res://addons/scenario/core/oauth_session.gd")


func _sign_in(expires_in: float = 3600.0) -> OAuthSession:
	var session := OAuthSession.new(OAuth.new(fake, "https://idp.example.test", "client_godot"),
		{"access_token": "at_1", "refresh_token": "rt_1", "expires_at": Time.get_unix_time_from_system() + expires_in})
	session.set_workspace({"id": "team_a", "name": "A"}, {"id": "proj_a1", "name": "Game"})
	client.set_session(session)
	return session


func _token_reply(access: String) -> Dictionary:
	return {"http": 200, "body": JSON.stringify({"access_token": access, "refresh_token": "rt_" + access, "expires_in": 3600})}


func test_signed_in_calls_carry_the_bearer_and_the_project() -> void:
	_sign_in()
	fake.replies.append({"fixture": "job"})
	await client.get_job("job_1")
	var call: Dictionary = fake.tool_calls()[0]
	assert_eq(_header(call, "Authorization"), "Bearer at_1")
	assert_eq(call["payload"]["params"]["arguments"], {"job_id": "job_1", "team_id": "team_a", "project_id": "proj_a1"})
	assert_eq(_header(fake.requests[0], "Authorization"), "Bearer at_1", "initialize too")


func test_a_job_is_read_in_its_own_project() -> void:
	_sign_in()
	fake.replies.append({"fixture": "job"})
	await client.get_job("job_1", {"team_id": "team_b", "project_id": "proj_b1"})
	assert_eq(fake.tool_calls()[0]["payload"]["params"]["arguments"]["project_id"], "proj_b1")


func test_teams_are_listed_without_a_project_and_projects_filled_in() -> void:
	var session := _sign_in()
	session.set_workspace({}, {})
	fake.replies.append(Fake.tool_result({"teams": [{"id": "team_a", "name": "A"}, {"id": "team_b", "projects": [{"id": "proj_b1"}]}]}))
	fake.replies.append(Fake.tool_result({"projects": [{"id": "proj_a1"}], "nextPaginationToken": "next"}))
	fake.replies.append(Fake.tool_result({"projects": [{"id": "proj_a2"}]}))
	var result: Dictionary = await client.list_teams()
	assert_true(result["ok"])
	assert_eq(result["value"][0]["projects"], [{"id": "proj_a1"}, {"id": "proj_a2"}])
	var calls := fake.tool_calls()
	assert_eq(calls[0]["payload"]["params"]["arguments"], {})
	assert_eq(calls[1]["payload"]["params"]["arguments"], {"team_id": "team_a", "limit": 100.0})
	assert_eq(calls[2]["payload"]["params"]["arguments"]["page_token"], "next")
	var refused: Dictionary = await client.get_job("job_1")
	assert_eq(refused["error"]["kind"], Errors.LOCAL, "nothing else goes out before a project is chosen")
	assert_eq(fake.tool_calls().size(), 3)


func test_a_refused_token_is_renewed_and_a_read_sent_again() -> void:
	_sign_in()
	fake.replies.append({"http": 401, "body": "{\"error\":\"invalid_token\"}"})
	fake.replies.append(_token_reply("at_2"))
	fake.replies.append({"fixture": "job"})
	var result: Dictionary = await client.get_job("job_1")
	assert_true(result["ok"])
	assert_eq(_header(fake.tool_calls()[1], "Authorization"), "Bearer at_2")


func test_a_paid_call_refused_for_its_token_is_not_sent_again() -> void:
	_sign_in()
	fake.replies.append({"http": 401, "body": "{\"error\":\"invalid_token\"}"})
	fake.replies.append(_token_reply("at_2"))
	var result: Dictionary = await client.submit("model_a", {"prompt": "p"})
	assert_false(result["ok"])
	assert_false(result["error"]["ambiguous"], "a refused request did not run")
	assert_eq(fake.tool_calls().size(), 1)
	assert_string_contains(result["error"]["message"], "nothing was sent")


func test_a_paid_call_goes_out_with_a_token_that_will_last() -> void:
	_sign_in(120.0)
	fake.replies.append(_token_reply("at_2"))
	fake.replies.append(Fake.tool_result({"job_id": "job_9", "status": "queued"}))
	var result: Dictionary = await client.submit("model_a", {"prompt": "p"})
	assert_true(result["ok"])
	assert_eq(_header(fake.tool_calls()[0], "Authorization"), "Bearer at_2")


func test_an_ended_session_sends_nothing() -> void:
	var session := _sign_in(0.0)
	session.tokens["expires_at"] = 1.0
	fake.replies.append({"http": 400, "body": "{\"error\":\"invalid_grant\"}"})
	var result: Dictionary = await client.submit("model_a", {"prompt": "p"})
	assert_eq(result["error"]["kind"], Errors.AUTH)
	assert_false(result["error"]["ambiguous"])
	assert_eq(fake.tool_calls().size(), 0)


func test_signed_in_errors_speak_of_the_account() -> void:
	_sign_in()
	fake.replies.append({"http": 403, "body": "forbidden"})
	var result: Dictionary = await client.get_job("job_1")
	assert_string_contains(result["error"]["message"], "Scenario account")


func test_job_and_asset_listings_are_free_reads_with_the_tools_arguments() -> void:
	fake.replies.append(Fake.tool_result({"jobs": []}))
	fake.replies.append(Fake.tool_result({"jobs": [], "nextPaginationToken": "t2"}))
	fake.replies.append(Fake.tool_result({"assets": [], "estimatedTotalHits": 0}))
	await client.list_jobs(80)
	var page: Dictionary = await client.list_jobs_page(30, "t1")
	await client.list_assets({"name": "assets_list", "parameters": {"limit": 50}})
	var calls := fake.tool_calls().map(func(r: Dictionary) -> Dictionary: return r["payload"]["params"])
	assert_eq(calls[0]["arguments"], {"limit": 50.0}, "jobs_list takes limit (max 50), not page_size")
	assert_eq(calls[1]["arguments"], {"limit": 30.0, "page_token": "t1"})
	assert_eq(page["value"]["nextPaginationToken"], "t2")
	assert_eq([calls[2]["name"], calls[2]["arguments"]["name"]], ["scenario_tool_execute_read", "assets_list"])
	assert_false(Client.is_submission("scenario_tool_execute_read", {}) or Client.is_submission("jobs_list", {}))
	assert_true(Client.is_retryable("scenario_tool_execute_read", {}), "the read executor runs read-class tools only")


func test_each_call_reports_its_tool_and_outcome_only() -> void:
	var seen: Array = []
	client.called.connect(func(tool: String, dry_run: bool, ok: bool, kind: String, ms: int) -> void:
		seen.append([tool, dry_run, ok, kind, ms >= 0]))
	fake.replies.append({"fixture": "estimate"})
	await client.estimate("model_x", {"prompt": "a chest"})
	fake.replies.append({"http": 403, "body": "forbidden"})
	await client.get_job("job_1")
	assert_eq(seen, [["model_run", true, true, "", true], ["job_get", false, false, Errors.FORBIDDEN, true]])
