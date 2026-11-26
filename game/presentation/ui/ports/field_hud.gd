extends Control
## Mission-local UI. Only the mounting application can query or submit to domain ports.
const R = preload("res://contracts/result.gd")
const Words = preload("res://presentation/ui/field_hud_text.gd")
const InputPort = preload("res://presentation/input/ports/field_input.gd")
signal resume_requested

var _scope := ""
var _query: Callable
var _submit: Callable
var _view := {}
var _revision := -1
var _generation := 0
var _age := 0.0
var _path := ""
var _language := "zh"
var _large := false
var _contrast := false
var _captions := true
var _capture := ""
var _confirm := false
var _field_capture := false
var _draft := {}
var _receipt := ""
var _panel := PanelContainer.new()
var _scroll := ScrollContainer.new()
var _body := VBoxContainer.new()
var _groups := VBoxContainer.new()
var _commands := GridContainer.new()
var _prefs := VBoxContainer.new()
var _field_info := Label.new()
var _field_hints := Label.new()
var _nodes := {}
var _labels := {}
var _pickers := {}
var _choice_cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	_panel.offset_left = 8
	_panel.offset_top = 8
	_panel.anchor_bottom = 1
	_panel.offset_bottom = -8
	_panel.add_child(_scroll)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_scroll.add_child(_body)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label("Title")
	_button("Resume","controller",_resume)
	_button("Settings","settings",func(): _prefs.visible = not _prefs.visible)
	_body.add_child(_prefs)
	_prefs.hide()
	_label("Downed")
	for mode in ["spectate","delegate"]:
		_button("Down"+mode.capitalize(),mode,_send.bind("downed",{"mode":mode}))
	_label("Strength")
	_label("Vitals")
	_label("Objective")
	_label("Formations","select")
	_body.add_child(_groups)
	_picker("Layout","layout")
	_picker("Zone","zone")
	_picker("Target","target")
	_label("Point")
	_label("Draft")
	_commands.columns = 2
	_body.add_child(_commands)
	_button("Mark","mark",_mark,_commands)
	_button("Reset","reset",func(): _draft.clear(); _render(),_commands)
	_button("Deploy","deploy",func(): _send("deploy",{"placements":_draft.values()}),_commands)
	for pair in [["Hold","hold"],["Charge","charge"],["Move","move"],["ApplyLayout","set_layout"],["Delegate","delegate"]]:
		_button(pair[0],pair[1],_order.bind(pair[1]),_commands)
	_button("Withdraw","withdraw",_ask_withdraw)
	_label("Question","confirm_hint")
	_button("Confirm","confirm",func(): _confirm = false; _send("withdraw",{}))
	_button("Cancel","cancel",func(): _confirm = false; _render())
	_label("Result")
	_button("Leave","leave",_send.bind("leave",{}))
	_label("Receipt")
	_label("Captions")
	_button("Language","language",_setting.bind("language"),_prefs)
	_button("Large","large",_setting.bind("large"),_prefs,true)
	_button("Contrast","contrast",_setting.bind("contrast"),_prefs,true)
	_button("Subtitles","captions",_setting.bind("captions"),_prefs,true)
	_picker("Binding","binding",_prefs)
	_button("Rebind","rebind",func(): _capture = _chosen("Binding"); _render(),_prefs)
	_field_info.name = "FieldInfo"
	_field_hints.name = "FieldHints"
	for label in [_field_info,_field_hints]:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_outline_color",Color.BLACK)
		label.add_theme_constant_override("outline_size",4)
		add_child(label)
		label.anchor_right = 1
		label.offset_left = 14
		label.offset_right = -14
	_field_info.offset_top = 12
	_field_hints.anchor_top = 1
	_field_hints.anchor_bottom = 1
	_field_hints.offset_bottom = -12
	_field_hints.grow_vertical = Control.GROW_DIRECTION_BEGIN
	resized.connect(_resize)
	_appearance()
	_resize()
	_render()

func _label(id: String, caption: String = "") -> void:
	var label := Label.new()
	label.name = id
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_child(label)
	_nodes[id] = label
	if not caption.is_empty(): _labels[id] = caption

func _button(id: String, caption: String, cb: Callable, parent: Container = null, toggle := false) -> Button:
	var b := Button.new()
	b.name = id
	b.toggle_mode = toggle
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	b.pressed.connect(cb)
	(parent if parent != null else _body).add_child(b)
	_nodes[id] = b
	_labels[id] = caption
	return b

