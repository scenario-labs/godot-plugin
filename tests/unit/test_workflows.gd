extends GutTest
## Scenario workflows: picker entries, inputs to form, price and run through
## workflow_run, placement by file type, and their jobs in the ledger.

const Workflows := preload("res://addons/scenario/core/workflows.gd")
const Form := preload("res://addons/scenario/core/schema_form.gd")
const Client := preload("res://addons/scenario/core/mcp_client.gd")
const Errors := preload("res://addons/scenario/core/errors.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")
const FakeTransport := preload("res://tests/support/fake_transport.gd")
const FakeNode := preload("res://tests/support/fake_scenario_node.gd")

var fake: FakeTransport
var client: Client
var ledger_path := ""


func before_each() -> void:
	fake = FakeTransport.new()
	client = Client.new(fake, "api_key_1", "secret_1")
	client.spending_disabled = false
	ledger_path = "user://test_workflow_jobs_%d.json" % randi()


func after_each() -> void:
	for suffix in ["", ".tmp"]:
		if FileAccess.file_exists(ledger_path + suffix):
			DirAccess.remove_absolute(ledger_path + suffix)


func _arguments(index: int = 0) -> Dictionary:
	return fake.tool_calls()[index]["payload"]["params"]["arguments"]


func test_entries_keep_ready_workflows_only() -> void:
	var entries := Workflows.entries(FakeNode.WORKFLOWS["private"])
	assert_eq(entries, [{"id": "workflow_prop3d", "name": "Prop to 3D", "note": "Concept image, then a textured GLB"},
		{"id": "workflow_kit", "name": "Prop Kit", "note": "Image, model and sound"}], "a draft cannot run")
	var public := Workflows.entries(FakeNode.WORKFLOWS["public"], true)
	assert_eq(public[0]["note"], "public, Three takes of one sound")
	assert_eq(public[1]["note"], "public")
	var long := Workflows.entries([{"id": "workflow_x", "name": "X", "description": "a".repeat(80) + "\nsecond line"}])
	assert_eq(long[0]["note"].length(), 60)
	assert_eq(Workflows.entries([{"id": "model_x"}, "junk"]), [])


func test_inputs_become_form_fields() -> void:
	var schema := Workflows.schema_from({"id": "workflow_prop3d", "inputs_definition": FakeNode.WORKFLOW_INPUTS["workflow_prop3d"]})
	assert_eq(schema["unsupported"], PackedStringArray(), "an optional list input is left to the workflow's default")
	var fields := Form.fields_from_schema(schema)
	var by_name := {}
	for field in fields:
		by_name[field["name"]] = field
	assert_false(by_name.has("extraSteps"))
	assert_eq(by_name["objectPrompt"]["type"], "prompt", "a text input named like a prompt labels the job")
	assert_eq(by_name["objectPrompt"]["label"], "Object", "the workflow's own label")
	assert_eq(by_name["style"]["type"], "enum")
	assert_eq(by_name["style"]["options"], ["stylized", "realistic"])
	assert_eq(by_name["referenceImage"]["type"], "file")
	assert_eq(by_name["detail"]["type"], "integer")
	assert_true(by_name["detail"]["cost_impact"])
	assert_eq(by_name["transparent"]["type"], "boolean")
	var values := Form.initial_values(fields)
	values["objectPrompt"] = "a lantern"
	assert_eq(Form.validate(fields, values), PackedStringArray())
	assert_eq(Form.payload(fields, values), {"objectPrompt": "a lantern", "style": "stylized", "detail": 2, "transparent": true})


func test_a_required_input_the_dock_cannot_fill_blocks_the_price() -> void:
	var schema := Workflows.schema_from({"inputs_definition": FakeNode.WORKFLOW_INPUTS["workflow_pubbatch"]})
	assert_eq(schema["unsupported"], PackedStringArray(["sprites"]))
	var fields := Form.fields_from_schema(schema)
	var problems := Form.validate(fields, {"prompt": "slimes"})
	assert_eq(problems.size(), 1)
	assert_string_contains(problems[0], "run this workflow on Scenario")
	assert_false(Form.payload(fields, {"prompt": "slimes"}).has("sprites"))


