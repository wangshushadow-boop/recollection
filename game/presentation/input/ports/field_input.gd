extends Node
## Local player input. The assembly owns authentication and the two authority ports.
signal feedback_changed(result: Dictionary)
signal context_changed(mode: String)
signal selection_changed(formation_ids: Array)
const R = preload("res://contracts/result.gd")
const S = preload("res://contracts/schema.gd")
const V = preload("res://contracts/values.gd")
const Profile = preload("res://presentation/input/field_profile.gd")
const LAYOUTS := ["line","shield_wall","loose","square","circle","wedge","column"]
const ORDER_PAGES := {
	"":[ "movement","formation","toggle","toggle_fire","toggle_mount","toggle_delegate","face","shield_wall","line"],
	"movement":["move","follow","charge","advance","","hold","retreat"],
	"formation":["line","shield_wall","loose","circle","square","wedge","column"],
	"toggle":["face","face_enemy","toggle_fire","toggle_mount","toggle_delegate"]}
const ORDER_LABELS := {"movement":"移动","formation":"阵型","toggle":"战术","move":"到此位置","follow":"跟随指挥官编队",
	"charge":"冲锋","advance":"接敌","hold":"坚守","retreat":"撤退","face":"面向此方向","face_enemy":"面向敌阵",
	"toggle_fire":"停射／射击","toggle_mount":"上马／下马","toggle_delegate":"委托／收回指挥","line":"横队","shield_wall":"盾墙",
	"loose":"疏阵","circle":"圆阵","square":"方阵","wedge":"楔阵","column":"纵队"}

var _profile: Profile
var _mission := ""
var _issuer := ""
var _actor: Dictionary = {}
var _revision := 0
var _send_batch: Callable
var _send_order: Callable
var _read_combat: Callable
var _read_order_target: Callable
var _formation_states := {}
var _page := ""
var _orders_open := false
var _walk_mode := false
var _distance_steps := 0
var _choices := {}
var _first_person := false
var _orbit := Vector2.ZERO
var _queued_release := {}
var _mode := "battle"
var _before_menu := "battle"
var _held := {}
var _strength := {}
var _blocked := {}
var _edges := []
var _orders := []
var _attack := ""
var _guard := ""
var _attack_source := ""
var _guard_source := ""
var _sent_attack := ""
var _sent_guard := ""
var _direction := "up"
var _mouse := Vector2.ZERO
var _yaw := 0
var _pitch := 0
var _weapon_slot := 0
var _interaction_target := ""
var _formations := []
var _revisions := {}
var _selection := []
var _target_position: Variant
var _target_formation: Variant
var _delegate := ""
var _layout := 0
var _sequence := 0
var _last_tick := -1
var _last_result := {}
var _last_order_revisions := []
var _stepping := false
var _feedback_label: Label
var _last_feedback := {}

func _init(profile_name: String = Profile.DEFAULT_NAME) -> void:
	_profile = Profile.new(profile_name)

func _ready() -> void:
	Input.joy_connection_changed.connect(_joy_connection)
	get_window().focus_exited.connect(_focus_lost)
	get_viewport().gui_focus_changed.connect(_gui_focus)

func _exit_tree() -> void:
	if Input.joy_connection_changed.is_connected(_joy_connection):
		Input.joy_connection_changed.disconnect(_joy_connection)
	if get_viewport() != null and get_viewport().gui_focus_changed.is_connected(_gui_focus):
		get_viewport().gui_focus_changed.disconnect(_gui_focus)
	if get_window() != null and get_window().focus_exited.is_connected(_focus_lost):
		get_window().focus_exited.disconnect(_focus_lost)
	_focus_lost()

func configure(mission_id: String, issuer_id: String, actor_handle: Dictionary, control_revision: int,
		submit_batch: Callable, submit_order: Callable, last_order_sequence: int = 0) -> Dictionary:
	if not _mission.is_empty() or mission_id.is_empty() or issuer_id.is_empty() or not V.integer(last_order_sequence) or not submit_batch.is_valid() or not submit_order.is_valid():
		return R.fail("InvalidArgument","input_scope")
	var result := _profile.load_saved()
	if not result.ok: return _feedback(result)
	result = set_control(actor_handle,control_revision)
	if not result.ok: return result
	_mission = mission_id
	_issuer = issuer_id
	_sequence = last_order_sequence
	_send_batch = submit_batch
	_send_order = submit_order
	return R.ok()

