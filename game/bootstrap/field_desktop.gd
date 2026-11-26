extends Node3D
## The desktop holds local controls and rendering resources. All reads and commands cross GameSession.
const R = preload("res://contracts/result.gd")
const PlayerInput = preload("res://presentation/input/ports/field_input.gd")
const Visuals = preload("res://presentation/visuals/ports/field_visuals.gd")
const Audio = preload("res://presentation/audio/ports/field_audio.gd")
const Camera = preload("res://presentation/camera/ports/field_camera.gd")
const HUD = preload("res://presentation/ui/ports/field_hud.gd")
const MEDIUM_NEAR_METRES := 53.0
var application: RefCounted
var scope := ""
var running := false
var _input_port := PlayerInput.new()
var _visuals := Visuals.new()
var _camera := Camera.new()
var _audio := Audio.new()
var _hud := HUD.new()
var _hud_state := {}
var _player := {}
var _visual_state := {}
var _pending_frame := false
var _pending_events := []
var _target: Variant
var _first := false
var _field_capture := false
var _prior_mouse_mode := Input.MOUSE_MODE_VISIBLE
var _last_actor := {}
var _last_control_revision := -1
var _deployment_sequence := 0
var _deployment_attempt := 0
var _deployment_request := {}
var _last_audio_end := false
var _exiting := false
var _previous_physics_step_limit: int
signal leave_requested

func _enter_tree() -> void:
	_previous_physics_step_limit = Engine.max_physics_steps_per_frame
	Engine.max_physics_steps_per_frame = 2

func _exit_tree() -> void:
	if _field_capture: Input.mouse_mode = _prior_mouse_mode
	Engine.max_physics_steps_per_frame = _previous_physics_step_limit

func mount(app: RefCounted, id: String) -> Dictionary:
	application = app
	scope = id
	for part in [_visuals,_camera,_audio,_input_port]: add_child(part)
	var overlay := CanvasLayer.new()
	add_child(overlay)
	overlay.add_child(_hud)
	var opened := _visuals.open_field(id)
	if not opened.ok: return opened
	opened = _audio.open_scope(id)
	if not opened.ok: return opened
	_audio.set_hud_captions(true)
	opened = _input_port.configure(id,"player",{},0,_batch,_order)
	if not opened.ok: return opened
	_input_port.set_process_input(false)
	_input_port.set_process_unhandled_input(false)
	_input_port.context_changed.connect(_input_context_changed)
	_input_port.bind_order_target(_order_target)
	get_window().focus_exited.connect(_lost_focus)
	_hud.resume_requested.connect(_resume_controls)
	_input_port.bind_combat_view(func(h):return R.ok(_player.get("player",{})) if h==_player.get("actor_handle") else R.fail("NotFound","actor"))
	opened = _camera.open_field(id,_pose,_camera_permission,app.field_camera_sweep,_picker,Vector3(-35,0,0))
	if not opened.ok: return opened
	opened = _refresh_views()
	if not opened.ok: return opened
	opened = _hud.mount(id,_hud_view,_hud_action)
	if not opened.ok: return opened
	_camera.set_mode(id,"deployment")
	return R.ok()

func begin() -> void:
	if running: return
	_deployment_request = {}
	var view: Dictionary = application.field_view("input")
	if view.ok: _deployment_sequence = view.value.get("last_order_sequence",0)
	running = true
	_hud.set_process(false)
	_audio.transition_music("battle")
	_prior_mouse_mode = Input.mouse_mode
	_input_port.set_process_input(true)
	_input_port.set_process_unhandled_input(true)
	get_viewport().gui_release_focus()
	_input_context_changed(_input_port.view().mode)

func _input_context_changed(mode: String) -> void:
	var capture: bool = running and not _exiting and not _last_audio_end and mode in ["battle","command"] and not _own_actor().is_empty() and _player.get("control_mode","direct")=="direct"
	if capture==_field_capture: return
	_field_capture = capture
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE
	_hud.set_field_capture(capture)

func _lost_focus() -> void:
	if _field_capture: _input_port.set_context("ui")

func _resume_controls() -> void:
	if running and not _exiting and not _last_audio_end:
		get_viewport().gui_release_focus()
		_input_port.set_context("battle")

func _batch(batch: Dictionary) -> Dictionary:
	return application.field_command("field.input",{"batch":batch},_hud_state.revision,"input/%s"%batch.source_tick)

func _order_target(kind: String) -> Dictionary:
	var target := {"position":null,"formation":null}
	if kind=="move":
		var center := get_viewport().get_visible_rect().get_center()
		var hit := _camera.pick(scope,center)
		if hit.ok and hit.value!=null and hit.value.visible_entity==null:
			target.position = hit.value.position_mm
			_target = target.position
	elif kind=="follow":
		for group: Dictionary in _hud_state.get("formations",[]):
			if _own_actor() in group.members:
				target.formation = group.id
				break
	elif kind=="face_enemy" and not _hud_state.get("targets",[]).is_empty():
		target.formation = _hud_state.targets[0]
	return target

