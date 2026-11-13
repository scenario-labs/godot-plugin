@tool
extends ConfirmationDialog
## Send feedback: a 1 to 5 rating, a message and an optional reply address.
## Nothing is sent before Send. The text stays here, in memory only, until a
## send succeeds.

signal sent

const PRIVACY_URL := "https://godot.scenario.com/#8-usage-data-and-feedback"

## editor/usage_reporter.gd, which sends it.
var reporter: Node
var rating := 0
var _rating_buttons: Array = []
var _message: TextEdit
var _email: LineEdit
var _status: Label
var _sending := false


func _init() -> void:
	title = "Send feedback to Scenario"
	ok_button_text = "Send"
	dialog_hide_on_ok = false
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)
	box.add_child(_label("How is Scenario for Godot working for you?"))
	var stars := HBoxContainer.new()
	var group := ButtonGroup.new()
	for value in range(1, 6):
		var button := Button.new()
		button.text = str(value)
		button.toggle_mode = true
		button.button_group = group
		button.tooltip_text = ["", "Poor", "Fair", "Good", "Very good", "Excellent"][value]
		button.pressed.connect(func() -> void: rating = value)
		stars.add_child(button)
		_rating_buttons.append(button)
	box.add_child(stars)
	box.add_child(_label("What works, what doesn't, what you'd like (optional):"))
	_message = TextEdit.new()
	_message.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_message.custom_minimum_size = Vector2(380, 120) * EditorInterface.get_editor_scale()
	box.add_child(_message)
	box.add_child(_label("Email, if you'd like a reply (optional):"))
	_email = LineEdit.new()
	_email.placeholder_text = "you@example.com"
	box.add_child(_email)
	_status = _label("")
	_status.visible = false
	box.add_child(_status)
	var note := _label("Sent with the plugin, Godot and OS versions. No prompts, files or account details.")
	note.modulate = Color(1, 1, 1, 0.65)
	box.add_child(note)
	var privacy := LinkButton.new()
	privacy.text = "What is sent"
	privacy.pressed.connect(OS.shell_open.bind(PRIVACY_URL))
	box.add_child(privacy)
	confirmed.connect(_on_send)


func open() -> void:
	_set_status("")
	popup_centered()


## Fills the form, for tests and captures.
func fill(p_rating: int, message: String, email: String) -> void:
	rating = p_rating
	for i in _rating_buttons.size():
		_rating_buttons[i].set_pressed_no_signal(i + 1 == p_rating)
	_message.text = message
	_email.text = email


func message_text() -> String:
	return _message.text


func status_text() -> String:
	return _status.text


func _on_send() -> void:
	if _sending or reporter == null:
		return
	_sending = true
	get_ok_button().disabled = true
	_set_status("Sending...")
	var result: Dictionary = await reporter.send_feedback(rating, _message.text, _email.text)
	_sending = false
	get_ok_button().disabled = false
	if not result["ok"]:
		_set_status(result["message"])
		return
	fill(0, "", "")
	_set_status("")
	hide()
	sent.emit()


func _set_status(text: String) -> void:
	_status.text = text
	_status.visible = not text.is_empty()


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = 380 * EditorInterface.get_editor_scale()
	return label