func set_control(actor_handle: Dictionary, control_revision: int) -> Dictionary:
	if _stepping or not V.integer(control_revision):
		return R.fail("InvalidArgument","control_revision")
	if not actor_handle.is_empty():
		var checked := S.validate_shape("AgentHandle",actor_handle)
		if not checked.ok: return checked
	if _actor != actor_handle or _revision != control_revision:
		_flush()
		# Old grant packets must never be retried using the new control context.
		if _pending_delivery():
			var frame: Dictionary = _last_result.value
			if _retryable(frame.batch_receipt):
				frame.batch_receipt = R.fail("StaleVersion","control_revision")
			for outgoing in frame.orders:
				if _retryable(outgoing.receipt):
					outgoing.receipt = R.fail("StaleVersion","control_revision")
		_edges.clear()
		_sent_attack = ""
		_sent_guard = ""
		_actor = actor_handle.duplicate()
		_revision = control_revision
		_weapon_slot = 0
	return R.ok()

## Seed the next input sample from the controlled actor's horizontal facing.
func align_look(heading: Vector3) -> Dictionary:
	if _stepping or _mission.is_empty() or _actor.is_empty():
		return R.fail("InvalidState","control")
	if not heading.is_finite() or Vector2(heading.x,heading.z).length_squared() <= 0.000001:
		return R.fail("InvalidArgument","heading")
	_yaw = V.yaw_microradians(atan2(-heading.x,-heading.z)).value
	return R.ok(Vector2(_yaw,_pitch)*0.000001)

## Let a quick tap wait for COM's legal release phase. Timing and equipment
## remain owned by the authority, including when local controls are remapped.
func bind_combat_view(read_actor: Callable) -> void:
	_read_combat = read_actor

func bind_order_target(reader: Callable) -> void:
	_read_order_target = reader

func _combat_view() -> Dictionary:
	if not _read_combat.is_valid() or _actor.is_empty(): return {}
	var result: Variant = _read_combat.call(_actor.duplicate())
	if typeof(result) == TYPE_DICTIONARY and result.get("ok") == true and typeof(result.get("value")) == TYPE_DICTIONARY:
		return result.value
	return {}

func set_weapon_slot(slot: int) -> Dictionary:
	if not V.integer(slot,0,V.MAX_U32): return R.fail("InvalidArgument","slot")
	_weapon_slot = slot
	return R.ok()

func set_interaction_target(target: String) -> void:
	_interaction_target = target

func set_formations(ids: Array, revisions: Dictionary, states: Array = []) -> Dictionary:
	var seen := {}
	for id in ids:
		if not V.integer(id,0,V.MAX_U32) or seen.has(id) or not V.integer(revisions.get(id)):
			return R.fail("InvalidArgument","formation_view")
		seen[id] = true
	_formations = ids.duplicate()
	_revisions = revisions.duplicate()
	_formation_states.clear()
	for row in states:
		if row is Dictionary and seen.has(row.get("id")): _formation_states[row.id] = row
	return select_formations(_selection.filter(func(id): return seen.has(id)))

func select_formations(ids: Array) -> Dictionary:
	var seen := {}
	for id in ids:
		if not V.integer(id,0,V.MAX_U32) or seen.has(id):
			return R.fail("InvalidArgument","selection")
		seen[id] = true
	_selection = ids.duplicate()
	selection_changed.emit(_selection.duplicate())
	return R.ok()

func set_target(position_mm: Variant = null, formation_id: Variant = null) -> Dictionary:
	if position_mm != null and (typeof(position_mm) != TYPE_ARRAY or position_mm.size() != 3 or not position_mm.all(func(n): return V.integer(n,-2147483648,2147483647))):
		return R.fail("InvalidArgument","target_position")
	if formation_id != null and not V.integer(formation_id,0,V.MAX_U32):
		return R.fail("InvalidArgument","target_formation_id")
	_target_position = position_mm.duplicate() if position_mm != null else null
	_target_formation = formation_id
	return R.ok()

