extends Node

const FLAG_PATH := "res://story/flags.json"
const CHARACTER_PATH := "res://story/characters.json"
const ENDING_PATH := "res://story/endings.json"
const MANIFEST_PATH := "res://assets/manifest.json"
const GRAPH_PATH := "res://story/graph.json"

var flags_data: Dictionary = {}
var flag_definitions: Dictionary = {}
var derived_definitions: Dictionary = {}
var characters: Dictionary = {}
var endings: Dictionary = {}
var manifest: Dictionary = {}
var graph: Dictionary = {}
var story_index: Dictionary = {}
var chapters: Dictionary = {}
var nodes: Dictionary = {}
var node_chapters: Dictionary = {}
var load_errors: Array[String] = []
var _text_table: Dictionary = {}

func _ready() -> void:
	load_all()

func load_all() -> bool:
	load_errors.clear()
	flags_data = _read_json(FLAG_PATH)
	characters = _read_json(CHARACTER_PATH)
	endings = _read_json(ENDING_PATH)
	manifest = _read_json(MANIFEST_PATH)
	graph = _read_json(GRAPH_PATH)
	story_index = _read_json("res://story/index.json")
	_text_table.clear()
	_load_text_for_chapter("")
	flag_definitions = flags_data.get("flags", {}).duplicate(true)
	flag_definitions.merge(flags_data.get("test_fixture_flags", {}), true)
	derived_definitions = flags_data.get("derived", {})
	nodes.clear()
	node_chapters.clear()
	chapters.clear()
	var entry_chapter := str(story_index.get("entry_node", "")).get_slice("-", 0)
	if not _load_chapter(entry_chapter):
		return false
	_validate_loaded_data()
	return load_errors.is_empty()

func ensure_node_loaded(node_id: String) -> bool:
	if nodes.has(node_id):
		return true
	var chapter_id := node_id.get_slice("-", 0)
	if not _load_chapter(chapter_id):
		return false
	_validate_loaded_data()
	return nodes.has(node_id)

func _load_chapter(chapter_id: String) -> bool:
	if chapters.has(chapter_id):
		return true
	var chapter_map: Dictionary = story_index.get("chapter_map", {})
	var requested_path := str(chapter_map.get(chapter_id, ""))
	if requested_path.is_empty():
		_error("No chapter file is mapped for '%s'" % chapter_id)
		return false
	var found := false
	for relative_path: String in story_index.get("chapter_files", []):
		var mapped_id := ""
		for id: String in chapter_map:
			if chapter_map[id] == relative_path:
				mapped_id = id
				break
		if mapped_id.is_empty():
			_error("Chapter file %s has no chapter_map entry" % relative_path)
			return false
		if not chapters.has(mapped_id) and not _load_single_chapter(mapped_id, relative_path):
			return false
		_load_text_for_chapter(mapped_id)
		if relative_path == requested_path:
			found = true
			break
	return found

func _load_single_chapter(chapter_id: String, relative_path: String) -> bool:
	var chapter := _read_json("res://story/" + relative_path)
	if str(chapter.get("id", "")) != chapter_id:
		_error("Chapter file %s does not declare id '%s'" % [relative_path, chapter_id])
		return false
	chapters[chapter_id] = chapter
	for raw_node: Variant in chapter.get("nodes", []):
		var node: Dictionary = raw_node
		var node_id := str(node.get("id", ""))
		if node_id.is_empty() or nodes.has(node_id):
			_error("Node id '%s' is empty or duplicated" % node_id)
		else:
			nodes[node_id] = node
			node_chapters[node_id] = chapter_id
	return true

func _load_text_for_chapter(chapter_id: String) -> void:
	var csv := FileAccess.open("res://story/text/en_tl.csv", FileAccess.READ)
	if csv == null:
		_error("Missing res://story/text/en_tl.csv")
		return
	csv.get_csv_line()
	while not csv.eof_reached():
		var row: PackedStringArray = csv.get_csv_line()
		if row.size() < 2 or row[0].is_empty():
			continue
		if chapter_id.is_empty() and row[0].begins_with("UI-"):
			_text_table[row[0]] = row[1]
		elif not chapter_id.is_empty() and row[0].begins_with(chapter_id + "-"):
			_text_table[row[0]] = row[1]

func text(key: String) -> String:
	return str(_text_table.get(key, "[MISSING TEXT KEY: %s]" % key))

