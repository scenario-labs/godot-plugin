extends GutTest
## Opt-in usage data and feedback payloads: nothing before the opt-in, only
## allowlisted events and fields, and the install ID gone when sharing stops.

const Usage := preload("res://addons/scenario/core/usage.gd")
const Feedback := preload("res://addons/scenario/core/feedback.gd")

var state_path := ""


func before_each() -> void:
	state_path = "res://tests/tmp_output/usage-%d/usage.json" % Time.get_ticks_usec()


func _state() -> Dictionary:
	if not FileAccess.file_exists(state_path):
		return {}
	return JSON.parse_string(FileAccess.get_file_as_string(state_path))


func test_nothing_is_recorded_or_sent_before_the_opt_in() -> void:
	var usage := Usage.new(state_path)
	assert_false(usage.record("extension_started"))
	assert_eq(usage.queue, [])
	assert_eq(usage.take_batch(), {})
	assert_eq(usage.install_id(), "")
	assert_false(FileAccess.file_exists(state_path), "no file before a choice")


func test_opt_in_creates_a_random_install_id_and_opt_out_deletes_it() -> void:
	var usage := Usage.new(state_path)
	usage.set_enabled(true)
	var id := usage.install_id()
	assert_eq(id.length(), 32)
	assert_true(Usage._is_id(id))
	assert_eq(Usage.new(state_path).install_id(), "", "another instance is off until enabled")
	var again := Usage.new(state_path)
	again.set_enabled(true)
	assert_eq(again.install_id(), id, "the same ID across editor sessions")
	usage.record("extension_started")
	usage.set_enabled(false)
	assert_eq(usage.queue, [], "unsent events are dropped")
	assert_false(_state().has("install_id"))
	usage.set_enabled(true)
	assert_ne(usage.install_id(), id, "a new ID after opting in again")


func test_asked_once() -> void:
	var usage := Usage.new(state_path)
	assert_false(usage.asked())
	usage.mark_asked()
	assert_true(Usage.new(state_path).asked())
	usage.set_enabled(true)
	usage.set_enabled(false)
	assert_true(usage.asked(), "the answer survives the opt-out")


func test_only_allowlisted_events_and_properties_are_kept() -> void:
	var usage := Usage.new(state_path)
	usage.set_enabled(true)
	assert_false(usage.record("prompt_typed", {"prompt": "a chest"}))
	assert_true(usage.record("generation_sent", {"lane": "image", "cu": 12.75, "prompt": "a chest", "project_id": "proj_1"}))
	assert_true(usage.record("scenario_request", {"request": "generate", "outcome": "error", "error_kind": "quota", "duration_ms": 812.0}))
	assert_true(usage.record("scenario_request", {"request": "rm -rf", "outcome": "maybe", "error_kind": "secret", "duration_ms": -3}))
	assert_true(usage.record("generation_finished", {"lane": "video", "state": "success", "cu": INF}))
	var events: Array = usage.queue.map(func(e: Dictionary) -> Dictionary: return e["properties"])
	assert_eq(events[0], {"lane": "image", "cu": 12.75})
	assert_eq(events[1], {"request": "generate", "outcome": "error", "error_kind": "quota", "duration_ms": 812})
	assert_typeof(events[1]["duration_ms"], TYPE_INT)
	assert_eq(events[2], {})
	assert_eq(events[3], {"state": "success"})
	assert_true(str(usage.queue[0]["timestamp"]).ends_with("Z"))


func test_batches_carry_the_id_and_context_and_leave_the_rest_queued() -> void:
	var usage := Usage.new(state_path)
	usage.set_enabled(true)
	for i in Usage.MAX_BATCH + 20:
		usage.record("extension_started")
	assert_true(usage.should_flush())
	var batch := usage.take_batch()
	assert_eq(batch["install_id"], usage.install_id())
	assert_eq(batch["events"].size(), Usage.MAX_BATCH)
	assert_eq(usage.queue.size(), 20)
	assert_eq(batch["context"].keys(), ["plugin_version", "godot_version", "os", "arch"])
	var text := JSON.stringify(batch)
	for word in ["prompt", "res://", "proj_", "team_", "api_"]:
		assert_false(text.contains(word), word)