func set_delegate_candidate(actor: String) -> void:
	_delegate = actor

func queue_order(kind: String, parameters: Dictionary = {}) -> Dictionary:
	if _mode not in ["command","ui"]:
		return _feedback(R.fail("InvalidState","selection_or_context"))
	return _queue_order(kind,parameters,_selection)

func _queue_order(kind: String, parameters: Dictionary, ids: Array) -> Dictionary:
	if ids.is_empty() or _mission.is_empty() or _stepping:
		return _feedback(R.fail("InvalidState","selection_or_context"))
	var target: Variant = _target_position if kind == "move" else null
	var enemy: Variant = _target_formation if kind in ["charge","follow","face_enemy"] else null
	if (kind == "move" and target == null) or (kind in ["charge","follow","face_enemy"] and enemy == null):
		return _feedback(R.fail("InvalidArgument","target"))
	_sequence += 1
	var order := {"mission_id":_mission, "issuer_id":_issuer, "client_sequence":_sequence,
		"order_id":"%s/input/%d" % [_issuer,_sequence], "issued_tick":0, "order_type":kind,
		"formation_ids":ids, "target_position":target, "target_formation_id":enemy, "parameters":parameters}
	var checked := S.validate_shape("FormationOrder",order)
	if not checked.ok: return _feedback(checked)
	_orders.append({"order":checked.value,"revisions":_revisions.duplicate()})
	return R.ok(order.order_id)

func bind_feedback(label: Label) -> void:
	_feedback_label = label
	if not _last_feedback.is_empty(): _render_feedback(_last_feedback)

func _render_feedback(result: Dictionary) -> void:
	if not is_instance_valid(_feedback_label): return
	if result.ok:
		_feedback_label.text = tr("指令已受理")
	elif result.error.code == "Unauthorized":
		_feedback_label.text = tr("你没有此项指挥权限")
	elif result.error.code == "Conflict" and str(result.error.field).begins_with("binding."):
		_feedback_label.text = tr("绑定已占用") + " · " + result.error.field.trim_prefix("binding.")
	else:
		_feedback_label.text = tr(result.error.message_key) + " · " + str(result.error.field)

func _feedback(result: Dictionary) -> Dictionary:
	_last_feedback = result.duplicate(true)
	_render_feedback(_last_feedback)
	feedback_changed.emit(_last_feedback.duplicate(true))
	return result

func rebind(action: String, event: InputEvent) -> Dictionary:
	var result := _profile.rebind(action,event)
	if result.ok:
		_choices.clear()
		_flush()
	return result if result.ok else _feedback(result)

func set_options(changes: Dictionary) -> Dictionary:
	var result := _profile.set_options(changes)
	if result.ok: _flush()
	return result

func view() -> Dictionary:
	return {"mode":_mode,"selection":_selection.duplicate(),"direction":_direction,"layout":LAYOUTS[_layout],
		"feedback":_last_feedback.duplicate(true),"last_order_sequence":_sequence,
		"first_person":_first_person,"zoom_held":_axis("zoom")>0,"free_look":_axis("free_look")>0,"orbit_offset":_orbit,
		"camera_distance_steps":_distance_steps,"preview_aim":Vector2(_look_after(_mouse * _profile.options.mouse_sensitivity))*0.000001,
		"score_held":_axis("scoreboard")>0,"command_page":_page,"orders_open":_orders_open or _mode=="command",
		"command_choices":_command_choices()}

func _command_choices() -> Array:
	if _choices.has(_page): return _choices[_page]
	var choices := []
	var menu: Array = ORDER_PAGES[_page]
	for i in menu.size():
		var id: String = menu[i]
		if id.is_empty(): continue
		var choice := {"key":_profile.key_label("order_key_"+str(i+1)),"label":ORDER_LABELS[id],"id":id}
		choice.make_read_only()
		choices.append(choice)
	choices.make_read_only()
	_choices[_page] = choices
	return choices

