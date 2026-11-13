@tool
extends VBoxContainer
## The dock's Library and History views, built in code, no logic: the
## project's assets with filters and thumbnails, and its earlier jobs.

const Library := preload("res://addons/scenario/editor/library.gd")
const Query := preload("res://addons/scenario/core/library_query.gd")
const Ledger := preload("res://addons/scenario/core/job_ledger.gd")

const KIND_ITEMS := [["all", "All kinds"], ["image", "Images"], ["3d", "3D"], ["audio", "Audio"]]
const SOURCE_ITEMS := [["all", "All"], ["generated", "Generated"], ["uploaded", "Uploaded"]]
const KIND_TEXT := {"image": "Image", "image-hdr": "HDR", "3d": "3D", "audio": "Audio"}

var library: Library
## "library" or "history"
var view := "library"
var _library_box: VBoxContainer
var _kind_option: OptionButton
var _source_option: OptionButton
var _search_edit: LineEdit
var _library_status: Label
var _cards: HFlowContainer
var _more_button: Button
var _history_box: VBoxContainer
var _history_status: Label
var _history_rows: VBoxContainer
var _older_button: Button
var _thumbnail_rects := {}  # asset id -> TextureRect


func bind(p_library: Library) -> void:
	library = p_library
	_build()
	library.changed.connect(_refresh)
	library.thumbnail_ready.connect(_on_thumbnail)
	_refresh()


## Shows one view; its first page is read when it opens.
func show_view(p_view: String) -> void:
	view = p_view
	if view == "library" and not library.loaded and not library.loading:
		library.refresh()
	elif view == "history" and not library.history_loaded and not library.history_loading:
		library.load_history()
	_refresh()


func _build() -> void:
	add_theme_constant_override("separation", 6)
	_library_box = VBoxContainer.new()
	_library_box.add_theme_constant_override("separation", 6)
	add_child(_library_box)
	var filters := HBoxContainer.new()
	_kind_option = _option(KIND_ITEMS)
	filters.add_child(_kind_option)
	_source_option = _option(SOURCE_ITEMS)
	filters.add_child(_source_option)
	_library_box.add_child(filters)
	var search_row := HBoxContainer.new()
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search names and prompts"
	_search_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	_search_edit.text_submitted.connect(func(_text: String) -> void: _apply_filter())
	search_row.add_child(_search_edit)
	search_row.add_child(_button("Refresh", _apply_filter))
	_library_box.add_child(search_row)
	_library_status = _dim("")
	_library_box.add_child(_library_status)
	_cards = HFlowContainer.new()
	_cards.add_theme_constant_override("h_separation", 6)
	_cards.add_theme_constant_override("v_separation", 6)
	_library_box.add_child(_cards)
	_more_button = _button("Show more", library.load_more)
	_library_box.add_child(_more_button)

	_history_box = VBoxContainer.new()
	_history_box.add_theme_constant_override("separation", 6)
	add_child(_history_box)
	var history_top := HBoxContainer.new()
	_history_status = _dim("")
	_history_status.size_flags_horizontal = SIZE_EXPAND_FILL
	history_top.add_child(_history_status)
	history_top.add_child(_button("Refresh", library.load_history))
	_history_box.add_child(history_top)
	_history_rows = VBoxContainer.new()
	_history_box.add_child(_history_rows)
	_older_button = _button("Load older", library.load_history.bind(true))
	_history_box.add_child(_older_button)


func _apply_filter() -> void:
	library.set_filter(KIND_ITEMS[maxi(_kind_option.selected, 0)][0], SOURCE_ITEMS[maxi(_source_option.selected, 0)][0], _search_edit.text)


func _refresh() -> void:
	if library == null:
		return
	_library_box.visible = view == "library"
	_history_box.visible = view == "history"
	# Opened before, then the project changed: the emptied view reads its first page again.
	if visible and library.controller.is_connected_account() and not library.controller.picking:
		if view == "library" and not library.loaded and not library.loading:
			library.refresh.call_deferred()
		elif view == "history" and not library.history_loaded and not library.history_loading:
			library.load_history.call_deferred()
	if view == "library":
		_refresh_library()
	else:
		_refresh_history()


func _refresh_library() -> void:
	for child in _cards.get_children():
		child.queue_free()
	_thumbnail_rects = {}
	if library.loading and library.assets.is_empty():
		_library_status.text = "Reading the project's assets..."
	elif not library.error.is_empty():
		_library_status.text = library.error
	elif library.loaded and library.assets.is_empty():
		_library_status.text = "Nothing here yet. Generations and uploads of this project appear here."
	else:
		var count := "%d of %d" % [library.assets.size(), library.total] if library.total >= 0 else str(library.assets.size())
		_library_status.text = "%s assets in this project" % count if library.loaded else ""
	for asset in library.assets:
		_cards.add_child(_card(asset))
	_more_button.visible = library.can_load_more()


