extends GutTest

const Query := preload("res://addons/scenario/core/library_query.gd")

const SCOPE := {"team_id": "team_a", "project_id": "proj_a1"}


func test_list_arguments_carry_the_scope_inside_the_parameters() -> void:
	var first := Query.list_args("", SCOPE)
	assert_eq(first["name"], "assets_list")
	assert_eq(first["parameters"], {"limit": Query.LIST_LIMIT, "include_urls": true, "team_id": "team_a", "project_id": "proj_a1"})
	var next := Query.list_args("tok", {}, 500)
	assert_eq(next["parameters"], {"limit": 100, "include_urls": true, "page_token": "tok"}, "an API key carries no scope")


## Rows as assets_list returned them on 2026-11-13 (ids and URLs shortened).
func test_rows_from_a_live_shaped_reply() -> void:
	var page := Query.parse_assets({"assets": [
		{"id": "asset_chest", "url": "https://cdn.cloud.scenario.com/assets-transform/asset_chest?p=100&Policy=p&Signature=s",
			"mimeType": "image/png", "kind": "image", "source": "txt2img", "description": "A wooden treasure chest.",
			"createdAt": "2026-11-13T14:19:44.083Z", "modelId": "model_google-gemini-nano-banana-2-1", "prompt": "asset_prompttext"},
		{"id": "asset_prompttext", "url": "https://cdn.cloud.scenario.com/assets/asset_prompttext?Policy=p", "mimeType": "text/plain",
			"kind": "text", "source": "uploaded-text", "createdAt": "2026-11-13T14:19:27.446Z"},
		{"id": "asset_logo", "mimeType": "image/png", "source": "uploaded", "name": "logo.png", "url": "https://cdn.cloud.scenario.com/assets/asset_logo?Policy=p"},
		{"id": "asset_crate", "mimeType": "model/gltf-binary", "kind": "3d", "source": "txt23d", "modelId": "model_x", "prompt": "a crate"},
		{"kind": "image"},
	], "nextPaginationToken": "tok"})
	assert_eq(page["next"], "tok")
	assert_eq(page["assets"].map(func(r: Dictionary) -> String: return r["id"]), ["asset_chest", "asset_logo", "asset_crate"],
		"prompt texts and rows without an id are left out")
	var chest: Dictionary = page["assets"][0]
	assert_eq([chest["name"], chest["prompt"], chest["generated"], chest["uploaded"]], ["A wooden treasure chest.", "", true, false],
		"the caption names it; a prompt kept as a text asset is not shown")
	assert_eq(chest["thumbnail"], "https://cdn.cloud.scenario.com/assets-transform/asset_chest?p=100&Policy=p&Signature=s&width=192&height=auto")
	var logo: Dictionary = page["assets"][1]
	assert_eq([logo["kind"], logo["name"], logo["uploaded"], logo["generated"]], ["image", "logo.png", true, false], "kind from the MIME type")
	assert_eq(logo["thumbnail"], "https://cdn.cloud.scenario.com/assets/asset_logo?Policy=p", "a plain file URL is used as it is")
	assert_eq(page["assets"][2]["thumbnail"], "", "no picture for 3D")
	assert_eq(Query.parse_assets("nonsense")["assets"], [])


func test_null_fields_read_as_empty() -> void:
	var row := Query.asset_row({"id": "asset_n", "kind": "image", "name": null, "modelId": null, "prompt": null, "description": null})
	assert_eq([row["name"], row["model_id"], row["prompt"], row["generated"]], ["asset_n", "", "", false])


