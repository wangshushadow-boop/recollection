extends Camera3D
## Local render-only camera. The composition root supplies the Mission's authorized
## pose, spectator rules, physical sweep and visibility-filtered picker.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const C = preload("res://contracts/canonical.gd")
const MODES := ["first","third","mounted","deployment","spectator"]
const SETTINGS := "user://field-camera.json"
const ARM_RADIUS_MM := 160
const CHASE_DISTANCE := 2.65
const SHOULDER := .43
const MOUNTED_BACK := .75
const HELD_MAGNIFICATION := 1.6
var _scope := ""
# A callback can publish another view or rebind the same scope name before it returns.
var _revision := 0
var _mode := ""
var _target := {}
var _read_pose: Callable
var _permit: Callable
var _sweep: Callable
var _pick_entity: Callable
var _focus := Vector3.ZERO
var _yaw := 0.0
var _pitch := -0.18
var _distance := 5.0
var _chase_distance := CHASE_DISTANCE
var _distance_steps := 0
var _arm := 0.0
var _follow_pivot := Vector3.ZERO
var _zoom_held := false
var _zoom_blend := 0.0
var _base_fov := 75.0
var _shake := true
var _last_tick := -1
var _ready_view := false
var _layers := 0

func _ready() -> void:
	_layers = cull_mask
	_base_fov = fov
	_hide_view()

func open_field(scope: String, pose_reader: Callable, permission_reader: Callable, sweep_reader: Callable, visible_entity: Callable, deployment_focus: Vector3) -> Dictionary:
	if not is_inside_tree() or not _scope.is_empty() or scope.is_empty() or not deployment_focus.is_finite():
		return R.fail("InvalidState","camera_scope")
	if not pose_reader.is_valid() or not permission_reader.is_valid() or not sweep_reader.is_valid() or not visible_entity.is_valid():
		return R.fail("InvalidArgument","camera_readers")
	var loaded := _load_options()
	if not loaded.ok: return loaded
	_scope = scope
	_revision += 1
	_read_pose = pose_reader
	_permit = permission_reader
	_sweep = sweep_reader
	_pick_entity = visible_entity
	_focus = deployment_focus
	near = .05
	return R.ok()

static func _handle(value: Variant) -> bool:
	return value is Dictionary and value.size()==2 and V.integer(value.get("index"),0,V.MAX_U32) and V.integer(value.get("generation"),1,V.MAX_U32)

func _grant(revision: int, mode: String, handle: Dictionary) -> Dictionary:
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	var permitted := _permit.is_valid() and is_same(_permit.call(_scope,mode,handle.duplicate()),true)
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	return R.ok() if permitted else R.fail("Unauthorized","camera_target")

func _anchor(mode: String, handle: Dictionary) -> Dictionary:
	if mode=="deployment":
		return R.ok({"feet":_focus,"pivot":_focus+Vector3.UP,"ignore":[],"heading":Vector3.ZERO})
	if not _read_pose.is_valid(): return R.fail("Unavailable","camera_pose")
	var read: Variant = _read_pose.call(_scope,handle.duplicate())
	if not read is Dictionary or not is_same(read.get("ok"),true) or not read.get("value") is Dictionary:
		return R.fail("NotFound","camera_pose")
	var pose: Dictionary = read.value
	var at: Variant = pose.get("position")
	var heading: Variant = pose.get("heading",Vector3.ZERO)
	var mounted: Variant = pose.get("mounted",false)
	var ignored: Variant = pose.get("collision_handles",[])
	if not at is Vector3 or not at.is_finite() or not heading is Vector3 or not heading.is_finite() or not mounted is bool:
		return R.fail("InvalidArgument","camera_pose")
	if not ignored is Array or not ignored.all(func(id):return id is String):
		return R.fail("InvalidArgument","collision_handles")
	if mode=="mounted" and not mounted: return R.fail("InvalidState","mount")
	if mounted and pose.has("mount_position"):
		at = pose.mount_position
		if not at is Vector3 or not at.is_finite(): return R.fail("InvalidArgument","mount_position")
	return R.ok({"feet":at,"pivot":at+Vector3.UP*(2.45 if mounted else 1.65),"heading":heading,"ignore":ignored.duplicate()})

func _authorized_pose(revision: int, mode: String, handle: Dictionary) -> Dictionary:
	var grant := _grant(revision,mode,handle)
	if not grant.ok: return grant
	var pose := _anchor(mode,handle)
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	if not pose.ok: return pose
	if mode!="deployment":
		grant = _grant(revision,mode,handle)
		if not grant.ok: return grant
	return pose

