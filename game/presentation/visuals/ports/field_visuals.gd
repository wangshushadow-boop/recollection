extends Node3D
## Read-only Mission projection. Scene composition owns this node and the camera.
const R = preload("res://contracts/result.gd")
const Models = preload("res://presentation/visuals/field_model.gd")
const Batches = preload("res://presentation/visuals/field_batches.gd")
const Ground = preload("res://presentation/visuals/field_environment.gd")
const NEAR_LIMIT := 36
const CORPSE_LIMIT := 64
const HIT_LIMIT := 48

class Proxy:
	var index: int
	var generation: int
	var role: String
	var team: int
	var previous: Vector3
	var position: Vector3
	var old_yaw: float
	var yaw: float
	var speed: float
	var phase: String
	var old_phase: String
	var direction: String
	var old_direction: String
	var since: int
	var old_since: int
	var mount_index := -1
	var mount_generation := 0
	var ranged: bool
	var figure: Models.Figure
	var last_mounted := false
	var last_pose := -1.0
	var distance: float

var _scope := ""
var _tick := -1
var _previous_tick := -1
var _host: Node3D
var _batches: Batches
var _models := {}
var _actors := {}
var _generation := {}
var _shots := {}
var _corpses: Array[Dictionary] = []
var _impacts: Array[Dictionary] = []
var _seen_events := {}
var _tints: Array[StandardMaterial3D] = []
var _near := {}
var _lod_tick := -100
var _lod_eye := Vector3.INF
var _lod_radius := -1.0
var _skinned := 0
var _far := 0
var _mounts := 0

func open_field(scope_id: String) -> Dictionary:
	if not is_inside_tree() or scope_id.is_empty() or not _scope.is_empty():
		return R.fail("InvalidState","visual_scope")
	_scope = scope_id
	_host = Node3D.new()
	add_child(_host)
	_batches = Batches.new()
	_host.add_child(_batches)
	for color: Color in Models.COLORS:
		var tint := StandardMaterial3D.new()
		tint.albedo_color = color
		tint.roughness = .9
		_tints.append(tint)
	for kind: String in Models.FILES:
		var model := Models.new()
		if not model.load_model(kind,_host):
			release_scope(scope_id)
			return R.fail("Unavailable","visual_asset."+kind)
		_models[kind] = model
		for frame in model.poses.size():
			_batches.add_group(kind+str(frame),model.poses[frame])
	var shaft := CylinderMesh.new()
	shaft.top_radius = .010
	shaft.bottom_radius = .010
	shaft.height = .62
	shaft.radial_segments = 5
	var head := CylinderMesh.new()
	head.top_radius = 0
	head.bottom_radius = .028
	head.height = .11
	head.radial_segments = 3
	var fletch := BoxMesh.new()
	fletch.size = Vector3(.063,.010,.11)
	var bolt := SurfaceTool.new()
	bolt.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along := Basis(Vector3.RIGHT,-PI*.5)
	bolt.append_from(shaft,0,Transform3D(along,Vector3.ZERO))
	bolt.append_from(head,0,Transform3D(along,Vector3.FORWARD*.36))
	bolt.append_from(fletch,0,Transform3D(Basis.IDENTITY,Vector3.BACK*.24))
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color("#60472d")
	_batches.add_group("arrow",bolt.commit(),wood)
	var spark := SphereMesh.new()
	spark.radial_segments = 5
	spark.rings = 2
	spark.radius = .12
	spark.height = .24
	var flash := StandardMaterial3D.new()
	flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	flash.albedo_color = Color("#ffce70")
	_batches.add_group("impact",spark,flash)
	_host.add_child(Ground.new())
	return R.ok()

func _valid_handle(h: Variant) -> bool:
	return h is Dictionary and h.get("index") is int and h.index >= 0 and h.get("generation") is int and h.generation > 0

func _finite(x: Variant) -> bool:
	return x is Vector3 and x.is_finite()