func test_filters() -> void:
	var image := Query.asset_row({"id": "a1", "kind": "image", "source": "txt2img", "modelId": "m", "prompt": "a red gem", "description": "Gem"})
	var hdr := Query.asset_row({"id": "a2", "kind": "image-hdr", "source": "uploaded", "name": "sky.exr"})
	var sound := Query.asset_row({"id": "a3", "kind": "audio", "source": "txt2audio", "modelId": "m", "prompt": "coin"})
	assert_true(Query.matches(image, "all", "all", ""))
	assert_true(Query.matches(hdr, "image", "all", ""), "HDR is an image")
	assert_false(Query.matches(sound, "image", "all", ""))
	assert_true(Query.matches(sound, "audio", "generated", ""))
	assert_false(Query.matches(sound, "all", "uploaded", ""))
	assert_true(Query.matches(hdr, "all", "uploaded", ""))
	assert_true(Query.matches(image, "all", "all", "  RED "), "prompt words, any case")
	assert_true(Query.matches(image, "all", "all", "gem"), "caption words")
	assert_false(Query.matches(image, "all", "all", "blue"))


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
	var png := {"mimeType": "image/png"}
	assert_eq(Query.lane_for_job("model_team-3d", [png, {"mimeType": "model/gltf-binary"}]), "model3d", "a preview listed before the GLB")
	assert_eq(Query.lane_for_job("model_team-3d", [png, {"mimeType": "application/octet-stream", "metadata": {"type": "inference-txt23d"}}]),
		"model3d", "a GLB listed as octet-stream, known by its 3D type")
	assert_eq(Query.lane_for_job("model_team-sfx", [{"mimeType": "audio/mpeg"}]), "sound")
	assert_eq(Query.lane_for_job("model_team-style", [png, png]), "image")
	assert_eq(Query.lane_for_job("model_team-video", [{"mimeType": "video/mp4"}]), "")


func test_history_rows() -> void:
	var page := Query.parse_history({"jobs": [
		{"jobId": "job_1", "status": "success", "modelId": "model_x", "prompt": "a chest", "createdAt": "2026-11-13T10:05:09.000Z"},
		{"jobId": "job_2", "status": "in-progress", "modelId": "model_x", "prompt": "asset_prompttext"},
		{"jobId": "job_up", "jobType": "upload", "status": "success"},
		{"status": "success"},
	], "nextPaginationToken": "tok"})
	assert_eq(page["next"], "tok")
	assert_eq(page["jobs"].size(), 2, "uploads and rows without an id are left out")
	assert_true(page["jobs"][0]["finished"])
	assert_false(page["jobs"][1]["finished"])
	assert_eq(page["jobs"][1]["prompt"], "", "a prompt kept as a text asset is not shown")
	assert_eq(Query.date_text(page["jobs"][0]["created_at"]), "2026-11-13 10:05")
	assert_eq(Query.model_name("model_openai-gpt-image-2-5-flare"), "GPT Image 2.5 Flare")
	assert_eq(Query.model_name("model_team-custom"), "team-custom")


func test_image_size_is_read_from_the_header_without_decoding() -> void:
	var image := Image.create(37, 21, false, Image.FORMAT_RGBA8)
	assert_eq(Query.image_size(image.save_png_to_buffer()), Vector2i(37, 21), "PNG")
	assert_eq(Query.image_size(image.save_jpg_to_buffer()), Vector2i(37, 21), "JPEG")
	assert_eq(Query.image_size(image.save_webp_to_buffer(false)), Vector2i(37, 21), "WebP lossless")
	assert_eq(Query.image_size(image.save_webp_to_buffer(true, 0.5)), Vector2i(37, 21), "WebP lossy")
	assert_eq(Query.image_size(PackedByteArray([1, 2, 3])), Vector2i.ZERO, "not an image")


func test_an_oversized_header_is_over_the_thumbnail_budget() -> void:
	# A PNG header claiming 100000 x 100000 pixels: what a decompression bomb looks like.
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
		0, 1, 0x86, 0xA0, 0, 1, 0x86, 0xA0])
	var size := Query.image_size(png)
	assert_eq(size, Vector2i(100000, 100000))
	assert_gt(size.x * size.y, Query.MAX_THUMBNAIL_PIXELS)