func profile_view() -> Dictionary:
	return {"bindings":_profile.bindings.duplicate(true),"options":_profile.options.duplicate()}

func set_context(mode: String) -> Dictionary:
	if mode not in ["battle","command","map","ui"] or _stepping: return R.fail("InvalidArgument","context")
	if mode != _mode:
		if mode == "ui": _before_menu = _mode
		_flush()
		_mode = mode
		context_changed.emit(mode)
	return R.ok()

func _flush() -> void:
	for source in _held: _blocked[source] = true
	_held.clear()
	_strength.clear()
	_edges.clear()
	_orders.clear()
	_queued_release.clear()
	_mouse = Vector2.ZERO
	_orbit = Vector2.ZERO
	_orders_open = false
	_page = ""
	if not _sent_attack.is_empty(): _edges.append(_attack_intent("cancel",_sent_attack))
	if not _sent_guard.is_empty(): _edges.append(_block_intent(false,_sent_guard))
	_attack = ""
	_guard = ""

func _gui_focus(control: Control) -> void:
	if control != null: _flush()

func _focus_lost() -> void:
	_flush()

func _joy_connection(device: int, connected: bool) -> void:
	if connected: return
	var prefix := "pad/%d/" % device
	# Neutralize just this device. Keyboard or another pad can still hold the same action.
	var lost := {}
	for source in _held.keys():
		if source.begins_with(prefix):
			lost[_held[source]] = true
			_held.erase(source)
			_strength.erase(source)
	if (lost.has("attack") or _attack_source.begins_with(prefix)) and not _held.values().has("attack"):
		_edges = _edges.filter(func(i): return not i.has("input_phase"))
		_queued_release = {}
		if not _sent_attack.is_empty(): _edges.append(_attack_intent("cancel",_sent_attack))
		_attack = ""
		_attack_source = ""
	if (lost.has("block") or _guard_source.begins_with(prefix)) and not _held.values().has("block"):
		_edges = _edges.filter(func(i): return not i.has("held"))
		if not _sent_guard.is_empty(): _edges.append(_block_intent(false,_sent_guard))
		_guard = ""
		_guard_source = ""
	if lost.has("free_look") and not _held.values().has("free_look"): _orbit = Vector2.ZERO
	for k in _blocked.keys():
		if k.begins_with(prefix): _blocked.erase(k)

# Observe releases before focused controls can consume them. New gameplay input
# otherwise enters through _unhandled_input so normal GUI shortcuts take priority.
func _input(event: InputEvent) -> void:
	var button_release: bool = (event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton) and not event.pressed
	if button_release or get_viewport().gui_get_focus_owner() != null:
		if handle_event(event): get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if handle_event(event): get_viewport().set_input_as_handled()

func _fallback_token(token: String) -> String:
	var parts := token.split("/")
	if parts.size() == 3 and parts[0] in ["k","m"]: return parts[0]+"/"+parts[1]+"/0"
	return token

func handle_event(event: InputEvent) -> bool:
	if _mission.is_empty() or _stepping or event == null: return false
	if event is InputEventMouseMotion:
		if is_inside_tree() and get_viewport().gui_get_focus_owner() != null: return false
		if _mode not in ["battle","command"] or not event.relative.is_finite(): return false
		if _axis("free_look")>0:
			_orbit_delta(event.relative*_profile.options.mouse_sensitivity)
			return true
		_mouse += event.relative
		_aim(event.relative)
		return true
	if event is InputEventJoypadMotion:
		if not is_finite(event.axis_value): return false
		var dz: float = _profile.options.deadzone_percent * 0.01
		var used := false
		for sign_text in ["+","-"]:
			var token := "a/%d/%s" % [event.axis,sign_text]
			var axis: float = event.axis_value if sign_text == "+" else -event.axis_value
			var strength := clampf((axis-dz)/(1.0-dz),0,1)
			used = _button("pad/%d/%s" % [event.device,token], token, strength, false) or used
		return used
	if not (event is InputEventKey or event is InputEventMouseButton or event is InputEventJoypadButton): return false
	if event is InputEventKey and event.echo: return false
	var token := Profile.token_for(event)
	if token.is_empty(): return false
	var base := _fallback_token(token)
	var source := "pad/%d/%s" % [event.device,token] if event is InputEventJoypadButton else "desktop/" + base
	if _mode=="battle" and _orders_open and event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_RIGHT and event.pressed:
		_page = ""
		_orders_open = false
		_blocked[source] = true
		return true
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN,MOUSE_BUTTON_WHEEL_LEFT,MOUSE_BUTTON_WHEEL_RIGHT] and event.pressed:
		var used := _button(source,token,1.0,event.shift_pressed)
		_button(source,token,0.0,event.shift_pressed)
		return used
	return _button(source,token,1.0 if event.pressed else 0.0,event is InputEventWithModifiers and event.shift_pressed)