func asset_label(asset_id: String) -> String:
	if asset_id.is_empty(): return "No portrait"
	if manifest.get("portraits", {}).has(asset_id):
		asset_id = str(manifest.portraits[asset_id].get("asset_id", ""))
	var key := str(manifest.get("assets", {}).get(asset_id, {}).get("label_key", ""))
	return text(key) if not key.is_empty() else "[MISSING ASSET: %s]" % asset_id

func _validate_loaded_data() -> void:
	for name: String in flag_definitions:
		var definition: Dictionary = flag_definitions[name]
		var flag_type := str(definition.get("type", ""))
		if not ["bool", "int", "float", "enum"].has(flag_type):
			_error("Flag %s has unsupported type '%s'" % [name, flag_type])
		elif flag_type == "enum" and (not definition.get("values", []) is Array or definition.get("values", []).is_empty()):
			_error("Enum flag %s needs a non-empty values list" % name)
		elif flag_type == "enum" and definition.get("default") != null and not definition.get("values", []).has(definition.get("default")):
			_error("Enum flag %s has an undeclared default" % name)
		elif flag_type == "int" and int(definition.get("min", 0)) > int(definition.get("max", 0)):
			_error("Integer flag %s has inverted bounds" % name)
		elif not StoryEvaluator._valid_value(name, definition.get("default"), definition):
			_error("Flag %s has an invalid default" % name)
	for character_id: String in characters.get("characters", {}):
		var character: Dictionary = characters.characters[character_id]
		if str(character.get("name_key", "")).is_empty():
			_error("Character %s has no name_key" % character_id)
		elif not _text_table.has(str(character.get("name_key", ""))):
			_error("Character %s references a missing text key" % character_id)
		if not manifest.get("portraits", {}).has(str(character.get("portrait_id", ""))):
			_error("Character %s references an unknown portrait ID" % character_id)
		for expression: String in character.get("expression_portraits", {}):
			if not character.get("expressions", []).has(expression): _error("Character %s maps an undeclared expression" % character_id)
			if not manifest.get("portraits", {}).has(str(character.expression_portraits[expression])): _error("Character %s maps an unknown portrait ID" % character_id)
	for node_id: String in nodes:
		var node: Dictionary = nodes[node_id]
		if not ["dialogue", "decision", "hub", "cutscene", "flowchart"].has(str(node.get("type", ""))):
			_error("Node %s has unsupported type '%s'" % [node_id, node.get("type", "")])
		if node.has("stage") and not manifest.get("stages", {}).has(str(node.stage)):
			_error("Node %s references unknown stage '%s'" % [node_id, node.stage])
		if node.has("portrait") and not manifest.get("portraits", {}).has(str(node.portrait)):
			_error("Node %s references unknown portrait ID '%s'" % [node_id, node.portrait])
		if node.has("next") and not _is_valid_target(str(node.next)):
			_error("Node %s points to missing node '%s'" % [node_id, node.next])
		for branch: Dictionary in node.get("next_if", []):
			if not _valid_condition(branch.get("when", {})): _error("Node %s has an invalid next_if condition" % node_id)
			_validate_references(branch.get("when", {}), node_id)
			if branch.has("next") and not _is_valid_target(str(branch.next)): _error("Node %s has a missing conditional target" % node_id)
			_validate_effects(branch.get("effects", []), "%s next_if" % node_id)
		for line: Dictionary in node.get("lines", []):
			if not _text_table.has(str(line.get("text_key", ""))): _error("Node %s uses a missing line text key" % node_id)
			if not characters.get("characters", {}).has(str(line.get("speaker", ""))): _error("Node %s references an unknown speaker" % node_id)
		for variant: Dictionary in node.get("variants", []):
			if not _valid_condition(variant.get("when", {})): _error("Hub %s has an invalid condition" % node_id)
			_validate_references(variant.get("when", {}), node_id)
			_validate_effects(variant.get("effects", []), "%s variant" % node_id)
			for line: Dictionary in variant.get("lines", []):
				if not _text_table.has(str(line.get("text_key", ""))): _error("Hub %s uses a missing line text key" % node_id)
				if not characters.get("characters", {}).has(str(line.get("speaker", ""))): _error("Hub %s references an unknown speaker" % node_id)
		if node.get("type") == "decision":
			var option_ids: Array[String] = []
			for option: Dictionary in node.get("options", []):
				var option_id := str(option.get("id", ""))
				if option_ids.has(option_id): _error("Decision %s repeats option id '%s'" % [node_id, option_id])
				option_ids.append(option_id)
				if not _text_table.has(str(option.get("label_key", ""))): _error("Decision %s uses a missing label text key" % node_id)
				if option.has("locked_hint_key") and not _text_table.has(str(option.locked_hint_key)): _error("Decision %s uses a missing locked hint key" % node_id)
				if not _valid_condition(option.get("requires", {"always": true})): _error("Option %s in %s has an invalid requires condition" % [option_id, node_id])
				_validate_references(option.get("requires", {"always": true}), node_id)
				if option.has("next") and not _is_valid_target(str(option.next)): _error("Option %s in %s points to missing node '%s'" % [option_id, node_id, option.next])
				_validate_effects(option.get("effects", []), "%s/%s" % [node_id, option_id])
				for branch: Dictionary in option.get("next_if", []):
					if not _valid_condition(branch.get("when", {})): _error("Option %s in %s has an invalid next_if condition" % [option_id, node_id])
					_validate_references(branch.get("when", {}), node_id)
					if branch.has("next") and not _is_valid_target(str(branch.next)): _error("Option %s in %s has missing conditional target" % [option_id, node_id])
					_validate_effects(branch.get("effects", []), "%s/%s next_if" % [node_id, option_id])
			if float(node.get("timer_seconds", 0.0)) > 0.0 and not option_ids.has(str(node.get("default_option", ""))):
				_error("Timed decision %s has an invalid default_option" % node_id)
		if node.has("prompt_key") and not _text_table.has(str(node.prompt_key)):
			_error("Decision %s has a missing prompt text key" % node_id)
	for protagonist: String in ["mario", "kaloy", "perlita", "civic"]:
		if not endings.get(protagonist, []) is Array:
			_error("endings.%s must be an array" % protagonist)
		else:
			var ending_ids: Array[String] = []
			for ending: Dictionary in endings[protagonist]:
				var ending_id := str(ending.get("id", ""))
				if ending_id.is_empty() or ending_ids.has(ending_id): _error("endings.%s has an empty or duplicate rule id" % protagonist)
				ending_ids.append(ending_id)
				if not ending.get("schema_only", false): _validate_references(ending.get("when", {}), "ending " + ending_id)
				if not ending.get("schema_only", false) and not _valid_condition(ending.get("when", {})): _error("Ending %s has an invalid condition" % ending_id)
				if str(ending.get("card_key", "")).is_empty(): _error("Ending %s has no card_key" % ending_id)
	for derived_name: String in derived_definitions:
		var derived: Dictionary = derived_definitions[derived_name]
		for rule: Dictionary in derived.get("rules", []):
			if rule.has("when"):
				if not _valid_condition(rule.when): _error("Derived value %s has an invalid rule condition" % derived_name)
				_validate_references(rule.when, "derived " + derived_name)
		for contribution: Dictionary in derived.get("sum", []):
			if not _valid_condition(contribution.get("when", {"always": true})): _error("Derived value %s has an invalid sum condition" % derived_name)
			_validate_references(contribution.get("when", {"always": true}), "derived " + derived_name)
		for adjustment: Dictionary in derived.get("adjustments", []):
			if not _valid_condition(adjustment.get("when", {"always": true})): _error("Derived value %s has an invalid adjustment condition" % derived_name)
			_validate_references(adjustment.get("when", {"always": true}), "derived " + derived_name)
	for asset_id: String in manifest.get("assets", {}):
		var asset: Dictionary = manifest.assets[asset_id]
		if not _text_table.has(str(asset.get("label_key", ""))): _error("Asset %s references a missing text key" % asset_id)
		var asset_path := str(asset.get("path", ""))
		if not asset_path.is_empty() and not ResourceLoader.exists(asset_path): _error("Asset %s path does not exist" % asset_id)
	for stage_id: String in manifest.get("stages", {}):
		var stage: Dictionary = manifest.stages[stage_id]
		if not manifest.get("assets", {}).has(str(stage.get("background", ""))): _error("Stage %s references an unknown background asset ID" % stage_id)
		if not manifest.get("lighting", {}).has(str(stage.get("lighting", ""))): _error("Stage %s references an unknown lighting preset" % stage_id)
	if graph.get("entry_node") != story_index.get("entry_node"):
		_error("graph.json entry_node does not match story/index.json")
	var graph_ids: Array[String] = []
	for graph_node: Dictionary in graph.get("nodes", []): graph_ids.append(str(graph_node.get("id", "")))
	for edge: Dictionary in graph.get("edges", []):
		if not graph_ids.has(str(edge.get("from", ""))) or not graph_ids.has(str(edge.get("to", ""))):
			_error("graph.json has an edge to an unknown graph node")

