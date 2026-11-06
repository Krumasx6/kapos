class_name ChoiceManager
extends Control

signal option_selected(option_id: String, timed_out: bool)

var timer: Timer
var title_label: Label
var list: VBoxContainer
var buttons: Dictionary = {}
var current_decision: Dictionary = {}
var option_ids: Array[String] = []

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_label = Label.new()
	title_label.position = Vector2(56, 420)
	title_label.size = Vector2(1168, 42)
	title_label.add_theme_font_size_override("font_size", 26)
	add_child(title_label)
	list = VBoxContainer.new()
	list.position = Vector2(56, 470)
	list.size = Vector2(1168, 220)
	list.add_theme_constant_override("separation", 8)
	add_child(list)
	timer = Timer.new()
	timer.one_shot = true
	timer.timeout.connect(_on_timeout)
	add_child(timer)

func show_decision(node: Dictionary) -> void:
	current_decision = node
	clear_options()
	title_label.text = StoryDB.text(str(node.get("prompt_key", "")))
	option_ids.clear()
	for option: Dictionary in node.get("options", []):
		var option_id := str(option.get("id", ""))
		option_ids.append(option_id)
		var button := Button.new()
		var locked := not StoryEvaluator.condition_matches(option.get("requires", {"always": true}), StoryState.flags, StoryDB.derived_definitions)
		button.text = StoryDB.text(str(option.get("label_key", "")))
		if locked:
			button.disabled = true
			button.modulate = Color(0.56, 0.56, 0.56)
			button.tooltip_text = StoryDB.text(str(option.get("locked_hint_key", "")))
			button.text += " (" + StoryDB.text("UI-TEST-LOCKED") + ") — " + button.tooltip_text
		else:
			button.pressed.connect(_select.bind(option_id, false))	
		button.custom_minimum_size = Vector2(0, 52)
		list.add_child(button)
		buttons[option_id] = button
	var duration := float(node.get("timer_seconds", 0.0))
	if duration > 0.0:
		timer.start(duration)
		_update_timer_label()
	else:
		title_label.text += "   —   " + StoryDB.text("UI-TEST-UNTIMED")

func _process(_delta: float) -> void:
	if timer.time_left > 0.0:
		_update_timer_label()

func _update_timer_label() -> void:
	var base := StoryDB.text(str(current_decision.get("prompt_key", "")))
	title_label.text = StoryDB.text("UI-TEST-COUNTDOWN").format({"prompt": base, "seconds": ceili(timer.time_left)})

func _select(option_id: String, timed_out: bool) -> void:
	timer.stop()
	option_selected.emit(option_id, timed_out)

func _on_timeout() -> void:
	_select(str(current_decision.get("default_option", "")), true)

func clear_options() -> void:
	timer.stop()
	buttons.clear()
	for child: Node in list.get_children():
		child.queue_free()
