extends GutTest

const Files := preload("res://addons/scenario/core/files.gd")
const ASSETS := "res://tests/assets/"


func _head(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(ASSETS + name).slice(0, 16)


func _riff(kind: String) -> PackedByteArray:
	var bytes := "RIFF".to_ascii_buffer()
	bytes.append_array(PackedByteArray([0, 0, 0, 0]))
	bytes.append_array(kind.to_ascii_buffer())
	return bytes


func test_sniffs_the_real_downloads() -> void:
	assert_eq(Files.sniff_extension(_head("image.bin")), "png")
	assert_eq(Files.sniff_extension(_head("sky.bin")), "jpg")
	assert_eq(Files.sniff_extension(_head("model.bin")), "glb")
	# Sonilo sends MP3 when WAV was asked for: the bytes decide.
	assert_eq(Files.sniff_extension(_head("sound.bin")), "mp3")


func test_sniffs_other_containers() -> void:
	assert_eq(Files.sniff_extension(_riff("WEBP")), "webp")
	assert_eq(Files.sniff_extension(_riff("WAVE")), "wav")
	assert_eq(Files.sniff_extension("OggS".to_ascii_buffer()), "ogg")
	assert_eq(Files.sniff_extension("ID3\u0004".to_ascii_buffer()), "mp3")
	assert_eq(Files.sniff_extension("#?RADIANCE\n".to_ascii_buffer()), "hdr")
	assert_eq(Files.sniff_extension(PackedByteArray([0x76, 0x2F, 0x31, 0x01])), "exr")
	assert_eq(Files.sniff_extension(PackedByteArray()), "")
	assert_eq(Files.sniff_extension("hello".to_ascii_buffer()), "")


func test_mime_fallback() -> void:
	assert_eq(Files.extension_for_mime("image/jpeg"), "jpg")
	assert_eq(Files.extension_for_mime("Audio/MPEG; charset=binary"), "mp3")
	assert_eq(Files.extension_for_mime("model/gltf-binary"), "glb")
	assert_eq(Files.extension_for_mime("application/zip"), "")


func test_slug() -> void:
	assert_eq(Files.slug("A Wooden Chest, brass trim!"), "a-wooden-chest-brass-trim")
	assert_eq(Files.slug("   "), "scenario")
	assert_eq(Files.slug("été 2026"), "t-2026")
	assert_true(Files.slug("word ".repeat(30)).length() <= 40)
	assert_false(Files.slug("word ".repeat(30)).ends_with("-"))


func test_node_name_skips_stopwords() -> void:
	assert_eq(Files.node_name("a wooden treasure chest with brass trim"), "ScenarioWoodenTreasureChest")
	assert_eq(Files.node_name("the sound of rain"), "ScenarioSoundRain")
	assert_eq(Files.node_name(""), "Scenario")
	assert_eq(Files.node_name("test model3d"), "ScenarioTestModel3d")
	assert_true(Files.node_name("bright coin pickup chime").is_valid_identifier())


func test_base_path() -> void:
	var path := Files.base_path("material", "Mossy cobblestone", "asset_j86nEeP2mgtx", "normal", "2026-10-04")
	assert_eq(path, "res://scenario/material/2026-10-04-mossy-cobblestone-p2mgtx-normal")
	var main := Files.base_path("image", "chest", "asset_ABCDEF123", "main", "2026-10-04", "res://art")
	assert_eq(main, "res://art/image/2026-10-04-chest-def123")


func test_roles() -> void:
	# PATINA's "smoothness" map holds roughness pixels: no inversion.
	assert_eq(Files.role_for({"metadata": {"type": "texture-smoothness"}}), "roughness")
	assert_eq(Files.role_for({"metadata": {"type": "texture-normal"}}), "normal")
	assert_eq(Files.role_for({"metadata": {"type": "skybox-base-360"}}), "panorama")
	assert_eq(Files.role_for({"metadata": {"type": "inference-txt2img"}}), "main")
	assert_eq(Files.role_for({"metadata": null}), "main")
	assert_eq(Files.role_for({}), "main")


func test_upload_types() -> void:
	assert_eq(Files.upload_type("res://ref.PNG"), {"mime": "image/png", "kind": "image"})
	assert_eq(Files.upload_type("/tmp/chest.glb")["kind"], "3d")
	assert_eq(Files.upload_type("notes.txt"), {})
