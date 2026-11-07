class_name StoryEvaluator
extends RefCounted

static func condition_matches(condition: Dictionary, values: Dictionary, derived: Dictionary = {}) -> bool:
	if condition.is_empty():
		return false
	if condition.has("always"):
		return bool(condition["always"])
	if condition.has("flag"):
		return bool(_value(str(condition["flag"]), values, derived))
	if condition.has("eq"):
		var pair: Array = condition["eq"]
		return pair.size() == 2 and _value(str(pair[0]), values, derived) == pair[1]
	if condition.has("in"):
		var pair: Array = condition["in"]
		return pair.size() == 2 and pair[1] is Array and pair[1].has(_value(str(pair[0]), values, derived))
	if condition.has("gte"):
		var pair: Array = condition["gte"]
		return pair.size() == 2 and float(_value(str(pair[0]), values, derived)) >= float(pair[1])
	if condition.has("lte"):
		var pair: Array = condition["lte"]
		return pair.size() == 2 and float(_value(str(pair[0]), values, derived)) <= float(pair[1])
	if condition.has("all"):
		for child: Variant in condition["all"]:
			if not condition_matches(child, values, derived):
				return false
		return true
	if condition.has("any"):
		for child: Variant in condition["any"]:
			if condition_matches(child, values, derived):
				return true
		return false
	if condition.has("not"):
		return not condition_matches(condition["not"], values, derived)
	return false

static func apply_effects(effects: Array, current: Dictionary, definitions: Dictionary) -> Dictionary:
	var result: Dictionary = current.duplicate(true)
	for raw_effect: Variant in effects:
		if not raw_effect is Dictionary:
			return {"_evaluation_error": "each effect must be an object"}
		var effect: Dictionary = raw_effect
		var flag_name := str(effect.get("set", effect.get("add", effect.get("clamp", ""))))
		if not definitions.has(flag_name):
			return {"_evaluation_error": "effect writes undeclared flag '%s'" % flag_name}
		var next_value: Variant
		if effect.has("set"):
			next_value = effect.get("to")
		elif effect.has("add"):
			var limits: Dictionary = definitions[flag_name]
			var source := float(result.get(flag_name, 0)) + float(effect.get("by", 0))
			next_value = clampf(source, float(limits.get("min", source)), float(limits.get("max", source)))
			if limits.get("type") == "int": next_value = int(next_value)
		else:
			var limits: Dictionary = definitions[flag_name]
			var source := float(result.get(flag_name, 0))
			next_value = clampf(source, float(effect.get("min", limits.get("min", source))), float(effect.get("max", limits.get("max", source))))
			if limits.get("type") == "int": next_value = int(next_value)
		if not _valid_value(flag_name, next_value, definitions[flag_name]):
			return {"_evaluation_error": "invalid value %s for flag '%s'" % [str(next_value), flag_name]}
		result[flag_name] = next_value
	return result

static func derived_value(name: String, values: Dictionary, derived_rules: Dictionary) -> Variant:
	if not derived_rules.has(name):
		return null
	var definition: Dictionary = derived_rules[name]
	var rules: Array = definition.get("rules", [])
	for rule: Dictionary in rules:
		if not rule.has("when") or condition_matches(rule["when"], values, derived_rules):
			return rule.get("value")
	if definition.has("sum"):
		var total := 0.0
		for contribution: Dictionary in definition["sum"]:
			if condition_matches(contribution.get("when", {"always": true}), values, derived_rules):
				total += float(contribution.get("value", 0))
		return clampf(total, float(definition.get("min", -INF)), float(definition.get("max", INF)))
	if definition.has("base"):
		var total := float(definition.get("base", 0))
		for adjustment: Dictionary in definition.get("adjustments", []):
			if condition_matches(adjustment.get("when", {"always": true}), values, derived_rules):
				total += float(adjustment.get("by", 0))
		return clampf(total, float(definition.get("min", -INF)), float(definition.get("max", INF)))
	return definition.get("default")

static func _value(name: String, values: Dictionary, derived: Dictionary) -> Variant:
	if values.has(name):
		return values[name]
	return derived_value(name, values, derived)

static func _valid_value(name: String, value: Variant, definition: Dictionary) -> bool:
	if value == null:
		return definition.get("type") == "enum"
	match str(definition.get("type", "")):
		"bool": return value is bool
		"int": return value is int and int(value) >= int(definition.get("min", -2147483648)) and int(value) <= int(definition.get("max", 2147483647))
		"float": return (value is int or value is float) and float(value) >= float(definition.get("min", -INF)) and float(value) <= float(definition.get("max", INF))
		"enum": return value is String and definition.get("values", []).has(value)
		_: return false