func _button(source: String, token: String, strength: float, additive: bool) -> bool:
	if strength > 0 and is_inside_tree() and get_viewport().gui_get_focus_owner() != null and _profile.bindings.menu.get(Profile.family(token)) != _fallback_token(token):
		_blocked[source] = true
		return false
	if _blocked.has(source):
		if strength == 0: _blocked.erase(source)
		return false
	var action: String = _held.get(source,"")
	if strength == 0:
		if action.is_empty(): return false
		_held.erase(source)
		_strength.erase(source)
		if not _held.values().has(action): _action(action,false,additive,source)
		return true
	if not action.is_empty():
		_strength[source] = strength
		if action.begins_with("look_"): _aim(_look_stick())
		return true
	action = _profile.action_for(token,_mode)
	if action.is_empty(): action = _profile.action_for(_fallback_token(token),_mode)
	if action.is_empty(): return false
	var first := not _held.values().has(action)
	_held[source] = action
	_strength[source] = strength
	if first: _action(action,true,additive,source)
	return true

func _axis(action: String) -> float:
	var magnitude := 0.0
	for source in _held:
		if _held[source] == action: magnitude = maxf(magnitude,_strength[source])
	return magnitude

func _look_stick() -> Vector2:
	return Vector2(_axis("look_right")-_axis("look_left"),_axis("look_down")-_axis("look_up"))

func _aim(delta: Vector2) -> void:
	if _axis("free_look")>0: return
	if delta.length_squared() < 0.0001: return
	if absf(delta.x) > absf(delta.y):
		_direction = "right" if delta.x > 0 else "left"
	else:
		_direction = "thrust" if delta.y > 0 else "up"

func _look_after(delta: Vector2) -> Vector2i:
	var yaw: int = V.yaw_microradians((_yaw-delta.x)*0.000001).value if delta.x!=0 else _yaw
	var pitch := clampi(_pitch+roundi(delta.y)*(1 if _profile.options.invert_y else -1),-1570796,1570796)
	return Vector2i(yaw,pitch)

func _orbit_delta(delta: Vector2) -> void:
	_orbit.x = wrapf(_orbit.x-delta.x*0.000001,-PI,PI)
	_orbit.y = clampf(_orbit.y+delta.y*0.000001*(1 if _profile.options.invert_y else -1),-PI/2,PI/2)

func _attack_intent(phase: String, direction: String) -> Dictionary:
	return {"actor_handle":_actor,"input_phase":phase,"direction":direction,"weapon_slot":_weapon_slot,"target_hint":null}

func _block_intent(held: bool, direction: String) -> Dictionary:
	return {"actor_handle":_actor,"held":held,"direction":direction}

