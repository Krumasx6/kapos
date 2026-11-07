extends Control

var director: SceneDirector
var dialogue: DialoguePlayer
var choices: ChoiceManager
var flowchart: FlowchartScreen
var status_label: Label

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	director = SceneDirector.new()
	add_child(director)
	dialogue = DialoguePlayer.new()
	add_child(dialogue)
	dialogue.continue_pressed.connect(_advance_dialogue)
	dialogue.line_shown.connect(_line_shown)
	choices = ChoiceManager.new()
	add_child(choices)
	choices.option_selected.connect(_choose)
	status_label = Label.new()
	status_label.position = Vector2(28, 676)
	status_label.add_theme_font_size_override("font_size", 13)
	add_child(status_label)
	_add_save_controls()
	if not StoryDB.load_errors.is_empty():
		_show_errors()
		return
	if not SaveSystem.load_autosave():
		StoryState.current_node = str(StoryDB.graph.get("entry_node", ""))
	show_node(StoryState.current_node)

func show_node(node_id: String) -> void:
	if not StoryDB.ensure_node_loaded(node_id):
		push_error("StoryRunner: could not load node '%s'" % node_id)
		return
	if not StoryDB.nodes.has(node_id):
		push_error("StoryRunner: unknown node '%s'" % node_id)
		return
	var node: Dictionary = StoryDB.nodes[node_id]
	var previous_node := StoryState.current_node
	var chapter_id := str(StoryDB.node_chapters.get(node_id, ""))
	if not chapter_id.is_empty() and not StoryState.chapter_snapshots.has(chapter_id):
		StoryState.snapshot_chapter(chapter_id, node_id)
	StoryState.record_node(node_id)
	_apply_variant_effects(node)
	if node.has("stage"):
		director.apply_stage(str(node.stage), _variant_portrait(node))
	status_label.text = StoryDB.text("UI-TEST-STATUS") % node_id
	match str(node.get("type", "")):
		"dialogue", "cutscene":
			choices.visible = false
			dialogue.visible = true
			dialogue.show_lines(_variant_lines(node), bool(node.get("non_interactive", node.get("type") == "cutscene")), float(node.get("line_interval", 2.5)))
		"hub":
			choices.visible = false
			dialogue.visible = true
			dialogue.show_lines(_variant_lines(node))
			SaveSystem.autosave()
		"decision":
			dialogue.visible = false
			choices.visible = true
			choices.show_decision(node)
		"flowchart":
			choices.visible = false
			dialogue.visible = false
			_show_flowchart(previous_node)
		_:
			push_error("StoryRunner: unsupported node type '%s'" % node.get("type", ""))

func _variant_lines(node: Dictionary) -> Array:
	var base_lines: Array = node.get("lines", [])
	if not node.has("variants"):
		return base_lines
	var result: Array = base_lines.duplicate()
	var matching := _matching_variants(node)
	if node.get("variant_mode", "first_match") == "all_matching":
		for variant: Dictionary in matching:
			result.append_array(variant.get("lines", []))
	elif not matching.is_empty():
		result.append_array(matching[0].get("lines", []))
	return result

func _matching_variants(node: Dictionary) -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for variant: Dictionary in node.get("variants", []):
		if StoryEvaluator.condition_matches(variant.get("when", {"always": true}), StoryState.flags, StoryDB.derived_definitions):
			matching.append(variant)
			if node.get("variant_mode", "first_match") != "all_matching":
				break
	return matching

func _apply_variant_effects(node: Dictionary) -> void:
	for variant: Dictionary in _matching_variants(node):
		var effects: Array = variant.get("effects", [])
		if effects.is_empty(): continue
		var updated := StoryEvaluator.apply_effects(effects, StoryState.flags, StoryDB.flag_definitions)
		if updated.has("_evaluation_error"):
			push_error("StoryRunner: " + str(updated["_evaluation_error"]))
			continue
		StoryState.apply_flag_values(updated)

func _variant_portrait(node: Dictionary) -> String:
	for variant: Dictionary in node.get("variants", []):
		if StoryEvaluator.condition_matches(variant.get("when", {"always": true}), StoryState.flags, StoryDB.derived_definitions):
			return str(variant.get("portrait_id", node.get("portrait", "")))
	return str(node.get("portrait", ""))

func _advance_dialogue() -> void:
	var node: Dictionary = StoryDB.nodes[StoryState.current_node]
	var next_id := str(node.get("next", ""))
	if not next_id.is_empty(): show_node(next_id)

func _line_shown(speaker_id: String, expression: String) -> void:
	var node: Dictionary = StoryDB.nodes.get(StoryState.current_node, {})
	var variant_portrait := _variant_portrait(node)
	if not variant_portrait.is_empty():
		director.apply_portrait(variant_portrait)
		return
	var character: Dictionary = StoryDB.characters.get("characters", {}).get(speaker_id, {})
	var portrait_id := str(character.get("expression_portraits", {}).get(expression, character.get("portrait_id", "")))
	director.apply_portrait(portrait_id)

