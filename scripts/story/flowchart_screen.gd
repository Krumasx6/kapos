class_name FlowchartScreen
extends Control

signal continue_pressed
signal resume_requested(node_id: String)

const NODE_SIZE := Vector2(230, 74)
var graph: Dictionary = {}
var graph_nodes: Array = []
var graph_edges: Array = []
var scale_factor := 1.0
var pan := Vector2(40, 60)
var dragging := false
var last_mouse := Vector2.ZERO
var selection_label: Label
var resume_node_id := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	graph = StoryDB.graph
	graph_nodes = graph.get("nodes", [])
	graph_edges = graph.get("edges", [])
	var heading := Label.new()
	heading.text = StoryDB.text("UI-FLOWCHART")
	heading.position = Vector2(28, 14)
	heading.add_theme_font_size_override("font_size", 24)
	add_child(heading)
	var hint := Label.new()
	hint.text = StoryDB.text("UI-TEST-FLOWCHART-LEGEND")
	hint.position = Vector2(28, 50)
	hint.add_theme_font_size_override("font_size", 14)
	add_child(hint)
	selection_label = Label.new()
	selection_label.position = Vector2(28, 88)
	selection_label.size = Vector2(560, 54)
	selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(selection_label)
	var button := Button.new()
	var current_node: Dictionary = StoryDB.nodes.get(StoryState.current_node, {})
	button.text = StoryDB.text("UI-CHAPTER-CONTINUE") if not str(current_node.get("next", "")).is_empty() else StoryDB.text("UI-CHAPTER-REPLAY")
	button.position = Vector2(1032, 650)
	button.size = Vector2(220, 44)
	button.pressed.connect(func() -> void: continue_pressed.emit())
	add_child(button)
	if not resume_node_id.is_empty():
		var resume_button := Button.new()
		resume_button.text = StoryDB.text("UI-TEST-RESUME")
		resume_button.position = Vector2(800, 650)
		resume_button.size = Vector2(220, 44)
		resume_button.pressed.connect(func() -> void: resume_requested.emit(resume_node_id))
		add_child(resume_button)
	queue_redraw()

func _draw() -> void:
	var positions: Dictionary = graph.get("positions", {})
	for lane: Dictionary in graph.get("lanes", []):
		var lane_x := float(lane.get("x", 0.0)) * scale_factor + pan.x
		draw_string(ThemeDB.fallback_font, Vector2(lane_x, 112.0 * scale_factor + pan.y), StoryDB.text(str(lane.get("title_key", ""))), HORIZONTAL_ALIGNMENT_LEFT, 360.0, 20, Color("#DDE3EA"))
		draw_line(Vector2(lane_x, 122.0 * scale_factor + pan.y), Vector2(lane_x + 385.0 * scale_factor, 122.0 * scale_factor + pan.y), Color("#69717A"), 2.0)
	for edge: Dictionary in graph_edges:
		var start := _node_center(str(edge.get("from", "")), positions)
		var finish := _node_center(str(edge.get("to", "")), positions)
		if start == Vector2.INF or finish == Vector2.INF:
			continue
		var selected := _edge_was_chosen(edge)
		var color := Color("#F5C451") if selected else Color("#78818C")
		var points := PackedVector2Array([start, start.lerp(finish, 0.5) + Vector2(0, -22), finish])
		draw_polyline(points, color, 4.0 if selected else 2.0, true)
	for node: Dictionary in graph_nodes:
		var node_id := str(node.get("id", ""))
		var raw_position: Array = positions.get(node_id, [0.0, 0.0])
		var node_position := Vector2(float(raw_position[0]), float(raw_position[1])) * scale_factor + pan
		var rect := Rect2(node_position, NODE_SIZE * scale_factor)
		var status := _status(node_id)
		var fill := Color("#405061")
		if status == "unexplored": fill = Color("#20262D")
		elif status == "seen": fill = Color("#587268")
		elif status == "chosen": fill = Color("#806A35")
		elif status == "locked": fill = Color("#292B35")
		var line_color := Color("#DDE3EA") if status != "unexplored" else Color("#69717A")
		if status == "alternative": line_color = Color("#83B8DD")
		draw_rect(rect, fill, true)
		if status == "locked":
			for x in range(0, int(rect.size.x), 12):
				draw_line(rect.position + Vector2(x, 0), rect.position + Vector2(minf(x + 6, rect.size.x), 0), line_color, 2.0)
				draw_line(rect.position + Vector2(x, rect.size.y), rect.position + Vector2(minf(x + 6, rect.size.x), rect.size.y), line_color, 2.0)
			for y in range(0, int(rect.size.y), 12):
				draw_line(rect.position + Vector2(0, y), rect.position + Vector2(0, minf(y + 6, rect.size.y)), line_color, 2.0)
				draw_line(rect.position + Vector2(rect.size.x, y), rect.position + Vector2(rect.size.x, minf(y + 6, rect.size.y)), line_color, 2.0)
		else:
			draw_rect(rect, line_color, false, 2.0)
		var title := "???" if status == "unexplored" else str(node.get("id", "")) + "\n" + str(node.get("type", ""))
		if node.get("type") == "option": title = str(node.get("decision_id", "")) + " · " + str(node.get("option_id", "")) + "\noption"
		if status == "locked": title += "  " + StoryDB.text("UI-TEST-LOCKED")
		draw_string(ThemeDB.fallback_font, rect.position + Vector2(12, 27), title, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 20, 15, line_color)