func _picker(id: String, caption: String, parent: Container = null) -> void:
	var row := HBoxContainer.new()
	(parent if parent != null else _body).add_child(row)
	var label := Label.new()
	row.add_child(label)
	_nodes[id+"Label"] = label
	_labels[id+"Label"] = caption
	var menu := OptionButton.new()
	menu.name = id
	menu.fit_to_longest_item = false
	menu.tooltip_text = "◀ / ▶"
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu.item_selected.connect(func(_i): _render())
	row.add_child(menu)
	_pickers[id] = menu
	_nodes[id+"Row"] = row

func _resize() -> void:
	_panel.offset_right = _panel.offset_left + clampf(size.x*0.34, minf(size.x-16,256), 385)
	queue_redraw()

func _resume() -> void:
	get_viewport().gui_release_focus()
	if _view.get("phase")=="battle":
		resume_requested.emit()

func set_field_capture(captured: bool) -> void:
	if _field_capture == captured: return
	_field_capture = captured
	if captured:
		_confirm = false
		_capture = ""
		_prefs.hide()
		for picker: OptionButton in _pickers.values():
			picker.get_popup().hide()
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null and is_ancestor_of(focus): focus.release_focus()
	_render()
	queue_redraw()

func _draw() -> void:
	if not _field_capture or _view.is_empty() or _view.get("phase")=="ended": return
	var center := (size*0.5).round()
	for direction: Vector2 in [Vector2.UP,Vector2.RIGHT,Vector2.DOWN,Vector2.LEFT]:
		draw_line(center+direction*3,center+direction*8,Color("#171717d0"),3)
		draw_line(center+direction*3,center+direction*8,Color("#faf5dd"),1)

func _w(key: Variant) -> String:
	return Words.word(key,_language)

func mount(scope: String, read_view: Callable, submit: Callable, settings_path := "user://field_hud.cfg") -> Dictionary:
	release_scope()
	if scope.is_empty() or not read_view.is_valid() or not submit.is_valid():
		return R.fail("InvalidArgument","hud_scope")
	_scope = scope
	_query = read_view
	_submit = submit
	_path = settings_path
	var cfg := ConfigFile.new()
	if not _path.is_empty() and FileAccess.file_exists(_path): cfg.load(_path)
	_language = "en" if cfg.get_value("hud","language","zh") == "en" else "zh"
	_large = cfg.get_value("hud","large",false) == true
	_contrast = cfg.get_value("hud","contrast",false) == true
	_captions = cfg.get_value("hud","captions",true) == true
	show()
	if is_node_ready(): _appearance()
	return refresh()

func release_scope() -> void:
	_generation += 1
	_field_capture = false
	queue_redraw()
	_scope = ""
	_query = Callable()
	_submit = Callable()
	_revision = -1
	_invalidate()
	_prefs.hide()
	hide()

func _invalidate() -> void:
	_view.clear()
	_draft.clear()
	_choice_cache.clear()
	_confirm = false
	_capture = ""
	_receipt = ""
	queue_redraw()
	if is_node_ready(): _render()

func _process(delta: float) -> void:
	_age += delta
	if _age >= 0.2 and not _scope.is_empty():
		_age = 0
		refresh()

func refresh() -> Dictionary:
	if not _query.is_valid(): return R.fail("Unavailable","hud_scope")
	var generation := _generation
	var result: Variant = _query.call()
	if generation != _generation: return R.fail("StaleVersion","hud_scope")
	if typeof(result) != TYPE_DICTIONARY or not result.get("ok",false):
		_invalidate()
		return result if typeof(result) == TYPE_DICTIONARY else R.fail("Unavailable","hud_view")
	var v: Variant = result.get("value")
	if typeof(v) != TYPE_DICTIONARY or v.get("scope_id") != _scope or typeof(v.get("revision")) != TYPE_INT or v.revision < _revision or v.get("phase") not in ["deployment","battle","ended"]:
		_invalidate()
		return R.fail("StaleVersion","hud_view")
	if _view.get("phase") != v.phase:
		queue_redraw()
		_confirm = false
		_capture = ""
		_draft.clear()
	_view = v.duplicate(true)
	_revision = v.revision
	if is_node_ready():
		_render()
	return R.ok()

