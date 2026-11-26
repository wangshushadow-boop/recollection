extends Control
## Mission-local UI. Only the mounting application can query or submit to domain ports.
const R = preload("res://contracts/result.gd")
const Words = preload("res://presentation/ui/field_hud_text.gd")
const InputPort = preload("res://presentation/input/ports/field_input.gd")
const BattleOverlay = preload("res://presentation/ui/field_battle_overlay.gd")
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
var _page := "menu"
var _draft := {}
var _receipt := ""
var _panel := PanelContainer.new()
var _scroll := ScrollContainer.new()
var _body := VBoxContainer.new()
var _groups := VBoxContainer.new()
var _commands := GridContainer.new()
var _prefs := VBoxContainer.new()
var _overlay := BattleOverlay.new()
var _shade := ColorRect.new()
var _nodes := {}
var _labels := {}
var _pickers := {}
var _choice_cache := {}

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shade.color = Color("#17140f66")
	_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_shade)
	_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_panel)
	_panel.add_child(_scroll)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_scroll.add_child(_body)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.minimum_size_changed.connect(_resize,CONNECT_DEFERRED)
	_label("Title")
	_button("Deploy","deploy",func(): _send("deploy",{"placements":_draft.values()}))
	_button("Resume","controller",_resume)
	_button("Settings","settings",_open_page.bind("settings"))
	_button("CommandBook","command_book",_open_page.bind("command"))
	_button("BackMenu","back_menu",_open_page.bind("menu"))
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
	_overlay.name = "BattleOverlay"
	add_child(_overlay)
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
	var deploy: bool = _view.get("phase")=="deployment" and _page!="settings"
	var height := minf(maxf(100,_body.get_combined_minimum_size().y+26),maxf(100,size.y-24))
	if deploy:
		_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_panel.offset_left = 12
		_panel.offset_right = minf(size.x-12,clampf(size.x*.34,270,385))
		_panel.offset_top = 12
		_panel.offset_bottom = height+12
	else:
		_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		var half_width := minf(size.x*.46,230 if _page=="command" else 178)
		var half_height := height*.5
		_panel.offset_left = -half_width
		_panel.offset_right = half_width
		_panel.offset_top = -half_height
		_panel.offset_bottom = half_height
	queue_redraw()

func _open_page(page: String) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	var navigating := focus!=null and is_ancestor_of(focus)
	var previous := _page
	_page = page
	_confirm = false
	_capture = ""
	_scroll.scroll_vertical = 0
	_render()
	if navigating:
		var next: Control = _nodes.BackMenu if page!="menu" else _nodes["CommandBook" if previous=="command" else "Settings"]
		if next.is_visible_in_tree(): next.grab_focus()

func _resume() -> void:
	get_viewport().gui_release_focus()
	if _view.get("phase")=="battle":
		resume_requested.emit()

func set_field_capture(captured: bool) -> void:
	if _field_capture == captured: return
	_field_capture = captured
	_page = "menu"
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
		_receipt = ""
		_page = "menu"
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
	var field: String = str(e.get("field",""))
	if field=="target": return _w("choose_target")
	if field.begins_with("binding."): return _w("binding_taken")+" · "+Words.action_name(field.trim_prefix("binding."),_language)
	return _w(e.get("code","Unavailable"))

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
		var who := _side_name(row.team_key,rules)
		var parts := []
		for stat in ["ready","reserve","routed","casualties"]:
			if row.has(stat): parts.append("%s %s" % [_w(stat),row[stat]])
		if row.get("withdrawn",false): parts.append(_w("withdrawn"))
		teams.append("%s   %s" % [who," · ".join(parts)])
	return "\n".join(teams)

func _side_name(id: Variant, rules: Dictionary) -> String:
	var own: Variant = _view.get("team_key")
	if is_same(id,own): return _w("own")
	var opponents := 0
	var number := 0
	for row in rules.get("teams",[]):
		if not is_same(row.team_key,own):
			opponents += 1
			if is_same(row.team_key,id): number = opponents
	return "%s %d"%[_w("other"),number] if opponents>1 and number>0 else _w("other")

func _vitals() -> String:
	var player: Dictionary = _view.get("player",{})
	var stats := []
	for stat in ["hp","ammo","morale","direction"]:
		if player.get(stat) != null and not str(player[stat]).is_empty(): stats.append("%s %s" % [_w(stat),_w(player[stat])])
	return " · ".join(stats)

