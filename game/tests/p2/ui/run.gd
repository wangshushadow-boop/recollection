extends SceneTree
## Real GUI events -> HUD -> INPUT -> FORM; authenticated RULES withdrawal / downed choice.
const HUD = preload("res://presentation/ui/ports/field_hud.gd")
const FieldInput = preload("res://presentation/input/ports/field_input.gd")
const FORM = preload("res://mission/formation/ports/field_formation.gd")
const RULES = preload("res://mission/rules/ports/field_rules.gd")
const R = preload("res://contracts/result.gd")
const UUID := "b48883c0-79fb-4cd3-96fe-43bb44dfddbb"
const SCOPE := "mission/"+UUID
var profile := "hudtest"+str(OS.get_process_id())
var prefs := "user://"+profile+".cfg"
var hud := HUD.new()
var input: FieldInput
var form: FORM
var rules: RULES
var login := RefCounted.new()
var phase := "deployment"
var revision := 0
var tick := 0
var rows := []
var commander_hp := 90
var scope_read := SCOPE
var auth := true
var point := [2500,0,500]
var last_action := {}
var sent := []
var failures := 0
var checks := 0
var encounter_template := {}
var field_overlay := {}

class FieldClicks extends Node:
	var buttons := []
	func _unhandled_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			buttons.append(event.button_index)
			get_viewport().set_input_as_handled()

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		printerr("FAIL HUD ",label)
		failures += 1

func setup() -> void:
	var sides := []
	var zones := []
	for i in 2:
		var first: int = i*2
		sides.append({"team_key":i,"faction_id":"river","commander_hero_id":null,"roster_allocations":[{"source_slot_range":[first,first+2]}]})
		zones.append({"team_key":i,"min_mm":[0,0,0],"max_mm":[1000,1000,1000]})
	for i in 4: rows.append({"handle":{"index":i,"generation":1},"source_slot":i,"components":{"team_key":0 if i<2 else 1}})
	var encounter := {"schema_version":1,"encounter_id":"encounter/"+UUID,"reservation_revision":1,"mode":"custom","scene_def_id":"field:scene/river_plain","ruleset_id":"field:ruleset/field_battle","rng_seed":"1234567890abcdef","environment":{},"sides":sides,"reserved_sources":[{"source_party_id":"party/"+UUID,"troop_def_id":"field:troop/infantry","hero_id":null,"count":4,"source_slot_range":[0,4],"loadout_snapshot_id":"issued"}],"battle_limit":4,"deployment_constraints":{},"siege_snapshot":null}
	encounter_template = encounter.duplicate(true)
	var built := RULES.build(SCOPE,encounter,zones,func(ctx,t,_a):return ctx==login and is_same(t,0),
		func(h):return R.ok({"hp":commander_hp if h.index==0 else 90,"routing":false}),func(_h):return R.ok([0,0,0]),
		func(h):return R.ok(rows[h.index]))
	check(built.ok,"RULES setup")
	rules = built.value
	check(rules.watch_commander(rows[0].handle,0).ok,"commander")
	form = FORM.new(SCOPE,func(ctx):return R.ok("player" if ctx==login and auth else ""),func(_id,p):return p[0]>=0)
	for i in 3:
		check(form.add_formation(i,0 if i<2 else 1,"player" if i<2 else "rival",[rows[i].handle]).ok,"formation")
	input = FieldInput.new(profile)
	root.add_child(input)
	check(input.configure(SCOPE,"player",rows[0].handle,0,func(_batch):return R.ok(),
		func(o,revs):return form.issue_order(o,login,revs)).ok,"INPUT setup")
	input.set_formations([0,1],{0:0,1:0})

func query() -> Dictionary:
	var groups := [form.view(0).value,form.view(1).value]
	var v := {"scope_id":scope_read,"revision":revision,"phase":phase,"formations":groups,
		"targets":[2],"team_key":0,"rules":rules.view(),"selection":input.view().selection,
		"player":{"hp":commander_hp,"ammo":4,"morale":92,"direction":"up"},"delegate_candidate":"captain",
		"deployment_zones":[{"id":"north","position_mm":[1000,0,300]}],"target_position":point,
		"can_withdraw":true,"allow_rebind":true,"bindable_actions":input.profile_view().bindings.keys(),"command_feedback":input.view().feedback,"subtitle":"Cavalry!"}
	if phase=="ended":
		v.result = rules.view().outcome.duplicate()
		v.result.slot_outcomes = [{"end_status":"wounded"},{"end_status":"withdrawn"}]
	v.bindings = input.profile_view().bindings
	v.merge(field_overlay,true)
	return R.ok(v)