func _card(asset: Dictionary) -> Control:
	var card := VBoxContainer.new()
	card.custom_minimum_size.x = _px(104)
	card.tooltip_text = "%s\n%s" % [asset["name"], Query.date_text(asset["created_at"])]
	var picture := TextureRect.new()
	picture.custom_minimum_size = Vector2(_px(96), _px(96))
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	picture.texture = library.thumbnails.get(asset["id"])
	_thumbnail_rects[asset["id"]] = picture
	var frame := PanelContainer.new()
	frame.add_child(picture)
	var kind_label := _dim(KIND_TEXT.get(asset["kind"], asset["kind"]))
	kind_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kind_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	kind_label.visible = picture.texture == null
	frame.add_child(kind_label)
	card.add_child(frame)
	var name := Label.new()
	name.text = asset["name"]
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.custom_minimum_size.x = _px(96)
	card.add_child(name)
	if library.busy.has(asset["id"]):
		card.add_child(_dim("Importing..."))
		return card
	card.add_child(_button("Import", library.import_asset.bind(asset)))
	var targets := library.reference_fields() if asset["kind"] == "image" else []
	if targets.size() == 1:
		card.add_child(_button("Reference", library.use_as_reference.bind(asset, targets[0]["name"])))
	elif targets.size() > 1:
		var menu := MenuButton.new()
		menu.text = "Reference"
		menu.flat = false
		for i in targets.size():
			menu.get_popup().add_item(targets[i]["label"], i)
		menu.get_popup().id_pressed.connect(func(i: int) -> void: library.use_as_reference(asset, targets[i]["name"]))
		card.add_child(menu)
	return card


func _refresh_history() -> void:
	for child in _history_rows.get_children():
		child.queue_free()
	if library.history_loading and library.history.is_empty():
		_history_status.text = "Reading the project's jobs..."
	elif not library.history_error.is_empty():
		_history_status.text = library.history_error
	elif library.history_loaded and library.history.is_empty():
		_history_status.text = "No jobs in this project yet."
	else:
		_history_status.text = "Jobs of this project, newest first"
	for job in library.history:
		_history_rows.add_child(_history_row(job))
	_older_button.visible = not library.history_next.is_empty() and not library.history_loading


func _history_row(job: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(_line("%s  %s" % [Query.model_name(job["model_id"]), Query.date_text(job["created_at"])], false))
	if not str(job["prompt"]).is_empty():
		var prompt := _line(str(job["prompt"]), true)
		prompt.tooltip_text = job["prompt"]
		box.add_child(prompt)
	var actions := HBoxContainer.new()
	var row := library.ledger_row(job["job_id"])
	if library.busy.has(job["job_id"]):
		actions.add_child(_line("Importing...", true))
	elif not job["finished"]:
		actions.add_child(_line(str(job["status"]).capitalize(), true))
	elif row.is_empty() or (row["state"] == Ledger.SUCCESS and not row["imported"]):
		actions.add_child(_button("Import", library.import_job.bind(job)))
	else:
		actions.add_child(_line("In the Jobs list", true))
	box.add_child(actions)
	box.add_child(HSeparator.new())
	return box


## One line, cut with an ellipsis when the dock is narrow.
func _line(text: String, dim: bool) -> Label:
	var label := Label.new()
	label.text = text
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = SIZE_EXPAND_FILL
	if dim:
		label.modulate = Color(1, 1, 1, 0.65)
	return label


func _on_thumbnail(asset_id: String) -> void:
	var picture: TextureRect = _thumbnail_rects.get(asset_id)
	if picture != null and is_instance_valid(picture):
		picture.texture = library.thumbnails.get(asset_id)
		var frame := picture.get_parent()
		if frame.get_child_count() > 1:
			frame.get_child(1).visible = false


func _option(items: Array) -> OptionButton:
	var option := OptionButton.new()
	option.fit_to_longest_item = false
	option.size_flags_horizontal = SIZE_EXPAND_FILL
	for item in items:
		option.add_item(item[1])
	option.item_selected.connect(func(_i: int) -> void: _apply_filter())
	return option


func _button(text: String, callable: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callable)
	return button


func _dim(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = _px(60)
	label.modulate = Color(1, 1, 1, 0.65)
	return label


## Pixels scaled to the editor's display scale (2x on Retina by default).
static func _px(value: float) -> float:
	return value * EditorInterface.get_editor_scale()