func apply_snapshot(s: Dictionary) -> Dictionary:
	if _scope == "" or s.get("scope_id") != _scope:
		return R.fail("NotFound","visual_scope")
	if not s.get("tick") is int or s.tick <= _tick:
		return R.fail("StaleVersion","tick")
	if not s.get("actors") is Array or not s.get("projectiles",[]) is Array:
		return R.fail("InvalidArgument","snapshot")
	var present := {}
	for a: Variant in s.actors:
		if not a is Dictionary or not _valid_handle(a.get("handle")) or a.get("role") not in Models.FILES or not a.get("team") is int:
			return R.fail("InvalidArgument","actor")
		if not _finite(a.get("position")) or not _finite(a.get("heading")) or not _finite(a.get("velocity")):
			return R.fail("InvalidArgument","pose")
		if present.has(a.handle.index) or a.handle.generation < _generation.get(a.handle.index,0):
			return R.fail("StaleVersion","handle")
		if not a.get("since",0) is int or not a.get("phase","Ready") is String or not a.get("direction","") is String:
			return R.fail("InvalidArgument","action")
		present[a.handle.index] = true
	var shots := {}
	for shot: Variant in s.get("projectiles",[]):
		if not shot is Dictionary or not shot.get("id") is String or shots.has(shot.id) or not _finite(shot.get("position")) or not _finite(shot.get("direction")):
			return R.fail("InvalidArgument","projectile")
		var old: Dictionary = _shots.get(shot.id,{})
		shots[shot.id] = {"before":old.get("position",shot.position),"position":shot.position,"direction":shot.direction}
	_shots = shots
	for index: int in _actors.keys():
		if not present.has(index):
			_drop(_actors[index])
			_actors.erase(index)
	for a: Dictionary in s.actors:
		var h: Dictionary = a.handle
		var p: Proxy = _actors.get(h.index)
		var arrived: bool = p == null or p.generation != h.generation or p.role != a.role
		if arrived:
			if p != null:
				_drop(p)
			p = Proxy.new()
			p.index = h.index
			p.generation = h.generation
			p.role = a.role
			p.position = a.position
			p.yaw = atan2(a.heading.x,a.heading.z)
			_actors[h.index] = p
			_generation[h.index] = h.generation
			_lod_tick = -100
		p.previous = p.position
		p.position = a.position
		p.old_yaw = p.yaw
		if Vector2(a.heading.x,a.heading.z).length_squared() > .000001:
			p.yaw = atan2(a.heading.x,a.heading.z)
		p.old_phase = a.get("phase","Ready") if arrived else p.phase
		p.old_direction = a.get("direction","") if arrived else p.direction
		p.old_since = a.get("since",0) if arrived else p.since
		p.phase = a.get("phase","Ready")
		p.since = a.get("since",0)
		p.direction = a.get("direction","")
		p.team = a.team
		p.speed = a.velocity.length()
		var mount_ref: Variant = a.get("mount_handle")
		p.mount_index = mount_ref.index if _valid_handle(mount_ref) else -1
		p.mount_generation = mount_ref.generation if p.mount_index >= 0 else 0
		var new_ranged: bool = p.role in ["archer","mounted_archer"] and a.get("weapon_slot",1) != 0
		if p.ranged != new_ranged or p.old_phase != p.phase:
			p.last_pose = -1.0
		p.ranged = new_ranged
	_previous_tick = s.tick if _tick < 0 else _tick
	_tick = s.tick
	return R.ok()

func _drop(p: Proxy) -> void:
	if p.figure != null:
		p.figure.root.free()
		p.figure = null
	_near.erase(p.index)