func _node_center(node_id: String, positions: Dictionary) -> Vector2:
	if not positions.has(node_id): return Vector2.INF
	var raw_position: Array = positions[node_id]
	return Vector2(float(raw_position[0]), float(raw_position[1])) * scale_factor + pan + NODE_SIZE * scale_factor * 0.5

func _status(node_id: String) -> String:
	if StoryState.seen_nodes.has(node_id): return "seen"
	var graph_node: Dictionary = {}
	for entry: Dictionary in graph_nodes:
		if entry.get("id") == node_id:
			graph_node = entry
			break
	if graph_node.get("flowchart_lock") is Dictionary:
		var lock: Dictionary = graph_node.flowchart_lock
		var unlocked := false
		for branch: Dictionary in StoryState.branch_log:
			if branch.get("decision_id") == lock.get("decision_id") and branch.get("option_id") == lock.get("option_id"):
				unlocked = true
		if not unlocked: return "locked"
	if graph_node.get("type") == "option":
		var source := str(graph_node.get("decision_id", ""))
		var option_id := str(graph_node.get("option_id", ""))
		var decision: Dictionary = StoryDB.nodes.get(source, {})
		var option: Dictionary = _find_option(decision, option_id) if not decision.is_empty() else graph_node
		for branch: Dictionary in StoryState.branch_log:
			if branch.get("decision_id") == source and branch.get("locked_options", []).has(option_id):
				return "locked"
		if not option.is_empty() and not StoryEvaluator.condition_matches(option.get("requires", {"always": true}), StoryState.flags, StoryDB.derived_definitions):
			return "locked"
		for branch: Dictionary in StoryState.branch_log:
			if branch.get("decision_id") == source:
				return "chosen" if branch.get("option_id") == option_id else "alternative"
		return "unexplored"
	for branch: Dictionary in StoryState.branch_log:
		var decision: Dictionary = StoryDB.nodes.get(str(branch.get("decision_id", "")), {})
		for option: Dictionary in decision.get("options", []):
			if str(option.get("id", "")) != str(branch.get("option_id", "")) and str(option.get("next", "")) == node_id:
				return "alternative"
	return "unexplored"

func _find_option(decision: Dictionary, option_id: String) -> Dictionary:
	for option: Dictionary in decision.get("options", []):
		if str(option.get("id", "")) == option_id: return option
	return {}

func _edge_was_chosen(edge: Dictionary) -> bool:
	for entry: Dictionary in StoryState.branch_log:
		if entry.get("decision_id") == edge.get("from") and entry.get("option_id") == edge.get("option_id"):
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed: scale_factor = minf(1.5, scale_factor + 0.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed: scale_factor = maxf(0.5, scale_factor - 0.1)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
			last_mouse = event.position
			if not event.pressed:
				_select_at(event.position)
		queue_redraw()
	elif event is InputEventMouseMotion and dragging:
		pan += event.position - last_mouse
		last_mouse = event.position
		queue_redraw()

func _select_at(point: Vector2) -> void:
	var positions: Dictionary = graph.get("positions", {})
	for node: Dictionary in graph_nodes:
		var node_id := str(node.get("id", ""))
		var raw: Array = positions.get(node_id, [0.0, 0.0])
		var rect := Rect2(Vector2(float(raw[0]), float(raw[1])) * scale_factor + pan, NODE_SIZE * scale_factor)
		if not rect.has_point(point): continue
		var status := _status(node_id)
		var detail := StoryDB.text("UI-TEST-NODE-STATUS").format({"node": node_id, "status": StoryDB.text("UI-TEST-STATUS-" + status.to_upper())})
		if node.get("type") == "option":
			var decision: Dictionary = StoryDB.nodes.get(str(node.get("decision_id", "")), {})
			var option := _find_option(decision, str(node.get("option_id", ""))) if not decision.is_empty() else node
			var key := ""
			if status == "locked": key = str(option.get("locked_hint_key", ""))
			elif status == "chosen" or status == "alternative": key = str(option.get("label_key", ""))
			if not key.is_empty(): detail += "\n" + StoryDB.text(key)
		elif StoryDB.nodes.has(node_id):
			var story_node: Dictionary = StoryDB.nodes[node_id]
			if status == "locked" and node.get("flowchart_lock") is Dictionary:
				var lock: Dictionary = node.flowchart_lock
				detail += "\n" + StoryDB.text(str(lock.get("hint_key", "")))
			if story_node.get("type") == "hub": detail += " " + StoryDB.text("UI-TEST-HUB-FIRST-MATCH")
		selection_label.text = detail
		return
	selection_label.text = ""
