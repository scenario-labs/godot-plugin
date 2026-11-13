extends GutTest

const Query := preload("res://addons/scenario/core/library_query.gd")


func test_browse_lists_placeable_kinds_newest_first() -> void:
	var args := Query.search_args("all", "all", "", 0)
	assert_eq(args["target"], "assets")
	assert_eq(args["filter"], "kind IN [\"image\", \"image-hdr\", \"3d\", \"audio\"]")
	assert_eq(args["sort_by"], ["createdAt:desc"])
	assert_true(args["include_urls"], "thumbnails come as signed CDN URLs")
	assert_false(args.has("query"))
	assert_eq([args["offset"], args["limit"]], [0, Query.PAGE_SIZE])


func test_filters_and_search() -> void:
	assert_eq(Query.search_args("3d", "all", "", 24)["filter"], "kind = \"3d\"")
	assert_eq(Query.search_args("image", "generated", "", 0)["filter"], "kind IN [\"image\", \"image-hdr\"] AND modelId EXISTS")
	assert_eq(Query.search_args("audio", "uploaded", "", 0)["filter"], "kind = \"audio\" AND NOT modelId EXISTS")
	var searched := Query.search_args("unknown", "unknown", "  chest  ", -3, 500)
	assert_eq(searched["query"], "chest")
	assert_false(searched.has("sort_by"), "a text search ranks by relevance")
	assert_eq(searched["filter"], Query.search_args("all", "all", "", 0)["filter"])
	assert_eq([searched["offset"], searched["limit"]], [0, 100])


func test_page_rows_from_search_hits() -> void:
	var page := Query.parse_page({"assets": [
		{"id": "asset_a", "kind": "image", "mimeType": "image/png", "createdAt": "2026-11-13T10:00:00.000Z", "name": "",
			"metadata": {"modelId": "model_x", "prompt": "a chest"}, "thumbnail": {"url": "https://cdn.cloud.scenario.com/t/a"}},
		{"id": "asset_b", "kind": "image", "name": "logo.png", "url": "https://cdn.cloud.scenario.com/f/b"},
		{"id": "asset_c", "kind": "audio", "name": "hit.wav", "url": "https://cdn.cloud.scenario.com/f/c"},
		{"kind": "image"},
	], "estimatedTotalHits": 40, "offset": 0})
	assert_eq(page["total"], 40)
	assert_eq(page["assets"].size(), 3, "a hit without an id is dropped")
	var first: Dictionary = page["assets"][0]
	assert_eq([first["name"], first["model_id"], first["generated"]], ["a chest", "model_x", true])
	assert_eq(first["thumbnail"], "https://cdn.cloud.scenario.com/t/a")
	assert_eq(page["assets"][1]["thumbnail"], "https://cdn.cloud.scenario.com/f/b", "an image without a thumbnail shows itself")
	assert_false(page["assets"][1]["generated"])
	assert_eq(page["assets"][2]["thumbnail"], "", "no picture for audio")
	assert_eq(Query.parse_page("nonsense")["assets"], [])


func test_lane_for_one_asset() -> void:
	assert_eq(Query.lane_for("model_scenario-skybox-gpt", "image"), "skybox", "a skybox model's panorama goes to the sky")
	assert_eq(Query.lane_for("model_patina-material", "image", "image/png"), "image", "one map alone is not a material")
	assert_eq(Query.lane_for("model_rodin-hyper3d-v2-5-text-to-3d", "image", "image/png"), "image", "a 3D model's preview alone is an image")
	assert_eq(Query.lane_for("model_rodin-hyper3d-v2-5-text-to-3d", "3d"), "model3d")
	assert_eq(Query.lane_for("model_other", "", "model/gltf-binary"), "model3d")
	assert_eq(Query.lane_for("", "audio"), "sound")
	assert_eq(Query.lane_for("", "image-hdr"), "skybox")
	assert_eq(Query.lane_for("", "video", "video/mp4"), "", "nothing places a video")


func test_lane_for_a_whole_job() -> void:
	assert_eq(Query.lane_for_job("model_patina-material", []), "material", "a listed model's lane")
	assert_eq(Query.lane_for_job("model_team-3d", ["image/png", "model/gltf-binary"]), "model3d", "a preview listed before the GLB")
	assert_eq(Query.lane_for_job("model_team-sfx", ["audio/mpeg"]), "sound")
	assert_eq(Query.lane_for_job("model_team-style", ["image/png", "image/png"]), "image")
	assert_eq(Query.lane_for_job("model_team-video", ["video/mp4"]), "")


func test_null_fields_and_a_missing_total() -> void:
	var page := Query.parse_page({"assets": [{"id": "asset_n", "kind": "image", "name": null, "metadata": {"modelId": null, "prompt": null}}]})
	var row: Dictionary = page["assets"][0]
	assert_eq([row["name"], row["model_id"], row["prompt"], row["generated"]], ["asset_n", "", "", false])
	assert_eq(page["total"], -1, "no total: paging goes by full pages")
	assert_eq(page["hits"], 1)


func test_history_rows() -> void:
	var page := Query.parse_history({"jobs": [
		{"jobId": "job_1", "status": "success", "modelId": "model_x", "prompt": "a chest", "createdAt": "2026-11-13T10:05:09.000Z"},
		{"jobId": "job_2", "status": "in-progress", "modelId": "model_x", "prompt": null},
		{"jobId": "job_up", "jobType": "upload", "status": "success"},
		{"status": "success"},
	], "nextPaginationToken": "tok"})
	assert_eq(page["next"], "tok")
	assert_eq(page["jobs"].size(), 2, "uploads and rows without an id are left out")
	assert_eq(page["jobs"][1]["prompt"], "")
	assert_true(page["jobs"][0]["finished"])
	assert_false(page["jobs"][1]["finished"])
	assert_eq(Query.date_text(page["jobs"][0]["created_at"]), "2026-11-13 10:05")
	assert_eq(Query.model_name("model_openai-gpt-image-2-5-flare"), "GPT Image 2.5 Flare")
	assert_eq(Query.model_name("model_team-custom"), "team-custom")