func _order(order: Dictionary, revisions: Dictionary) -> Dictionary:
	var command := order.duplicate()
	command.client_sequence += _deployment_sequence
	var result: Dictionary = application.field_command("field.order",{"order":command,"revisions":revisions},_hud_state.revision,order.order_id)
	if result.ok:
		_audio.play_event({"event_id":order.order_id,"scope_id":scope,"revision":_hud_state.revision,"tick":order.issued_tick,
			"type":"command","payload":{"confirmed":true,"order_type":order.order_type}},_camera.global_position)
	return result

func _hud_view() -> Dictionary:
	var projection := _hud_state.duplicate()
	var local := _input_port.view()
	projection.selection = local.selection
	projection.command_feedback = local.feedback
	projection.allow_rebind = true
	var bindings: Dictionary = _input_port.profile_view().bindings
	projection.bindable_actions = bindings.keys()
	projection.bindings = bindings
	projection.input_mode = local.mode
	projection.command_page = local.command_page
	projection.command_choices = local.command_choices
	projection.orders_open = local.orders_open
	projection.scoreboard_held = local.score_held
	projection.subtitle = _audio.caption_text()
	if _target != null: projection.target_position = _target
	return R.ok(projection)

func _hud_action(action: String,data: Dictionary) -> Dictionary:
	if data.scope_id!=scope: return R.fail("StaleVersion","hud")
	if action=="withdraw":
		# Confirmation concerns the local side; a render/physics tick boundary
		# may advance the revision while that same confirmation is on screen.
		if _hud_state.phase!="battle" or not _hud_state.get("can_withdraw",false):
			return R.fail("InvalidState","withdraw")
		return application.field_command("field.withdraw",{},_hud_state.revision)
	if data.revision!=_hud_state.revision: return R.fail("StaleVersion","hud")
	match action:
		"rebind": return _input_port.rebind(data.binding,data.event)
		"select": return _input_port.select_formations(data.ids)
		"order":
			var status := _input_port.select_formations(data.formation_ids)
			if status.ok: status = _input_port.set_target(data.target_position,data.target_formation_id)
			return _input_port.queue_order(data.kind,data.parameters) if status.ok else status
		"deploy","downed":
			var body := data.duplicate()
			body.erase("scope_id")
			body.erase("revision")
			if action=="deploy":
				if running or _hud_state.phase!="deployment": return R.fail("InvalidState","field.deployment")
				if body.get("placements") is Array and body.placements.is_empty():
					begin()
					return R.ok()
				_deployment_attempt += 1
				_deployment_request = {"body":body,"revision":data.revision,"id":"deployment/%d"%_deployment_attempt,"tries":0}
				return _deliver_deployment()
			return application.field_command("field."+action,body,data.revision)
		"leave":
			call_deferred("emit_signal","leave_requested")
			return R.ok()
	return R.fail("InvalidArgument","field.action")

func _deliver_deployment() -> Dictionary:
	var pending := _deployment_request
	var reply: Dictionary = application.field_command("field.deploy",pending.body,pending.revision,pending.id)
	if reply.ok:
		begin()
	elif reply.error.field in ["navigation_sync","nav_revision","field.navigation","deployment.spawn_site"] and pending.tries<60:
		pending.tries += 1
	else:
		_deployment_request = {}
	return reply

func _physics_process(_delta: float) -> void:
	if not running and not _exiting and not _deployment_request.is_empty():
		_deliver_deployment()

func _refresh_views() -> Dictionary:
	var hud: Dictionary = application.field_view("hud")
	if not hud.ok: return hud
	_hud_state = hud.value
	# The HUD projection also carries the committed local player's control state.
	_player = _hud_state
	var own := []
	var revisions := {}
	for row in _hud_state.formations:
		if row.get("controllable",false):
			own.append(row.id)
			revisions[row.id] = row.control_revision
	var h: Dictionary = _own_actor()
	var rev: int = _player.get("control_revision",0)
	if h!=_last_actor or rev!=_last_control_revision:
		var changed := _input_port.set_control(h,rev)
		if not changed.ok: return changed
		if not h.is_empty() and h!=_last_actor:
			var aligned := _input_port.align_look(_player.heading)
			if not aligned.ok: return aligned
		_last_actor = h
		_last_control_revision = rev
		if running and not h.is_empty(): _input_context_changed(_input_port.view().mode)
	_input_port.set_delegate_candidate(_hud_state.get("delegate_candidate",""))
	own.sort()
	return _input_port.set_formations(own,revisions,_hud_state.formations)

func before_step(tick: int) -> Dictionary:
	if not running or _exiting: return R.ok()
	var delivered := _input_port.step(tick)
	if not delivered.ok: return delivered
	var receipt: Dictionary = delivered.value.batch_receipt
	if not receipt.ok and receipt.error.retryable: return receipt
	return R.ok()