func test_inputs_given_as_a_map_and_file_arrays() -> void:
	var schema := Workflows.schema_from({"inputs": {"refs": {"type": "file", "array": true}, "seed": {"type": "number"}}})
	var types := {}
	for field in Form.fields_from_schema(schema):
		types[field["name"]] = field["type"]
	assert_eq(types, {"refs": "files", "seed": "integer"})


func test_outputs_are_placed_by_file_type() -> void:
	var png := {"path": "res://a/x.png", "role": "main"}
	var glb := {"path": "res://a/y.glb", "role": "main"}
	var mp3 := {"path": "res://a/z.mp3", "role": "main"}
	assert_eq(Workflows.groups([png, glb, mp3]), {"model3d": [glb, png], "sound": [mp3]}, "the sound is placed too")
	assert_eq(png["role"], "preview", "an image next to a GLB is its preview")
	var image := {"path": "res://a/x.webp", "role": "main"}
	assert_eq(Workflows.groups([image, mp3]), {"image": [image], "sound": [mp3]}, "an image first never reaches the sound player")
	assert_eq(Workflows.groups([]), {})


func test_3d_outputs_are_downloaded_as_glb() -> void:
	assert_eq(Workflows.download_format({"mimeType": "model/gltf-binary"}), "glb")
	assert_eq(Workflows.download_format({"mimeType": "application/octet-stream", "metadata": {"type": "inference-txt23d"}}), "glb")
	assert_eq(Workflows.download_format({"mimeType": "image/png", "metadata": {"type": "inference-txt2img"}}), "")
	assert_eq(Workflows.download_format({"metadata": null}), "")


func test_flags_sent_as_null_or_text_are_read() -> void:
	var schema := Workflows.schema_from({"inputs_definition": [
		{"name": "refs", "type": "file", "array": "true"},
		{"name": "steps", "type": "inputs_array", "required": null},
		{"name": "models", "type": "model_array", "required": "true"},
	]})
	assert_eq(schema["parameters"][0]["type"], "file_array")
	assert_eq(schema["unsupported"], PackedStringArray(["models"]))


func test_a_workflow_is_priced_with_a_dry_run_and_never_retried() -> void:
	fake.replies.append(FakeTransport.tool_result({"creativeUnitsCost": 18, "creativeUnitsDiscount": 0}))
	var result: Dictionary = await client.estimate("workflow_prop3d", {"objectPrompt": "lantern"})
	assert_true(result["ok"])
	assert_eq(result["value"]["cu"], 18.0)
	var arguments := _arguments()
	assert_eq(fake.tool_calls()[0]["payload"]["params"]["name"], "workflow_run")
	assert_eq(arguments, {"workflow_id": "workflow_prop3d", "inputs": {"objectPrompt": "lantern"}, "dry_run": true})
	assert_false(Client.is_retryable("workflow_run", {"dry_run": true}), "a run started by mistake fans out")
	assert_false(Client.is_submission("workflow_run", {"dry_run": true}))
	assert_true(Client.is_submission("workflow_run", {}))


func test_a_workflow_price_that_returns_a_job_is_an_alarm() -> void:
	fake.replies.append(FakeTransport.tool_result({"creativeUnitsCost": 18, "job": {"jobId": "job_started"}}))
	var result: Dictionary = await client.estimate("workflow_prop3d", {})
	assert_eq(result["error"]["kind"], Errors.ESTIMATE_JOB)


func test_a_workflow_run_is_sent_once_and_reads_its_job() -> void:
	fake.replies.append(FakeTransport.tool_result({"job": {"jobId": "job_wf1", "status": "queued"}, "workflow": {"id": "workflow_prop3d"}}))
	var result: Dictionary = await client.submit("workflow_prop3d", {"objectPrompt": "lantern"})
	assert_eq(result["value"], {"job_id": "job_wf1", "status": "queued"})
	assert_eq(_arguments(), {"workflow_id": "workflow_prop3d", "inputs": {"objectPrompt": "lantern"}})
	fake.replies.append({"error": "timeout"})
	fake.replies.append(FakeTransport.tool_result({"job": {"jobId": "job_never"}}))
	var lost: Dictionary = await client.submit("workflow_prop3d", {"objectPrompt": "lantern"})
	assert_true(lost["error"]["ambiguous"])
	assert_eq(fake.tool_calls().size(), 2, "a paid run is never sent again")