func _send(action: String, fields: Dictionary) -> Dictionary:
	if _view.is_empty() or not _submit.is_valid(): return R.fail("Unavailable","hud_scope")
	var generation := _generation
	var data := fields.duplicate(true)
	data.merge({"scope_id":_scope,"revision":_revision})
	var r: Variant = _submit.call(action,data)
	if generation != _generation: return R.fail("StaleVersion","hud_scope")
	if typeof(r) != TYPE_DICTIONARY or not r.has("ok"): r = R.fail("Unavailable","receipt")
	_receipt = _w("accepted") if r.ok else _error_text(r)
	refresh()
	return r

func _error_text(r: Dictionary) -> String:
	var e: Dictionary = r.get("error",{})
	return "%s · %s" % [_w(e.get("code","Unavailable")),str(e.get("field",""))]

func _selection() -> Array:
	return _view.get("selection",[])

func _toggle(id: int) -> void:
	var ids := _selection().duplicate()
	if ids.has(id): ids.erase(id)
	else: ids.append(id)
	_send("select",{"ids":ids})

func _chosen(id: String) -> Variant:
	var menu: OptionButton = _pickers[id]
	return menu.get_item_metadata(menu.selected) if menu.selected >= 0 else null

func _choices(id: String, values: Array, captions: Array) -> void:
	if _choice_cache.get(id) == [values,captions]: return
	var menu: OptionButton = _pickers[id]
	var prev: Variant = _chosen(id)
	menu.clear()
	for i in values.size():
		menu.add_item(str(captions[i]))
		menu.set_item_metadata(i,values[i])
	if prev != null and values.has(prev): menu.select(values.find(prev))
	_choice_cache[id] = [values.duplicate(true),captions.duplicate()]

func _mark() -> void:
	var zone: Variant = _chosen("Zone")
	if zone == null: return
	for id in _selection():
		_draft[id] = {"formation_id":id,"zone_id":zone,"layout":_chosen("Layout")}
	_render()

func _order(kind: String) -> void:
	var params := {}
	if kind == "set_layout":
		kind = "layout"
		params = {"layout":_chosen("Layout")}
	elif kind == "delegate":
		params = {"actor":_view.get("delegate_candidate","")}
	_send("order",{"kind":kind,"parameters":params,"formation_ids":_selection(),"target_formation_id":_chosen("Target"),"target_position":_view.get("target_position")})

func _ask_withdraw() -> void:
	_confirm = true
	_render()
	_nodes.Cancel.grab_focus()

func _point(mm: Array) -> String:
	return "%.1f, %.1f, %.1f" % [mm[0]*0.001,mm[1]*0.001,mm[2]*0.001]

func _strength(rules: Dictionary) -> String:
	var teams := []
	for row in rules.get("teams",[]):
		var who := _w("own" if is_same(row.team_key,_view.get("team_key")) else "other")
		var parts := []
		for stat in ["ready","reserve","routed","casualties"]:
			if row.has(stat): parts.append("%s %s" % [_w(stat),row[stat]])
		if row.get("withdrawn",false): parts.append(_w("withdrawn"))
		teams.append("%s %s   %s" % [who,row.team_key," · ".join(parts)])
	return "\n".join(teams)

func _vitals() -> String:
	var player: Dictionary = _view.get("player",{})
	var stats := []
	for stat in ["hp","ammo","morale","direction"]:
		if player.get(stat) != null: stats.append("%s %s" % [_w(stat),_w(player[stat])])
	return " · ".join(stats)

func _desktop_key(action: String) -> String:
	var binding: Dictionary = _view.get("bindings",{}).get(action,{})
	var token: String = binding.get("desktop","")
	return InputPort.Profile.desktop_key_name(token) if not token.is_empty() else ""

