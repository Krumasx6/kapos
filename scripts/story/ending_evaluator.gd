class_name EndingEvaluator
extends RefCounted

static func evaluate_rules(rules: Array, flags: Dictionary, derived: Dictionary) -> Dictionary:
	for rule: Dictionary in rules:
		if rule.get("schema_only", false):
			continue
		if StoryEvaluator.condition_matches(rule.get("when", {"always": true}), flags, derived):
			return rule
	return {}

static func evaluate_all(endings: Dictionary, flags: Dictionary, derived: Dictionary) -> Dictionary:
	return {
		"mario": evaluate_rules(endings.get("mario", []), flags, derived),
		"kaloy": evaluate_rules(endings.get("kaloy", []), flags, derived),
		"perlita": evaluate_rules(endings.get("perlita", []), flags, derived),
		"civic": evaluate_rules(endings.get("civic", []), flags, derived)
	}