func after_step() -> Dictionary:
	if _exiting: return R.ok()
	var refreshed := _refresh_views()
	if not refreshed.ok: return refreshed
	_pending_frame = true
	_input_port.set_interaction_target(_hud_state.interaction_target)
	for event: Dictionary in _hud_state.confirmed_events:
		_pending_events.append(event.merged({"tick":_hud_state.tick}))
		if event.has("event_id"):
			var payload := {"confirmed":true}
			if event.get("position") is Vector3:
				var p: Vector3 = event.position
				payload.position_mm = [roundi(p.x*1000),roundi(p.y*1000),roundi(p.z*1000)]
			_audio.play_event({"scope_id":scope,"revision":_hud_state.tick,"tick":_hud_state.tick,
				"event_id":event.event_id,"type":event.type,"payload":payload},_camera.global_position)
	if _hud_state.phase=="ended" and not _last_audio_end:
		_last_audio_end = true
		_audio.transition_music("victory" if _hud_state.rules.outcome.winner_team_keys.has(_hud_state.team_key) else "defeat")
	if _field_capture and (_last_audio_end or _own_actor().is_empty() or _player.get("control_mode","direct")!="direct"):
		_input_port.set_context("ui")
	return R.ok()

func present_frame(delta: float) -> Dictionary:
	if _exiting or not running: return R.ok()
	if not _pending_frame:
		if not _visual_state.is_empty(): _present_camera(delta)
		return R.ok()
	var visual: Dictionary = application.field_view("visual")
	if not visual.ok: return visual
	_visual_state = visual.value
	var accepted := _visuals.apply_snapshot(_visual_state)
	if not accepted.ok: return accepted
	accepted = _visuals.consume_view_events(scope,_visual_state.tick,_pending_events)
	if not accepted.ok: return accepted
	_pending_events.clear()
	_pending_frame = false
	if _last_audio_end: _hud.set_process(true)
	_present_camera(delta)
	return _hud.refresh()

func _present_camera(delta: float) -> void:
	var controls := _input_port.view()
	_first = controls.first_person
	var desired := _mode()
	var focus: Dictionary = {} if desired=="deployment" else _own_actor()
	var current := _camera.state()
	if desired!=current.mode or focus!=current.target:
		_camera.set_mode(scope,desired,focus)
	_camera.set_zoom_held(_field_capture and controls.zoom_held)
	if desired in ["first","third","mounted"]:
		_camera.update_player_view(scope,_visual_state.tick,delta,controls.preview_aim+controls.orbit_offset,controls.camera_distance_steps)
	else:
		_camera.update_view(scope,_visual_state.tick,delta)
	_visuals.set_first_person_actor(focus if _camera.state().mode=="first" else {})

func _own_actor() -> Dictionary:
	var actor: Variant = _player.get("actor_handle")
	return actor if actor is Dictionary else {}

func _mode() -> String:
	if not running or _own_actor().is_empty(): return "deployment"
	if _player.get("control_mode","direct")in ["spectate","spectator"]: return "spectator"
	if _first: return "first"
	return "mounted" if _player.get("player",{}).get("mount_handle")!=null else "third"

func _camera_permission(id: String,mode: String,handle: Dictionary) -> bool:
	if id!=scope: return false
	if mode=="deployment": return not running or _own_actor().is_empty()
	return handle==_own_actor() and mode==_mode()

func _pose(id: String,h: Dictionary) -> Dictionary:
	if id!=scope or h!=_player.get("actor_handle"): return R.fail("NotFound","camera_actor")
	var ids: Array = ["field/%s/%s"%[h.index,h.generation]]
	var horse: Variant = _player.get("player",{}).get("mount_handle")
	if horse!=null: ids.append("field/%s/%s"%[horse.index,horse.generation])
	return R.ok({"position":_player.position,"heading":_player.heading,"mounted":horse!=null,"collision_handles":ids})

func _picker(id: String, name_or_path: String) -> Dictionary:
	if id!=scope: return R.fail("NotFound","field")
	if not name_or_path.begins_with("field/"): return R.ok(null)
	for row in _visual_state.get("actors",[]):
		if name_or_path=="field/%s/%s"%[row.handle.index,row.handle.generation]: return R.ok(row.handle)
	return R.fail("NotFound","visibility")

func _process(_dt: float) -> void:
	if _exiting or scope.is_empty(): return
	if not running:
		_camera.update_view(scope,0,1.0/60.0)
	if not _visual_state.is_empty():
		_visuals.render_interpolated(Engine.get_physics_interpolation_fraction(),_camera.global_position,MEDIUM_NEAR_METRES)

func active_playbacks() -> Array[WeakRef]:
	return _audio.active_playbacks()

func release() -> void:
	_exiting = true
	if running: Input.mouse_mode = _prior_mouse_mode
	_field_capture = false
	_hud.release_scope()
	_audio.stop_scope(scope)
	_camera.release_scope(scope)
	_visuals.release_scope(scope)
