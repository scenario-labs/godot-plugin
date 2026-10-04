extends "res://addons/agentkit/agent_job.gd"
## FREE live contract check (0 CU) against Scenario, through the real plugin
## controller and HTTP transport: every model listed in lanes.gd loads its
## schema, prices with its presets (or reports the input it still needs),
## "More" returns models where the lane allows it, and with SCENARIO_NO_SPEND=1
## Generate is refused before any request. Run through tools/contract_check.py.

const Controller := preload("res://addons/scenario/editor/controller.gd")
const HttpTransport := preload("res://addons/scenario/editor/http_transport.gd")
const Lanes := preload("res://addons/scenario/core/lanes.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const Form := preload("res://addons/scenario/core/schema_form.gd")

const PROMPTS := {
	"image": "a wooden treasure chest with brass trim, game prop",
	"model3d": "a wooden treasure chest with brass trim",
	"material": "mossy cobblestone floor",
	"skybox": "alpine valley at dawn, snowy peaks",
	"sound": "bright coin pickup chime",
}


func run() -> Dictionary:
	await wait_frames(3)
	if OS.get_environment("SCENARIO_NO_SPEND") != "1":
		return {"ok": false, "error": "Run with SCENARIO_NO_SPEND=1 (tools/contract_check.py sets it)."}
	var run_dir := "res://tests/tmp_output/contract-%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var controller := Controller.new()
	root.add_child(controller)
	controller.setup(HttpTransport.new(), run_dir + "/jobs.json", run_dir + "/credentials.json")
	controller.auto_import = false
	if not controller.is_connected_account():
		return {"ok": false, "error": "SCENARIO_API_KEY / SCENARIO_API_SECRET not set"}

	var ok := true
	var models: Array = []
	var recommendations: Array = []
	for lane in Lanes.LANES:
		var lane_id: String = lane["id"]
		controller.lane_id = lane_id
		controller.values = {}
		for model in lane["models"]:
			await controller.select_model(model["id"])
			var row := {"lane": lane_id, "model": model["id"], "fields": controller.fields.size(), "state": "", "cu": null, "note": ""}
			var prompt_name := Form.prompt_name(controller.fields)
			var needs_file := controller.fields.any(func(f: Dictionary) -> bool: return f["required"] and f["type"] in ["file", "files"])
			if controller.fields.is_empty() or (prompt_name.is_empty() and not needs_file):
				row["state"] = "schema"
				row["note"] = controller.price_message if controller.fields.is_empty() else "neither a prompt nor a required input file"
				ok = false
			else:
				if not prompt_name.is_empty():
					controller.set_value(prompt_name, PROMPTS[lane_id])
				await controller.estimate_now()
				row["state"] = controller.price_state
				row["cu"] = controller.price_cu if controller.price_state == Controller.PRICE_READY else null
				row["note"] = controller.price_message
				# "invalid" is a local form problem (an image-to-3D model needs its image): expected.
				if not controller.price_state in [Controller.PRICE_READY, Controller.PRICE_INVALID]:
					ok = false
			models.append(row)
		if lane.get("recommend", true):
			await controller.select_model(Lanes.default_model(lane_id))
			controller.set_value("prompt", PROMPTS[lane_id])
			controller.recommended.erase(lane_id)
			await controller.load_recommendations()
			var found: Array = controller.recommended.get(lane_id, [])
			recommendations.append({"lane": lane_id, "count": found.size(), "first": found[0]["id"] if not found.is_empty() else ""})
			if found.is_empty() or not found.all(func(m: Dictionary) -> bool: return str(m["id"]).begins_with("model_")):
				ok = false

	# The spending switch: priced, confirmed, and still refused locally.
	await controller.select_lane("sound")
	controller.set_value("prompt", PROMPTS["sound"])
	await controller.estimate_now()
	var priced := controller.price_state == Controller.PRICE_READY
	var sent: Dictionary = await controller.generate(true)
	var row := controller.ledger.find(str(sent.get("local_id", "")))
	var refused: bool = priced and not sent.get("ok", true) and row.get("state") == Ledger.REJECTED \
		and str(row.get("error", "")).contains("SCENARIO_NO_SPEND") and str(row.get("job_id", "")).is_empty()
	ok = ok and refused
	controller.queue_free()
	return {"ok": ok, "models": models, "recommendations": recommendations, "no_spend_refused": refused}