## Send the committed snapshot first. An early batch may be retried with the same event IDs.
func consume_view_events(scope_id: String, tick: int, events: Array) -> Dictionary:
	if scope_id != _scope or _scope.is_empty():
		return R.fail("NotFound","visual_scope")
	if tick < 0 or tick < _tick-1:
		return R.fail("StaleVersion","tick")
	if tick > _tick:
		return R.fail("Unavailable","visual_snapshot")
	for e: Variant in events:
		if not e is Dictionary or e.get("confirmed") != true or e.get("type") not in ["hit","downed"]:
			continue
		var id: Variant = e.get("event_id")
		if not id is String or id.is_empty() or _seen_events.has(id):
			continue
		var h: Variant = e.get("actor_handle")
		if not _valid_handle(h):
			continue
		var p: Proxy = _actors.get(h.index)
		if p != null and p.generation != h.generation:
			p = null
		var at: Variant = e.get("position",p.position if p != null else null)
		if not _finite(at):
			continue
		var event_tick: int = clampi(e.get("tick",tick),0,tick) if e.get("tick",tick) is int else tick
		if e.type == "downed":
			var role: Variant = p.role if p != null else e.get("role")
			if role not in Models.FILES: continue
			if _corpses.size() == CORPSE_LIMIT: _corpses.pop_front()
			_corpses.append({"at":at,"role":role,"ranged":p.ranged if p!=null else e.get("weapon_slot",1)!=0,"yaw":p.yaw if p != null else 0.0,
				"team":p.team if p != null else int(e.get("team",0)),"until":event_tick+150})
		else:
			if _impacts.size() == HIT_LIMIT: _impacts.pop_front()
			_impacts.append({"at":Vector3(at)+Vector3.UP*1.1,"until":event_tick+10})
		_seen_events[id] = event_tick
	for key in _seen_events.keys():
		if _seen_events[key] < tick-180:
			_seen_events.erase(key)

	return R.ok()

func _select_near(eye: Vector3, radius: float) -> void:
	var possible: Array[Proxy] = []
	for p: Proxy in _actors.values():
		p.distance = p.position.distance_squared_to(eye)
		if p.phase != "Downed" and p.distance <= radius*radius:
			possible.append(p)
	possible.sort_custom(func(a: Proxy,b: Proxy): return a.distance < b.distance if a.distance != b.distance else a.index < b.index)
	var targets := {}
	for j in mini(NEAR_LIMIT,possible.size()):
		var p := possible[j]
		targets[p.index] = true
		if p.figure == null:
			p.figure = _models[p.role].instantiate(_host)
			p.figure.root.name = "Agent_%d_%d" % [p.index,p.generation]
			p.last_pose = -1.0
			if p.figure.tunic: p.figure.tunic.material_override = _tints[posmod(p.team,2)]
	for index: int in _near.keys():
		if not targets.has(index) and _actors.has(index):
			_drop(_actors[index])
	_near = targets
	_lod_tick = _tick
	_lod_eye = eye
	_lod_radius = radius