func _confirm_view(revision: int, pose: Dictionary) -> Dictionary:
	var latest := _authorized_pose(revision,_mode,_target)
	if not latest.ok: return latest
	if latest.value!=pose: return R.fail("InvalidState","camera_pose_changed")
	return R.ok()

func set_mode(scope: String, mode: String, handle: Dictionary = {}) -> Dictionary:
	if scope!=_scope or _scope.is_empty(): return R.fail("NotFound","camera_scope")
	var revision := _revision
	handle = handle.duplicate()
	var read := R.fail("InvalidArgument","camera_mode")
	if mode in MODES and (handle.is_empty() if mode=="deployment" else _handle(handle)):
		read = _authorized_pose(revision,mode,handle)
	if not read.ok:
		if revision==_revision and not _mode.is_empty():
			var prior := _authorized_pose(revision,_mode,_target)
			if not prior.ok and revision==_revision: _recover(maxi(0,_last_tick))
		return read
	if mode==_mode and handle==_target: return R.ok()
	var heading: Vector3 = read.value.heading
	if _target!=handle and Vector2(heading.x,heading.z).length_squared()>.000001:
		_yaw = atan2(-heading.x,-heading.z)
	_mode = mode
	_target = handle.duplicate()
	if mode=="deployment" or mode=="spectator":
		_zoom_held=false
		_zoom_blend=0.0
		_apply_fov()
	_arm = 0.0
	_hide_view()
	return R.ok()

static func _mm(p: Vector3) -> Array:
	return [roundi(p.x*1000),roundi(p.y*1000),roundi(p.z*1000)]

func _ray(a: Vector3,b: Vector3,radius_mm: int,mask: int,tick: int,ignore: Array) -> Dictionary:
	if not _sweep.is_valid(): return R.fail("Unavailable","camera_query")
	var revision := _revision
	var sample: Variant = _sweep.call([{"from":_mm(a),"to":_mm(b),"radius_mm":radius_mm,"mask":mask,
		"ignored_handles":ignore.duplicate()}],{"scope_id":_scope,"tick":tick})
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	if not sample is Dictionary or not is_same(sample.get("ok"),true) or not sample.get("value") is Array:
		return R.fail("Unavailable","camera_query")
	if sample.value.is_empty(): return R.ok(null)
	# The engine adapter sorts a single query's candidates by fraction, then by handle.
	var hit: Variant = sample.value[0]
	if not hit is Dictionary or not V.integer(hit.get("fraction_ppm"),0,1000000):
		return R.fail("InvalidArgument","camera_hit")
	return R.ok(hit.duplicate(true))

func _safe_length(origin: Vector3, offset: Vector3, tick: int, ignore: Array) -> Dictionary:
	var result := _ray(origin,origin+offset,ARM_RADIUS_MM,1,tick,ignore)
	if not result.ok: return result
	if result.value == null: return R.ok(offset.length())
	if result.value.fraction_ppm==0: return R.fail("Unavailable","camera_pivot_obstructed")
	return R.ok(maxf(0,offset.length()*float(result.value.fraction_ppm)*.000001-.025))

func update_view(scope: String, tick: int, dt: float, look := Vector2.ZERO, zoom := 0.0, impact := 0.0) -> Dictionary:
	return _update_frame(scope,tick,dt,look,zoom,impact,false)

# Rejoining the player's look uses the current combat angles, including after a free-look orbit.
func update_player_view(scope: String, tick: int, dt: float, aim: Vector2, distance_steps := 0) -> Dictionary:
	var zoom := (distance_steps-_distance_steps)*0.35
	var updated := _update_frame(scope,tick,dt,Vector2(angle_difference(_yaw,aim.x),aim.y-_pitch),zoom,0,true)
	if updated.ok: _distance_steps = distance_steps
	return updated

func _update_frame(scope: String, tick: int, dt: float, look: Vector2, zoom: float, impact: float, combat_aim: bool) -> Dictionary:
	if scope!=_scope or _scope.is_empty() or _mode.is_empty(): return R.fail("InvalidState","camera_scope")
	var revision := _revision
	var read := _authorized_pose(revision,_mode,_target)
	if not read.ok:
		if revision==_revision: _recover(maxi(0,_last_tick))
		return read
	if tick<0 or tick<_last_tick or not is_finite(dt) or dt<0 or not look.is_finite() or not is_finite(zoom) or not is_finite(impact):
		return R.fail("InvalidArgument","camera_frame")
	var result := _place(read.value,tick,dt,look,zoom,impact,combat_aim)
	if not result.ok and revision==_revision:
		if result.error.field in ["camera_query","camera_hit","camera_pivot_obstructed"]:
			var confirmed := _confirm_view(revision,read.value)
			if confirmed.ok:
				_hide_view()
			elif revision==_revision:
				_recover(tick)
		else:
			_recover(tick)
	return result

