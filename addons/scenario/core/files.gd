@tool
extends RefCounted
## File naming, type sniffing and output roles for downloaded results.

const ROOT := "res://scenario"
const DOWNLOADS := "res://.godot/scenario/downloads"

## Scenario asset metadata.type to the role an importer uses.
## PATINA labels its roughness map "texture-smoothness": the pixels are
## roughness (moss bright, polished stone dark; checked 2026-10-04), so it
## goes to the roughness slot without inversion.
const ROLES := {
	"texture-albedo": "albedo",
	"texture-basecolor": "albedo",
	"texture-normal": "normal",
	"texture-smoothness": "roughness",
	"texture-roughness": "roughness",
	"texture-metallic": "metallic",
	"texture-metalness": "metallic",
	"texture-height": "height",
	"texture-ao": "ao",
	"texture-occlusion": "ao",
	"inference-txt2img-texture": "base",
	"skybox-base-360": "panorama",
}

const IMPORTABLE := ["png", "jpg", "webp", "glb", "gltf", "wav", "mp3", "ogg", "exr", "hdr"]


static func role_for(asset: Dictionary) -> String:
	var metadata: Variant = asset.get("metadata", {})
	var type := str(metadata.get("type", "")) if metadata is Dictionary else ""
	return ROLES.get(type, "main")


## Lowercase words joined by dashes, at most max_length characters.
static func slug(text: String, max_length: int = 40) -> String:
	var out := ""
	var dash := false
	for c in text.to_lower():
		var code := c.unicode_at(0)
		var keep := (code >= 97 and code <= 122) or (code >= 48 and code <= 57)
		if keep:
			if dash and not out.is_empty():
				out += "-"
			out += c
			dash = false
		else:
			dash = true
		if out.length() >= max_length:
			break
	out = out.left(max_length).trim_suffix("-")
	return out if not out.is_empty() else "scenario"


## Node name from the prompt: "Scenario" + up to three meaningful words.
## "a wooden treasure chest, game prop" -> "ScenarioWoodenTreasureChest".
static func node_name(prompt: String) -> String:
	var words: PackedStringArray = []
	for word in slug(prompt, 80).split("-", false):
		# "scenario" too: slug() falls back to it for an empty prompt.
		if word in ["a", "an", "the", "of", "with", "and", "in", "on", "scenario"]:
			continue
		# Not capitalize(): it turns "model3d" into "Model 3d".
		words.append(word.left(1).to_upper() + word.substr(1))
		if words.size() == 3:
			break
	return "Scenario" + "".join(words)


## "<root>/<lane>/<date>-<slug>-<asset tail>[-<role>]" without extension.
static func base_path(lane: String, prompt: String, asset_id: String, role: String, date: String, root: String = ROOT) -> String:
	var tail := asset_id.trim_prefix("asset_").right(6).to_lower()
	var name := "%s-%s-%s" % [date, slug(prompt), tail]
	if not role.is_empty() and role != "main":
		name += "-" + role
	return "%s/%s/%s" % [root, lane, name]


## File extension from the first bytes, or "" when unknown.
static func sniff_extension(head: PackedByteArray) -> String:
	if head.size() >= 8 and head[0] == 0x89 and head[1] == 0x50 and head[2] == 0x4E and head[3] == 0x47:
		return "png"
	if head.size() >= 3 and head[0] == 0xFF and head[1] == 0xD8 and head[2] == 0xFF:
		return "jpg"
	if head.size() >= 12 and _ascii(head, 0, 4) == "RIFF":
		var kind := _ascii(head, 8, 4)
		if kind == "WEBP":
			return "webp"
		if kind == "WAVE":
			return "wav"
	if head.size() >= 4 and _ascii(head, 0, 4) == "glTF":
		return "glb"
	if head.size() >= 4 and _ascii(head, 0, 4) == "OggS":
		return "ogg"
	if head.size() >= 3 and _ascii(head, 0, 3) == "ID3":
		return "mp3"
	if head.size() >= 2 and head[0] == 0xFF and (head[1] & 0xE0) == 0xE0:
		return "mp3"
	if head.size() >= 4 and head[0] == 0x76 and head[1] == 0x2F and head[2] == 0x31 and head[3] == 0x01:
		return "exr"
	if head.size() >= 10 and _ascii(head, 0, 10) == "#?RADIANCE":
		return "hdr"
	if head.size() >= 1 and head[0] == 0x7B:
		return "gltf"
	return ""


## Extension from a MIME type, the fallback when the bytes say nothing.
static func extension_for_mime(mime: String) -> String:
	match mime.to_lower().split(";")[0].strip_edges():
		"image/png":
			return "png"
		"image/jpeg", "image/jpg":
			return "jpg"
		"image/webp":
			return "webp"
		"model/gltf-binary":
			return "glb"
		"model/gltf+json":
			return "gltf"
		"audio/mpeg", "audio/mp3":
			return "mp3"
		"audio/wav", "audio/x-wav", "audio/wave":
			return "wav"
		"audio/ogg":
			return "ogg"
	return ""


## MIME type and Scenario asset kind for a file to upload as a reference.
static func upload_type(path: String) -> Dictionary:
	match path.get_extension().to_lower():
		"png":
			return {"mime": "image/png", "kind": "image"}
		"jpg", "jpeg":
			return {"mime": "image/jpeg", "kind": "image"}
		"webp":
			return {"mime": "image/webp", "kind": "image"}
		"glb":
			return {"mime": "model/gltf-binary", "kind": "3d"}
		"wav":
			return {"mime": "audio/wav", "kind": "audio"}
		"mp3":
			return {"mime": "audio/mpeg", "kind": "audio"}
		"ogg":
			return {"mime": "audio/ogg", "kind": "audio"}
	return {}


static func today() -> String:
	var d := Time.get_date_dict_from_system()
	return "%04d-%02d-%02d" % [d["year"], d["month"], d["day"]]


static func _ascii(bytes: PackedByteArray, start: int, length: int) -> String:
	return bytes.slice(start, start + length).get_string_from_ascii()