func submit(action: String, data: Dictionary) -> Dictionary:
	last_action = {"action":action,"data":data.duplicate(true)}
	sent.append(action)
	check(not data.has("team_key") and not data.has("owner") and data.scope_id==SCOPE and data.revision==revision,"scope-only intent")
	match action:
		"select": return input.select_formations(data.ids)
		"deploy":
			phase = "battle"
			return R.ok()
		"order":
			input.set_context("command")
			input.select_formations(data.formation_ids)
			input.set_target(data.target_position,data.target_formation_id)
			return input.queue_order(data.kind,data.parameters)
		"downed": return rules.request_downed_mode(0,data.mode,login)
		"withdraw": return rules.request_withdrawal(0,login)
		"rebind": return input.rebind(data.binding,data.event)
		"leave": return R.ok()
	return R.fail("InvalidArgument","action")

func advance() -> void:
	tick += 1
	var frame := input.step(tick)
	check(frame.ok and form.advance(tick).ok,"INPUT/FORM tick")
	var result := rules.stage({"tick":tick-1,"mission_id":SCOPE,"entities":rows.duplicate(true),"spawned_slots":[0,1,2,3]},
		{"source_tick":tick,"mission_id":SCOPE})
	check(result.ok,"RULES tick")
	rules.commit()
	if rules.view().outcome != null: phase = "ended"
	revision += 1
	hud.refresh()

func control(id: String) -> Control:
	return hud.find_child(id,true,false) as Control

func frames() -> void:
	await process_frame
	await process_frame
	await process_frame

func press_key(code: Key) -> void:
	for state in [true,false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = state
		root.push_input(e,true)

func pad(code: JoyButton) -> void:
	for state in [true,false]:
		var e := InputEventJoypadButton.new()
		e.button_index = code
		e.pressed = state
		root.push_input(e,true)

func click(id: String) -> void:
	var b := control(id)
	var scroll := hud.find_children("*","ScrollContainer",true,false)[0] as ScrollContainer
	scroll.ensure_control_visible(b)
	await frames()
	var pos := b.get_global_rect().get_center()
	check(scroll.get_global_rect().has_point(pos) and b.is_visible_in_tree(),"reachable "+id)
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	root.push_input(motion,true)
	for state in [true,false]:
		var e := InputEventMouseButton.new()
		e.position = pos
		e.global_position = pos
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = state
		root.push_input(e,true)
	await frames()

func captured_field() -> void:
	var field := FieldClicks.new()
	root.add_child(field)
	control("Settings").grab_focus()
	hud.set_field_capture(true)
	await frames()
	check(not control("Settings").is_visible_in_tree() and root.gui_get_focus_owner()==null,"captured field releases GUI focus and hides buttons")
	var hint := control("FieldHints") as Label
	check(hint.is_visible_in_tree() and hint.text.contains("攻击") and hint.text.contains("格挡"),"field controls show active keyboard/mouse bindings")
	check(root.get_visible_rect().encloses(hint.get_global_rect()) and root.get_visible_rect().encloses(control("FieldInfo").get_global_rect()),"captured readouts fit inside the viewport")
	var count := sent.size()
	for pos in [Vector2(root.size)*0.5,Vector2(45,65)]:
		for button in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]:
			for down in [true,false]:
				var e := InputEventMouseButton.new()
				e.button_index = button
				e.position = pos
				e.global_position = pos
				e.pressed = down
				root.push_input(e,true)
	check(field.buttons==[MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT,MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT] and sent.size()==count,"both combat buttons pass through reticle and former command panel")
	field_overlay = {"orders_open":true,"command_page":"movement","command_choices":[{"key":"K","id":"charge"}]}
	hud.refresh()
	check(control("FieldInfo").text.contains("K 冲锋"),"orders display current binding and selection")
	field_overlay.scoreboard_held = true
	hud.refresh()
	check(control("FieldInfo").text.contains("本方") and control("FieldInfo").text.contains("对方"),"held battle status uses projected teams")
	field_overlay.clear()
	hud.set_field_capture(false)
	hud.refresh()
	check(control("Settings").is_visible_in_tree() and not hint.is_visible_in_tree(),"released cursor restores command controls")
	field.free()