func _action(action: String, pressed: bool, additive: bool, source: String) -> void:
	if action == "menu" and pressed:
		if _mode=="battle" and _orders_open:
			_page = ""
			_orders_open = false
			return
		if _mode == "ui" and is_inside_tree():
			get_viewport().gui_release_focus()
		set_context(_before_menu if _mode == "ui" else "ui")
		return
	if action == "command_mode" and pressed and _mode in ["battle","command"]:
		set_context("battle" if _mode == "command" else "command")
		return
	if _mode in ["battle","command"] and pressed:
		if action.begins_with("order_key_"):
			_order_key(action.trim_prefix("order_key_").to_int())
			return
		if Profile._formation_key(action):
			_command_action(action,additive)
			_orders_open = true
			_page = ""
			return
	if action=="free_look" and not pressed: _orbit=Vector2.ZERO
	if _mode == "command" and pressed:
		_command_action(action,additive)
		return
	if _mode != "battle" or _actor.is_empty(): return
	if action=="crouch" and pressed and _combat_view().get("mount_handle")!=null:
		action = "dismount"
		_held[source] = action
	if action=="block" and pressed and (not _attack.is_empty() or not _queued_release.is_empty()):
		action = "cancel_attack"
	if action.begins_with("look_"):
		_aim(_look_stick())
	elif action == "attack":
		if _profile.options.toggle_attack:
			if not pressed: return
			pressed = _attack.is_empty()
		if pressed:
			if not _queued_release.is_empty(): return
			_attack_source = source
			var current := _combat_view()
			if V.integer(current.get("weapon_slot"),0,V.MAX_U32): _weapon_slot = current.weapon_slot
			if current.get("phase") == "Hold":
				# An explicit click can resume a held action after a focus-loss
				# cancel outside the authoritative cancellation window.
				_attack = current.direction
			else:
				_attack = _direction
				_edges.append(_attack_intent("start",_attack))
		elif not _attack.is_empty():
			var release := _attack_intent("release",_attack)
			if _read_combat.is_valid(): _queued_release = release
			else: _edges.append(release)
			_attack = ""
	elif action == "block":
		if _profile.options.toggle_block:
			if not pressed: return
			pressed = _guard.is_empty()
		if pressed:
			_guard_source = source
			_guard = _direction
			_edges.append(_block_intent(true,_guard))
		elif not _guard.is_empty():
			_edges.append(_block_intent(false,_guard))
			_guard = ""
	elif pressed:
		match action:
			"view_toggle": _first_person = not _first_person
			"walk_toggle": _walk_mode = not _walk_mode
			"camera_nearer": _distance_steps = maxi(-4,_distance_steps-1)
			"camera_farther": _distance_steps = mini(6,_distance_steps+1)
			"weapon_next":
				var current := _combat_view()
				var weapons: Array = current.get("weapons",[])
				if weapons.size()>1:
					var slot: int = current.weapon_slot
					for i in range(_edges.size()-1,-1,-1):
						if _edges[i].has("slot"):
							slot = _edges[i].slot
							break
					slot = (slot+1)%weapons.size()
					_edges.append({"actor_handle":_actor,"slot":slot,"item_ref":null})
			"cancel_attack":
				if not _queued_release.is_empty():
					var cancel := _queued_release.duplicate()
					cancel.input_phase = "cancel"
					_edges.append(cancel)
					_queued_release = {}
				elif not _attack.is_empty():
					_edges.append(_attack_intent("cancel",_attack))
				_attack = ""
			"equip_melee","equip_ranged":
				var slot := 0 if action == "equip_melee" else 1
				_edges.append({"actor_handle":_actor,"slot":slot,"item_ref":null})
			"jump","interact","mount","dismount":
				if action=="interact":
					if _combat_view().get("mount_handle")!=null: action="dismount"
					elif _interaction_target.begins_with("field/"): action="mount"
				var target := "self" if action == "jump" or action == "dismount" else _interaction_target
				if not target.is_empty(): _edges.append({"actor_handle":_actor,"target_ref":target,"action":action})