func test_an_unknown_send_is_not_an_end() -> void:
	assert_false("unknown" in Usage.FINISHED, "it may still resolve to done or failed")
	assert_true("dismissed" in Usage.FINISHED)


func test_the_queue_is_bounded() -> void:
	var usage := Usage.new(state_path)
	usage.set_enabled(true)
	for i in Usage.MAX_QUEUE + 5:
		usage.record("extension_started")
	assert_eq(usage.queue.size(), Usage.MAX_QUEUE)


func test_relay_url_can_point_at_a_development_relay() -> void:
	assert_eq(Usage.relay_url("events"), "https://godot.scenario.com/telemetry/v1/events")
	OS.set_environment("SCENARIO_TELEMETRY_URL", "http://127.0.0.1:3000/telemetry/v1/")
	assert_eq(Usage.relay_url("feedback"), "http://127.0.0.1:3000/telemetry/v1/feedback")
	OS.unset_environment("SCENARIO_TELEMETRY_URL")


func test_feedback_form_checks() -> void:
	assert_eq(Feedback.problem(0, "", ""), "Choose a rating from 1 to 5.")
	assert_eq(Feedback.problem(6, "", ""), "Choose a rating from 1 to 5.")
	assert_eq(Feedback.problem(3, "", ""), "")
	assert_string_contains(Feedback.problem(3, "x".repeat(Feedback.MAX_MESSAGE + 1), ""), "Shorten")
	for email in ["not an address", "a@b", "@example.com", "a@@example.com", "a b@example.com"]:
		assert_string_contains(Feedback.problem(3, "", email), "email", email)
	assert_eq(Feedback.problem(3, "", " me@example.com "), "")
	assert_string_contains(Feedback.problem(3, "", "me\t@example.com"), "email", "any whitespace, as the relay")
	assert_string_contains(Feedback.problem(3, "", "a".repeat(65) + "@example.com"), "email", "local part over 64")
	assert_eq(Feedback.problem(3, "", "a".repeat(64) + "@example.com"), "")
	# An emoji is two UTF-16 units: the relay's limit counts those, not characters.
	assert_string_contains(Feedback.problem(3, "\U01F600".repeat(Feedback.MAX_MESSAGE / 2 + 1), ""), "Shorten")
	assert_eq(Feedback.problem(3, "\U01F600".repeat(Feedback.MAX_MESSAGE / 2), ""), "")


func test_feedback_keeps_its_submission_id_until_sent() -> void:
	const ID := "0123456789abcdef0123456789abcdef"
	var feedback := Feedback.new()
	var first := feedback.payload(4, "  Works well ", "", ID)
	assert_eq(first["message"], "Works well")
	assert_false(first.has("email"))
	assert_eq(first["install_id"], ID, "the install ID while usage data is shared")
	assert_eq(first["submission_id"].length(), 32)
	var retry := feedback.payload(3, "Works", "", ID)
	assert_eq(retry["submission_id"], first["submission_id"], "a retry is the same submission")
	var with_email := feedback.payload(4, "Works well", " me@example.com ", ID)
	assert_eq(with_email["email"], "me@example.com")
	assert_false(with_email.has("install_id"), "an address is never tied to the usage install ID")
	assert_ne(with_email["submission_id"], first["submission_id"], "adding an address starts a new submission")
	assert_eq(feedback.payload(3, "Works", "me@example.com", ID)["submission_id"], with_email["submission_id"])
	var off := feedback.payload(3, "Works", "")
	assert_false(off.has("install_id"), "no install ID while usage data is off")
	feedback.sent()
	assert_ne(feedback.payload(5, "", "")["submission_id"], off["submission_id"])
