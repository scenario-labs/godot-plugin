extends GutTest

const Sse := preload("res://addons/scenario/core/sse.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")


func _fixture(name: String) -> String:
	return FileAccess.get_file_as_string("res://tests/fixtures/%s.sse" % name)


func test_every_recorded_fixture_parses_to_its_result() -> void:
	for name in ["estimate", "job", "jobs", "schema_patina", "schema_flare"]:
		var parsed := Sse.parse(_fixture(name), "text/event-stream", 2)
		assert_true(parsed["ok"], "fixture %s" % name)
		assert_true(parsed["value"].has("result"), "fixture %s has a result" % name)


func test_estimate_fixture_carries_the_price() -> void:
	var parsed := Sse.parse(_fixture("estimate"), "text/event-stream", 2)
	var structured: Dictionary = parsed["value"]["result"]["structuredContent"]
	assert_eq(structured["creativeUnitsCost"], 11.0)
	assert_eq(structured["job"], {})


func test_last_matching_message_wins_over_progress() -> void:
	var body := "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n" \
		+ "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"a\":1}}\n\n" \
		+ "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"a\":2}}\n\n"
	var parsed := Sse.parse(body, "text/event-stream", 7)
	assert_eq(parsed["value"]["result"]["a"], 2.0)


func test_malformed_event_does_not_hide_a_later_result() -> void:
	var body := "data: {not json\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\n\n"
	assert_true(Sse.parse(body, "text/event-stream", 3)["ok"])


func test_multiline_data_and_crlf() -> void:
	var body := "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\r\ndata: \"id\":4,\"result\":{\"x\":true}}\r\n\r\n"
	var parsed := Sse.parse(body, "text/event-stream", 4)
	assert_true(parsed["ok"])
	assert_eq(parsed["value"]["result"]["x"], true)


func test_done_marker_is_ignored() -> void:
	var body := "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\ndata: [DONE]\n\n"
	assert_true(Sse.parse(body, "text/event-stream", 1)["ok"])


func test_plain_json_reply_and_batch() -> void:
	assert_true(Sse.parse("{\"jsonrpc\":\"2.0\",\"id\":5,\"result\":{}}", "application/json", 5)["ok"])
	assert_true(Sse.parse("[{\"jsonrpc\":\"2.0\",\"id\":6,\"error\":{\"code\":-1}}]", "application/json", 6)["ok"])


func test_stream_detected_without_content_type() -> void:
	assert_true(Sse.parse("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n", "", 1)["ok"])


func test_reply_for_another_id_is_a_protocol_error() -> void:
	var parsed := Sse.parse("data: {\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}\n\n", "text/event-stream", 1)
	assert_false(parsed["ok"])
	assert_eq(parsed["error"]["kind"], Errors.PROTOCOL)


func test_empty_body() -> void:
	assert_true(Sse.parse("", "", null)["ok"], "a notification may get an empty reply")
	assert_false(Sse.parse("  ", "", 1)["ok"])


func test_invalid_json_body() -> void:
	assert_eq(Sse.parse("<html>", "text/html", 1)["error"]["kind"], Errors.PROTOCOL)


func test_float_and_int_ids_match() -> void:
	assert_true(Sse.parse("{\"jsonrpc\":\"2.0\",\"id\":12,\"result\":{}}", "application/json", 12)["ok"])