func _desktop_key(action: String) -> String:
	var binding: Dictionary = _view.get("bindings",{}).get(action,{})
	var token: String = binding.get("desktop","")
	return InputPort.Profile.desktop_key_name(token) if not token.is_empty() else ""

func _render_field() -> void:
	var rules: Dictionary = _view.get("rules",{})
	var own := -1
	var other := 0
	for team in rules.get("teams",[]):
		if is_same(team.team_key,_view.get("team_key")): own = team.get("ready",0)
		else: other += int(team.get("ready",0))
	_overlay.set_strength(own,other,_w("own"),_w("other"))
	var player: Dictionary = _view.get("player",{})
	var weapons: Array = player.get("weapons",[])
	var slot: int = player.get("weapon_slot",-1)
	var kit := PackedStringArray()
	if slot>=0 and slot<weapons.size(): kit.append(_w(weapons[slot]))
	if player.has("ammo"): kit.append("%s  %s"%[_w("ammo"),player.ammo])
	_overlay.weapon.text = "   ·   ".join(kit)
	_overlay.health.text = "%s   %s"%[_w("hp"),player.hp] if player.has("hp") else ""
	# River field actors enlist with COM's default initial health of 100.
	_overlay.health_bar.max_value = player.get("max_hp",100)
	_overlay.health_bar.value = player.get("hp",0)
	_overlay.health_bar.visible = player.has("hp") and player.hp<=_overlay.health_bar.max_value
	_overlay.equipment.get_parent().visible = not player.is_empty()
	_overlay.board.visible = _view.get("scoreboard_held",false)
	if _overlay.board.visible:
		_overlay.board_title.text = _w("scoreboard")
		var teams: Array = rules.get("teams",[])
		var stats := ["ready","reserve","routed"]
		if teams.any(func(t):return t.has("casualties")): stats.append("casualties")
		var table := [[_w("side")]+stats.map(_w)]
		for team in teams:
			var label := _side_name(team.team_key,rules)
			if team.get("withdrawn",false): label += " · "+_w("withdrawn")
			var row := [label]
			for stat in stats: row.append(team.get(stat,"—"))
			table.append(row)
		_overlay.set_score(table)
		_overlay.board_body.text = _vitals()
	_overlay.order_box.visible = _view.get("orders_open",false) and not _overlay.board.visible
	if _overlay.order_box.visible:
		var groups := []
		var ids := []
		for g in _view.get("formations",[]):
			if g.get("controllable",true): ids.append(g.id)
		ids.sort()
		for g in _view.get("formations",[]):
			var index: int = ids.find(g.id)
			if index<0: continue
			var key := _desktop_key("select_"+str(index+1))
			var title := _w(g.get("troop_role",g.get("layout","line")))
			groups.append(["%s  %s · %d"%[key,title,g.get("count",g.get("members",[]).size())],g.id in _selection()])
		_overlay.set_cards(_overlay.formations,groups)
		var choices := []
		for choice in _view.get("command_choices",[]):
			choices.append(["%s  %s" % [choice.key,_w(choice.id)],false])
		_overlay.set_cards(_overlay.orders,choices)
	var lines := PackedStringArray()
	var feedback: Dictionary = _view.get("command_feedback",{})
	if feedback.get("ok")==false: lines.append(_error_text(feedback))
	if _captions and not str(_view.get("subtitle","")).is_empty(): lines.append(str(_view.subtitle))
	_overlay.notice.text = "\n".join(lines)
	var hints := PackedStringArray()
	var actions := ["attack","block","select_all","scoreboard","menu"]
	if _view.get("orders_open",false): actions = ["select_all","scoreboard","menu"]
	for action in actions:
		var key := _desktop_key(action)
		if not key.is_empty(): hints.append(key+" "+_w(action))
	_overlay.hints.text = "    ".join(hints)

