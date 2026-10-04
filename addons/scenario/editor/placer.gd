@tool
extends RefCounted
## Imports downloaded results and places them in the edited scene.
##
## Every scene change is one named undo step, and new nodes get an owner so
## they are saved with the scene. Without an open scene the files are still
## imported and saved as resources.

const Files := preload("res://addons/scenario/core/files.gd")

## Texture import settings written before the first import (godot-pipeline-automation:
## a [remap] + [params] sidecar is honoured, so each file imports once).
const TEXTURE_3D := {"compress/mode": 2, "mipmaps/generate": true, "detect_3d/compress_to": 0}
const TEXTURE_NORMAL := {"compress/mode": 2, "mipmaps/generate": true, "compress/normal_map": 1, "detect_3d/compress_to": 0}
const TEXTURE_PANORAMA := {"compress/mode": 0, "mipmaps/generate": false, "detect_3d/compress_to": 0}


## files: [{"path": "res://...", "role": "albedo" | ...}]. Returns {"ok", "message", "resource_paths"}.
func place(lane: String, files: Array, label: String) -> Dictionary:
	match lane:
		"image":
			return _place_image(files, label)
		"model3d":
			return _place_model(files, label)
		"material":
			return _place_material(files, label)
		"skybox":
			return _place_skybox(files, label)
		"sound":
			return _place_sound(files, label)
	return {"ok": false, "message": "Unknown lane " + lane, "resource_paths": []}


## Writes the import sidecars the lane needs, lets the editor scan (new
## folders are unknown to it until then), and imports anything still missing.
func import_files(lane: String, files: Array) -> void:
	var paths: PackedStringArray = []
	for item in files:
		var path: String = item["path"]
		var ext := path.get_extension().to_lower()
		if ext in ["png", "jpg", "webp"]:
			if lane == "material":
				_write_texture_sidecar(path, TEXTURE_NORMAL if item["role"] == "normal" else TEXTURE_3D)
			elif lane == "skybox":
				_write_texture_sidecar(path, TEXTURE_PANORAMA)
		paths.append(path)
	var fs := EditorInterface.get_resource_filesystem()
	var tree := Engine.get_main_loop() as SceneTree
	fs.scan()
	# scan() starts on a later frame and imports new files itself; wait for the results.
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await tree.process_frame
		if fs.is_scanning():
			continue
		var done := true
		for path in paths:
			if not is_imported(path):
				done = false
				break
		if done:
			return
	var missing: PackedStringArray = []
	for path in paths:
		if not is_imported(path):
			missing.append(path)
	if not missing.is_empty():
		for path in missing:
			fs.update_file(path)
		fs.reimport_files(missing)


## True when the editor finished importing the file: its .import sidecar lists
## generated files and the first one exists (a sidecar alone is not an import).
static func is_imported(path: String) -> bool:
	var sidecar := path + ".import"
	if not FileAccess.file_exists(sidecar):
		return false
	var text := FileAccess.get_file_as_string(sidecar)
	if text.contains("valid=false"):
		return false
	for line in text.split("\n"):
		if line.begins_with("dest_files=["):
			var first := line.get_slice("\"", 1)
			return not first.is_empty() and FileAccess.file_exists(first)
	return false