func test_no_spend_refuses_a_workflow_run_but_prices_it() -> void:
	client.spending_disabled = true
	assert_eq((await client.submit("workflow_prop3d", {}))["error"]["kind"], Errors.LOCAL)
	assert_eq(fake.requests.size(), 0)
	fake.replies.append(FakeTransport.tool_result({"creativeUnitsCost": 18}))
	assert_true((await client.estimate("workflow_prop3d", {}))["ok"])


func test_workflow_form_and_listing_through_the_client() -> void:
	fake.replies.append(FakeTransport.tool_result({"workflow": {"id": "workflow_prop3d", "inputs_definition": FakeNode.WORKFLOW_INPUTS["workflow_prop3d"]}}))
	var schema: Dictionary = await client.get_schema("workflow_prop3d")
	assert_eq(fake.tool_calls()[0]["payload"]["params"]["name"], "workflow_get")
	assert_eq(schema["value"]["parameters"].size(), 5)
	fake.replies.append(FakeTransport.tool_result({"workflows": FakeNode.WORKFLOWS["private"]}))
	fake.replies.append(FakeTransport.tool_result({"workflows": FakeNode.WORKFLOWS["public"]}))
	var listed: Dictionary = await client.list_workflows()
	assert_eq(listed["value"].map(func(e: Dictionary) -> String: return e["id"]), ["workflow_prop3d", "workflow_kit", "workflow_pubsfx", "workflow_pubbatch"])
	assert_eq(_arguments(1), {"privacy": "private", "status": "ready", "limit": 100.0}, "JSON numbers read back as floats")
	assert_eq(_arguments(2)["privacy"], "public")


func test_listing_keeps_the_project_when_the_public_catalog_fails() -> void:
	fake.replies.append(FakeTransport.tool_result({"workflows": FakeNode.WORKFLOWS["private"]}))
	fake.replies.append({"rpc_error": {"code": -32000, "message": "catalog down"}})
	var listed: Dictionary = await client.list_workflows()
	assert_true(listed["ok"])
	assert_eq(listed["value"].size(), 2)


func test_a_workflow_job_reconciles_by_its_workflow_id() -> void:
	var ledger := Ledger.new(ledger_path)
	var now := 1790000000.0
	var local_id := ledger.add_intent("workflow", "workflow_prop3d", {"objectPrompt": "lantern"}, "fp", 6.0, now)
	ledger.mark_unknown(local_id, "timeout", now)
	var created := Time.get_datetime_string_from_unix_time(int(now) + 2) + ".000Z"
	var server := [{"jobId": "job_wf9", "workflowId": "workflow_prop3d", "status": "running", "createdAt": created}]
	assert_eq(ledger.reconcile(server, now + 10), 1)
	assert_eq(ledger.find(local_id)["job_id"], "job_wf9")


func test_a_run_waiting_for_a_person_says_so_until_it_moves_on() -> void:
	var ledger := Ledger.new(ledger_path)
	var local_id := ledger.add_intent("workflow", "workflow_prop3d", {}, "fp", 6.0, 1.0)
	ledger.mark_submitted(local_id, "job_wf2", "queued", 1.0)
	var row := ledger.apply_job({"jobId": "job_wf2", "status": "in-progress", "awaiting_input": [{"node_id": "n"}]}, 2.0)
	assert_eq(row["state"], Ledger.RUNNING)
	assert_eq(row["error"], Ledger.AWAITING)
	row = ledger.apply_job({"jobId": "job_wf2", "status": "in-progress"}, 3.0)
	assert_eq(row["error"], "", "answered on Scenario")
