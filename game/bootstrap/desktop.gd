extends Control
## The desktop projects the current session; actions use the same application entry points.
const LANDSCAPE := "res://presentation/ui/art/river_campaign.webp"
const IVORY := Color("#f1e5c9")
const BRASS := Color("#d3ad71")
const MUTED := Color("#d3c6ab")
signal field_requested
var _root: RefCounted
var _status: Label
var _title: Label
var _slot: LineEdit
var _slot_row: HBoxContainer
var _buttons := {}
var _area: VBoxContainer
var _character_panel: Control

func _label(caption: String, points: int, color := IVORY) -> Label:
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size",points)
	label.add_theme_color_override("font_color",color)
	return label

func _layout() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var art := TextureRect.new()
	art.name = "CampaignLandscape"
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	if ResourceLoader.exists(LANDSCAPE): art.texture = load(LANDSCAPE)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0,.30,.55,.85,1.0])
	gradient.colors = PackedColorArray([Color("#101719f7"),Color("#13191beb"),Color("#141a1b72"),Color("#18202212"),Color("#18202208")])
	var veil := GradientTexture2D.new()
	veil.gradient = gradient
	veil.fill_to = Vector2.RIGHT
	var shade := TextureRect.new()
	shade.texture = veil
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	add_child(scroll)
	scroll.anchor_left = .064
	scroll.anchor_top = .035
	scroll.anchor_right = .064
	scroll.anchor_bottom = .965
	scroll.offset_right = 280
	_area = VBoxContainer.new()
	_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_area.alignment = BoxContainer.ALIGNMENT_CENTER
	_area.add_theme_constant_override("separation",8)
	scroll.add_child(_area)

	var wordmark := _label("RECOLLECTION",24,BRASS)
	var roman := SystemFont.new()
	roman.font_names = PackedStringArray(["Georgia","Liberation Serif","DejaVu Serif"])
	var tracking := FontVariation.new()
	tracking.base_font = roman
	tracking.spacing_glyph = 3
	wordmark.add_theme_font_override("font",tracking)
	_area.add_child(wordmark)
	_title = _label("",48)
	var heading := SystemFont.new()
	heading.font_names = PackedStringArray(["KaiTi","STKaiti","Noto Serif CJK SC","SimSun"])
	_title.add_theme_font_override("font",heading)
	_area.add_child(_title)
	_rule()

func _rule() -> void:
	var line := ColorRect.new()
	line.color = Color("#bfa3766c")
	line.custom_minimum_size.y = 1
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_area.add_child(line)

func _style(fill: Color, edge: Color, line_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = edge
	style.border_width_left = line_width
	style.content_margin_left = 16
	style.content_margin_right = 16
	return style

func _button(id: String, caption: String, action: Callable, primary := false) -> void:
	var button := Button.new()
	button.text = caption
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size.y = 48 if primary else 34
	button.add_theme_font_size_override("font_size",22 if primary else 18)
	button.add_theme_color_override("font_color",IVORY)
	button.add_theme_color_override("font_hover_color",Color.WHITE)
	button.add_theme_color_override("font_focus_color",Color.WHITE)
	var normal := _style(Color("#735934da") if primary else Color.TRANSPARENT,BRASS,3 if primary else 0)
	var active := _style(Color("#80633ddf"),Color("#ffe2a6"),3)
	button.add_theme_stylebox_override("normal",normal)
	button.add_theme_stylebox_override("hover",active)
	button.add_theme_stylebox_override("pressed",active)
	var focus_style := active.duplicate() as StyleBoxFlat
	focus_style.draw_center = false
	focus_style.set_border_width_all(1)
	button.add_theme_stylebox_override("focus",focus_style)
	button.pressed.connect(action)
	_area.add_child(button)
	_buttons[id] = button
	if primary:
		var arrow := _label("›",27,IVORY)
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(arrow)
		arrow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		arrow.offset_right = -16
		arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

func mount(context: RefCounted) -> void:
	_root = context
	_layout()
	_button("field","进入河原野战",func():field_requested.emit(),true)
	_button("new","新建沙盒",func(): _display(_root.new_world(_slot.text)))
	_button("load","读取存档",func(): _display(_root.load_world(_slot.text)))
	_button("save","保存进度",func(): _display(_root.session().save_session()))
	_button("resume","继续待结算战果",func(): _display(_root.resume_result()))
	_button("character","人物",_open_character)
	_button("train","进入训练",func(): _display(_root.start_training()))
	_button("leave","结束训练",func(): _display(_root.session().dispose_mission()))
	_button("close","关闭会话",func(): _display(_root.session().close_session("frontend")))
	_rule()
	_slot_row = HBoxContainer.new()
	_slot_row.add_theme_constant_override("separation",12)
	_area.add_child(_slot_row)
	_slot_row.add_child(_label("存档槽",14,MUTED))
	_slot = LineEdit.new()
	_slot.text = "campaign"
	_slot.placeholder_text = "字母、数字、下划线或连字符"
	_slot.tooltip_text = "使用字母、数字、下划线或连字符，最多 64 个字符。"
	_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot.add_theme_font_size_override("font_size",14)
	_slot.add_theme_color_override("font_color",MUTED)
	_slot.add_theme_stylebox_override("normal",_style(Color("#202521b3"),BRASS,1))
	_slot_row.add_child(_slot)
	_status = _label("",14,BRASS)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_area.add_child(_status)
	_refresh()
	_buttons.field.grab_focus()

func _open_character() -> void:
	var reply: Dictionary = _root.character_view()
	if not reply.ok:
		_display(reply)
		return
	_character_panel=load("res://presentation/ui/ports/character_panel.gd").new()
	add_child(_character_panel)
	_area.hide()
	_character_panel.closed.connect(_close_character)
	_character_panel.mount(reply.value,_root.character_view,_root.character_command)

func _close_character() -> void:
	remove_child(_character_panel)
	_character_panel.queue_free()
	_character_panel=null
	_area.show()
	_refresh()
	_buttons.character.grab_focus()

func _display(reply: Dictionary) -> void:
	_status.text="操作完成" if reply.ok else "%s · %s"%[reply.error.code,reply.error.field]
	_refresh()

func _refresh() -> void:
	var state: String=_root.session().query().value.state
	_title.text={"Frontend":"主菜单","CampaignMap":"沙盒世界","CustomSetup":"自定义训练","Mission":"训练中","Results":"战果"}.get(state,state)
	_buttons.new.visible=state=="Frontend"
	_buttons.load.visible=state=="Frontend"
	_slot_row.visible=state=="Frontend"
	_buttons.save.visible=state=="CampaignMap"
	_buttons.character.visible=state=="CampaignMap"
	_buttons.resume.visible=state=="Results" and _root.pending_result().ok
	_buttons.resume.disabled=not _root.has_campaign_settlement()
	if _buttons.resume.visible and _buttons.resume.disabled:
		_status.text="存档中有待结算的战果。载入对应的战役结算规则后可继续。"
	_buttons.field.visible=state in ["Frontend","CampaignMap","CustomSetup"]
	_buttons.train.visible=_buttons.field.visible
	_buttons.leave.visible=state=="Mission"
	_buttons.close.visible=state!="Frontend"
	_status.visible=not _status.text.is_empty()

func field_closed(reply: Dictionary) -> void:
	show()
	_display(reply)
	if _buttons.field.visible: _buttons.field.grab_focus()

func show_failure(error: Dictionary, retry: Callable) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_layout()
	_title.text="启动失败"
	_area.add_child(_label("%s · %s"%[error.code,error.field],16))
	_button("retry","重新启动",retry,true)
	_buttons.retry.grab_focus()
