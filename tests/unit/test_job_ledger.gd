extends GutTest

const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const T0 := 1791105052.0  # 2026-10-04T09:10:52Z
var path := ""


func before_each() -> void:
	path = "res://tests/tmp_output/ledger-%d/jobs.json" % randi()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))


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


func test_rows_keep_their_project_and_reconcile_only_there() -> void:
	var ledger := _ledger()
	var scope := {"team_id": "team_a", "project_id": "proj_a1"}
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0, "", scope)
	ledger.mark_unknown(local_id, "timeout", T0)
	var row := _ledger().find(local_id)
	assert_eq([row["team_id"], row["project_id"]], ["team_a", "proj_a1"])
	var server := [{"jobId": "job_1", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"}]
	assert_eq(ledger.reconcile(server, T0 + 10, "proj_other"), 0, "jobs listed in another project")
	assert_eq(ledger.reconcile(server, T0 + 10), 0, "jobs listed with an API key")
	assert_eq(ledger.reconcile(server, T0 + 10, "proj_a1"), 1)


func test_an_unknown_send_blocks_across_an_api_key_and_a_sign_in() -> void:
	var ledger := _ledger()
	var keyed := ledger.add_intent("image", "model_a", {"prompt": "a chest", "seed": 4}, "fp_key", 2.0, T0)
	ledger.mark_unknown(keyed, "timeout", T0)
	assert_true(_ledger().blocks_request("model_a", {"seed": 4.0, "prompt": "a chest"}, "proj_a1"), "same request, signed in")
	assert_false(ledger.blocks_request("model_a", {"prompt": "a chest", "seed": 5}, "proj_a1"))
	ledger.dismiss(keyed, T0)
	var scoped := ledger.add_intent("image", "model_a", {"prompt": "a chest"}, "fp_a1", 2.0, T0, "", {"team_id": "team_a", "project_id": "proj_a1"})
	ledger.mark_unknown(scoped, "timeout", T0)
	assert_true(ledger.blocks_request("model_a", {"prompt": "a chest"}, ""), "same request, with an API key")
	assert_false(ledger.blocks_request("model_a", {"prompt": "a chest"}, "proj_b1"), "another project is told apart by its fingerprint")


func test_a_row_linked_to_a_finished_job_is_read_for_its_outputs() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0)
	ledger.mark_unknown(local_id, "timeout", T0)
	ledger.reconcile([{"jobId": "job_1", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"}], T0 + 10)
	assert_eq(ledger.find(local_id)["state"], Ledger.SUCCESS)
	assert_eq(ledger.active().size(), 1, "polled once, for the outputs")
	ledger.apply_job({"jobId": "job_1", "status": "success", "assetIds": []}, T0 + 20)
	assert_eq(ledger.active().size(), 0, "one read is enough, even when the job had no outputs")
	assert_eq(_ledger().active().size(), 0, "and it stays read after a restart")


func test_adopted_results_are_finished_and_never_added_twice() -> void:
	var ledger := _ledger()
	var scope := {"team_id": "team_a", "project_id": "proj_a1"}
	var from_history := ledger.adopt("image", "model_x", "a chest", "job_9", ["asset_1", "asset_2"], T0, scope)
	var row := _ledger().find(from_history)
	assert_eq([row["state"], row["job_id"], row["asset_ids"], row["project_id"], row["source"]],
		[Ledger.SUCCESS, "job_9", ["asset_1", "asset_2"], "proj_a1", "history"])
	assert_true(ledger.unresolved().is_empty() and ledger.active().is_empty(), "nothing to poll or reconcile")
	assert_eq(ledger.adopt("image", "model_x", "a chest", "job_9", [], T0 + 1), from_history, "the same job reuses its row")
	var asset := ledger.adopt("image", "", "logo.png", "", ["asset_7"], T0, scope, "library")
	assert_eq(ledger.adopt("image", "", "logo.png", "", ["asset_7"], T0 + 1, scope, "library"), asset, "the same asset too")
	assert_ne(ledger.adopt("image", "", "icon.png", "", ["asset_8"], T0, scope, "library"), asset)
	assert_eq(ledger.jobs.size(), 3)


func test_a_job_an_unknown_row_may_stand_for() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0, "", {"team_id": "team_a", "project_id": "proj_a1"})
	ledger.mark_unknown(local_id, "timeout", T0)
	var job := {"jobId": "job_1", "modelId": "model_a", "createdAt": "2026-10-04T09:10:53.000Z"}
	assert_true(ledger.could_be_unresolved(job, "proj_a1"))
	assert_false(ledger.could_be_unresolved(job, "proj_b1"), "another project")
	assert_false(ledger.could_be_unresolved({"jobId": "job_2", "modelId": "model_b", "createdAt": job["createdAt"]}, "proj_a1"), "another model")
	assert_false(ledger.could_be_unresolved({"jobId": "job_3", "modelId": "model_a", "createdAt": "2026-10-05T09:00:00.000Z"}, "proj_a1"), "outside the window")
	ledger.dismiss(local_id, T0)
	assert_false(ledger.could_be_unresolved(job, "proj_a1"), "a dismissed row stands for nothing")


func test_rows_that_need_an_action_stay_in_the_jobs_list() -> void:
	var ledger := _ledger()
	var lost := ledger.add_intent("image", "model_a", {}, "fp_lost", 2.0, T0)
	ledger.mark_unknown(lost, "timeout", T0)
	var running := ledger.add_intent("image", "model_a", {}, "fp_run", 2.0, T0 + 1)
	ledger.mark_submitted(running, "job_run", "queued", T0 + 1)
	for i in 20:
		ledger.adopt("image", "", "import %d" % i, "job_imp_%d" % i, ["asset_%d" % i], T0 + 2 + i, {}, "library")
	var shown := ledger.shown(12)
	assert_eq(shown.size(), 12)
	assert_true(shown.any(func(r: Dictionary) -> bool: return r["local_id"] == lost), "Dismiss stays reachable")
	assert_true(shown.any(func(r: Dictionary) -> bool: return r["local_id"] == running), "Cancel stays reachable")
	assert_eq(shown[0]["state"], Ledger.SUCCESS, "newest first")
	ledger.dismiss(lost, T0 + 30)
	assert_false(ledger.shown(12).any(func(r: Dictionary) -> bool: return r["local_id"] == lost))


func test_an_intent_that_cannot_be_saved_is_not_kept() -> void:
	DirAccess.make_dir_recursive_absolute(path + ".tmp")  # a folder where the file goes
	var ledger := _ledger()
	assert_eq(ledger.add_intent("image", "m", {"prompt": "chest"}, "fp", 2.0, T0), "", "the caller sends nothing")
	assert_true(ledger.jobs.is_empty())
	DirAccess.remove_absolute(path + ".tmp")


func test_reconcile_links_a_job_only_one_unknown_row_could_stand_for() -> void:
	var ledger := _ledger()
	var older := ledger.add_intent("workflow", "wflow_a", {"prompt": "a chest"}, "fp_1", 2.0, T0)
	ledger.mark_unknown(older, "timeout", T0)
	var newer := ledger.add_intent("workflow", "wflow_a", {"prompt": "a lamp"}, "fp_2", 2.0, T0 + 2)
	ledger.mark_unknown(newer, "timeout", T0 + 2)
	var server := [{"jobId": "job_1", "workflowId": "wflow_a", "status": "success", "createdAt": "2026-10-04T09:10:56.000Z"}]
	assert_eq(ledger.reconcile(server, T0 + 10), 0, "either row could be the job's")
	assert_eq([ledger.find(older)["state"], ledger.find(newer)["state"]], [Ledger.UNKNOWN, Ledger.UNKNOWN])
	ledger.dismiss(newer, T0 + 20)
	assert_eq(ledger.reconcile(server, T0 + 30), 1)
	assert_eq(ledger.find(older)["job_id"], "job_1")


func test_a_dismissed_row_is_not_read_again() -> void:
	var ledger := _ledger()
	var local_id := ledger.add_intent("image", "model_a", {}, "fp", 2.0, T0)
	ledger.mark_unknown(local_id, "timeout", T0)
	ledger.reconcile([{"jobId": "job_1", "modelId": "model_a", "status": "success", "createdAt": "2026-10-04T09:10:53.000Z"}], T0 + 10)
	ledger.dismiss(local_id, T0 + 20)
	assert_true(ledger.active().is_empty(), "its outputs are not read, nor imported")
	assert_false(Ledger.needs_project(ledger.find(local_id)))


func test_rows_of_the_other_connection_method_are_set_aside() -> void:
	const JobScopes := preload("res://addons/scenario/core/job_scopes.gd")
	var ledger := _ledger()
	var with_key := ledger.add_intent("image", "m", {"prompt": "p"}, "fp_k", 2.0, T0)
	ledger.mark_submitted(with_key, "job_k", "queued", T0)
	var signed_in := ledger.add_intent("image", "m", {"prompt": "p"}, "fp_s", 2.0, T0, "", {"team_id": "t", "project_id": "proj"})
	ledger.mark_submitted(signed_in, "job_s", "queued", T0)
	assert_true(JobScopes.is_set_aside(ledger.find(with_key), true), "a key's row under a sign-in, until found")
	assert_false(JobScopes.is_set_aside(ledger.find(signed_in), true))
	assert_true(JobScopes.is_set_aside(ledger.find(signed_in), false), "a signed-in row under a key")
	assert_false(JobScopes.is_set_aside(ledger.find(with_key), false))
	ledger.dismiss(signed_in, T0)
	assert_false(JobScopes.is_set_aside(ledger.find(signed_in), false), "dismissed: nothing left to follow")