func _choose(option_id: String, timed_out: bool) -> void:
	var decision: Dictionary = StoryDB.nodes[StoryState.current_node]
	var selected: Dictionary = {}
	for option: Dictionary in decision.get("options", []):
		if str(option.get("id", "")) == option_id: selected = option
	if selected.is_empty() or not StoryEvaluator.condition_matches(selected.get("requires", {"always": true}), StoryState.flags, StoryDB.derived_definitions):
		push_error("StoryRunner: rejected locked or unknown option '%s'" % option_id)
		return
	var locked_options: Array[String] = []
	for other: Dictionary in decision.get("options", []):
		if not StoryEvaluator.condition_matches(other.get("requires", {"always": true}), StoryState.flags, StoryDB.derived_definitions):
			locked_options.append(str(other.get("id", "")))
	var prospective: Dictionary = StoryEvaluator.apply_effects(selected.get("effects", []), StoryState.flags, StoryDB.flag_definitions)
	if prospective.has("_evaluation_error"):
		push_error("StoryRunner: " + str(prospective["_evaluation_error"]))
		return
	if prospective.is_empty() and not selected.get("effects", []).is_empty(): return
	if not StoryState.apply_flag_values(prospective): return
	StoryState.branch_log.append({"decision_id": decision.id, "option_id": option_id, "chapter": StoryDB.node_chapters.get(decision.id, ""), "timed_out": timed_out, "locked_options": locked_options})
	var next_id := str(selected.get("next", ""))
	for conditional: Dictionary in selected.get("next_if", []):
		if StoryEvaluator.condition_matches(conditional.get("when", {}), StoryState.flags, StoryDB.derived_definitions):
			var conditional_effects: Array = conditional.get("effects", [])
			var updated := StoryEvaluator.apply_effects(conditional_effects, StoryState.flags, StoryDB.flag_definitions)
			if updated.has("_evaluation_error"):
				push_error("StoryRunner: " + str(updated["_evaluation_error"]))
				return
			if not updated.is_empty() or conditional_effects.is_empty(): StoryState.apply_flag_values(updated)
			next_id = str(conditional.get("next", next_id))
			break
	StoryState.current_node = next_id
	SaveSystem.autosave()
	show_node(next_id)

func _show_flowchart(resume_node_id: String = "") -> void:
	flowchart = FlowchartScreen.new()
	flowchart.resume_node_id = resume_node_id
	flowchart.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(flowchart)
	flowchart.continue_pressed.connect(_continue_after_flowchart)
	flowchart.resume_requested.connect(_resume_from_flowchart)

func _open_flowchart() -> void:
	if is_instance_valid(flowchart): return
	_show_flowchart(StoryState.current_node)

func _resume_from_flowchart(node_id: String) -> void:
	if is_instance_valid(flowchart): flowchart.queue_free()
	flowchart = null
	show_node(node_id)

func _restart_chapter() -> void:
	if is_instance_valid(flowchart): flowchart.queue_free()
	var chapter_id := str(StoryDB.node_chapters.get(StoryState.current_node, ""))
	if not StoryState.restore_snapshot(chapter_id): StoryState.reset()
	show_node(StoryState.current_node)
	SaveSystem.autosave()

func _continue_after_flowchart() -> void:
	var node: Dictionary = StoryDB.nodes.get(StoryState.current_node, {})
	var next_id := str(node.get("next", ""))
	for branch: Dictionary in node.get("next_if", []):
		if StoryEvaluator.condition_matches(branch.get("when", {}), StoryState.flags, StoryDB.derived_definitions):
			var effects: Array = branch.get("effects", [])
			if not effects.is_empty():
				var updated := StoryEvaluator.apply_effects(effects, StoryState.flags, StoryDB.flag_definitions)
				if updated.has("_evaluation_error"):
					push_error("StoryRunner: " + str(updated["_evaluation_error"]))
					return
				if not StoryState.apply_flag_values(updated): return
			next_id = str(branch.get("next", next_id))
			break
	if next_id.is_empty():
		_restart_chapter()
		return
	if is_instance_valid(flowchart): flowchart.queue_free()
	flowchart = null
	show_node(next_id)

func _show_errors() -> void:
	var label := Label.new()
	label.position = Vector2(40, 40)
	label.size = Vector2(1200, 600)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = "Story data failed to load:\n" + "\n".join(StoryDB.load_errors)
	add_child(label)

func _add_save_controls() -> void:
	var row := HBoxContainer.new()
	row.position = Vector2(28, 8)
	row.add_theme_constant_override("separation", 6)
	add_child(row)
	for slot in range(1, 4):
		var save_button := Button.new()
		save_button.text = StoryDB.text("UI-TEST-SAVE") % slot
		save_button.pressed.connect(SaveSystem.save_slot.bind(slot))
		row.add_child(save_button)
		var load_button := Button.new()
		load_button.text = StoryDB.text("UI-TEST-LOAD") % slot
		load_button.pressed.connect(_load_slot.bind(slot))
		row.add_child(load_button)
	var flowchart_button := Button.new()
	flowchart_button.text = StoryDB.text("UI-TEST-FLOWCHART")
	flowchart_button.pressed.connect(_open_flowchart)
	row.add_child(flowchart_button)

func _load_slot(slot: int) -> void:
	if SaveSystem.load_slot(slot):
		if is_instance_valid(flowchart):
			flowchart.queue_free()
			flowchart = null
		show_node(StoryState.current_node)

