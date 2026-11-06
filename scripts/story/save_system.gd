extends Node

const SAVE_VERSION := 3
const AUTOSAVE_PATH := "user://autosave.json"

func autosave() -> void:
	_write(AUTOSAVE_PATH)

func save_slot(slot: int) -> bool:
	if slot < 1 or slot > 3:
		push_error("SaveSystem: manual slot must be 1, 2, or 3")
		return false
	return _write("user://slot_%d.json" % slot)

func load_slot(slot: int) -> bool:
	if slot < 1 or slot > 3:
		push_error("SaveSystem: manual slot must be 1, 2, or 3")
		return false
	return load_path("user://slot_%d.json" % slot)

func load_autosave() -> bool:
	return load_path(AUTOSAVE_PATH)

func load_path(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var content := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(content)
	if not parsed is Dictionary:
		push_error("SaveSystem: invalid JSON in %s" % path)
		return false
	var save_data: Dictionary = parsed
	if int(save_data.get("version", 0)) > SAVE_VERSION:
		push_error("SaveSystem: save version is newer than this game")
		return false
	if int(save_data.get("story_data_version", 1)) > int(StoryDB.story_index.get("story_data_version", 1)):
		push_error("SaveSystem: save contains newer story data than this game")
		return false
	var migrated := _migrate(save_data)
	if migrated.has("migration_error"):
		push_error("SaveSystem: " + str(migrated["migration_error"]))
		return false
	return StoryState.restore(migrated)

func _write(path: String) -> bool:
	var state: Dictionary = StoryState.serialize()
	var payload := {"version": SAVE_VERSION, "story_data_version": StoryDB.story_index.get("story_data_version", 1), "saved_at": Time.get_datetime_string_from_system(true, true), "node": state.node, "flags": state.flags, "branch_log": state.branch_log, "seen_nodes": state.seen_nodes, "chapter_snapshots": state.chapter_snapshots}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("SaveSystem: could not open %s for writing" % path)
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	return true

func _migrate(data: Dictionary) -> Dictionary:
	var migrated := data.duplicate(true)
	if int(migrated.get("version", 0)) < 3:
		migrated["version"] = 3
		migrated["chapter_snapshots"] = migrated.get("chapter_snapshots", {})
	var merged_flags := _upgrade_flags(migrated.get("flags", {}))
	if merged_flags.has("migration_error"):
		migrated["migration_error"] = merged_flags["migration_error"]
		return migrated
	migrated["flags"] = merged_flags
	var snapshots: Dictionary = migrated.get("chapter_snapshots", {})
	for chapter_id: String in snapshots:
		var snapshot: Dictionary = snapshots[chapter_id]
		var snapshot_flags := _upgrade_flags(snapshot.get("flags", {}))
		if snapshot_flags.has("migration_error"):
			migrated["migration_error"] = snapshot_flags["migration_error"]
			return migrated
		snapshot["flags"] = snapshot_flags
		snapshots[chapter_id] = snapshot
	migrated["chapter_snapshots"] = snapshots
	return migrated

func _upgrade_flags(source: Dictionary) -> Dictionary:
	var upgraded := source.duplicate(true)
	var renames: Dictionary = StoryDB.flags_data.get("migrations", {}).get("flag_renames", {})
	for old_name: String in renames:
		if upgraded.has(old_name):
			var new_name := str(renames[old_name])
			if not StoryDB.flag_definitions.has(new_name):
				return {"migration_error": "rename target '%s' is undeclared" % new_name}
			if not upgraded.has(new_name): upgraded[new_name] = upgraded[old_name]
			upgraded.erase(old_name)
	for name: String in StoryDB.flag_definitions:
		if not upgraded.has(name): upgraded[name] = StoryDB.flag_definitions[name].get("default")
	for name: String in upgraded:
		if not StoryDB.flag_definitions.has(name):
			return {"migration_error": "flag '%s' has no migration rule" % name}
	return upgraded