func _place(pose: Dictionary,tick: int,dt: float,look: Vector2,zoom: float,impact: float,combat_aim := false) -> Dictionary:
	var revision := _revision
	var yaw := wrapf(_yaw+look.x,-PI,PI)
	var pitch := clampf(_pitch+look.y,-1.40,1.35)
	var chase := _mode=="third" or _mode=="mounted"
	var personal := chase or _mode=="first"
	if combat_aim and personal: pitch=clampf(_pitch+look.y,-PI/2,PI/2)
	var distance := clampf((_chase_distance if personal else _distance)+zoom,1.0,20.0)
	var elevation := clampf(pitch,-1.40,-.28) if _mode=="deployment" else pitch
	var view_basis := Basis.from_euler(Vector3(elevation,yaw,0))
	var pivot: Vector3 = pose.pivot
	var follow := pivot
	var extent := distance
	if _mode=="first":
		var head_start: Vector3 = pose.feet+Vector3.UP*.26
		var head_room := _safe_length(head_start,pivot-head_start,tick,pose.ignore)
		if not head_room.ok: return head_room
		pivot = head_start+Vector3.UP*float(head_room.value)
		extent = 0.0
	elif _mode=="deployment":
		extent = 12.0+distance*2.5
	elif _mode=="mounted":
		extent += MOUNTED_BACK
	var offset := view_basis.z*extent
	if chase:
		# Only follow the last verified target, with a short lag for ordinary strides.
		if _ready_view and _follow_pivot.distance_squared_to(pivot)<1.0:
			follow += ((_follow_pivot-pivot)*exp(-18.0*dt)).limit_length(.22)
		offset += follow-pivot + view_basis.x*SHOULDER + view_basis.y*.14
	var wanted := offset.length()
	if extent>0.0:
		# Sweep from the authoritative pivot through the complete shoulder offset.
		var safe := _safe_length(pivot,offset,tick,pose.ignore)
		if not safe.ok: return safe
		wanted = safe.value
	var confirmed := _confirm_view(revision,pose)
	if not confirmed.ok: return confirmed
	# Retract immediately; smooth only travel inside the checked segment.
	_arm = wanted if chase and not _ready_view else minf(wanted,move_toward(_arm,wanted,45*minf(dt,.15)))
	var roll := clampf(impact,-1,1)*.018 if _shake else 0.0
	global_transform = Transform3D(view_basis.rotated(view_basis.z,roll),pivot+offset.normalized()*_arm)
	_follow_pivot = follow
	_yaw = yaw
	_pitch = pitch
	if personal: _chase_distance = distance
	else: _distance = distance
	_zoom_blend = move_toward(_zoom_blend,float(_zoom_held),dt*8.0) if personal else 0.0
	_apply_fov()
	_last_tick = tick
	_ready_view = true
	_revision += 1
	cull_mask = _layers
	make_current()
	return R.ok(state())

func pick(scope: String, screen_point: Vector2, max_distance := 300.0) -> Dictionary:
	if scope!=_scope or _scope.is_empty() or not _ready_view: return R.fail("InvalidState","camera_scope")
	var revision := _revision
	var anchor := _authorized_pose(revision,_mode,_target)
	if not anchor.ok:
		if revision==_revision: _recover(_last_tick)
		return anchor
	if not screen_point.is_finite() or not get_viewport().get_visible_rect().has_point(screen_point) or not is_finite(max_distance) or max_distance<.001 or max_distance>2000:
		return R.fail("InvalidArgument","pick")
	var start := project_ray_origin(screen_point)
	var hit := _ray(start,start+project_ray_normal(screen_point)*max_distance,0,0xffffffff,_last_tick,anchor.value.ignore)
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	var confirmed := _confirm_view(revision,anchor.value)
	if not confirmed.ok:
		if revision==_revision: _recover(_last_tick)
		return confirmed
	if not hit.ok or hit.value==null: return hit
	if not _pick_entity.is_valid(): return R.fail("Unavailable","camera_visibility")
	var permitted: Variant = _pick_entity.call(_scope,hit.value.get("entity_handle"))
	if revision!=_revision: return R.fail("InvalidState","camera_changed")
	confirmed = _confirm_view(revision,anchor.value)
	if not confirmed.ok:
		if revision==_revision: _recover(_last_tick)
		return confirmed
	# A hidden foremost contact reveals neither a position nor an object behind it.
	if not permitted is Dictionary or not is_same(permitted.get("ok"),true) or not permitted.has("value"): return R.ok(null)
	var picked: Variant = permitted.get("value")
	if picked!=null and not _handle(picked): return R.fail("InvalidArgument","visible_entity")
	var point: Variant = hit.value.get("point_mm")
	if not point is Array or point.size()!=3 or not point.all(func(x):return V.integer(x,-2147483648,2147483647)):
		return R.fail("InvalidArgument","camera_hit")
	return R.ok({"position_mm":point.duplicate(),"visible_entity":picked.duplicate() if picked!=null else null})