static func _write_texture_sidecar(path: String, params: Dictionary) -> void:
	var lines := PackedStringArray(["[remap]", "", "importer=\"texture\"", "type=\"CompressedTexture2D\"", "", "[params]", ""])
	for key in params:
		lines.append("%s=%s" % [key, var_to_str(params[key])])
	var file := FileAccess.open(path + ".import", FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()


# --- Lanes --------------------------------------------------------------------

func _place_image(files: Array, label: String) -> Dictionary:
	var path := _first(files, ["main", "base", "albedo"])
	var texture := load(path) as Texture2D
	if texture == null:
		return _fail("The image could not be imported: " + path)
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _ok("Image imported to %s. Open a scene to place it." % path, [path])
	var target := _selected_of(["Sprite2D", "Sprite3D", "TextureRect", "TextureButton", "Decal"])
	var undo := EditorInterface.get_editor_undo_redo()
	if target != null:
		var property := "texture_albedo" if target is Decal else ("texture_normal" if target is TextureButton else "texture")
		undo.create_action("Scenario: set image on %s" % target.name, UndoRedo.MERGE_DISABLE, root)
		undo.add_do_property(target, property, texture)
		undo.add_undo_property(target, property, target.get(property))
		undo.commit_action()
		return _ok("Image set on %s." % target.name, [path])
	var node: Node
	if root is Node3D:
		var sprite := Sprite3D.new()
		sprite.texture = texture
		sprite.pixel_size = 1.0 / maxf(texture.get_height(), 1.0)  # one metre tall
		sprite.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		node = sprite
	elif root is Control:
		var rect := TextureRect.new()
		rect.texture = texture
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.custom_minimum_size = Vector2(256, 256)
		node = rect
	else:
		var sprite_2d := Sprite2D.new()
		sprite_2d.texture = texture
		node = sprite_2d
	_add_node(node, _parent_for(root, node), root, label, "Scenario: add image")
	return _ok("Image added as %s." % node.name, [path])


func _place_model(files: Array, label: String) -> Dictionary:
	var path := ""
	for item in files:
		if str(item["path"]).get_extension().to_lower() in ["glb", "gltf"]:
			path = item["path"]
			break
	if path.is_empty():
		return _fail("The job returned no GLB or glTF model.")
	var scene := load(path) as PackedScene
	if scene == null:
		return _fail("The 3D model could not be imported: " + path)
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root is Node3D:
		return _ok("Model imported to %s. Open a 3D scene to place it." % path, [path])
	var instance := scene.instantiate()
	_add_node(instance, _parent_for(root, instance), root, label, "Scenario: add 3D model")
	return _ok("Model added as %s." % instance.name, [path])


func _place_material(files: Array, label: String) -> Dictionary:
	var material := StandardMaterial3D.new()
	var albedo := _first(files, ["albedo", "base", "main"])
	if albedo.is_empty():
		return _fail("The material has no color map.")
	material.albedo_texture = load(albedo)
	var normal := _first(files, ["normal"])
	if not normal.is_empty():
		material.normal_enabled = true
		material.normal_texture = load(normal)
	var roughness := _first(files, ["roughness"])
	if not roughness.is_empty():
		material.roughness = 1.0
		material.roughness_texture = load(roughness)
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	var metallic := _first(files, ["metallic"])
	if not metallic.is_empty():
		material.metallic = 1.0
		material.metallic_texture = load(metallic)
		material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	var ao := _first(files, ["ao"])
	if not ao.is_empty():
		material.ao_enabled = true
		material.ao_texture = load(ao)
	var height := _first(files, ["height"])
	if not height.is_empty():
		material.heightmap_enabled = true
		material.heightmap_texture = load(height)
		material.heightmap_scale = 1.0
		material.heightmap_deep_parallax = false
	var material_path := albedo.get_basename().trim_suffix("-albedo").trim_suffix("-base") + ".tres"
	if ResourceSaver.save(material, material_path) != OK:
		return _fail("Could not save the material to " + material_path)
	material = load(material_path)
	EditorInterface.get_resource_filesystem().update_file(material_path)
	var root := EditorInterface.get_edited_scene_root()
	var targets: Array = []
	if root != null:
		for node in EditorInterface.get_selection().get_selected_nodes():
			if node is GeometryInstance3D:
				targets.append(node)
	if targets.is_empty():
		return _ok("Material saved to %s. Select a mesh to apply it, or drag it onto one." % material_path, [material_path])
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action("Scenario: apply material", UndoRedo.MERGE_DISABLE, root)
	for node in targets:
		undo.add_do_property(node, "material_override", material)
		undo.add_undo_property(node, "material_override", node.material_override)
	undo.commit_action()
	return _ok("Material applied to %d mesh(es)." % targets.size(), [material_path])


func _place_skybox(files: Array, label: String) -> Dictionary:
	var path := _first(files, ["panorama", "main"])
	var texture := load(path) as Texture2D
	if texture == null:
		return _fail("The skybox could not be imported: " + path)
	var sky_material := PanoramaSkyMaterial.new()
	sky_material.panorama = texture
	var sky := Sky.new()
	sky.sky_material = sky_material
	var sky_path := path.get_basename() + "-sky.tres"
	if ResourceSaver.save(sky, sky_path) != OK:
		return _fail("Could not save the sky to " + sky_path)
	sky = load(sky_path)
	EditorInterface.get_resource_filesystem().update_file(sky_path)
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _ok("Sky saved to %s. Open a scene to use it." % sky_path, [sky_path])
	var undo := EditorInterface.get_editor_undo_redo()
	var world := _find_world_environment(root)
	if world != null and world.environment != null:
		var environment := world.environment
		undo.create_action("Scenario: set skybox", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_property(environment, "background_mode", Environment.BG_SKY)
		undo.add_undo_property(environment, "background_mode", environment.background_mode)
		undo.add_do_property(environment, "sky", sky)
		undo.add_undo_property(environment, "sky", environment.sky)
		undo.commit_action()
		return _ok("Skybox set on %s." % world.name, [sky_path])
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	var new_world := WorldEnvironment.new()
	new_world.environment = environment
	_add_node(new_world, root, root, "WorldEnvironment", "Scenario: add skybox")
	return _ok("Skybox added with a new WorldEnvironment.", [sky_path])


func _place_sound(files: Array, label: String) -> Dictionary:
	var path := _first(files, ["main"])
	var stream := load(path) as AudioStream
	if stream == null:
		return _fail("The sound could not be imported: " + path)
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return _ok("Sound imported to %s. Open a scene to place it." % path, [path])
	var player: Node
	if root is Node3D:
		player = AudioStreamPlayer3D.new()
	elif root is Node2D:
		player = AudioStreamPlayer2D.new()
	else:
		player = AudioStreamPlayer.new()
	player.set("stream", stream)
	_add_node(player, _parent_for(root, player), root, label, "Scenario: add sound")
	return _ok("Sound added as %s." % player.name, [path])


# --- Helpers ------------------------------------------------------------------

func _add_node(node: Node, parent: Node, root: Node, label: String, action: String) -> void:
	node.name = _unique_name(parent, label)
	if node is Node3D and parent == root and root is Node3D:
		node.position = _in_front_of_editor_camera(root)
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, root)
	undo.add_do_method(parent, "add_child", node, true)
	undo.add_do_method(node, "set_owner", root)
	undo.add_do_reference(node)
	undo.add_undo_method(parent, "remove_child", node)
	undo.commit_action()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)