func _validate_references(value: Variant, context: String) -> void:
	if value is Dictionary:
		if value.has("flag") and not flag_definitions.has(str(value.flag)) and not derived_definitions.has(str(value.flag)):
			_error("Node %s reads undeclared flag '%s'" % [context, value.flag])
		for operator: String in ["eq", "in", "gte", "lte"]:
			if value.has(operator) and value[operator] is Array and value[operator].size() == 2:
				var pair: Array = value[operator]
				var name := str(pair[0])
				if not flag_definitions.has(name) and not derived_definitions.has(name):
					_error("Node %s reads undeclared flag '%s'" % [context, name])
				elif operator == "eq" and flag_definitions.has(name) and flag_definitions[name].get("type") == "enum" and pair[1] != null and not flag_definitions[name].get("values", []).has(pair[1]):
					_error("Node %s compares %s with invalid enum value '%s'" % [context, name, pair[1]])
				elif operator == "in" and flag_definitions.has(name) and flag_definitions[name].get("type") == "enum":
					if pair[1] is Array:
						for enum_value: Variant in pair[1]:
							if not flag_definitions[name].get("values", []).has(enum_value): _error("Node %s uses invalid enum value for %s" % [context, name])
		for key: Variant in value.keys(): _validate_references(value[key], context)
	elif value is Array:
		for child: Variant in value: _validate_references(child, context)