func select_option(id: String, index: int) -> void:
	var pick := control(id) as OptionButton
	pick.select(index)
	pick.item_selected.emit(index)

func screenshot(stage: String) -> void:
	if DisplayServer.get_name()=="headless" or not OS.get_cmdline_user_args().has("--snapshot"): return
	await RenderingServer.frame_post_draw
	var out := OS.get_temp_dir().path_join("recollection-field-hud-%dx%d-%s.png" % [root.size.x,root.size.y,stage])
	check(root.get_texture().get_image().save_png(out)==OK,"capture "+stage)
	print("HUD snapshot ",out)

func start_binding(action: String) -> void:
	var picker := control("Binding") as OptionButton
	for i in picker.item_count:
		if picker.get_item_metadata(i)==action:
			select_option("Binding",i)
			control("Rebind").grab_focus()
			press_key(KEY_ENTER)
			return
	check(false,"missing binding "+action)

func key_down(code: Key) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	return e

func remap_actions() -> void:
	var options := []
	var picker := control("Binding") as OptionButton
	for i in picker.item_count: options.append(picker.get_item_metadata(i))
	var from_input: Array = input.profile_view().bindings.keys()
	from_input.erase("menu")
	check(options==from_input,"all INPUT actions offered except reserved menu")
	start_binding("attack")
	press_key(KEY_K)
	start_binding("move_forward")
	press_key(KEY_I)
	start_binding("order_hold")
	press_key(KEY_J)
	start_binding("order_hold")
	pad(JOY_BUTTON_PADDLE1)
	start_binding("move_forward")
	press_key(KEY_ESCAPE)
	var bindings: Dictionary = input.profile_view().bindings
	check(bindings.attack.desktop=="k/%d/0"%KEY_K and bindings.move_forward.desktop=="k/%d/0"%KEY_I,"attack/move remaps and cancellation")
	check(bindings.order_hold.desktop=="k/%d/0"%KEY_J and bindings.order_hold.pad=="j/%d"%JOY_BUTTON_PADDLE1,"command keyboard and gamepad remaps")
	var restored := FieldInput.new(profile)
	check(restored.configure(SCOPE,"player",rows[0].handle,0,func(_b):return R.ok(),func(_o,_r):return R.ok()).ok and restored.profile_view().bindings==bindings,"all bindings restored from disk")
	check(not restored.rebind("menu",key_down(KEY_P)).ok,"menu protected by INPUT")
	restored.handle_event(key_down(KEY_I))
	restored.handle_event(key_down(KEY_K))
	var intents: Array = restored.step(1).value.batch.inputs
	check(intents.any(func(i):return i.get("input_phase")=="start") and intents.any(func(i):return i.get("desired_direction")==[0,0,-1000000] and i.speed_fraction==1.0),"restored combat and movement produce real intents")
	restored.set_context("command")
	restored.set_formations([0],{0:0})
	restored.select_formations([0])
	restored.handle_event(key_down(KEY_J))
	var order_frame := restored.step(2)
	check(order_frame.value.orders.size()==1 and order_frame.value.orders[0].order.order_type=="hold","restored keyboard command emitted")
	var joy := InputEventJoypadButton.new()
	joy.button_index = JOY_BUTTON_PADDLE1
	joy.pressed = true
	# Release the keyboard before exercising the same action on the gamepad.
	var released := key_down(KEY_J)
	released.pressed = false
	restored.handle_event(released)
	restored.handle_event(joy)
	order_frame = restored.step(3)
	check(order_frame.value.orders.size()==1 and order_frame.value.orders[0].order.order_type=="hold","restored gamepad command emitted")
	restored.free()