func _render_field() -> void:
	var lines := PackedStringArray()
	var rules: Dictionary = _view.get("rules",{})
	if _view.get("scoreboard_held",false):
		lines.append(_strength(rules))
	elif _view.get("orders_open",false):
		var selected := PackedStringArray()
		for id in _selection(): selected.append(str(id))
		var title := _w(_view.get("command_page","")) if not str(_view.get("command_page","")).is_empty() else _w("orders")
		if not selected.is_empty(): title += " · #"+", #".join(selected)
		lines.append(title)
		var choices := PackedStringArray()
		for choice in _view.get("command_choices",[]):
			choices.append("%s %s" % [choice.key,_w(choice.id)])
		if not choices.is_empty(): lines.append("    ".join(choices))
	else:
		lines.append(_vitals())
	var feedback: Dictionary = _view.get("command_feedback",{})
	if feedback.get("ok")==false: lines.append(_error_text(feedback))
	if _captions and not str(_view.get("subtitle","")).is_empty(): lines.append(str(_view.subtitle))
	_field_info.text = "\n".join(lines)
	var hints := PackedStringArray()
	var actions := ["attack","block","select_all","scoreboard","menu"]
	if _view.get("orders_open",false): actions = ["select_all","scoreboard","menu"]
	for action in actions:
		var key := _desktop_key(action)
		if not key.is_empty(): hints.append(key+" "+_w(action))
	_field_hints.text = "    ".join(hints)

func _render() -> void:
	if _nodes.is_empty(): return
	_panel.visible = not _field_capture
	_field_info.visible = _field_capture
	_field_hints.visible = _field_capture
	if _field_capture:
		_render_field()
		return
	for id in _labels: _nodes[id].text = _w(_labels[id])
	var phase: String = _view.get("phase","")
	var deploy := phase == "deployment"
	var battle := phase == "battle"
	var finished := phase == "ended"
	var rules: Dictionary = _view.get("rules",{})
	var modes: Array = rules.get("commander_options",[])
	var left_field: bool = rules.get("teams",[]).any(func(t):return is_same(t.team_key,_view.get("team_key")) and t.get("withdrawn",false))
	var command: bool = battle and not rules.get("commander_downed",false) and not left_field
	var can_withdraw: bool = battle and _view.get("can_withdraw",false) and not left_field
	_nodes.Resume.visible = command and not _confirm and _view.get("control_mode","direct")=="direct"
	if not can_withdraw: _confirm = false
	_nodes.Title.text = _w(phase if not phase.is_empty() else "Unavailable")
	_nodes.Title.add_theme_font_size_override("font_size",22 if not _large else 26)
	_text("Strength",_strength(rules))
	_text("Vitals",_vitals())
	_text("Objective",str(_view.get("objective","")))
	_text("Captions",str(_view.get("subtitle","")) if _captions else "")
	_nodes.Formations.visible = deploy or battle
	_groups.visible = (deploy or battle) and not _confirm
	_nodes.Formations.visible = _groups.visible
	_render_groups()
	_nodes.LayoutRow.visible = deploy or (command and not _confirm)
	_choices("Layout",InputPort.LAYOUTS,InputPort.LAYOUTS.map(_w))
	_nodes.ZoneRow.visible = deploy
	var zones := [null]
	var zone_names := [_w("pick")]
	for z in _view.get("deployment_zones",[]):
		zones.append(z.id)
		var pos: Array = z.get("position_mm",[])
		zone_names.append("%s  %s" % [z.id,_point(pos) if pos.size()==3 else ""])
	_choices("Zone",zones,zone_names)
	var targets: Array = [null]+_view.get("targets",[])
	_choices("Target",targets,[_w("pick")]+targets.slice(1).map(func(id):return "#"+str(id)))
	_nodes.TargetRow.visible = command and not _confirm
	var point: Variant = _view.get("target_position")
	var has_point: bool = typeof(point)==TYPE_ARRAY and point.size()==3
	_text("Point","%s  %s" % [_w("point"),_point(point)] if command and has_point else "")
	var lines := []
	for id in _draft.keys():
		if not zones.has(_draft[id].zone_id):
			_draft.erase(id)
			continue
		lines.append("#%s → %s · %s" % [id,_draft[id].zone_id,_w(_draft[id].layout)])
	_text("Draft",(_w("preview")+"\n"+"\n".join(lines)) if deploy and not lines.is_empty() else "")
	var selected := not _selection().is_empty()
	_commands.visible = not _confirm
	_show_action("Mark",deploy,selected and _chosen("Zone") != null)
	_show_action("Reset",deploy,not _draft.is_empty())
	_show_action("Deploy",deploy,true)
	_show_action("Hold",command,selected)
	_show_action("ApplyLayout",command,selected)
	_show_action("Charge",command,selected and _chosen("Target") != null)
	_show_action("Move",command,selected and has_point)
	_show_action("Delegate",command,_selection().size()==1 and not str(_view.get("delegate_candidate","")).is_empty())
	_text("Downed",_w("downed")+" · "+_w(rules.get("control_mode","")) if battle and rules.get("commander_downed",false) else "")
	_nodes.DownSpectate.visible = battle and modes.has("spectate") and not _confirm
	_nodes.DownDelegate.visible = battle and modes.has("delegate") and not _confirm
	_nodes.Withdraw.visible = can_withdraw and not _confirm
	for id in ["Question","Confirm","Cancel"]: _nodes[id].visible = _confirm
	_nodes.Leave.visible = finished
	_text("Result",_result(rules) if finished else "")
	var fb: Dictionary = _view.get("command_feedback",{})
	var msg := _receipt
	if fb.get("ok") == false: msg = _error_text(fb)
	var actions: Array = _view.get("bindable_actions",[]).filter(func(a):return a is String and a != "menu")
	var can_bind: bool = _view.get("allow_rebind",false) and not actions.is_empty()
	if not can_bind or not actions.has(_capture): _capture = ""
	var captions := []
	for action in actions:
		var key := _desktop_key(action)
		captions.append(Words.action_name(action,_language)+( " · "+key if not key.is_empty() else ""))
	_choices("Binding",actions,captions)
	_nodes.BindingRow.visible = can_bind
	_nodes.Rebind.visible = can_bind
	if not _capture.is_empty(): _nodes.Rebind.text = _w("key")
	_text("Receipt",_w("key")+" · "+Words.action_name(_capture,_language) if not _capture.is_empty() else msg)
	_nodes.Large.set_pressed_no_signal(_large)
	_nodes.Contrast.set_pressed_no_signal(_contrast)
	_nodes.Subtitles.set_pressed_no_signal(_captions)

