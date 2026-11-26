extends RefCounted

const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const Queries = preload("res://infrastructure/engine/queries.gd")
const BODY_LAYER := 1 << 29
const ENVIRONMENT := 0xffffffff ^ BODY_LAYER
const ENEMY_CLEARANCE_M := 6.0
const EYE := Vector3.UP * 1.55
const SADDLE_M := 0.95
const BODY_FIELDS := ["handle","type","team_key","position","facing","mounted","shield"]

var _world: SubViewport
var _committed := {}
var _current := {}
var _committed_order: Array = []
var _staged_order: Array = []
var _changed_slots: Array = []
var _same_order := false
var _staged := false
var _generations := {}
var _bodies := {}
var _targets := {}
var _human := CapsuleShape3D.new()
var _horse := BoxShape3D.new()
var _shield := BoxShape3D.new()
var _clear_shape := CapsuleShape3D.new()

func _init(world: SubViewport) -> void:
	_world = world
	_human.radius = 0.30
	_human.height = 1.80
	_horse.size = Vector3(0.72,1.22,1.80)
	_shield.size = Vector3(0.62,0.88,0.08)
	_clear_shape.radius = 0.36
	_clear_shape.height = 1.80

static func _team(key: Variant) -> bool:
	return V.integer(key,0,V.MAX_U32) or (key is String and not key.is_empty())

func stage(rows: Array) -> Dictionary:
	if _staged:
		return R.fail("Conflict","field.bodies")
	return _stage(rows,rows.size()==_committed_order.size())

func _stage(rows: Array, same_order: bool) -> Dictionary:
	var next := _committed.duplicate() if same_order else {}
	var ordered := _committed_order.duplicate() if same_order else []
	var changed := []
	for i in rows.size():
		var row: Variant = rows[i]
		var slot: Variant = _committed_order[i] if same_order else null
		if same_order and slot.source!=null and is_same(row,slot.source):
			continue
		if not row is Dictionary:
			return R.fail("InvalidArgument","field.body")
		var h: Variant = row.get("handle")
		var previous_row: Variant
		if h is Dictionary and h.get("index") is int:
			if same_order and h.index!=slot.handle.index:
				# The full snapshot path also checks for duplicate indices after a reorder.
				return _stage(rows,false)
			previous_row = _committed.get(h.index)
			if previous_row != null and is_same(previous_row.source,row):
				if next.has(h.index):
					return R.fail("Conflict","field.body.handle")
				next[h.index] = previous_row
				ordered.append(previous_row)
				continue
		if not _team(row.get("team_key")) or not row.get("position") is Vector3 or not row.position.is_finite():
			return R.fail("InvalidArgument","field.body")
		if not h is Dictionary or h.size()!=2 or not V.integer(h.get("index"),0,V.MAX_U32) or not V.integer(h.get("generation"),1,V.MAX_U32):
			return R.fail("InvalidArgument","field.body.handle")
		if not same_order and next.has(h.index):
			return R.fail("Conflict","field.body.handle")
		var previous: int = _generations.get(h.index,0)
		if h.generation < previous or (h.generation == previous and not _committed.has(h.index)):
			return R.fail("StaleVersion","field.body.generation")
		var kind: Variant = row.get("type","human")
		var facing: Variant = row.get("facing",Vector3.FORWARD)
		var mounted: Variant = row.get("mounted",false)
		var shield: Variant = row.get("shield",false)
		if kind not in ["human","mount"] or not mounted is bool or not shield is bool or not facing is Vector3 or not facing.is_finite():
			return R.fail("InvalidArgument","field.body.pose")
		var planar := Vector3(facing.x,0,facing.z)
		if planar.is_zero_approx():
			return R.fail("InvalidArgument","field.body.facing")
		var owned: Dictionary
		planar = planar.normalized()
		if previous_row != null and h.generation == previous:
			if not is_same(previous_row.team_key,row.team_key) or previous_row.type != kind:
				return R.fail("Conflict","field.body.identity")
			if previous_row.position==row.position and previous_row.facing==planar and previous_row.mounted==mounted and previous_row.shield==shield:
				if not same_order:
					next[h.index] = previous_row
					ordered.append(previous_row)
				continue
			owned = previous_row.handle
		else:
			owned = h.duplicate()
			owned.make_read_only()
		# Only the closed immutable shape can be retained. Other caller data stays detached.
		var reusable: bool = row.is_read_only() and h.is_read_only() and row.size()==BODY_FIELDS.size() and row.has_all(BODY_FIELDS)
		next[h.index] = {"handle":owned,"position":row.position,"facing":planar,
			"team_key":row.team_key,"type":kind,"mounted":mounted,"shield":shield,"source":row if reusable else null}
		if same_order:
			ordered[i] = next[h.index]
			changed.append(h.index)
		else:
			ordered.append(next[h.index])
	_staged_order = ordered
	_changed_slots = changed
	_same_order = same_order
	_sync(next)
	_staged = true
	return R.ok()