func _valid_condition(condition: Variant) -> bool:
	if not condition is Dictionary or condition.is_empty() or condition.size() != 1: return false
	if condition.has("always"): return condition["always"] is bool
	if condition.has("flag"): return condition["flag"] is String
	for operator: String in ["eq", "in", "gte", "lte"]:
		if condition.has(operator):
			if not condition[operator] is Array or condition[operator].size() != 2 or not condition[operator][0] is String: return false
			if operator == "in": return condition[operator][1] is Array
			if operator == "gte" or operator == "lte": return condition[operator][1] is int or condition[operator][1] is float
			return true
	if condition.has("all") or condition.has("any"):
		var key := "all" if condition.has("all") else "any"
		if not condition[key] is Array: return false
		for child: Variant in condition[key]:
			if not _valid_condition(child): return false
		return true
	if condition.has("not"): return _valid_condition(condition["not"])
	return false

func _validate_effects(effects: Array, context: String) -> void:
	for effect: Dictionary in effects:
		var operations: Array[String] = []
		for key: String in ["set", "add", "clamp"]:
			if effect.has(key): operations.append(key)
		if operations.size() != 1:
			_error("Effect in %s must use exactly one operation" % context)
			continue
		var operation := operations[0]
		var flag_name := str(effect.get(operation, ""))
		if not flag_definitions.has(flag_name):
			_error("Effect in %s writes undeclared flag '%s'" % [context, flag_name])
			continue
		var definition: Dictionary = flag_definitions[flag_name]
		if operation == "set":
			if not effect.has("to") or not StoryEvaluator._valid_value(flag_name, effect.get("to"), definition):
				_error("Effect in %s sets an invalid value for '%s'" % [context, flag_name])
		elif definition.get("type") != "int" and definition.get("type") != "float":
			_error("Numeric effect in %s requires a numeric flag '%s'" % [context, flag_name])
		elif operation == "add" and not (effect.get("by") is int or effect.get("by") is float):
			_error("Add effect in %s requires a numeric 'by' value" % context)
func _is_valid_target(target: String) -> bool:
	if nodes.has(target):
		return true
	for graph_node: Dictionary in graph.get("nodes", []):
		if graph_node.get("id") == target and graph_node.get("type") != "option":
			return true
	return false

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_error("Missing data file %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		_error("Expected a JSON object in %s" % path)
		return {}
	return parsed

func _error(message: String) -> void:
	load_errors.append(message)
	push_error("StoryDB: " + message)