func _render_groups() -> void:
	var seen := {}
	for g in _view.get("formations",[]):
		var id: int = g.id
		var node_name := "Group"+str(id)
		seen[id] = true
		var b := _groups.get_node_or_null(node_name) as Button
		if b == null:
			b = Button.new()
			b.name = node_name
			b.toggle_mode = true
			b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.pressed.connect(_toggle.bind(id))
			_groups.add_child(b)
		b.disabled = not g.get("controllable",true)
		b.set_pressed_no_signal(_selection().has(id))
		var parts := ["#%d ×%d" % [id,g.get("count",g.get("members",[]).size())],_w(g.get("layout","")),_w("readonly" if b.disabled else "authority")]
		if g.get("active") is Dictionary: parts.append(_w(g.active.get("order_type","")))
		if not str(g.get("delegate","")).is_empty(): parts.append(_w("delegate")+" "+str(g.delegate))
		var fb: Dictionary = g.get("feedback",{})
		for key in ["state","reason"]:
			if not str(fb.get(key,"")).is_empty(): parts.append(_w(fb[key]))
		var terrain: Dictionary = g.get("terrain_feedback",{})
		if not str(terrain.get("reason","")).is_empty(): parts.append(_w(terrain.reason))
		b.text = ("[+]  " if b.button_pressed else "[  ]  ") + " · ".join(parts)
	for b in _groups.get_children():
		var id := str(b.name).trim_prefix("Group").to_int()
		if not seen.has(id):
			_groups.remove_child(b)
			b.queue_free()
	for id in _draft.keys():
		if not seen.has(id) or _groups.get_node("Group"+str(id)).disabled: _draft.erase(id)

func _result(rules: Dictionary) -> String:
	var res: Variant = _view.get("result")
	if typeof(res) != TYPE_DICTIONARY: res = rules.get("outcome")
	if typeof(res) != TYPE_DICTIONARY: return ""
	var winners: Array = res.get("winner_team_keys",[])
	var own: Variant = _view.get("team_key")
	var outcome := "defeat"
	if rules.get("teams",[]).any(func(t):return is_same(t.team_key,own) and t.get("withdrawn",false)):
		outcome = "withdrawn"
	elif winners.any(func(team):return is_same(team,own)): outcome = "victory"
	elif res.get("outcome")=="draw": outcome = "draw"
	var parts := [_w(outcome)]
	if not winners.is_empty(): parts.append(_w("winners")+" "+" / ".join(winners.map(func(t):return str(t))))
	var counts := {}
	for row in res.get("slot_outcomes",[]):
		var status: String = row.get("end_status","") if row is Dictionary else ""
		if not status.is_empty(): counts[status] = counts.get(status,0)+1
	for status in counts: parts.append("%s ×%d" % [_w(status),counts[status]])
	return " · ".join(parts)