func three_side_result(first_leaves: bool, draw := false) -> void:
	var teams := [0,"0",2]
	var encounter := encounter_template.duplicate(true)
	encounter.sides.clear()
	encounter.battle_limit = 3
	encounter.reserved_sources[0].count = 3
	encounter.reserved_sources[0].source_slot_range = [0,3]
	var exits := []
	var entities := []
	var hp := [90 if first_leaves else 0,90,90]
	for i in teams.size():
		encounter.sides.append({"team_key":teams[i],"faction_id":"river","commander_hero_id":null,"roster_allocations":[{"source_slot_range":[i,i+1]}]})
		exits.append({"team_key":teams[i],"min_mm":[0,0,0],"max_mm":[1,1,1]})
		entities.append({"handle":{"index":i,"generation":1},"source_slot":i,"components":{"team_key":teams[i]}})
	var built := RULES.build(SCOPE,encounter,exits,func(who,team,_act):return is_same(who,team),
		func(h):return R.ok({"hp":hp[h.index],"routing":false}),func(_h):return R.ok([0,0,0]))
	check(built.ok,"three-team RULES fixture")
	if not built.ok: return
	var rules3: RULES = built.value
	if first_leaves: check(rules3.request_withdrawal(0,0).ok,"A requests own retreat")
	var ctx := {"mission_id":SCOPE,"tick":0,"entities":entities,"spawned_slots":[0,1,2]}
	var stepped := rules3.stage(ctx,{"mission_id":SCOPE,"source_tick":1})
	check(stepped.ok and stepped.value.outcome==null,"other two sides continue")
	rules3.commit()
	if first_leaves:
		hp[1] = 0
		if draw: hp[2] = 0
		ctx.entities = entities.slice(1)
	else:
		check(rules3.request_withdrawal("0","0").ok,"B requests own retreat after A fell")
	ctx.tick = 1
	check(rules3.stage(ctx,{"mission_id":SCOPE,"source_tick":2}).ok,"actual terminal tick")
	rules3.commit()
	var end := rules3.view()
	check(end.outcome.outcome==("draw" if draw else ("victory" if first_leaves else "withdrawn")),"global cause from RULES")
	for i in teams.size():
		var v := {"scope_id":SCOPE,"revision":2,"phase":"ended","team_key":teams[i],"rules":end}
		hud.mount(SCOPE,func():return R.ok(v),submit,prefs)
		var expected: Array = ["Withdrawn","Draw","Draw"] if draw else (["Withdrawn","Defeat","Victory"] if first_leaves else ["Defeat","Withdrawn","Victory"])
		check(control("Result").text.get_slice(" · ",0)==expected[i],"personal result "+str(i)+" "+expected[i])