func commit() -> Dictionary:
	if not _staged:
		return R.fail("InvalidState","field.bodies")
	for index in (_changed_slots if _same_order else _current.keys()):
		_generations[index] = _current[index].handle.generation
	_committed = _current
	_committed_order = _staged_order
	_staged_order = []
	_changed_slots = []
	_staged = false
	return R.ok()

func rollback() -> Dictionary:
	if _staged:
		_sync(_committed)
		_staged_order = []
		_changed_slots = []
		_staged = false
	return R.ok()

func _body(shape: Shape3D, at: Vector3, h: Dictionary, region: String) -> StaticBody3D:
	var node := StaticBody3D.new()
	node.collision_layer = BODY_LAYER
	node.collision_mask = 0
	node.set_meta("entity_handle","field/%d/%d" % [h.index,h.generation])
	node.set_meta("region",region)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = at
	node.add_child(collider)
	_targets[node.get_instance_id()] = h
	return node

func _remove(index: int) -> void:
	var proxy: Dictionary = _bodies[index]
	_targets.erase(proxy.body.get_instance_id())
	if proxy.shield != null:
		_targets.erase(proxy.shield.get_instance_id())
	proxy.body.free()
	_bodies.erase(index)

func _place(index: int, row: Dictionary) -> void:
	var horse: bool = row.type == "mount"
	var lifted: float = SADDLE_M if row.mounted and not horse else 0.0
	if not _bodies.has(index):
		var body := _body(_horse if horse else _human,Vector3.UP*(0.8 if horse else 0.9),row.handle,"body")
		var shield: StaticBody3D
		if row.shield and not horse:
			shield = _body(_shield,Vector3.ZERO,row.handle,"shield")
			shield.position = Vector3(0,1.12,-0.38)
			body.add_child(shield)
		_world.add_child(body)
		_bodies[index] = {"body":body,"shield":shield}
	var proxy: Dictionary = _bodies[index]
	proxy.body.transform = Transform3D(Basis.looking_at(row.facing),row.position + Vector3.UP*lifted)
	# SceneTree normally flushes these notifications after the fixed-step callback.
	proxy.body.force_update_transform()
	if proxy.shield != null:
		proxy.shield.force_update_transform()

func _sync(next: Dictionary) -> void:
	if not _same_order:
		for index in _current:
			if not next.has(index):
				_remove(index)
	for index in (_changed_slots if _same_order else next.keys()):
		var row: Dictionary = next[index]
		var old: Dictionary = _current.get(index,{})
		if is_same(old,row):
			continue
		if not old.is_empty() and (old.handle != row.handle or old.type != row.type or old.shield != row.shield):
			_remove(index)
		_place(index,row)
	_current = next

func tag_hit(collider: CollisionObject3D, point: Vector3, hit: Dictionary) -> void:
	var handle: Variant = _targets.get(collider.get_instance_id())
	hit.target = handle
	if handle == null or hit.region == "shield" or _current[handle.index].type == "mount":
		return
	var height: float = point.y - collider.global_position.y
	hit.region = "head" if height >= 1.48 else ("limb" if height < 0.72 else "body")

func los(from_m: Vector3, to_m: Vector3) -> bool:
	if not from_m.is_finite() or not to_m.is_finite():
		return false
	if from_m == to_m:
		return true
	var ray := PhysicsRayQueryParameters3D.create(from_m + EYE,to_m + EYE,ENVIRONMENT)
	ray.hit_from_inside = true
	return _world.world_3d.direct_space_state.intersect_ray(ray).is_empty()

static func _cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x/ENEMY_CLEARANCE_M),floori(position.z/ENEMY_CLEARANCE_M))

static func _enemy_near(grid: Dictionary, position: Vector3, team: Variant) -> bool:
	var cell := _cell(position)
	for x in range(-1,2):
		for z in range(-1,2):
			for other in grid.get(cell + Vector2i(x,z),[]):
				if not is_same(other.team_key,team) and position.distance_squared_to(other.position) <= ENEMY_CLEARANCE_M*ENEMY_CLEARANCE_M:
					return true
	return false

func clearance(sites: Array) -> Dictionary:
	var grid := {}
	for row in _current.values():
		var cell := _cell(row.position)
		if not grid.has(cell):
			grid[cell] = []
		grid[cell].append(row)
	var space := _world.world_3d.direct_space_state
	var check := PhysicsShapeQueryParameters3D.new()
	check.shape = _clear_shape
	var clear := []
	for site in sites:
		if not site is Dictionary or not _team(site.get("team_key")) or not Queries._vector(site.get("spawn_position_mm")):
			return R.fail("InvalidArgument","field.spawn_site")
		var p := Queries._meters(site.spawn_position_mm)
		check.transform = Transform3D(Basis.IDENTITY,p + Vector3.UP*0.94)
		clear.append(not _enemy_near(grid,p,site.team_key) and space.intersect_shape(check,1).is_empty())
	return R.ok(clear)