func state() -> Dictionary:
	return {"scope_id":_scope,"mode":_mode,"target":_target.duplicate(),"fov":fov,"shake":_shake,"active":_ready_view}

func set_zoom_held(held: bool) -> void:
	_zoom_held = held and not _scope.is_empty() and _mode in ["first","third","mounted"]

func _apply_fov() -> void:
	if _zoom_blend==0.0:
		fov = _base_fov
	else:
		var magnification := lerpf(1.0,HELD_MAGNIFICATION,smoothstep(0.0,1.0,_zoom_blend))
		fov = rad_to_deg(2.0*atan(tan(deg_to_rad(_base_fov)*.5)/magnification))

func set_options(field_of_view: float, shake: bool) -> Dictionary:
	if not is_finite(field_of_view) or field_of_view<45 or field_of_view>105:
		return R.fail("InvalidArgument","camera_fov")
	var milli := roundi(field_of_view*1000)
	var encoded := C.encode({"fov_mdeg":milli,"shake":shake})
	if not encoded.ok: return encoded
	var tmp := ProjectSettings.globalize_path(SETTINGS)+"."+str(OS.get_process_id())+"."+str(get_instance_id())+".tmp"
	var file := FileAccess.open(tmp,FileAccess.WRITE)
	if file==null: return R.fail("Unavailable","camera_settings")
	file.store_buffer(encoded.value)
	file.flush()
	var wrote := file.get_error()==OK
	file.close()
	if not wrote or DirAccess.rename_absolute(tmp,ProjectSettings.globalize_path(SETTINGS))!=OK:
		DirAccess.remove_absolute(tmp)
		return R.fail("Unavailable","camera_settings")
	_base_fov = milli*.001
	_apply_fov()
	_shake = shake
	return R.ok()

func _load_options() -> Dictionary:
	if not FileAccess.file_exists(SETTINGS): return R.ok()
	var file := FileAccess.open(SETTINGS,FileAccess.READ)
	if file==null or file.get_length()>4096: return R.fail("InvalidArgument","camera_settings")
	var parsed := C.decode(file.get_buffer(file.get_length()))
	if not parsed.ok or not parsed.value is Dictionary or parsed.value.size()!=2:
		return R.fail("InvalidArgument","camera_settings")
	var angle: Variant = parsed.value.get("fov_mdeg")
	var shake: Variant = parsed.value.get("shake")
	if not V.integer(angle,45000,105000) or not shake is bool: return R.fail("InvalidArgument","camera_settings")
	_base_fov = angle*.001
	_apply_fov()
	_shake = shake
	return R.ok()

func _hide_view() -> void:
	_revision += 1
	_ready_view = false
	cull_mask = 0
	clear_current(false)

func _recover(tick: int) -> void:
	_hide_view()
	set_zoom_held(false)
	_zoom_blend=0.0
	_apply_fov()
	_mode = ""
	_target = {}
	_arm = 0.0
	_last_tick = maxi(_last_tick,tick)
	global_transform = Transform3D(Basis.IDENTITY,_focus)
	var revision := _revision
	var fallback := _authorized_pose(revision,"deployment",{})
	if fallback.ok:
		_mode = "deployment"
		if not _place(fallback.value,tick,.15,Vector2.ZERO,0,0).ok and revision==_revision:
			_mode = ""

func release_scope(scope: String) -> void:
	if _scope.is_empty() or scope!=_scope: return
	_hide_view()
	global_transform = Transform3D.IDENTITY
	_scope = ""
	_mode = ""
	_target = {}
	_last_tick = -1
	_arm = 0
	_read_pose = Callable()
	_permit = Callable()
	_sweep = Callable()
	_pick_entity = Callable()
	_yaw = 0
	_pitch = -.18
	_distance = 5.0
	_chase_distance = CHASE_DISTANCE
	_distance_steps = 0
	_zoom_held = false
	_zoom_blend = 0.0
	_apply_fov()