func run() -> void:
	create_timer(20.0).timeout.connect(func():printerr("FAIL HUD timeout");quit(1))
	if DisplayServer.get_name()=="headless" and root.size==Vector2i(64,64): root.size = Vector2i(960,600)
	setup()
	root.add_child(hud)
	check(hud.mount(SCOPE,query,submit,prefs).ok,"mount")
	await frames()
	await click("Group0")
	await click("Group1")
	check(input.view().selection==[0,1],"multi selection by mouse")
	select_option("Zone",1)
	select_option("Layout",3)
	await click("Mark")
	check(control("Draft").text.count("north")==2 and not sent.has("deploy"),"two placement previews are local")
	await screenshot("deployment-zh")
	await click("Reset")
	check(not control("Draft").visible and not sent.has("deploy"),"cancel deployment draft")
	await click("Mark")
	await click("Deploy")
	check(last_action.get("data",{}).get("placements",[]).size()==2 and phase=="battle","deployment request")
	check(control("Charge").disabled,"no implicit target")
	await click("Hold")
	check(form.view(0).value.active==null,"no premature authority update")
	advance()
	check(form.view(0).value.active.order_type=="hold" and form.view(1).value.active.order_type=="hold","multi formation hold")
	await captured_field()
	await click("ApplyLayout")
	advance()
	check(form.view(0).value.layout=="square" and form.view(1).value.layout=="square","layout")
	select_option("Target",1)
	control("Target").grab_focus()
	pad(JOY_BUTTON_DPAD_LEFT)
	check(control("Charge").disabled,"D-pad clears target")
	pad(JOY_BUTTON_DPAD_RIGHT)
	check(not control("Charge").disabled,"D-pad picks target")
	await click("Charge")
	advance()
	check(form.view(0).value.active.target_formation_id==2,"targeted charge")
	point = [-2000,0,1000]
	hud.refresh()
	await click("Move")
	advance()
	check(control("Group0").text.contains("无法到达"),"explicit failed reachability feedback")
	await click("Group1")
	await click("Delegate")
	advance()
	check(form.view(0).value.delegate=="captain" and control("Group0").text.contains("captain"),"delegation")
	auth = false
	await click("Hold")
	advance()
	check(control("Receipt").text.contains("无指挥权限"),"authority refused after stale intent")
	auth = true
	await click("Withdraw")
	check(not control("Hold").is_visible_in_tree(),"confirmation blocks orders")
	press_key(KEY_ESCAPE)
	check(not control("Confirm").visible and not sent.has("withdraw"),"escape cancels withdrawal")
	await click("Withdraw")
	await click("Cancel")
	check(not sent.has("withdraw"),"cancel withdrawal")
	root.gui_release_focus()
	pad(JOY_BUTTON_DPAD_UP)
	check(root.gui_get_focus_owner()==control("Resume"),"D-pad enters field controls")
	pad(JOY_BUTTON_DPAD_DOWN)
	check(root.gui_get_focus_owner()==control("Settings"),"D-pad navigates to settings")
	pad(JOY_BUTTON_A)
	await frames()
	check(control("Language").is_visible_in_tree(),"gamepad activates settings")
	await click("Language")
	await click("Large")
	await click("Contrast")
	await click("Subtitles")
	check(control("Title").text=="Field command" and not control("Captions").visible,"locale captions")
	remap_actions()
	var old := hud
	hud = HUD.new()
	root.add_child(hud)
	old.release_scope()
	old.free()
	hud.mount(SCOPE,query,submit,prefs)
	await frames()
	check(control("Title").text=="Field command" and control("Large").button_pressed and control("Contrast").button_pressed and not control("Subtitles").button_pressed and not control("Captions").visible,"settings survive fresh HUD")
	press_key(KEY_F6)
	check(root.gui_get_focus_owner()==control("Resume"),"F6 acquires focus")
	press_key(KEY_F6)
	check(root.gui_get_focus_owner()==null,"F6 releases focus")
	var panel := hud.find_children("*","PanelContainer",true,false)[0] as PanelContainer
	check(root.get_visible_rect().encloses(panel.get_global_rect()) and panel.size.x<root.size.x*0.6,"panel fits "+str(root.size))
	var scroll := hud.find_children("*","ScrollContainer",true,false)[0] as ScrollContainer
	for item in hud.find_children("*","Control",true,false):
		if item.is_visible_in_tree() and (item is Button or item is Label):
			check(item.get_global_rect().end.x<=scroll.get_global_rect().end.x+1,item.name+" width")
	scroll.scroll_vertical = 0
	await screenshot("battle-en")
	scope_read = "mission/other"
	check(not hud.refresh().ok and not control("Strength").visible and not control("Group0") and control("Receipt").text.is_empty(),"scope mismatch clears sensitive state")
	scope_read = SCOPE
	revision -= 1
	check(not hud.refresh().ok and not control("Group0"),"old revision cannot resurrect after invalidation")
	revision += 1
	hud.refresh()
	commander_hp = 0
	advance()
	check(control("DownSpectate").visible and not control("Hold").visible,"downed options from rules")
	await click("DownDelegate")
	advance()
	check(rules.view().control_mode=="delegate","authenticated downed delegate")
	await click("DownSpectate")
	advance()
	check(rules.view().control_mode=="spectate","spectate")
	await click("Withdraw")
	await click("Confirm")
	check(rules.view().outcome==null,"withdraw waits for authoritative tick")
	advance()
	check(phase=="ended" and control("Leave").visible and control("Result").text.contains("Winners 1") and control("Result").text.contains("Wounded ×1"),"RULES result and supplied slot outcomes")
	await click("Leave")
	check(last_action.action=="leave","exit route")
	three_side_result(true)
	three_side_result(false)
	three_side_result(true,true)
	hud.release_scope()
	check(not hud.visible and not hud.refresh().ok,"end lifecycle")
	hud.free()
	input.free()
	for path in [prefs,"user://"+profile+".json"]:
		if FileAccess.file_exists(path): DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("FIELD_HUD checks=",checks," failed=",failures," display=",DisplayServer.get_name()," viewport=",root.size)
	quit(1 if failures else 0)
