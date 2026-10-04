extends GutTest

const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const T0 := 1791105052.0  # 2026-10-04T09:10:52Z
var path := ""


func before_each() -> void:
	path = "user://test_ledger_%d.json" % randi()


func after_each() -> void:
	for suffix in ["", ".tmp", ".unreadable"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(path + suffix)


func _ledger() -> Ledger:
	var ledger := Ledger.new(path)
	ledger.load_from_disk()
	return ledger


func test_intent_is_on_disk_before_the_request() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {"prompt": "chest"}, "fp1", 2.0, T0)
	var reread := _ledger()
	assert_eq(reread.jobs.size(), 1)
	assert_eq(reread.find(local_id)["prompt"], "chest")


func test_reload_turns_submitting_into_unknown_and_blocks_resend() -> void:
	var ledger := _ledger()
	ledger.add_intent("image", "m", {"prompt": "chest"}, "fp1", 2.0, T0)
	var reread := _ledger()
	assert_eq(reread.jobs[0]["state"], Ledger.UNKNOWN)
	assert_true(reread.blocks("fp1"))
	assert_false(reread.blocks("fp2"))


func test_submitted_job_follows_server_status() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {"prompt": "chest"}, "fp1", 2.0, T0)
	ledger.mark_submitted(local_id, "job_1", "queued", T0 + 1)
	assert_eq(ledger.find(local_id)["state"], Ledger.QUEUED)
	assert_false(ledger.blocks("fp1"))
	ledger.apply_job({"jobId": "job_1", "status": "in-progress"}, T0 + 2)
	assert_eq(ledger.find(local_id)["state"], Ledger.RUNNING)
	ledger.apply_job({"jobId": "job_1", "status": "success", "assetIds": ["asset_a"], "cuCost": 2}, T0 + 3)
	var row := ledger.find(local_id)
	assert_eq(row["state"], Ledger.SUCCESS)
	assert_eq(row["asset_ids"], ["asset_a"])
	assert_eq(row["charged_cu"], 2.0)
	assert_eq(_ledger().find(local_id)["state"], Ledger.SUCCESS, "persisted")


func test_billing_shape_from_jobs_list() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {}, "fp", 2.0, T0)
	ledger.mark_submitted(local_id, "job_1", "queued", T0)
	ledger.apply_job({"jobId": "job_1", "status": "success", "billing": {"cuCost": 14}}, T0)
	assert_eq(ledger.find(local_id)["charged_cu"], 14.0)


func test_moderated_failure_is_blocked() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {}, "fp", 2.0, T0)
	ledger.mark_submitted(local_id, "job_1", "queued", T0)
	ledger.apply_job({"jobId": "job_1", "status": "failure", "error": "Content moderation flagged the prompt"}, T0)
	assert_eq(ledger.find(local_id)["state"], Ledger.BLOCKED)


func test_cancel_request_holds_until_scenario_reports_it() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {}, "fp", 2.0, T0)
	ledger.mark_submitted(local_id, "job_1", "in-progress", T0)
	ledger.mark_cancel_requested(local_id, T0)
	ledger.apply_job({"jobId": "job_1", "status": "in-progress"}, T0)
	assert_eq(ledger.find(local_id)["state"], Ledger.CANCEL_REQUESTED)
	ledger.apply_job({"jobId": "job_1", "status": "canceled"}, T0)
	assert_eq(ledger.find(local_id)["state"], Ledger.CANCELED)
	assert_eq(ledger.active().size(), 0)


func test_rejected_request_does_not_block() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "m", {}, "fp", 2.0, T0)
	ledger.mark_rejected(local_id, "Not enough Creative Units", T0)
	assert_false(ledger.blocks("fp"))
	assert_eq(ledger.unresolved().size(), 0)


func test_reconcile_links_a_single_match() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0)
	ledger.mark_unknown(local_id, "timeout", T0)
	var server := [
		{"jobId": "job_other_model", "modelId": "model_b", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"},
		{"jobId": "job_match", "modelId": "model_a", "status": "in-progress", "createdAt": "2026-10-04T09:10:54.500Z"},
		{"jobId": "job_too_late", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T10:30:00.000Z"},
	]
	assert_eq(ledger.reconcile(server, T0 + 10), 1)
	var row := ledger.find(local_id)
	assert_eq(row["job_id"], "job_match")
	assert_eq(row["state"], Ledger.RUNNING)
	assert_false(ledger.blocks("fp"))


func test_reconcile_leaves_ambiguous_matches_to_the_user() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0)
	ledger.mark_unknown(local_id, "timeout", T0)
	var server := [
		{"jobId": "job_1", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"},
		{"jobId": "job_2", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:55.000Z"},
	]
	assert_eq(ledger.reconcile(server, T0 + 10), 0)
	assert_eq(ledger.find(local_id)["state"], Ledger.UNKNOWN)
	ledger.dismiss(local_id, T0 + 20)
	assert_false(ledger.blocks("fp"))


func test_reconcile_skips_jobs_already_tracked() -> void:
	var ledger := _ledger()
	var tracked := ledger.add_intent("image", "model_a", {}, "fp_a", 2.0, T0)
	ledger.mark_submitted(tracked, "job_1", "success", T0)
	var unknown := ledger.add_intent("image", "model_a", {}, "fp_b", 2.0, T0)
	ledger.mark_unknown(unknown, "timeout", T0)
	var server := [{"jobId": "job_1", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"}]
	assert_eq(ledger.reconcile(server, T0), 0)


func test_iso_to_unix() -> void:
	assert_almost_eq(Ledger.iso_to_unix("2026-10-04T09:10:52.353Z"), T0 + 0.353, 0.001)
	assert_eq(Ledger.iso_to_unix("bad"), -1.0)


func test_trim_drops_finished_rows_first() -> void:
	var ledger := _ledger()
	var keep := ledger.add_intent("image", "m", {}, "fp_keep", 1.0, T0)
	ledger.mark_unknown(keep, "", T0)
	for i in Ledger.MAX_ROWS + 5:
		var id := ledger.add_intent("image", "m", {}, "fp_%d" % i, 1.0, T0 + i)
		ledger.mark_rejected(id, "", T0 + i)
	assert_eq(ledger.jobs.size(), Ledger.MAX_ROWS)
	assert_false(ledger.find(keep).is_empty(), "unresolved rows are never trimmed")


func test_unreadable_ledger_is_set_aside() -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("{broken")
	file.close()
	var ledger := _ledger()
	assert_eq(ledger.jobs.size(), 0)
	assert_true(FileAccess.file_exists(path + ".unreadable"))


func test_intent_keeps_an_explicit_prompt_label() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("sound", "model_elevenlabs-sound-effects-v2", {"text": "coin"}, "fp", 1.0, T0, "coin")
	assert_eq(ledger.find(local_id)["prompt"], "coin")
