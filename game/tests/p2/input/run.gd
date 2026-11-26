extends SceneTree
const Field = preload("res://presentation/input/ports/field_input.gd")
const Profile = preload("res://presentation/input/field_profile.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const Form = preload("res://mission/formation/ports/field_formation.gd")
const S = preload("res://contracts/schema.gd")
const R = preload("res://contracts/result.gd")
const H := {"index":7,"generation":1}
var failures := 0
var checks := 0
var batches := []
var submitted := []
var combat: Combat
var form: Form
var actor_token := RefCounted.new()
var profile_name := "qa_input_" + str(Time.get_ticks_usec())

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL ",message)

func _initialize() -> void:
	run.call_deferred()

func key(code: int, on: bool = true, shift: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = on
	e.shift_pressed = shift
	return e

func joy(button: int, on: bool = true) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = button
	e.device = 17
	e.pressed = on
	return e

func axis(index: int, value: float) -> InputEventJoypadMotion:
	var e := InputEventJoypadMotion.new()
	e.axis = index
	e.axis_value = value
	e.device = 17
	return e

func mouse(button: int, on: bool = true) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = on
	return e

func mouse_look(x: int,y: int) -> InputEventMouseMotion:
	var e := InputEventMouseMotion.new()
	e.relative = Vector2(x,y)
	return e

func auth(ctx: Variant) -> Dictionary:
	return R.ok("player") if is_same(ctx,actor_token) else R.fail("Unauthorized")

func submit_batch(batch: Dictionary) -> Dictionary:
	batches.append(batch)
	var wire := S.encode_value("IntentBatch",batch)
	check(wire.ok and S.decode_value("IntentBatch",wire.value).ok,"canonical batch roundtrip")
	if combat == null: return R.ok()
	var actions: Array = batch.inputs.filter(func(i): return i.has("input_phase") or i.has("held") or i.has("slot"))
	var result := combat.step(batch.source_tick,actions)
	check(result.ok and result.value.receipts.all(func(r): return r.ok),"true COM action receipts on tick %s"%batch.source_tick)
	return result

func submit_order(order: Dictionary, revisions: Dictionary) -> Dictionary:
	submitted.append(order)
	check(S.encode_value("FormationOrder",order).ok,"canonical FormationOrder")
	return form.issue_order(order,actor_token,revisions)

func fresh_field() -> Field:
	var input := Field.new(profile_name)
	root.add_child(input)
	check(input.configure("mission/input","player",H,4,submit_batch,submit_order).ok,"configure input")
	batches.clear()
	submitted.clear()
	return input

func device_case(pad: bool, direction: String) -> Array:
	combat = Combat.new()
	check(combat.enlist(H,{"team":0,"role":"infantry"}).ok,"true combat roster")
	var field := fresh_field()
	var offsets := {"up":Vector2i(0,-8),"thrust":Vector2i(0,8),"left":Vector2i(-8,0),"right":Vector2i(8,0)}
	var d: Vector2i = offsets[direction]
	if pad: field.handle_event(axis(2 if d.x else 3,signi(d.x if d.x else d.y)))
	else: field.handle_event(mouse_look(d.x,d.y))
	field.handle_event(axis(5,1) if pad else mouse(1))
	var stream := []
	for tick in range(1,10):
		if tick == 2:
			# A later look change does not change the charged direction.
			field.handle_event(axis(3,0) if pad else mouse_look(0,0))
		if tick == 4: field.handle_event(axis(5,0) if pad else mouse(1,false))
		var outcome := field.step(tick)
		check(outcome.ok,"step")
		stream.append_array(outcome.value.batch.inputs.filter(func(i): return i.has("input_phase")))
	check(stream.map(func(i):return i.input_phase)==["start","hold","hold","release"] and stream.all(func(i):return i.direction==direction and i.target_hint==null),"phase edges and locked direction " + direction)
	field.handle_event(axis(4,1) if pad else mouse(2))
	var guard := field.step(10)
	check(guard.value.batch.inputs.any(func(i):return i.get("held",false)) and combat.view(H).value.phase == "Guard","block reaches combat")
	field.handle_event(axis(4,0) if pad else mouse(2,false))
	var unblock := field.step(11)
	check(combat.view(H).value.phase=="Ready","unblock reaches combat")
	stream.append_array(guard.value.batch.inputs.filter(func(i):return i.has("held")))
	stream.append_array(unblock.value.batch.inputs.filter(func(i):return i.has("held")))
	field.free()
	combat = null
	return stream

func quick_click() -> bool:
	combat = Combat.new()
	check(combat.enlist(H,{"team":0,"role":"infantry"}).ok,"quick-click actor")
	var field := fresh_field()
	field.bind_combat_view(combat.view)
	field.handle_event(mouse(1))
	field.handle_event(mouse(1,false))
	var phases := []
	for tick in range(1,13):
		var frame := field.step(tick)
		check(frame.ok,"quick-click step")
		for item in frame.value.batch.inputs:
			if item.has("input_phase"): phases.append(item.input_phase)
	check(phases==["start","release"] and combat.view(H).value.phase=="Ready","tap releases once at the legal COM phase")
	field.free()
	combat = null
	return true

func commander_actions() -> void:
	combat = Combat.new()
	check(combat.enlist(H,{"team":0,"role":"infantry","action_profile":"commander","ranged":"bow","ammo":2}).ok,"commander loadout")
	var field := fresh_field()
	field.bind_combat_view(combat.view)
	field.handle_event(mouse(1))
	for tick in range(1,12): field.step(tick)
	field.handle_event(mouse_look(16,0))
	field.handle_event(mouse(2))
	field.step(12)
	check(combat.view(H).value.phase=="Guard" and combat.view(H).value.direction=="right","feint a held attack directly into a directional guard")
	field.handle_event(mouse(1,false))
	field.handle_event(mouse(2,false))
	field.step(13)
	field.handle_event(mouse(MOUSE_BUTTON_WHEEL_UP))
	field.step(14)
	field.handle_event(mouse(2))
	field.handle_event(mouse(2,false))
	check(not field.step(15).value.batch.inputs.any(func(i):return i.has("held")),"a lowered bow does not raise a shield")
	field.handle_event(mouse(1))
	for tick in range(16,37): field.step(tick)
	check(combat.view(H).value.phase=="Hold","full bow draw")
	field.handle_event(mouse(2))
	field.handle_event(mouse(1,false))
	field.handle_event(mouse(2,false))
	field.step(37)
	check(combat.view(H).value.phase=="Ready" and combat.view(H).value.ammo==2,"lower a drawn bow without releasing an arrow")
	field.handle_event(mouse(MOUSE_BUTTON_WHEEL_UP))
	field.step(38)
	field.handle_event(mouse(2))
	field.step(39)
	field.handle_event(mouse(1))
	field.handle_event(mouse(2,false))
	field.step(40)
	check(combat.view(H).value.phase=="Windup","counterattack as the guard key is released")
	field.handle_event(mouse(MOUSE_BUTTON_WHEEL_UP))
	field.handle_event(mouse(1,false))
	field.handle_event(mouse(1))
	field.step(41)
	check(combat.view(H).value.weapon_slot==1 and combat.view(H).value.phase=="Windup" and combat.view(H).value.ammo==2,"switch from a prepared strike and start drawing a bow within one tick")
	field.free()
	combat = null

func formation_case() -> bool:
	form = Form.new("mission/input",auth,func(_id,_point): return true)
	check(form.add_formation(4,0,"player",[H]).ok and form.add_formation(9,"0","other",[{"index":8,"generation":1}]).ok,"two real independently controlled formations")
	var field := fresh_field()
	var label := Label.new()
	label.position = Vector2(12,12)
	label.size = Vector2(360,40)
	root.add_child(label)
	field.bind_feedback(label)
	check(field.set_formations([4,9],{4:0,9:0}).ok,"list")
	field.handle_event(key(KEY_B))
	field.handle_event(key(KEY_B,false))
	field.handle_event(key(KEY_2))
	field.handle_event(key(KEY_2,false))
	field.handle_event(key(KEY_H))
	field.handle_event(key(KEY_H,false))
	var denied := field.step(1)
	check(denied.value.orders.size()==1 and denied.value.orders[0].receipt.error.code=="Unauthorized" and label.is_visible_in_tree() and label.text=="你没有此项指挥权限","T-INPUT-03 real authority feedback on mounted Label")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		var area := Rect2i(label.get_rect())
		var visible := root.get_texture().get_image().get_region(area)
		label.hide()
		await RenderingServer.frame_post_draw
		var background := root.get_texture().get_image().get_region(area)
		check(not visible.is_empty() and visible.get_data()!=background.get_data(),"rendered denial label differs from background")
		label.show()
		print("INPUT authority feedback rendered with ",DisplayServer.get_name())
	check(form.advance(1).ok and form.view(9).value.active==null,"foreign order unchanged")
	field.handle_event(key(KEY_1))
	field.handle_event(key(KEY_1,false))
	field.set_target([100,0,-500],9)
	field.handle_event(joy(JOY_BUTTON_A))
	field.handle_event(joy(JOY_BUTTON_A,false))
	field.handle_event(key(KEY_F))
	field.handle_event(key(KEY_F,false))
	field.set_delegate_candidate("captain")
	field.handle_event(key(KEY_G))
	field.handle_event(key(KEY_G,false))
	var accepted := field.step(2)
	check(accepted.value.orders.size()==3 and accepted.value.orders.all(func(i):return i.receipt.ok) and form.advance(2).ok,"three allowed kinds")
	var view: Dictionary = form.view(4).value
	check(view.active.target_position==[100,0,-500] and view.layout=="shield_wall" and view.delegate=="captain","world target, shape, delegation")
	check(field.step(2)==accepted and submitted.size()==4,"stable retry")
	check(field.step(1).error.code=="StaleVersion","stale tick")
	field.handle_event(key(KEY_0))
	field.handle_event(key(KEY_0,false))
	field.handle_event(key(KEY_R))
	field.handle_event(key(KEY_R,false))
	var both := field.step(3)
	check(both.value.orders[0].order.formation_ids==[4,9] and both.value.orders[0].order.target_formation_id==9 and both.value.orders[0].receipt.error.code=="Unauthorized" and form.advance(3).ok,"all-selection cannot gain authority")
	field.set_context("battle")
	field.set_formations([4],{4:form.view(4).value.control_revision})
	field.select_formations([4])
	field.bind_order_target(func(_kind):return {"position":null,"formation":null})
	for code in [KEY_F1,KEY_F3]:
		field.handle_event(key(code))
		field.handle_event(key(code,false))
	var result := field.step(4)
	check(result.value.orders.size()==1 and result.value.orders[0].receipt.ok and form.advance(4).ok and form.view(4).value.active.order_type=="free_attack","F1 F3 publishes a general charge before an enemy is identified")
	field.free()
	label.free()
	return true

func events_and_settings() -> bool:
	var field := fresh_field()
	check(field.rebind("inventory",key(KEY_Y)).ok,"move pack shortcut before assigning I to walking")
	check(field.rebind("move_forward",key(KEY_I)).ok and field.rebind("block",joy(JOY_BUTTON_RIGHT_SHOULDER)).ok,"desktop/controller rebind")
	check(field.rebind("attack",key(KEY_ESCAPE)).error.code=="Conflict" and field.rebind("menu",key(KEY_Z)).error.code=="Unauthorized","menu alternative protected")
	check(field.rebind("move_back",key(KEY_I)).error.code=="Conflict" and not field.set_options({"deadzone_percent":100}).ok,"conflicting mapping and invalid deadzone")
	check(field.set_options({"toggle_block":true,"invert_y":true,"deadzone_percent":20}).ok,"accessibility settings persist")
	field.free()
	field = fresh_field()
	check(field.profile_view().options.toggle_block and field.profile_view().options.invert_y,"reopened local profile")
	check(not field.handle_event(key(KEY_W)) and not field.handle_event(key(KEY_W,false)),"old binding removed")
	Input.parse_input_event(key(KEY_I))
	Input.flush_buffered_events()
	await process_frame
	var moved := field.step(1)
	check(moved.value.batch.inputs.back().speed_fraction==1 and moved.value.batch.inputs.back().desired_direction==[0,0,-1000000],"real Godot input dispatch after restart")
	field.set_context("ui")
	check(field.step(2).value.batch.inputs.back().speed_fraction==0,"focus flushes movement")
	field.set_context("battle")
	field.handle_event(key(KEY_I,false))
	field.handle_event(axis(0,0.19))
	check(field.step(3).value.batch.inputs.back().speed_fraction==0,"stick below deadzone")
	field.handle_event(axis(0,0.60))
	var half := field.step(4)
	check(is_equal_approx(half.value.batch.inputs.back().speed_fraction,0.5),"analogue deadzone remap")
	field.handle_event(joy(JOY_BUTTON_RIGHT_SHOULDER))
	field.handle_event(joy(JOY_BUTTON_RIGHT_SHOULDER,false))
	check(field.step(5).value.batch.inputs.any(func(i):return i.get("held",false)),"toggle block holds after button release")
	field.handle_event(key(KEY_I))
	Input.joy_connection_changed.emit(17,false)
	var cleared := field.step(6)
	check(cleared.value.batch.inputs.any(func(i):return i.has("held") and not i.held) and cleared.value.batch.inputs.back().desired_direction==[0,0,-1000000],"device disconnection clears pad axis and latched block, preserves keyboard")
	field.handle_event(key(KEY_I,false))
	field.handle_event(mouse_look(0,5))
	check(field.step(7).value.batch.inputs.any(func(i):return i.get("pitch",0)>0),"inverted look sampled")
	var edit := LineEdit.new()
	root.add_child(edit)
	edit.grab_focus()
	field.handle_event(key(KEY_I))
	check(field.step(8).value.batch.inputs.back().speed_fraction==0,"focused GUI suppresses gameplay")
	edit.release_focus()
	edit.free()
	check(field.set_control({"index":7,"generation":2},8).ok,"authority handoff")
	var changed := field.step(9)
	check(changed.value.batch.control_revision==8 and changed.value.batch.inputs.all(func(i):return i.actor_handle.generation==2),"handoff flushes old generation")
	field.free()
	return true

func run() -> void:
	var legacy := Profile.new(profile_name)
	var old_map := Profile._defaults(true)
	old_map.move_forward.desktop = Profile.token_for(key(KEY_I))
	check(legacy._save(old_map,legacy.options).ok,"write prior player layout")
	var migrated := Profile.new(profile_name)
	check(migrated.load_saved().ok and migrated.action_for(Profile.token_for(key(KEY_I)),"battle")=="move_forward" and migrated.action_for(Profile.token_for(key(KEY_R)),"battle")=="view_toggle" and migrated.action_for(Profile.token_for(key(KEY_TAB)),"battle")=="scoreboard","old profile retains personal bindings and gains new defaults")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://"+profile_name+".json"))
	var prior := Profile._defaults()
	prior.erase("inventory")
	prior.move_forward.desktop = Profile.token_for(key(KEY_I))
	check(legacy._save(prior,legacy.options).ok and migrated.load_saved().ok and migrated.bindings.inventory.is_empty() and migrated.action_for(Profile.token_for(key(KEY_I)),"battle")=="move_forward","existing field layout keeps custom I binding")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://"+profile_name+".json"))
	var orbit := fresh_field()
	orbit.align_look(Vector3.FORWARD)
	orbit.handle_event(mouse_look(960,0))
	var idle := orbit.step(1)
	check(absf(orbit.view().preview_aim.x)>2.0 and not idle.value.batch.inputs.any(func(i):return i.has("yaw")),"third person can see the actor's front without turning the body")
	orbit.handle_event(key(KEY_W))
	var walking := orbit.step(2)
	check(walking.value.batch.inputs.any(func(i):return i.has("yaw") and abs(i.yaw)<90000 and i.yaw!=0),"starting movement turns the body gradually")
	orbit.handle_event(mouse(2))
	var blocking := orbit.step(3)
	check(blocking.value.batch.inputs.any(func(i):return i.get("yaw")==-2400000) and blocking.value.batch.inputs.any(func(i):return i.get("held",false)),"guard and sight agree on the first defensive step")
	orbit.handle_event(key(KEY_I))
	orbit.handle_event(key(KEY_I,false))
	check(orbit.view().mode=="inventory" and orbit.step(4).value.batch.inputs.back().speed_fraction==0,"inventory flushes held movement")
	orbit.handle_event(key(KEY_ESCAPE))
	orbit.handle_event(key(KEY_ESCAPE,false))
	check(orbit.view().mode=="battle","escape closes battlefield inventory directly")
	orbit.set_context("command")
	orbit.set_context("ui")
	orbit.set_context("inventory")
	orbit.close_inventory()
	orbit.handle_event(key(KEY_ESCAPE))
	check(orbit.view().mode=="command","pack opened from menu restores that menu then the original context")
	orbit.free()
	for keys in [[KEY_W],[KEY_A],[KEY_D],[KEY_S],[KEY_W,KEY_A],[KEY_W,KEY_D],[KEY_S,KEY_A],[KEY_S,KEY_D]]:
		var foot := fresh_field()
		foot.align_look(Vector3.RIGHT)
		for code in keys: foot.handle_event(key(code))
		var facing := Vector3.RIGHT
		var travel := Vector3.ZERO
		for tick in range(1,39):
			var intents: Array = foot.step(tick).value.batch.inputs
			for intent in intents:
				if intent.has("yaw"):
					var turned := Vector3.FORWARD.rotated(Vector3.UP,intent.yaw*.000001)
					check(facing.angle_to(turned)<deg_to_rad(5.01),"bounded foot turn")
					facing = turned
			var direction: Array = intents.back().desired_direction
			travel = Vector3(direction[0],0,direction[2]).normalized()
		var expected := (Vector3.RIGHT*(int(KEY_W in keys)-int(KEY_S in keys)) + Vector3.BACK*(int(KEY_D in keys)-int(KEY_A in keys))).normalized()
		check(travel.dot(expected)>.999 and facing.dot(expected)>.999,"third-person movement and body align for "+str(keys))
		foot.handle_event(mouse(2))
		var guard: Array = foot.step(39).value.batch.inputs
		check(facing.dot(Vector3.RIGHT)>.999 or guard.any(func(i):return i.has("yaw") and absi(i.yaw+1570796)<2),"guard returns to sight even with direction held")
		foot.handle_event(mouse(2,false))
		foot.step(40)
		var released: Array = foot.step(41).value.batch.inputs
		if expected.dot(Vector3.RIGHT)<.999:
			check(released.any(func(i):return i.has("yaw") and absi(i.yaw+1570796)>2),"releasing guard restores movement-facing while keys remain held")
		foot.free()
	var saddle := fresh_field()
	saddle.align_look(Vector3.FORWARD)
	saddle.bind_combat_view(func(_h):return R.ok({"mount_handle":{"index":80,"generation":1},"mount_heading":Vector3.RIGHT}))
	saddle.handle_event(key(KEY_W))
	saddle.handle_event(key(KEY_W,false))
	saddle.handle_event(mouse_look(400,0))
	var riding: Dictionary = saddle.step(1).value.batch.inputs.back()
	check(is_equal_approx(riding.speed_fraction,1.0/3) and riding.desired_direction==[1000000,0,0],"gait persists and orbit does not steer the mount")
	saddle.handle_event(key(KEY_D))
	check(saddle.step(2).value.batch.inputs.back().desired_direction[2]>0,"right rein turns relative to horse")
	saddle.handle_event(key(KEY_S))
	check(saddle.step(3).value.batch.inputs.back().speed_fraction==0,"S brakes instead of reversing the camera-relative travel vector")
	saddle.handle_event(key(KEY_S,false))
	saddle.handle_event(axis(1,-1))
	saddle.handle_event(axis(1,0))
	check(saddle.step(4).value.batch.inputs.back().speed_fraction>0,"released pad throttle retains gait")
	Input.joy_connection_changed.emit(17,false)
	check(saddle.step(5).value.batch.inputs.back().speed_fraction==0,"disconnecting the mount's throttle device stops its gait")
	saddle.free()
	var controls := fresh_field()
	controls.handle_event(key(KEY_W))
	check(controls.step(1).value.batch.inputs.back().stance=="sprint","default keyboard run")
	controls.handle_event(key(KEY_CAPSLOCK))
	controls.handle_event(key(KEY_CAPSLOCK,false))
	check(controls.step(2).value.batch.inputs.back().stance=="walk","walk mode persists after releasing Caps Lock")
	controls.handle_event(key(KEY_KP_ADD))
	check(controls.view().camera_distance_steps==-1,"keypad plus brings camera nearer")
	controls.set_formations([4],{4:0})
	controls.handle_event(key(KEY_F1))
	check(controls.view().command_page=="movement","movement order menu opens")
	controls.handle_event(mouse(MOUSE_BUTTON_RIGHT))
	controls.handle_event(mouse(MOUSE_BUTTON_RIGHT,false))
	check(not controls.view().orders_open and not controls.step(3).value.batch.inputs.any(func(i): return i.has("held")),"closing orders doesn't raise shield")
	controls.bind_combat_view(func(_actor):return R.ok({"mount_handle":{"index":80,"generation":1}}))
	controls.handle_event(key(KEY_Z))
	var rider := controls.step(4).value.batch as Dictionary
	check(rider.inputs.any(func(i):return i.get("action")=="dismount") and rider.inputs.back().stance!="crouch","mounted Z requests a dismount without a crouch stance")
	controls.free()
	var before := failures
	for direction in ["up","left","right","thrust"]:
		var desktop := device_case(false,direction)
		var pad := device_case(true,direction)
		check(desktop.size()==6 and desktop==pad,"T-INPUT-02 directional device equivalence " + direction)
	check(quick_click(),"short press and release reached completion")
	commander_actions()
	print("T-INPUT-02 ", "PASS" if failures==before else "FAIL")
	before = failures
	check(await formation_case(),"formation scenario reached final check")
	print("T-INPUT-03 ", "PASS" if failures==before else "FAIL")
	before = failures
	check(await events_and_settings(),"device scenario reached final check")
	print("T-INPUT-01-AUTOMATED ", "PASS" if failures==before else "FAIL")
	print("P2-INPUT-001 ", "PASS" if failures==0 else "FAIL"," checks=",checks," failures=",failures," physical_pads=",Input.get_connected_joypads().size())
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://"+profile_name+".json"))
	quit(0 if failures==0 else 1)
