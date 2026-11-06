class_name DialoguePlayer
extends Control

signal continue_pressed
signal line_shown(speaker_id: String, expression: String)

var text_label: Label
var continue_button: Button
var active_lines: Array[Dictionary] = []
var line_index := 0

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	text_label = Label.new()
	text_label.name = "DialogueText"
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_label.add_theme_font_size_override("font_size", 24)
	text_label.position = Vector2(56, 510)
	text_label.size = Vector2(1168, 110)
	add_child(text_label)
	continue_button = Button.new()
	continue_button.text = StoryDB.text("UI-TEST-CONTINUE")
	continue_button.position = Vector2(1040, 640)
	continue_button.size = Vector2(184, 48)
	continue_button.pressed.connect(_advance_line)
	add_child(continue_button)

func show_lines(lines: Array) -> void:
	active_lines.clear()
	for line: Variant in lines:
		if line is Dictionary: active_lines.append(line)
	line_index = 0
	_show_current_line()

func _show_current_line() -> void:
	if active_lines.is_empty():
		text_label.text = ""
		return
	var line: Dictionary = active_lines[line_index]
	var speaker_id := str(line.get("speaker", ""))
	var speaker: Dictionary = StoryDB.characters.get("characters", {}).get(speaker_id, {})
	var speaker_name := StoryDB.text(str(speaker.get("name_key", "")))
	text_label.text = StoryDB.text("UI-TEST-DIALOGUE-LINE") % [speaker_name, StoryDB.text(str(line.get("text_key", "")))]
	continue_button.text = StoryDB.text("UI-TEST-CONTINUE") if line_index == active_lines.size() - 1 else StoryDB.text("UI-TEST-NEXT-LINE")
	line_shown.emit(speaker_id, str(line.get("expr", "neutral")))

func _advance_line() -> void:
	if line_index + 1 < active_lines.size():
		line_index += 1
		_show_current_line()
	else:
		continue_pressed.emit()