func _show_action(id: String, shown: bool, enabled: bool) -> void:
	_nodes[id].visible = shown
	_nodes[id].disabled = not enabled

func _text(id: String, value: String) -> void:
	_nodes[id].text = value
	_nodes[id].visible = not value.is_empty()

func _setting(key: String) -> void:
	match key:
		"language": _language = "en" if _language == "zh" else "zh"
		"large": _large = not _large
		"contrast": _contrast = not _contrast
		"captions": _captions = not _captions
	_appearance()
	if not _path.is_empty():
		var cfg := ConfigFile.new()
		for pair in [["language",_language],["large",_large],["contrast",_contrast],["captions",_captions]]:
			cfg.set_value("hud",pair[0],pair[1])
		if cfg.save(_path) != OK: _receipt = _error_text(R.fail("Unavailable","hud_settings"))
	_render()

func _appearance() -> void:
	var sheet := Theme.new()
	sheet.default_font_size = 19 if _large else 15
	theme = sheet
	var box := StyleBoxFlat.new()
	box.bg_color = Color("#0a1016") if _contrast else Color("#17242af5")
	box.border_color = Color("#e8bb70")
	box.border_width_left = 2
	for side in [SIDE_LEFT,SIDE_RIGHT,SIDE_TOP,SIDE_BOTTOM]: box.set_content_margin(side,9)
	_panel.add_theme_stylebox_override("panel",box)
	_nodes.Title.add_theme_color_override("font_color",Color("#ffe0a1"))

func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _field_capture: return
	if event is InputEventKey and event.echo: return
	if _capture.is_empty():
		var focus := get_viewport().gui_get_focus_owner()
		if _confirm and event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
			_confirm = false
			_render()
			_nodes.Withdraw.grab_focus()
			get_viewport().set_input_as_handled()
			return
		var keyboard: bool = event is InputEventKey and event.keycode == KEY_F6
		var pad: bool = event is InputEventJoypadButton and event.button_index == JOY_BUTTON_DPAD_UP and focus == null
		if (keyboard or pad) and event.is_pressed():
			if focus != null and is_ancestor_of(focus): get_viewport().gui_release_focus()
			else: _nodes.Resume.grab_focus()
			get_viewport().set_input_as_handled()
		elif event is InputEventJoypadButton and focus != null and is_ancestor_of(focus):
			_pad_navigation(event,focus)
		return
	if event is InputEventJoypadMotion:
		if absf(event.axis_value)<0.5: return
	elif not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventMouseButton) or not event.is_pressed(): return
	get_viewport().set_input_as_handled()
	var action := _capture
	_capture = ""
	if event is InputEventKey and event.keycode == KEY_ESCAPE:
		_render()
		return
	_send("rebind",{"binding":action,"event":event})

func _pad_navigation(event: InputEventJoypadButton, focus: Control) -> void:
	var code := event.button_index
	if code == JOY_BUTTON_B:
		if event.pressed:
			if _confirm: _confirm = false; _render(); _nodes.Withdraw.grab_focus()
			elif _prefs.visible: _prefs.hide(); _nodes.Settings.grab_focus()
			else: get_viewport().gui_release_focus()
	elif focus is OptionButton and code in [JOY_BUTTON_A,JOY_BUTTON_DPAD_LEFT,JOY_BUTTON_DPAD_RIGHT]:
		if event.pressed and focus.item_count:
			var next := posmod(focus.selected+(-1 if code==JOY_BUTTON_DPAD_LEFT else 1),focus.item_count)
			focus.select(next)
			focus.item_selected.emit(next)
	else:
		var keys := {JOY_BUTTON_A:KEY_ENTER,JOY_BUTTON_DPAD_UP:KEY_UP,JOY_BUTTON_DPAD_DOWN:KEY_DOWN,
			JOY_BUTTON_DPAD_LEFT:KEY_LEFT,JOY_BUTTON_DPAD_RIGHT:KEY_RIGHT}
		if not keys.has(code): return
		var nav := InputEventKey.new()
		nav.keycode = keys[code]
		nav.pressed = event.pressed
		get_viewport().push_input(nav,true)
	get_viewport().set_input_as_handled()
