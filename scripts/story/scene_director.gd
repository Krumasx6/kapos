class_name SceneDirector
extends Control

var preset: Dictionary = {}
var background_rect: ColorRect
var background_texture: TextureRect
var lighting_overlay: ColorRect
var background_label: Label
var portrait_rect: ColorRect
var portrait_texture: TextureRect
var portrait_label: Label
var fade_overlay: ColorRect

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background_rect = ColorRect.new()
	background_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background_rect)
	background_texture = TextureRect.new()
	background_texture.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	background_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	background_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background_texture)
	lighting_overlay = ColorRect.new()
	lighting_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lighting_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(lighting_overlay)
	background_label = _label(Vector2(50, 38), Vector2(600, 40), 22)
	add_child(background_label)
	portrait_rect = ColorRect.new()
	portrait_rect.position = Vector2(850, 150)
	portrait_rect.size = Vector2(250, 320)
	add_child(portrait_rect)
	portrait_texture = TextureRect.new()
	portrait_texture.position = portrait_rect.position
	portrait_texture.size = portrait_rect.size
	portrait_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait_texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(portrait_texture)
	portrait_label = _label(Vector2(850, 480), Vector2(250, 36), 18)
	add_child(portrait_label)
	fade_overlay = ColorRect.new()
	fade_overlay.color = Color.BLACK
	fade_overlay.modulate.a = 0.0
	fade_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(fade_overlay)

func apply_stage(stage_id: String, portrait_id: String = "") -> void:
	preset = StoryDB.manifest.get("stages", {}).get(stage_id, {})
	background_rect.color = Color(str(preset.get("placeholder_color", "#26303A")))
	background_label.text = StoryDB.text("UI-TEST-STAGE") % StoryDB.asset_label(str(preset.get("background", "")))
	var background_asset: Dictionary = StoryDB.manifest.get("assets", {}).get(str(preset.get("background", "")), {})
	background_texture.texture = _load_texture(background_asset)
	background_texture.visible = background_texture.texture != null
	background_rect.visible = not background_texture.visible
	var lighting: Dictionary = StoryDB.manifest.get("lighting", {}).get(str(preset.get("lighting", "")), {})
	lighting_overlay.color = Color(str(lighting.get("color", "#FFFFFF")))
	lighting_overlay.modulate.a = float(lighting.get("alpha", 0.0))
	apply_portrait(portrait_id)
	transition(str(preset.get("transition", "cut")))

func apply_portrait(portrait_id: String) -> void:
	var portrait: Dictionary = StoryDB.manifest.get("portraits", {}).get(portrait_id, {})
	portrait_rect.color = Color(str(portrait.get("placeholder_color", "#6A5A4C")))
	portrait_label.text = StoryDB.text("UI-TEST-PORTRAIT") % StoryDB.asset_label(portrait_id)
	var portrait_asset: Dictionary = StoryDB.manifest.get("assets", {}).get(str(portrait.get("asset_id", "")), {})
	portrait_texture.texture = _load_texture(portrait_asset)
	portrait_texture.visible = portrait_texture.texture != null
	portrait_rect.visible = not portrait_texture.visible

func _load_texture(asset: Dictionary) -> Texture2D:
	var path := str(asset.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path): return null
	return load(path) as Texture2D

func transition(kind: String) -> void:
	if kind == "cut":
		fade_overlay.modulate.a = 0.0
		return
	if kind == "fade":
		fade_overlay.modulate.a = 1.0
		var fade_tween := create_tween()
		fade_tween.tween_property(fade_overlay, "modulate:a", 0.0, 0.35)
	elif kind == "rain_wipe":
		fade_overlay.modulate.a = 1.0
		var viewport_width := get_viewport_rect().size.x
		fade_overlay.position.x = -viewport_width
		var wipe_tween := create_tween()
		wipe_tween.tween_property(fade_overlay, "position:x", viewport_width, 0.45)
		wipe_tween.tween_callback(func() -> void:
			fade_overlay.position.x = 0.0
			fade_overlay.modulate.a = 0.0
		)
	elif kind == "flowchart_zoom":
		scale = Vector2.ONE * 0.98
		var zoom_tween := create_tween()
		zoom_tween.tween_property(self, "scale", Vector2.ONE, 0.25)

func _label(at: Vector2, dimensions: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = at
	label.size = dimensions
	label.add_theme_font_size_override("font_size", font_size)
	return label