func _render() -> void:
	if _nodes.is_empty(): return
	_overlay.visible = _field_capture and not _view.is_empty()
	_panel.visible = not _field_capture
	_shade.visible = not _field_capture and _view.get("phase","") in ["battle","ended"]
	if _field_capture:
		_render_field()
		return
	for id in _labels: _nodes[id].text = _w(_labels[id])
	var phase: String = _view.get("phase","")
	var deploy := phase == "deployment" and _page!="settings"
	var battle := phase == "battle"
	var finished := phase == "ended"
	var rules: Dictionary = _view.get("rules",{})
	var modes: Array = rules.get("commander_options",[])
	var left_field: bool = rules.get("teams",[]).any(func(t):return is_same(t.team_key,_view.get("team_key")) and t.get("withdrawn",false))
	var direct: bool = battle and not rules.get("commander_downed",false) and not left_field
	var command: bool = direct and _page=="command"
	var can_withdraw: bool = battle and _view.get("can_withdraw",false) and not left_field
	if not can_withdraw: _confirm = false
	var menu: bool = _page=="menu" and not _confirm
	_nodes.Resume.visible = direct and menu and _view.get("control_mode","direct")=="direct"
	_nodes.CommandBook.visible = direct and menu
	_nodes.Settings.visible = menu and not finished
	_nodes.BackMenu.visible = _page!="menu" and not _confirm
	_prefs.visible = _page=="settings" and not _confirm
	var title := "battle_menu" if battle else phase
	if _page=="command": title = "command_book"
	if _page=="settings": title = "settings"
	if _confirm: title = "withdraw"
	_nodes.Title.text = _w(title if not title.is_empty() else "Unavailable")
	_nodes.Title.add_theme_font_size_override("font_size",22 if not _large else 26)
	_text("Strength",_strength(rules) if deploy or command or finished else "")
	_text("Vitals",_vitals() if command else "")
	_text("Objective",str(_view.get("objective","")) if deploy or command else "")
	_text("Captions",str(_view.get("subtitle","")) if _captions and (deploy or command) else "")
	_groups.visible = (deploy or command) and not _confirm
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
	_commands.visible = (deploy or command) and not _confirm
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
	_nodes.Withdraw.visible = can_withdraw and menu
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
	_resize()

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
		var count: int = g.get("count",g.get("members",[]).size())
		var parts := ["#%d"%id]
		if g.has("troop_role"): parts.append(_w(g.troop_role))
		parts.append(_w("await_deploy") if count==0 and _view.get("phase")=="deployment" else "×%d"%count)
		parts.append(_w(g.get("layout","")))
		if b.disabled: parts.append(_w("readonly"))
		if g.get("active") is Dictionary: parts.append(_w(g.active.get("order_type","")))
		if not str(g.get("delegate","")).is_empty(): parts.append(_w("delegated"))
		var fb: Dictionary = g.get("feedback",{})
		for key in ["state","reason"]:
			if not str(fb.get(key,"")).is_empty(): parts.append(_w(fb[key]))
		var terrain: Dictionary = g.get("terrain_feedback",{})
		if not str(terrain.get("reason","")).is_empty(): parts.append(_w(terrain.reason))
		b.text = ("◆   " if b.button_pressed else "◇   ") + " · ".join(parts)
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
	if not winners.is_empty(): parts.append(_w("winners")+" "+" / ".join(winners.map(func(t):return _side_name(t,rules))))
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
	var box := BattleOverlay.frame(Color("#12110f") if _contrast else Color("#28251ff5"),BattleOverlay.Brass,12)
	box.border_width_top = 3
	box.border_width_bottom = 2
	_panel.add_theme_stylebox_override("panel",box)
	sheet.set_stylebox("normal","Button",BattleOverlay.frame(Color("#342f27"),Color("#6c5e45"),6))
	sheet.set_stylebox("hover","Button",BattleOverlay.frame(Color("#504431"),Color("#e3c184"),6))
	sheet.set_stylebox("pressed","Button",BattleOverlay.frame(Color("#5b4931"),Color("#e3c184"),6))
	_nodes.Deploy.add_theme_stylebox_override("normal",BattleOverlay.frame(Color("#6e512c"),Color("#dda95e"),7))
	_nodes.Resume.add_theme_stylebox_override("normal",BattleOverlay.frame(Color("#6e512c"),Color("#dda95e"),7))
	_nodes.Title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
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
		if _page!="menu" and event is InputEventKey and event.keycode==KEY_ESCAPE and event.pressed:
			_open_page("menu")
			get_viewport().set_input_as_handled()
			return
		var keyboard: bool = event is InputEventKey and event.keycode == KEY_F6
		var pad: bool = event is InputEventJoypadButton and event.button_index == JOY_BUTTON_DPAD_UP and focus == null
		if (keyboard or pad) and event.is_pressed():
			if focus != null and is_ancestor_of(focus): get_viewport().gui_release_focus()
			else:
				for id in ["Resume","BackMenu","Deploy","DownSpectate","Leave","Settings"]:
					if _nodes[id].is_visible_in_tree():
						_nodes[id].grab_focus()
						break
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
			elif _page!="menu":
				var previous := _page
				_open_page("menu")
				_nodes["Settings" if previous=="settings" else "CommandBook"].grab_focus()
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