func render_interpolated(alpha: float, eye: Vector3, near_radius: float = 22.0) -> void:
	if _tick < 0 or not eye.is_finite(): return
	alpha = clampf(alpha,0,1)
	# A display frame can span several committed ticks. Interpolate only the last tick's fraction.
	alpha = 1.0 - (1.0-alpha)/maxi(1,_tick-_previous_tick)
	var t := lerpf(float(_previous_tick),float(_tick),alpha)
	if _tick-_lod_tick >= 8 or eye.distance_squared_to(_lod_eye)>16 or _lod_radius != near_radius:
		_select_near(eye,maxf(0,near_radius))
	_batches.begin_frame()
	_skinned = 0
	_far = 0
	_mounts = 0
	for p: Proxy in _actors.values():
		var old := p.since > t and p.phase != p.old_phase
		var phase := p.old_phase if old else p.phase
		if phase == "Downed":
			if p.figure: p.figure.root.visible = false
			continue
		var yaw := lerp_angle(p.old_yaw,p.yaw,alpha)
		var pos := p.previous.lerp(p.position,alpha)
		var horse: Proxy = _actors.get(p.mount_index)
		var mounted: bool = horse != null and horse.generation == p.mount_generation and horse.role == "mount" and horse.phase != "Downed"
		if mounted:
			yaw = lerp_angle(horse.old_yaw,horse.yaw,alpha)
			pos = horse.previous.lerp(horse.position,alpha) + Basis(Vector3.UP,yaw)*Models.saddle_offset(horse.figure)
		var transform3 := Transform3D(Basis(Vector3.UP,yaw),pos)
		var offset := posmod(p.index,27)
		if p.role == "mount": _mounts += 1
		if p.figure != null:
			p.figure.root.visible = true
			if p.role == "mount":
				transform3.basis = transform3.basis.scaled(Vector3.ONE*Models.HORSE_SCALE)
			p.figure.root.transform = transform3
			# Skin playback follows the same authority tick at 30 Hz near camera.
			if t-p.last_pose >= 1.5 or p.last_pose < 0 or p.last_mounted != mounted or phase in ["Active","Guard","Windup","Recovery"]:
				_models[p.role].pose(p.figure,t+offset,p.speed,phase,p.old_direction if old else p.direction,
					(p.old_since if old else p.since)+offset,mounted,p.ranged)
				p.last_pose = t
				p.last_mounted = mounted
			_skinned += 1
		else:
			var frame := 0
			if phase == "Guard":
				frame = 7
			elif phase in ["Windup","Active","Hold","Recovery"]:
				frame = 3 + maxi(0,Models.DIRECTIONS.find(p.old_direction if old else p.direction))
			elif p.speed > .12:
				frame = 1 + floori((t+offset)/9.0)%2
			_batches.push(_batch_pose(p.role,mounted,p.ranged,frame),transform3,Models.COLORS[posmod(p.team,2)])
			_far += 1
	for s: Dictionary in _shots.values():
		var dir: Vector3 = s.direction
		var basis := Basis.IDENTITY
		if dir.length_squared() > .000001:
			basis = Basis.looking_at(dir.normalized(),Vector3.RIGHT if absf(dir.normalized().y)>.95 else Vector3.UP)
		_batches.push("arrow",Transform3D(basis,Vector3(s.before).lerp(s.position,alpha)),Color.WHITE)
	for i in range(_corpses.size()-1,-1,-1):
		var c := _corpses[i]
		if c.until < _tick:
			_corpses.remove_at(i)
		else:
			var fallen := Basis(Vector3.UP,c.yaw)*Basis(Vector3.BACK,PI*.5)
			_batches.push(_batch_pose(c.role,false,c.ranged,0),Transform3D(fallen,c.at+Vector3.UP*.20),Models.COLORS[posmod(c.team,2)])
	for i in range(_impacts.size()-1,-1,-1):
		var e := _impacts[i]
		if e.until < _tick:
			_impacts.remove_at(i)
		else:
			_batches.push("impact",Transform3D(Basis.IDENTITY,e.at),Color.WHITE)
	_batches.flush()

func _batch_pose(role: String, mounted: bool, ranged: bool, frame: int) -> String:
	if role=="mounted_archer" and not ranged: role = "cavalry"
	if (role in ["cavalry","mounted_archer"] and not mounted) or (role=="archer" and not ranged):
		frame += Models.POSES_PER_SET
	return role+str(frame)

func report() -> Dictionary:
	return {"scope_id":_scope,"tick":_tick,"near_skeletons":_skinned,"far_animated_instances":_far,
		"visible_actors":_skinned+_far,"mounts":_mounts,"projectiles":_shots.size(),
		"impacts":_impacts.size(),"corpses":_corpses.size()}

func release_scope(scope_id: String) -> void:
	if scope_id != _scope: return
	if _host != null: _host.free()
	_host = null
	_batches = null
	_models.clear()
	_actors.clear()
	_generation.clear()
	_shots.clear()
	_corpses.clear()
	_impacts.clear()
	_seen_events.clear()
	_tints.clear()
	_near.clear()
	_tick = -1
	_previous_tick = -1
	_lod_eye = Vector3.INF
	_lod_tick = -100
	_lod_radius = -1
	_skinned = 0
	_far = 0
	_mounts = 0
	_scope = ""