func _command_action(action: String, additive: bool) -> void:
	if action == "select_all":
		select_formations(_formations)
	elif action.begins_with("select_") and not _formations.is_empty():
		var index: int
		if action in ["select_prev","select_next"]:
			var current: int = _formations.find(_selection.back()) if not _selection.is_empty() else -1
			index = posmod(current + (1 if action == "select_next" else -1),_formations.size())
		else:
			index = action.trim_prefix("select_").to_int()-1
		if index >= 0 and index < _formations.size():
			var ids := _selection.duplicate() if additive else []
			var id: int = _formations[index]
			if id in ids: ids.erase(id)
			else: ids.append(id)
			select_formations(ids)
	elif action.begins_with("order_"): _issue_choice(action.trim_prefix("order_"))
	elif action == "cycle_layout":
		_layout = (_layout+1) % LAYOUTS.size()
		queue_order("layout",{"layout":LAYOUTS[_layout]})
	elif action == "delegate":
		queue_order("delegate",{"actor":_delegate})

func _order_key(number: int) -> void:
	var options: Array = ORDER_PAGES[_page]
	if number<1 or number>options.size() or options[number-1]=="": return
	var choice: String = options[number-1]
	if _selection.is_empty(): select_formations(_formations)
	if _selection.is_empty():
		_feedback(R.fail("Unavailable","formations"))
		return
	if ORDER_PAGES.has(choice):
		_page = choice
		_orders_open = true
		return
	_page = ""
	_orders_open = false
	_issue_choice(choice)

func _issue_choice(choice: String) -> void:
	var ids := _selection.duplicate()
	if choice in ["move","follow","charge","face_enemy"] and _read_order_target.is_valid():
		var target: Dictionary = _read_order_target.call(choice)
		var picked := set_target(target.get("position"),target.get("formation"))
		if not picked.ok:
			_feedback(picked)
			return
	if choice=="charge" and _target_formation==null: choice = "free_attack"
	if choice=="follow": ids.erase(_target_formation)
	if choice in LAYOUTS:
		_layout = LAYOUTS.find(choice)
		_queue_order("layout",{"layout":choice},ids)
	elif choice=="face":
		_queue_order("face",{"facing_microradians":_look_after(_mouse*_profile.options.mouse_sensitivity).x},ids)
	elif choice=="toggle_fire":
		var holding := ids.all(func(id):return _formation_states.get(id,{}).get("fire_mode")=="hold_fire")
		_queue_order("fire_at_will" if holding else "hold_fire",{},ids)
	elif choice=="toggle_mount":
		var mounted := ids.all(func(id):return _formation_states.get(id,{}).get("mounted",false))
		_queue_order("dismount" if mounted else "mount",{},ids)
	elif choice=="toggle_delegate":
		for id in ids:
			var delegated: Variant = _formation_states.get(id,{}).get("delegate")
			_queue_order("delegate",{"actor":"" if delegated==_delegate else _delegate},[id])
	else:
		_queue_order(choice,{},ids)

func _call(port: Callable, args: Array) -> Dictionary:
	if not port.is_valid(): return R.fail("Unavailable","input_port")
	var result: Variant = port.callv(args)
	if typeof(result) != TYPE_DICTIONARY or typeof(result.get("ok")) != TYPE_BOOL:
		return R.fail("InvalidState","input_port")
	if not result.ok and (typeof(result.get("error")) != TYPE_DICTIONARY or not result.error.has_all(["field","code","message_key"])):
		return R.fail("InvalidState","input_port")
	return result

static func _retryable(receipt: Dictionary) -> bool:
	return not receipt.ok and is_same(receipt.error.get("retryable"),true)

func _pending_delivery() -> bool:
	if _last_result.is_empty(): return false
	var frame: Dictionary = _last_result.value
	return _retryable(frame.batch_receipt) or frame.orders.any(func(row): return _retryable(row.receipt))

