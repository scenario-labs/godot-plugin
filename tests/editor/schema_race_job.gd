extends "res://addons/agentkit/agent_job.gd"
## Editor regression test (#64): two loads of the same model's schema overlap.
## Connecting an account starts loading the default lane's model, and picking
## that same model starts a second load. When the first load finishes last, it
## must not reset the form the second one already returned and the user filled.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const MODEL := "model_openai-gpt-image-2-5-flare"


## Holds every schema reply until the test opens its gate, so the test sets the order.
class GatedFake extends "res://tests/support/fake_scenario_node.gd":
	var gates: Array = []

	func post(url: String, headers: PackedStringArray, body: String, timeout_s: float) -> Dictionary:
		var payload: Dictionary = JSON.parse_string(body)
		if str(payload.get("method", "")) == "tools/call" and payload["params"]["name"] == "model_schema_get":
			var gate := Gate.new()
			gates.append(gate)
			await gate.opened
		return super(url, headers, body, timeout_s)


class Gate:
	signal opened


func run() -> Dictionary:
	await wait_frames(3)
	var run_dir := "res://tests/tmp_output/schema-race-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var fake := GatedFake.new()
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(fake, run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.credentials.use_keychain = false
	# Connecting loads the default model of the Image lane (GPT Image 2.5 Flare).
	if not controller.is_connected_account():
		controller._use_account("api_test", "sec_test", "file")
	await _until(func() -> bool: return fake.gates.size() == 1)
	# Picking the same model while it loads starts a second load.
	controller.select_model(MODEL)
	await _until(func() -> bool: return fake.gates.size() == 2)
	# The pick's load returns first and the form gets its prompt...
	fake.gates[1].opened.emit()
	await _until(func() -> bool: return not controller.fields.is_empty())
	controller.set_value("prompt", "a wooden treasure chest")
	# ...then the load started when the account connected returns.
	fake.gates[0].opened.emit()
	await wait_frames(5)

	var failures: Array = []
	if controller.prompt_text() != "a wooden treasure chest":
		failures.append("the prompt was reset by the older schema load: %s" % str(controller.values))
	if not controller.problems.is_empty():
		failures.append("the form reports %s" % str(controller.problems))
	controller.queue_free()
	return {"ok": failures.is_empty(), "checks": 2, "failures": failures, "paid_calls": fake.paid_calls.size()}


func _until(condition: Callable, frames: int = 600) -> void:
	for i in frames:
		if condition.call():
			return
		await root.get_tree().process_frame
