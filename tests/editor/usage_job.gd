extends "res://addons/agentkit/agent_job.gd"
## Headless editor test of opt-in usage data and feedback, against the fake
## backend and a stand-in for the website relay: the dock asks once after the
## first connection, No thanks records nothing, sharing records allowlisted
## events and sends them in a batch, turning it off deletes the install ID, and
## the feedback dialog keeps its text until a send succeeds.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const DockUI := preload("res://addons/scenario/editor/dock_ui.gd")
const UsageReporter := preload("res://addons/scenario/editor/usage_reporter.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Fake := preload("res://tests/support/fake_scenario_node.gd")


## The website relay: records each post and answers with the next status.
class Relay:
	extends RefCounted
	var posts: Array = []
	var statuses: Array = []

	func post(url: String, _headers: PackedStringArray, body: String, _timeout_s: float) -> Dictionary:
		posts.append({"url": url, "body": JSON.parse_string(body), "text": body})
		var status: int = statuses.pop_front() if not statuses.is_empty() else 202
		return {"status": status, "headers": {}, "body": "{}", "error": ""}


var failures: Array = []
var checks := 0


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/usage-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var fake := Fake.new()
	root.add_child(fake)
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.credentials.use_keychain = false
	controller.output_root = run_dir + "/scenario"
	controller.auto_import = false

	var relay := Relay.new()
	var reporter := UsageReporter.new()
	root.add_child(reporter)
	reporter.setup(controller, relay, run_dir + "/usage.json")
	check("a headless editor never sends", reporter.offline)
	reporter.offline = false  # this test stands in for a windowed editor
	reporter.start()
	var ui := DockUI.new()
	ui.reporter = reporter
	root.add_child(ui)
	ui.bind(controller)
	check("not asked before a connection", not reporter.should_ask() and not ui._consent_box.is_visible_in_tree())

	# First connection: the dock asks once. No thanks records nothing.
	controller.client.set_credentials("api_test", "sec_test")
	controller.account = {"api_key": "api_test", "source": "test", "method": "api_key"}
	controller.changed.emit()
	await wait_frames(1)
	check("asked after the first connection", reporter.should_ask() and ui._consent_box.visible)
	await controller.client.list_jobs(1)  # connect_account's key check: the connection is confirmed
	# Turned on in Editor Settings while the card shows: the card goes, the connection is recorded.
	reporter.set_sharing(true)
	await wait_frames(1)
	check("on from Editor Settings: the card goes", not ui._consent_box.visible and not reporter.should_ask())
	check("sharing on while connected: the connection is recorded", reporter.usage.queue.any(func(e: Dictionary) -> bool:
		return e["event"] == "connected" and e["properties"] == {"method": "api_key"}))
	# A key Scenario rejects: its check is recorded, a connection is not.
	controller.client.set_credentials("", "")
	controller.account = {"api_key": "", "source": "", "method": ""}
	controller.changed.emit()
	controller.client.set_credentials("api_bad", "sec_bad")
	controller.account = {"api_key": "api_bad", "source": "test", "method": "api_key"}
	controller.changed.emit()
	reporter._on_called("jobs_list", {"page_size": 1}, false, "auth", 40)
	var connections: Array = reporter.usage.queue.filter(func(e: Dictionary) -> bool: return e["event"] == "connected")
	var key_checks: Array = reporter.usage.queue.filter(func(e: Dictionary) -> bool:
		return e["event"] == "scenario_request" and e["properties"]["request"] == "check_key")
	check("a rejected key is not counted as a connection", connections.size() == 1 and key_checks.size() == 1
		and key_checks[0]["properties"]["error_kind"] == "auth")
	controller.client.set_credentials("api_test", "sec_test")
	controller.account = {"api_key": "api_test", "source": "test", "method": "api_key"}
	controller.changed.emit()
	reporter.set_sharing(false)
	var answers: Array = []
	reporter.sharing_chosen.connect(func(share: bool) -> void: answers.append(share))
	ui._choose_sharing(false)
	check("No thanks: not asked again, nothing on", not reporter.should_ask() and not ui._consent_box.visible
		and not reporter.usage.enabled and answers == [false] and reporter.usage.queue.is_empty())
	await _generate(controller, "a wooden chest, game prop")
	reporter.flush()
	check("No thanks: nothing queued or sent", reporter.usage.queue.is_empty() and relay.posts.is_empty())
	check("No thanks: no install ID saved", not FileAccess.get_file_as_string(run_dir + "/usage.json").contains("install_id"))

	# Sharing turned on in Editor Settings: allowlisted events, one batch.
	reporter.set_sharing(true)
	var install_id := reporter.usage.install_id()
	check("sharing on: a random install ID", install_id.length() == 32)
	await _generate(controller, "a secret prompt about treasure")
	var events: Array = reporter.usage.queue.map(func(e: Dictionary) -> String: return e["event"])
	check("sharing on: requests and the generation are recorded", "scenario_request" in events
		and "generation_sent" in events and "generation_finished" in events)
	var finished: Array = reporter.usage.queue.filter(func(e: Dictionary) -> bool: return e["event"] == "generation_finished")
	check("generation_finished has the lane, state and CU", finished.size() == 1
		and finished[0]["properties"] == {"lane": "image", "state": "success", "cu": 2.0})
	var price: Array = reporter.usage.queue.filter(func(e: Dictionary) -> bool:
		return e["event"] == "scenario_request" and e["properties"]["request"] == "price_check")
	check("a price check is told apart from a generation", not price.is_empty() and price[0]["properties"]["outcome"] == "ok")
	await reporter.flush()
	check("one batch to the relay", relay.posts.size() == 1 and str(relay.posts[0]["url"]).ends_with("/telemetry/v1/events"))
	var batch: Dictionary = relay.posts[0]["body"]
	check("the batch carries the install ID and context", batch.get("install_id") == install_id
		and batch.get("context", {}).has("godot_version") and batch.get("events", []).size() == events.size())
	var text: String = relay.posts[0]["text"]
	check("the batch has no prompt, path, key or job id", not text.contains("secret prompt") and not text.contains("res://")
		and not text.contains("api_test") and not text.contains("job_fake") and not text.contains("local_"))
	check("the queue is empty after the batch", reporter.usage.queue.is_empty())

	# Turned off: the queue is dropped and the ID deleted.
	reporter.usage.record("extension_started")
	reporter.set_sharing(false)
	await reporter.flush()
	check("sharing off: queue dropped, ID deleted, nothing sent", reporter.usage.queue.is_empty()
		and reporter.usage.install_id() == "" and relay.posts.size() == 1
		and not FileAccess.get_file_as_string(run_dir + "/usage.json").contains(install_id))

	# Feedback: from the footer menu, works with sharing off, keeps the text on failure.
	ui._on_menu(DockUI.MENU_FEEDBACK)
	await wait_frames(1)
	check("feedback dialog opens from the menu", ui._feedback.visible)
	ui._feedback.fill(4, "The dock is handy", "not an address")
	await ui._feedback._on_send()
	check("a bad address is refused before sending", ui._feedback.status_text().contains("email") and relay.posts.size() == 1)
	ui._feedback.fill(4, "The dock is handy", "me@example.com")
	relay.statuses = [500]
	await ui._feedback._on_send()
	check("a failed send keeps the text", ui._feedback.visible and ui._feedback.message_text() == "The dock is handy"
		and ui._feedback.status_text().contains("kept") and relay.posts.size() == 2)
	relay.statuses = [200]
	await ui._feedback._on_send()
	var sent: Dictionary = relay.posts[2]["body"]
	check("feedback sent to the relay", str(relay.posts[2]["url"]).ends_with("/telemetry/v1/feedback") and sent.get("rating") == 4.0
		and sent.get("message") == "The dock is handy" and sent.get("email") == "me@example.com")
	check("a retry is the same submission", sent.get("submission_id") == relay.posts[1]["body"].get("submission_id"))
	check("no install ID with sharing off", not sent.has("install_id"))
	check("the dialog closes and clears after a send", not ui._feedback.visible and ui._feedback.message_text() == "")

	reporter.offline = true
	var refused: Dictionary = await reporter.send_feedback(5, "", "")
	check("offline: feedback refused, nothing sent", not refused["ok"] and relay.posts.size() == 3)

	var paid := fake.paid_calls.size()
	ui.queue_free()
	reporter.queue_free()
	controller.queue_free()
	fake.queue_free()
	await wait_frames(2)
	return {"ok": failures.is_empty(), "checks": checks, "failures": failures, "paid_calls": paid}


func _generate(controller: Controller, prompt: String) -> void:
	await controller.select_lane("image")
	controller.set_value("prompt", prompt)
	await controller.estimate_now()
	var sent: Dictionary = await controller.generate(true)
	await controller.poll()
	check("generated: " + prompt, controller.ledger.find(sent.get("local_id", "")).get("state") == Ledger.SUCCESS)