## Port receipts are independent. Within the order stream we must confirm older
## sequences before sending newer ones, even when the preceding ACK was lost.
func _deliver() -> void:
	_stepping = true
	var frame: Dictionary = _last_result.value
	if _retryable(frame.batch_receipt):
		frame.batch_receipt = _call(_send_batch,[frame.batch]).duplicate(true)
		if not frame.batch_receipt.ok:
			_feedback(frame.batch_receipt)
			if not _retryable(frame.batch_receipt):
				_sent_attack = ""
				_sent_guard = ""
				# Edges sampled since this frame belong to the next tick.
				if not _edges.any(func(i): return i.get("input_phase") == "start"):
					_attack = ""
					_queued_release = {}
					_edges = _edges.filter(func(i): return not i.has("input_phase"))
				if not _edges.any(func(i): return is_same(i.get("held"),true)):
					_guard = ""
					_edges = _edges.filter(func(i): return not i.has("held"))
	for i in frame.orders.size():
		var row: Dictionary = frame.orders[i]
		if not _retryable(row.receipt): continue
		row.receipt = _call(_send_order,[row.order,_last_order_revisions[i]]).duplicate(true)
		_feedback(row.receipt)
		if _retryable(row.receipt): break
	_stepping = false

func step(tick: int) -> Dictionary:
	if _stepping or _mission.is_empty() or not V.integer(tick,1) or tick < _last_tick: return R.fail("StaleVersion","source_tick")
	if _pending_delivery(): _deliver()
	if tick == _last_tick: return _last_result.duplicate(true)
	if _pending_delivery(): return R.fail("Unavailable","previous_input_tick")
	var inputs := _edges.duplicate()
	if not _queued_release.is_empty():
		var phase: Variant = _combat_view().get("phase")
		if phase == "Hold":
			inputs.append(_queued_release)
			_queued_release = {}
		elif phase != null and phase != "Windup" and not inputs.any(func(i): return i.get("input_phase") == "start"):
			_queued_release = {}
	if _mode in ["battle","command"] and not _actor.is_empty():
		var stick := _look_stick().limit_length(1.0)
		if _axis("free_look")>0:
			_orbit_delta(stick*_profile.options.stick_sensitivity)
			stick = Vector2.ZERO
		var delta: Vector2 = _mouse * _profile.options.mouse_sensitivity + stick * _profile.options.stick_sensitivity
		var aim := _look_after(delta)
		_yaw = aim.x
		_pitch = aim.y
		if delta != Vector2.ZERO: inputs.append({"actor_handle":_actor,"yaw":_yaw,"pitch":_pitch})
		if not _attack.is_empty() and not inputs.any(func(i): return i.has("input_phase")):
			inputs.append(_attack_intent("hold",_attack))
	if not _actor.is_empty():
		var move := Vector2(_axis("move_right")-_axis("move_left"),_axis("move_back")-_axis("move_forward")).limit_length(1.0)
		var world := Vector3(move.x,0,move.y).normalized().rotated(Vector3.UP,_yaw*0.000001)
		var keyboard_move := false
		for source: String in _held:
			if source.begins_with("desktop/") and str(_held[source]).begins_with("move_"):
				keyboard_move = true
				break
		var run := _axis("sprint")>0 or (keyboard_move and not _walk_mode)
		var stance := "crouch" if _axis("crouch")>0 else ("sprint" if run else "walk")
		inputs.append({"actor_handle":_actor,"desired_direction":[roundi(world.x*1000000),0,roundi(world.z*1000000)],"speed_fraction":minf(1.0,move.length()),"stance":stance})
	var batch := S.validate_shape("IntentBatch",{"mission_id":_mission,"source_tick":tick,"control_revision":_revision,"inputs":inputs})
	if not batch.ok: return _feedback(batch)
	var outgoing := []
	_last_order_revisions.clear()
	for pending in _orders:
		var order: Dictionary = pending.order.duplicate()
		order.issued_tick = tick
		order.make_read_only()
		pending.revisions.make_read_only()
		outgoing.append({"order":order,"receipt":R.fail("Unavailable","prior_order_pending")})
		_last_order_revisions.append(pending.revisions)
	_edges.clear()
	_orders.clear()
	_mouse = Vector2.ZERO
	_last_tick = tick
	_last_result = R.ok({"batch":batch.value,"batch_receipt":R.fail("Unavailable","pending_batch"),"orders":outgoing})
	# A transient failure may be a lost ACK. A focus change must still neutralize
	# the sampled controls if this exact frame later succeeds.
	_sent_attack = _queued_release.get("direction",_attack)
	_sent_guard = _guard
	_deliver()
	return _last_result.duplicate(true)
