extends Node

signal state_changed

var _flags: Dictionary = {}
var flags: Dictionary:
	get:
		return _flags.duplicate(true)
var _meters: Dictionary = {}
var meters: Dictionary:
	get:
		return _meters.duplicate(true)
var branch_log: Array[Dictionary] = []
var seen_nodes: Array[String] = []
var current_node: String = ""
var chapter_snapshots: Dictionary = {}

func _ready() -> void:
	reset()

func reset() -> void:
	_flags.clear()
	_meters.clear()
	for key: String in StoryDB.flag_definitions:
		var definition: Dictionary = StoryDB.flag_definitions[key]
		var value: Variant = definition.get("default")
		_flags[key] = value
		if definition.get("type") == "int" or definition.get("type") == "float":
			_meters[key] = value
	branch_log.clear()
	seen_nodes.clear()
	chapter_snapshots.clear()
	current_node = str(StoryDB.graph.get("entry_node", ""))
	state_changed.emit()

func set_flag(flag_name: String, value: Variant) -> bool:
	if not StoryDB.flag_definitions.has(flag_name):
		push_error("StoryState: cannot set undeclared flag '%s'" % flag_name)
		return false
	var definition: Dictionary = StoryDB.flag_definitions[flag_name]
	if not StoryEvaluator._valid_value(flag_name, value, definition):
		push_error("StoryState: invalid %s value '%s' for flag '%s'" % [definition.get("type", "unknown"), str(value), flag_name])
		return false
	_flags[flag_name] = value
	if _meters.has(flag_name):
		_meters[flag_name] = value
	state_changed.emit()
	return true

func apply_flag_values(next_flags: Dictionary) -> bool:
	for key: String in next_flags:
		if not StoryDB.flag_definitions.has(key) or not StoryEvaluator._valid_value(key, next_flags[key], StoryDB.flag_definitions[key]):
			push_error("StoryState: rejected invalid update for flag '%s'" % key)
			return false
	_flags = next_flags.duplicate(true)
	for key: String in _meters:
		_meters[key] = _flags.get(key, 0)
	state_changed.emit()
	return true

func record_node(node_id: String) -> void:
	if not seen_nodes.has(node_id):
		seen_nodes.append(node_id)
	current_node = node_id
	state_changed.emit()

func snapshot_chapter(chapter_id: String, start_node: String) -> void:
	if not chapter_snapshots.has(chapter_id):
		chapter_snapshots[chapter_id] = {"flags": flags, "branch_log": branch_log.duplicate(true), "seen_nodes": seen_nodes.duplicate(), "node": start_node}

func restore_snapshot(chapter_id: String) -> bool:
	if not chapter_snapshots.has(chapter_id):
		return false
	var snapshot: Dictionary = chapter_snapshots[chapter_id]
	if not apply_flag_values(snapshot.get("flags", {})):
		return false
	branch_log.clear()
	for entry: Dictionary in snapshot.get("branch_log", []): branch_log.append(entry.duplicate(true))
	seen_nodes = snapshot.get("seen_nodes", []).duplicate()
	current_node = str(snapshot.get("node", current_node))
	return true

func serialize() -> Dictionary:
	return {"flags": _flags.duplicate(true), "branch_log": branch_log.duplicate(true), "seen_nodes": seen_nodes.duplicate(), "chapter_snapshots": chapter_snapshots.duplicate(true), "node": current_node}

func restore(data: Dictionary) -> bool:
	var target_node := str(data.get("node", StoryDB.graph.get("entry_node", "")))
	if not StoryDB.ensure_node_loaded(target_node):
		push_error("StoryState: save points to unknown node '%s'" % target_node)
		return false
	var restored_flags: Dictionary = {}
	for name: String in StoryDB.flag_definitions:
		restored_flags[name] = StoryDB.flag_definitions[name].get("default")
	for name: String in data.get("flags", {}):
		if not StoryDB.flag_definitions.has(name):
			push_error("StoryState: save contains undeclared flag '%s' and no migration rule" % name)
			return false
		restored_flags[name] = data.flags[name]
	if not apply_flag_values(restored_flags):
		return false
	branch_log.clear()
	for entry: Variant in data.get("branch_log", []):
		branch_log.append(entry.duplicate(true))
	seen_nodes.assign(data.get("seen_nodes", []))
	chapter_snapshots = data.get("chapter_snapshots", {}).duplicate(true)
	current_node = target_node
	return true