## The selected node when it can hold the new node, otherwise the scene root.
func _parent_for(root: Node, node: Node) -> Node:
	for selected in EditorInterface.get_selection().get_selected_nodes():
		if selected == root or root.is_ancestor_of(selected):
			if node is Node3D and selected is Node3D:
				return selected
			if node is Node2D and selected is Node2D:
				return selected
			if node is Control and selected is Control:
				return selected
			if not (node is Node3D or node is Node2D or node is Control):
				return selected
	return root


func _selected_of(classes: Array) -> Node:
	for node in EditorInterface.get_selection().get_selected_nodes():
		for class_name_ in classes:
			if node.is_class(class_name_):
				return node
	return null


## Four metres in front of the 3D editor camera, on the ground plane when the
## camera looks down at it; the origin when there is no editor camera.
static func _in_front_of_editor_camera(root: Node3D) -> Vector3:
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d() if viewport != null else null
	if camera == null:
		return Vector3.ZERO
	var spot := camera.global_position - camera.global_basis.z * 4.0
	if spot.y < 0.0 or absf(spot.y) < 2.0:
		spot.y = 0.0
	return root.global_transform.affine_inverse() * spot


static func _find_world_environment(root: Node) -> WorldEnvironment:
	if root is WorldEnvironment:
		return root
	for child in root.find_children("*", "WorldEnvironment", true, false):
		return child
	return null


static func _unique_name(parent: Node, label: String) -> String:
	var base := label.validate_node_name()
	if base.is_empty():
		base = "Scenario"
	var name := base
	var index := 2
	while parent.has_node(NodePath(name)):
		name = "%s%d" % [base, index]
		index += 1
	return name


static func _first(files: Array, roles: Array) -> String:
	for role in roles:
		for item in files:
			if item["role"] == role:
				return item["path"]
	return ""


static func _ok(message: String, paths: Array) -> Dictionary:
	return {"ok": true, "message": message, "resource_paths": paths}


static func _fail(message: String) -> Dictionary:
	return {"ok": false, "message": message, "resource_paths": []}
