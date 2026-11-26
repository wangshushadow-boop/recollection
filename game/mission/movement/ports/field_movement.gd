extends RefCounted
## One MOV owner per Mission. Formation slots, headings and positions are in metres.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const Queue = preload("res://mission/movement/path_queue.gd")
const IntentRoute = preload("res://mission/movement/intent_route.gd")
const JumpMotion = preload("res://mission/movement/jump_motion.gd")
const Schema = preload("res://contracts/schema.gd")
const CELL := 1.2
const NEIGHBOURS := 48
const QUERIES_PER_TICK := 8
# Legacy hurtboxes use layer 2, scoped field bodies use layer 30. MOV resolves actors in its own grid.
const SCENERY_MASK := 0xffffffff ^ 2 ^ (1 << 29)

class Drive:
	var handle: Dictionary
	var context: Variant
	var direction: Vector3
	var fraction: float

class DriveBlock:
	var index: int
	var other_position: Vector3
	var origin: Vector3
	var candidate: Vector3
	var radii: float

class Body:
	var index: int
	var last_drive_block: DriveBlock
	var birth: RefCounted
	var generation: int
	var profile: String
	var profile_tick := -1
	var airborne := false
	var position: Vector3
	var velocity := Vector3.ZERO
	var heading: Vector3
	var radius: float
	var group := ""
	var route_key: Variant = ""
	var offset := Vector3.ZERO
	var revision := -1
	var cursor := 1
	var arrived := false
	var blocked := ""
	var wait := 0.0
	var path := PackedVector3Array()
	var ticket := {}
	var access_version := -1
	var join_index := 0
	var passages: Array = []
	var courtesy := Vector3.ZERO
	var courtesy_time := 0.0
	var drive: Drive
	var leg: IntentRoute
	var leg_cursor := 0
	var revoked := false
	var scene_travel := 0.0
	var assignment_stamp: RefCounted
	var grid_cell := Vector2i.ZERO
	var grid_order := 0

	func copy_from(other: Body, with_drives: bool) -> void:
		var new_birth := not is_same(birth,other.birth)
		if new_birth:
			index = other.index
			birth = other.birth
			generation = other.generation
		if new_birth or not is_same(assignment_stamp,other.assignment_stamp):
			profile = other.profile
			profile_tick = other.profile_tick
			radius = other.radius
			assignment_stamp = other.assignment_stamp
			group = other.group
			route_key = other.route_key
			offset = other.offset
			revision = other.revision
			path = other.path
			ticket = other.ticket
			access_version = other.access_version
			join_index = other.join_index
			passages = other.passages
		position = other.position
		airborne = other.airborne
		velocity = other.velocity
		heading = other.heading
		cursor = other.cursor
		arrived = other.arrived
		blocked = other.blocked
		wait = other.wait
		courtesy = other.courtesy
		courtesy_time = other.courtesy_time
		if with_drives:
			last_drive_block = other.last_drive_block
			drive = other.drive
			leg = other.leg
			leg_cursor = other.leg_cursor
			revoked = other.revoked

class Corridor:
	var origin: Vector3
	var goal: Vector3
	var profile: String
	var ticket := {}
	var points := PackedVector3Array()
	var reachable := false
	var version := -1

class Roster:
	var weak_token: WeakRef
	var indices := PackedInt64Array()
	var births: Array[RefCounted] = []
	var stamps: Array = [null,null]
	var rows: Array = [[],[]]

# Logical lineup is shared by equal rosters; a stamp names one exact body
# buffer. Rebuilding a buffer after rollback must invalidate its cached rows.
var _lineup := RefCounted.new()
var _buffer_stamp := RefCounted.new()
var _buffer_slot := 0
var _bindings := {}
var _stage: RefCounted
var _stage_tick := -1
var _stage_ready := false
var _busy := false
var _draft: Variant
var _engine: RefCounted
var _scope: String
var _queue: RefCounted
var _access: RefCounted
var _direct: RefCounted
var _authorize: Callable
var _drivers := {}
var _airborne_count := 0
var _launches := {}
var _had_drives := false
var _members_ready := false
var _next_driver := 0
var _exact_sweeps_until := -1
var _lowest_leg_y := INF
var _highest_leg_y := -INF
var _legs_clear_scenery := false
var _bodies := {}
var _retired := {}
var _routes := {}
var _zones: Array = []
var _cells := {}
var _cells_lineup: RefCounted
var _unsorted_cells := {}
var _tick := -1
var _revision := -1
var _serial := 0
var _checks := 0
var _yields := 0
var _blocker: Body

func _init(engine: RefCounted, mission_id: String, move_authority := Callable()) -> void:
	_engine = engine
	_scope = mission_id
	_queue = Queue.new(engine, mission_id)
	_access = Queue.new(engine, mission_id)
	_direct = Queue.new(engine,mission_id)
	_authorize = move_authority

static func _valid_handle(handle: Dictionary) -> bool:
	return handle.size() == 2 and V.integer(handle.get("index"), 0, V.MAX_U32) and V.integer(handle.get("generation"), 1, V.MAX_U32)

func _body(handle: Dictionary) -> Body:
	if not _valid_handle(handle):
		return null
	var b: Body = _bodies.get(handle.index)
	return b if b != null and b.generation == handle.generation else null

static func _point_ok(p: Vector3) -> bool:
	return p.is_finite() and maxf(absf(p.x), maxf(absf(p.y),absf(p.z))) <= 2147483.0

static func _mm(p: Vector3) -> Array:
	return [roundi(p.x * 1000), roundi(p.y * 1000), roundi(p.z * 1000)]

static func _radius(profile: String) -> float:
	return 0.47 if profile == "mounted" else 0.28

func spawn(handle: Dictionary, position: Vector3, profile: String = "foot", heading: Vector3 = Vector3.FORWARD, stage: Variant = null) -> Dictionary:
	if stage != null or _stage != null or _busy:
		if not _editable(stage): return R.fail("InvalidState","movement_stage")
		return _draft.spawn(handle,position,profile,heading)
	var flat := Vector3(heading.x, 0, heading.z)
	if not _valid_handle(handle) or not _point_ok(position) or profile not in ["foot","mounted"] or not heading.is_finite() or flat.is_zero_approx():
		return R.fail("InvalidArgument", "movement_spawn")
	if _bodies.has(handle.index) or handle.generation <= _retired.get(handle.index, 0):
		return R.fail("Conflict", "movement_handle")
	var b := Body.new()
	b.index = handle.index
	b.birth = RefCounted.new()
	b.generation = handle.generation
	b.profile = profile
	b.radius = _radius(profile)
	b.position = position
	b.heading = flat.normalized()
	_bodies[handle.index] = b
	_lineup = b.birth
	_buffer_stamp = _lineup
	return R.ok()

## COM can dismount a rider in damage, after this step's motion already ran.
## Keep that displacement and use the new footprint and route from now on.
func set_profile(handle: Dictionary, profile: String, stage: Variant) -> Dictionary:
	if _busy or _stage==null or not is_same(stage,_stage):
		return R.fail("InvalidState","movement_stage")
	if profile not in ["foot","mounted"] or not _valid_handle(handle):
		return R.fail("InvalidArgument","movement_profile")
	var b: Body = _draft._body(handle)
	if b==null: return R.fail("NotFound","movement_handle")
	if b.profile==profile: return R.ok()
	if b.airborne: return R.fail("InvalidState","airborne")
	b.assignment_stamp = RefCounted.new()
	b.profile = profile
	b.profile_tick = _stage_tick
	b.radius = _radius(profile)
	if profile=="foot": b.velocity = b.velocity.limit_length(3.4)
	if not b.group.is_empty():
		var shared: Corridor = _draft._routes[b.group]
		b.route_key = b.group if shared.profile==profile else [b.group,profile]
		if not _draft._routes.has(b.route_key):
			_draft._routes[b.route_key] = _corridor(shared.origin,shared.goal,profile)
	b.revision = -1
	b.access_version = -1
	b.ticket = {}
	b.path = PackedVector3Array()
	b.passages = []
	b.leg = null
	b.leg_cursor = 0
	b.courtesy_time = 0.0
	b.wait = 0.0
	b.blocked = ""
	b.arrived = false
	_draft._members_ready = false
	return R.ok()

func despawn(handle: Dictionary, stage: Variant = null) -> Dictionary:
	if stage != null or _stage != null or _busy:
		if not _editable(stage): return R.fail("InvalidState","movement_stage")
		return _draft.despawn(handle)
	var b := _body(handle)
	if b == null:
		return R.fail("NotFound", "movement_handle")
	if b.airborne: _airborne_count -= 1
	_retired[handle.index] = handle.generation
	_bodies.erase(handle.index)
	_drivers.erase(handle.index)
	_lineup = RefCounted.new()
	_buffer_stamp = _lineup
	return R.ok()

## Authored bounds of a bottleneck. The short horizontal axis is its width.
func set_terrain(zones: Array, stage: Variant = null) -> Dictionary:
	if stage != null or _stage != null or _busy:
		if not _editable(stage): return R.fail("InvalidState","movement_stage")
		return _draft.set_terrain(zones)
	for zone in zones:
		if typeof(zone) != TYPE_DICTIONARY or typeof(zone.get("bounds")) != TYPE_AABB or typeof(zone.get("profiles")) != TYPE_ARRAY:
			return R.fail("InvalidArgument", "terrain")
		var bounds: AABB = zone.bounds
		if not _point_ok(bounds.position) or not _point_ok(bounds.end) or not bounds.has_volume():
			return R.fail("InvalidArgument", "terrain_bounds")
		for profile in zone.profiles:
			if profile not in ["foot", "mounted"]:
				return R.fail("InvalidArgument", "terrain_profile")
	_zones = zones.duplicate(true)
	_members_ready = false
	var stamp := RefCounted.new()
	for b: Body in _bodies.values():
		b.assignment_stamp = stamp
		b.revision = -1
		b.access_version = -1
		b.leg = null
	return R.ok()

func set_corridor(group: String, origin: Vector3, goal: Vector3, profile: String = "foot", stage: Variant = null) -> Dictionary:
	if stage != null or _stage != null or _busy:
		if not _editable(stage): return R.fail("InvalidState","movement_stage")
		return _draft.set_corridor(group,origin,goal,profile)
	if group.is_empty() or not _point_ok(origin) or not _point_ok(goal) or profile not in ["foot","mounted"]:
		return R.fail("InvalidArgument", "corridor")
	var old: Corridor = _routes.get(group)
	if old != null:
		if old.profile != profile:
			return R.fail("Conflict", "corridor_profile")
		if old.origin.is_equal_approx(origin) and old.goal.is_equal_approx(goal):
			return R.ok()
	_routes[group] = _corridor(origin,goal,profile)
	var other := "foot" if profile=="mounted" else "mounted"
	var alternate := [group,other]
	if _routes.has(alternate):
		_routes[alternate] = _corridor(origin,goal,other)
	return R.ok()

static func _corridor(origin: Vector3,goal: Vector3,profile: String) -> Corridor:
	var route := Corridor.new()
	route.origin = origin
	route.goal = goal
	route.profile = profile
	return route

func assign(handle: Dictionary, group: String, slot_offset: Vector3 = Vector3.ZERO, stage: Variant = null) -> Dictionary:
	if stage != null or _stage != null or _busy:
		if not _editable(stage): return R.fail("InvalidState","movement_stage")
		return _draft.assign(handle,group,slot_offset)
	var b := _body(handle)
	var route: Corridor = _routes.get(group)
	if b == null or route == null:
		return R.fail("NotFound", "movement_assignment")
	var key: Variant = group
	if b.profile!=route.profile:
		if b.group!=group: return R.fail("InvalidArgument","movement_slot")
		key = b.route_key
	if not _point_ok(slot_offset) or not is_zero_approx(slot_offset.y):
		return R.fail("InvalidArgument", "movement_slot")
	if b.group != group or b.offset != slot_offset:
		_members_ready = false
		b.assignment_stamp = RefCounted.new()
		b.group = group
		b.route_key = key
		b.offset = slot_offset
		b.revision = -1
		b.access_version = -1
		b.arrived = false
	return R.ok()

func view(handle: Dictionary, stage: Variant = null) -> Dictionary:
	if stage != null:
		if _busy or not is_same(stage,_stage): return R.fail("InvalidState","movement_stage")
		return _draft.view(handle)
	var b := _body(handle)
	if b == null:
		return R.fail("NotFound", "movement_handle")
	return R.ok({"position":b.position, "velocity":b.velocity, "heading":b.heading,
		"profile":b.profile, "arrived":b.arrived, "blocked":b.blocked,"airborne":b.airborne})

## Tickets bind each index to a particular spawn, including abandoned draft births.
func bind_roster(handles: Array, stage: Variant = null) -> Dictionary:
	if stage != null and (_busy or not is_same(stage,_stage)):
		return R.fail("InvalidState","movement_stage")
	var bodies: Dictionary = _bodies if stage == null else _draft._bodies
	var seen := {}
	var roster := Roster.new()
	for handle in handles:
		if typeof(handle) != TYPE_DICTIONARY or not _valid_handle(handle):
			return R.fail("InvalidArgument","movement_handle")
		var b: Body = bodies.get(handle.index)
		if b == null or b.generation != handle.generation: return R.fail("NotFound","movement_handle")
		if seen.has(handle.index): return R.fail("Conflict","movement_handle")
		seen[handle.index] = true
		roster.indices.append(handle.index)
		roster.births.append(b.birth)
	for id in _bindings.keys():
		if _bindings[id].weak_token.get_ref() == null: _bindings.erase(id)
	var token := RefCounted.new()
	roster.weak_token = weakref(token)
	_bindings[token.get_instance_id()] = roster
	return R.ok(token)

func read_positions(token: Variant, stage: Variant = null) -> Dictionary:
	return _read_roster(token,stage,false)

func read_poses(token: Variant, stage: Variant = null) -> Dictionary:
	return _read_roster(token,stage,true)

func _read_roster(token: Variant, stage: Variant, full: bool) -> Dictionary:
	if stage != null and (_busy or not is_same(stage,_stage)): return R.fail("InvalidState","movement_stage")
	if not token is RefCounted or not is_instance_valid(token): return R.fail("NotFound","roster")
	var roster: Roster = _bindings.get(token.get_instance_id())
	if roster == null or not is_same(roster.weak_token.get_ref(),token): return R.fail("NotFound","roster")
	var slot: int = _buffer_slot if stage == null else _draft._buffer_slot
	var stamp: RefCounted = _buffer_stamp if stage == null else _draft._buffer_stamp
	var count := roster.indices.size()
	if not is_same(roster.stamps[slot],stamp):
		var bodies: Dictionary = _bodies if stage == null else _draft._bodies
		var resolved: Array[Body] = []
		for i in count:
			var b: Body = bodies.get(roster.indices[i])
			if b == null or not is_same(b.birth,roster.births[i]): return R.fail("NotFound","movement_handle")
			resolved.append(b)
		roster.rows[slot] = resolved
		roster.stamps[slot] = stamp
	var rows: Array = roster.rows[slot]
	var positions := PackedVector3Array()
	var velocities := PackedVector3Array()
	var headings := PackedVector3Array()
	positions.resize(count)
	if full:
		velocities.resize(count)
		headings.resize(count)
	for i in count:
		var b: Body = rows[i]
		positions[i] = b.position
		if full:
			velocities[i] = b.velocity
			headings[i] = b.heading
	return R.ok({"positions":positions,"velocities":velocities,"headings":headings}) if full else R.ok(positions)

func _editable(stage: Variant) -> bool:
	return _stage != null and is_same(stage,_stage) and not _stage_ready and not _busy

func request_jump(handle: Dictionary,context: Variant,stage: Variant) -> Dictionary:
	if not _editable(stage): return R.fail("InvalidState","movement_stage")
	var b: Body = _draft._body(handle)
	if b==null: return R.fail("NotFound","movement_handle")
	if b.airborne or b.profile!="foot" or b.profile_tick==_stage_tick:
		return R.fail("InvalidState","jump_profile")
	_busy = true
	var launch := R.fail("Unauthorized","movement_control")
	if _authorized(handle,context,_stage_tick):
		var sweep: Callable = _engine.query_sweep_batch.bind({"scope_id":_scope,"tick":_stage_tick})
		launch = JumpMotion.can_launch(b.position,b.radius,SCENERY_MASK,sweep)
	_busy = false
	if not launch.ok: return launch
	_launches[handle.index] = {"handle":handle.duplicate(),"context":context}
	_draft._airborne_count += 1
	b.airborne = true
	b.arrived = false
	b.velocity.y = JumpMotion.SPEED
	return R.ok()

## Both controllers use a composition-owned authority reader; the caller's context
## is only a credential. Movement reuse is permitted only for the same actor birth.
func apply_move_intent(stage: Variant, intent: Dictionary, context: Variant) -> Dictionary:
	if not _editable(stage): return R.fail("InvalidState","movement_stage")
	# The local MOV hot path consumes the v1 domain value directly. Only the four
	# typed fields below are accepted, so no wire encoding or deep freeze is needed.
	if intent.size()!=4 or not intent.has("stance") or not intent.get("actor_handle") is Dictionary or not _valid_handle(intent.actor_handle):
		return R.fail("InvalidArgument","MoveIntent")
	for key in intent:
		if typeof(key)!=TYPE_STRING: return R.fail("InvalidArgument","MoveIntent")
	for key in intent.actor_handle:
		if typeof(key)!=TYPE_STRING: return R.fail("InvalidArgument","actor_handle")
	var vector: Variant = intent.get("desired_direction")
	var speed: Variant = intent.get("speed_fraction")
	if not vector is Array or vector.size()!=3 or not V.integer(vector[0],-2147483648,2147483647) or not V.integer(vector[1],0,0) or not V.integer(vector[2],-2147483648,2147483647):
		return R.fail("InvalidArgument","desired_direction")
	if typeof(speed) not in [TYPE_FLOAT,TYPE_INT] or not is_finite(speed) or speed<0 or speed>1:
		return R.fail("InvalidArgument","speed_fraction")
	var stance: Variant = intent.stance
	if stance!=null and (typeof(stance)!=TYPE_STRING or stance not in ["walk","sprint","crouch"]):
		return R.fail("InvalidArgument","stance")
	var b: Body = _draft._body(intent.actor_handle)
	if b==null: return R.fail("NotFound","movement_handle")
	var direction := Vector3(vector[0],0,vector[2]).normalized()
	var quantized := roundi(speed*Schema.SPEED_SCALE)
	if direction==Vector3.ZERO and quantized>0: return R.fail("InvalidArgument","movement_direction")
	var drive := Drive.new()
	drive.handle = intent.actor_handle.duplicate()
	drive.handle.make_read_only()
	_busy = true
	var permitted := _authorized(drive.handle,context,_stage_tick)
	_busy = false
	if not permitted: return R.fail("Unauthorized","movement_control")
	drive.context = context
	drive.direction = direction
	var gait := .45 if stance=="crouch" else (.75 if stance=="walk" else 1.0)
	drive.fraction = quantized/float(Schema.SPEED_SCALE)*gait
	if b.drive==null:
		b.passages = []
		b.assignment_stamp = RefCounted.new()
	_draft._had_drives = true
	b.drive = drive
	b.revoked = false
	_draft._drivers[drive.handle.index] = true
	return R.ok()

func _authorized(handle: Dictionary, context: Variant, tick: int) -> bool:
	return _authorize.is_valid() and is_same(_authorize.call(_scope,handle,context,tick),true)

## Early phases can deploy and assign into this stage before the movement phase.
func begin_step(tick: int) -> Dictionary:
	if _busy or _stage != null: return R.fail("InvalidState","movement_stage")
	if tick < 0 or tick <= _tick: return R.fail("StaleVersion","tick")
	if _draft == null: _draft = get_script().new(_engine,_scope,_authorize)
	var available: Dictionary = _draft._bodies
	var with_drives: bool = _had_drives or _draft._had_drives
	_draft._had_drives = _had_drives
	_draft._members_ready = _members_ready
	_draft._buffer_slot = 1-_buffer_slot
	if is_same(_draft._lineup,_lineup):
		var grid_ready := is_same(_cells_lineup,_lineup) and is_same(_draft._cells_lineup,_lineup)
		if not grid_ready: _draft._cells_lineup = null
		for id in _bodies:
			var copy: Body = available[id]
			var source: Body = _bodies[id]
			copy.copy_from(source,with_drives)
			if grid_ready and copy.grid_cell!=source.grid_cell: _draft._relocate(copy,source.grid_cell)
	else:
		# Preserve insertion order for avoidance. Reuse body objects; path data
		# is shared read-only until the path changes.
		var next := {}
		for id in _bodies:
			var copy: Body = available.get(id)
			if copy == null: copy = Body.new()
			copy.copy_from(_bodies[id],with_drives)
			next[id] = copy
		_draft._bodies = next
		_draft._cells_lineup = null
		_draft._lineup = _lineup
		_draft._buffer_stamp = RefCounted.new()
	_draft._routes = {}
	for key in _routes:
		var from: Corridor = _routes[key]
		var route := Corridor.new()
		route.origin = from.origin
		route.goal = from.goal
		route.profile = from.profile
		route.ticket = from.ticket
		route.points = from.points
		route.reachable = from.reachable
		route.version = from.version
		_draft._routes[key] = route
	_draft._retired = _retired.duplicate()
	_draft._zones = _zones
	_draft._revision = _revision
	_draft._serial = _serial
	_draft._tick = _tick
	_draft._queue = _queue.fork()
	_draft._access = _access.fork()
	_draft._direct = _direct.fork()
	_draft._drivers = _drivers.duplicate()
	_draft._airborne_count = _airborne_count
	_launches = {}
	_draft._next_driver = _next_driver
	_draft._exact_sweeps_until = _exact_sweeps_until
	_draft._lowest_leg_y = _lowest_leg_y
	_draft._highest_leg_y = _highest_leg_y
	_stage = RefCounted.new()
	_stage_tick = tick
	return R.ok(_stage)

func stage_step(tick: int, dt: float, stage: Variant = null) -> Dictionary:
	if _busy or _stage_ready or (stage != null and not is_same(stage,_stage)):
		return R.fail("InvalidState","movement_stage")
	if _stage == null:
		var start := begin_step(tick)
		if not start.ok: return start
	if tick != _stage_tick: return R.fail("StaleVersion","tick")
	_busy = true
	var result: Dictionary = _draft._run_step(tick,dt)
	_busy = false
	if not result.ok:
		rollback_step(_stage)
		return result
	_stage_ready = true
	result.value["stage_token"] = _stage
	return result

func commit_step(stage: Variant) -> Dictionary:
	if _busy or not _stage_ready or not is_same(stage,_stage): return R.fail("InvalidState","movement_stage")
	# The control snapshot can change after staging. Check every active drive
	# before the first published write, blocking nested stage edits from readers.
	_busy = true
	for grant in _launches.values():
		if _draft._body(grant.handle)!=null and not _authorized(grant.handle,grant.context,_stage_tick):
			_busy=false
			rollback_step(stage)
			return R.fail("Unauthorized","movement_control")
	for id in _draft._drivers:
		var b: Body = _draft._bodies[id]
		if not _authorized(b.drive.handle,b.drive.context,_stage_tick):
			_busy = false
			rollback_step(stage)
			return R.fail("Unauthorized","movement_control")
	_busy = false
	var previous := _bodies
	_bodies = _draft._bodies
	_draft._bodies = previous
	var old_cells := _cells
	var old_cells_lineup := _cells_lineup
	var old_unsorted := _unsorted_cells
	_cells = _draft._cells
	_cells_lineup = _draft._cells_lineup
	_unsorted_cells = _draft._unsorted_cells
	_draft._cells = old_cells
	_draft._cells_lineup = old_cells_lineup
	_draft._unsorted_cells = old_unsorted
	var old_lineup := _lineup
	var old_stamp := _buffer_stamp
	_lineup = _draft._lineup
	_buffer_stamp = _draft._buffer_stamp
	_buffer_slot = _draft._buffer_slot
	_draft._lineup = old_lineup
	_draft._buffer_stamp = old_stamp
	_routes = _draft._routes
	_retired = _draft._retired
	_zones = _draft._zones
	_revision = _draft._revision
	_serial = _draft._serial
	_tick = _draft._tick
	_queue = _draft._queue
	_access = _draft._access
	_direct = _draft._direct
	_drivers = _draft._drivers
	_airborne_count = _draft._airborne_count
	_launches = {}
	_had_drives = _draft._had_drives
	_members_ready = _draft._members_ready
	_next_driver = _draft._next_driver
	_exact_sweeps_until = _draft._exact_sweeps_until
	_lowest_leg_y = _draft._lowest_leg_y
	_highest_leg_y = _draft._highest_leg_y
	_stage = null
	_stage_ready = false
	return R.ok(_tick)

func rollback_step(stage: Variant) -> Dictionary:
	if _busy or _stage == null or not is_same(stage,_stage): return R.fail("InvalidState","movement_stage")
	_stage = null
	_launches = {}
	_stage_ready = false
	return R.ok()

func _remaining_queries(tick: int) -> int:
	return QUERIES_PER_TICK - _queue.attempts_at(tick) - _access.attempts_at(tick) - _direct.attempts_at(tick)

func _prepare(tick: int) -> Dictionary:
	var sync: Dictionary = _engine.sync_navigation(_scope)
	if not sync.ok:
		return sync
	if sync.value.status != "applied":
		return R.fail("Unavailable", "navigation_sync")
	var revision: int = sync.value.applied_revision
	for route: Corridor in _routes.values():
		if _revision != revision:
			route.ticket = {}
			route.version = -1
		if route.version >= 0 or not route.ticket.is_empty():
			continue
		var q: Dictionary = _queue.request_path(_mm(route.origin), _mm(route.goal), route.profile)
		if q.ok:
			route.ticket = q.value
		elif q.error.code != "Unavailable":
			return q
	_revision = revision
	var spent: Dictionary = _queue.process_budget(tick, _remaining_queries(tick))
	if not spent.ok:
		return spent
	for route: Corridor in _routes.values():
		if route.version >= 0 or route.ticket.is_empty():
			continue
		var result: Dictionary = _queue.poll_path(route.ticket)
		if not result.ok:
			if result.error.code == "NotFound":
				route.ticket = {}
			elif result.error.code != "Unavailable":
				return result
			continue
		route.points = PackedVector3Array()
		for point in result.value.points:
			route.points.append(Vector3(point[0],point[1],point[2]) * 0.001)
		route.reachable = result.value.reachable and not route.points.is_empty()
		_serial += 1
		route.version = _serial
		_members_ready = false
	return spent

func _needs_leg(b: Body) -> bool:
	return b.leg==null or b.leg.revision!=_revision or (b.drive.fraction>0 and (
		(b.leg.direction.dot(b.drive.direction)<.99985 and not _braking_turn(b)) or (b.leg_cursor>=b.leg.points.size() and b.leg.continues)))

func _braking_turn(b: Body) -> bool:
	return b.profile=="mounted" and b.velocity.length_squared()>.000001 and b.leg_cursor<b.leg.points.size() and b.leg.direction.dot(b.drive.direction)<.99985

func _prepare_drives(tick: int) -> Dictionary:
	var ids := _drivers.keys()
	var jobs := []
	var available := _remaining_queries(tick)
	var unused := available
	var replay: bool = _direct.attempts_at(tick)>0
	for offset in ids.size():
		if jobs.size()>=QUERIES_PER_TICK or (unused<=0 and not replay): break
		var index := (_next_driver+offset)%ids.size()
		var b: Body = _bodies[ids[index]]
		if b.airborne or b.drive.fraction<=0 or not _needs_leg(b): continue
		var goal := b.position+b.drive.direction*IntentRoute.RANGE
		var origin_mm := _mm(b.position)
		var goal_mm := _mm(goal)
		if not replay or not _direct.has_answer(tick,_revision,origin_mm,goal_mm,b.profile):
			if unused<=0: continue
			unused -= 1
		var request: Dictionary = _direct.request_drive_path(origin_mm,goal_mm,b.profile)
		if not request.ok: return request
		jobs.append({"body":b,"path":request.value,"index":index})
	if jobs.is_empty(): return R.ok()
	var spent: Dictionary = _direct.process_budget(tick,available)
	if not spent.ok: return spent
	for job in jobs:
		var path: Variant = job.path.cached
		if path==null or job.path.ticket.nav_revision!=spent.value.nav_revision:
			var solved: Dictionary = _direct.poll_path(job.path.ticket)
			if not solved.ok:
				if solved.error.code=="Unavailable": continue
				return solved
			path=solved.value
		var b: Body = job.body
		var leg := IntentRoute.new()
		leg.revision = _revision
		leg.direction = b.drive.direction
		var checked := leg.from_path(b.position,path)
		if not checked.ok: return checked
		b.leg = leg
		b.leg_cursor = 0
		# Direct ground motion stays on these segments. Landing clears the leg.
		_lowest_leg_y = minf(_lowest_leg_y,b.position.y)
		_highest_leg_y = maxf(_highest_leg_y,b.position.y)
		for point in leg.points:
			_lowest_leg_y = minf(_lowest_leg_y,point.y)
			_highest_leg_y = maxf(_highest_leg_y,point.y)
		_next_driver = (job.index+1)%ids.size()
	return R.ok()

static func _scene_cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x/8),floori(p.y/2),floori(p.z/8))

func _occupied_scene_cells(tick: int) -> Dictionary:
	if _drivers.size()<64 or tick<_exact_sweeps_until: return R.ok(null)
	var cells := {}
	for id in _drivers:
		var b: Body = _bodies[id]
		cells[_scene_cell(b.position)] = true
	var keys := cells.keys()
	if keys.size()*3>=_drivers.size():
		_exact_sweeps_until = tick+30
		return R.ok(null)
	var queries := []
	for key: Vector3i in keys:
		var center := Vector3(key)*Vector3(8,2,8)+Vector3(4,1,4)
		# The sphere encloses the entire 8x2x8 cell, the tallest probe lift,
		# mounted radius and the largest allowed step (9 m/s for 0.1 s).
		queries.append({"from":_mm(center),"to":_mm(center+Vector3.UP*.01),"radius_mm":7650,"mask":SCENERY_MASK})
	var hits: Dictionary = _engine.query_sweep_batch(queries,{"scope_id":_scope,"tick":tick})
	if not hits.ok: return hits
	cells.clear()
	for hit in hits.value:
		if not V.integer(hit.get("query_index"),0,keys.size()-1): return R.fail("InvalidState","movement_sweep")
		cells[keys[hit.query_index]] = true
	# On collider-covered ground the broad test rarely saves work.
	if cells.size()*2>=keys.size(): _exact_sweeps_until = tick+30
	return R.ok(cells)

func _scene_clearances(tick: int, dt: float) -> Dictionary:
	var floor_top := INF
	if _drivers.size()>=64 and _engine.has_method("field_scenery_top"):
		floor_top = _engine.field_scenery_top(_scope,SCENERY_MASK)
	# Each probe bottom starts 40 mm above its segment. Allow the 3 mm minimum
	# probe to overshoot a short leg, plus float error and the 30 mm contact margin.
	_legs_clear_scenery = is_finite(floor_top) and _lowest_leg_y+0.005>floor_top and _lowest_leg_y > -1022.0 and _highest_leg_y < 1022.0
	if _legs_clear_scenery: return R.ok()
	var broad := R.ok(null) if is_finite(floor_top) else _occupied_scene_cells(tick)
	if not broad.ok: return broad
	var requests := []
	var actors: Array[Body] = []
	var lengths := PackedFloat32Array()
	for id in _drivers:
		var b: Body = _bodies[id]
		if b.airborne: continue
		if broad.value!=null and not broad.value.has(_scene_cell(b.position)):
			b.scene_travel = INF
			continue
		b.scene_travel = 0.0
		if _needs_leg(b) or b.leg_cursor>=b.leg.points.size(): continue
		if b.drive.fraction<=0 and (b.profile=="foot" or b.velocity.is_zero_approx()): continue
		var delta := b.leg.points[b.leg_cursor]-b.position
		if delta.length_squared()<.000001: continue
		var extent := minf(delta.length(),(9.0 if b.profile=="mounted" else 3.4)*dt)
		var origin := b.position+Vector3.UP*(b.radius+.04)
		var probe := maxf(extent,.003)
		var end := origin+delta.normalized()*probe
		# The whole swept sphere clears the slab, including its side faces.
		# Leave 30 mm for quantization and the physics backend's contact tolerance.
		if minf(origin.y,end.y)-b.radius > floor_top+0.030 and maxf(absf(origin.y),absf(end.y))<1024.0:
			b.scene_travel = extent
			continue
		requests.append({"from":_mm(origin),"to":_mm(end),"radius_mm":roundi(b.radius*1000),"mask":SCENERY_MASK})
		actors.append(b)
		lengths.append(probe)
		b.scene_travel = extent
	if requests.is_empty(): return R.ok()
	# A door or a new collision-only scene can change without changing the nav map.
	var hits: Dictionary = _engine.query_sweep_batch(requests,{"scope_id":_scope,"tick":tick})
	if not hits.ok: return hits
	for hit in hits.value:
		if not V.integer(hit.get("query_index"),0,actors.size()-1) or not V.integer(hit.get("fraction_ppm"),0,1000000):
			return R.fail("InvalidState","movement_sweep")
		var index: int = hit.query_index
		var b := actors[index]
		b.scene_travel = minf(b.scene_travel,maxf(0,lengths[index]*hit.fraction_ppm*.000001-.025))
	return R.ok()

# Admission to a shared corridor must start on the member's own island. Solve
# only at assignment/revision changes, with the remainder of the same tick budget.
func _members(tick: int, remaining: int) -> Dictionary:
	if _members_ready: return R.ok()
	var pending: Array[Body] = []
	var full := false
	var stamp := RefCounted.new()
	for b: Body in _bodies.values():
		if b.drive!=null or b.revoked or b.airborne: continue
		var route: Corridor = _routes.get(b.route_key)
		if route == null or route.version < 0 or not route.reachable or b.revision == route.version:
			continue
		b.assignment_stamp = stamp
		if b.access_version != route.version:
			b.ticket = {}
			b.access_version = route.version
			var nearest := INF
			b.join_index = 0
			for i in range(1, route.points.size()):
				var a := route.points[i-1]
				var end := route.points[i]
				var projection := Geometry3D.get_closest_point_to_segment(b.position,a,end) if a != end else end
				var dist := b.position.distance_squared_to(projection)
				if dist < nearest:
					nearest = dist
					b.join_index = i
			# A member already on this exact navigation segment can use its suffix.
			if nearest < 0.000001 and (b.join_index+1 < route.points.size() or b.offset.is_zero_approx()):
				_set_path(b,route,PackedVector3Array())
				continue
		if b.ticket.is_empty():
			if full:
				continue
			var join := route.points[b.join_index]
			if b.join_index+1 == route.points.size():
				join += b.offset
			var request: Dictionary = _access.request_path(_mm(b.position),_mm(join),b.profile)
			if not request.ok:
				if request.error.code == "Unavailable":
					full = true
					continue
				return request
			b.ticket = request.value
		pending.append(b)
	var spent: Dictionary = _access.process_budget(tick,remaining)
	if not spent.ok:
		return spent
	_members_ready = not full and spent.value.pending==0
	for b in pending:
		var result: Dictionary = _access.poll_path(b.ticket)
		if not result.ok:
			_members_ready = false
			if result.error.code == "NotFound":
				b.ticket = {}
			elif result.error.code != "Unavailable":
				return result
			continue
		var route: Corridor = _routes[b.route_key]
		var points: Array = result.value.points
		b.path = PackedVector3Array()
		b.revision = route.version
		if not result.value.reachable or points.is_empty():
			continue
		var first: Array = points[0]
		if b.position.distance_to(Vector3(first[0],first[1],first[2])*0.001) > 0.015:
			continue
		var access_points := PackedVector3Array()
		for index in range(1,points.size()-1):
			var raw: Array = points[index]
			access_points.append(Vector3(raw[0],raw[1],raw[2])*0.001)
		_set_path(b,route,access_points)
	return spent

func _set_path(b: Body, route: Corridor, approach: PackedVector3Array) -> void:
	b.path = approach
	for i in range(b.join_index,route.points.size()):
		var point := route.points[i]
		if i+1 == route.points.size():
			point += b.offset
		b.path.append(point)
	b.revision = route.version
	b.cursor = 0
	b.passages = []
	var start := b.position
	for zone in _zones:
		var bounds: AABB = zone.bounds
		var axis := 0 if bounds.size.x >= bounds.size.z else 2
		var side := 2-axis
		for point in b.path:
			if bounds.intersects_segment(start,point) != null or bounds.has_point(start):
				var sign_travel := signf(point[axis]-start[axis])
				if sign_travel == 0.0:
					start = point
					continue
				var two_lanes := bounds.size[side] >= b.radius*4.2
				var offset := sign_travel * bounds.size[side]*0.25 if two_lanes else 0.0
				b.passages.append({"bounds":bounds,"axis":axis,"side":side,"lane":bounds.get_center()[side]+offset,"direction":sign_travel,"two":two_lanes})
				break
			start = point
		start = b.position

static func _cell(point: Vector3) -> Vector2i:
	return Vector2i(floori(point.x / CELL), floori(point.z / CELL))

func _put(cell: Vector2i, b: Body) -> void:
	if not _cells.has(cell):
		_cells[cell] = []
	_cells[cell].append(b)

func _relocate(b: Body, cell: Vector2i) -> void:
	var old: Array = _cells[b.grid_cell]
	old.erase(b)
	if old.is_empty(): _cells.erase(b.grid_cell)
	_put(cell,b)
	if _cells[cell].size()>1: _unsorted_cells[cell] = true
	b.grid_cell = cell

static func _spawn_order(a: Body,b: Body) -> bool:
	return a.grid_order<b.grid_order

func _prepare_grid(bodies: Array) -> void:
	if not is_same(_cells_lineup,_lineup):
		_cells.clear()
		for i in bodies.size():
			var b: Body = bodies[i]
			b.grid_order = i
			b.grid_cell = _cell(b.position)
			_put(b.grid_cell,b)
		_cells_lineup = _lineup
	else:
		# Match the previous full rebuild's spawn order for equal-cell blockers.
		for cell in _unsorted_cells:
			if _cells.has(cell): _cells[cell].sort_custom(_spawn_order)
	_unsorted_cells.clear()

func _clear_step(b: Body, candidate: Vector3) -> bool:
	_blocker = null
	for zone in _zones:
		var bounds: AABB = zone.bounds
		var too_narrow := minf(bounds.size.x,bounds.size.z)<2*b.radius
		if (too_narrow or not zone.profiles.has(b.profile)) and (bounds.has_point(b.position) or bounds.intersects_segment(b.position, candidate) != null):
			return false
		if bounds.has_point(candidate):
			var x_long := bounds.size.x >= bounds.size.z
			var side := candidate.z if x_long else candidate.x
			var lo := bounds.position.z if x_long else bounds.position.x
			var width := bounds.size.z if x_long else bounds.size.x
			if side < lo + b.radius or side > lo + width - b.radius:
				return false
	for passage in b.passages:
		var box: AABB = passage.bounds
		var axis: int = passage.axis
		var side: int = passage.side
		if candidate[axis] >= box.position[axis] and candidate[axis] <= box.end[axis] and candidate.y >= box.position.y and candidate.y <= box.end.y:
			if candidate[side] < box.position[side]+b.radius or candidate[side] > box.end[side]-b.radius:
				return false
			if passage.two and absf(candidate[side]-passage.lane) > box.size[side]*0.25-b.radius:
				return false
		elif passage.two and candidate[axis] > box.position[axis]-3.0 and candidate[axis] < box.end[axis]+3.0:
			# Keep the exit clear while the opposite queue aligns at the entrance.
			var center := box.get_center()[side]
			var facing: float = passage.direction
			var previous_side := (b.position[side]-center)*facing
			var proposed_side := (candidate[side]-center)*facing
			if proposed_side < b.radius and proposed_side <= previous_side:
				return false
	var reach := Vector3(b.radius+0.47,0,b.radius+0.47)
	var first := _cell(b.position.min(candidate)-reach)
	var last := _cell(b.position.max(candidate)+reach)
	var motion := candidate-b.position
	var length_sq := motion.length_squared()
	var inspected := 0
	for x in range(first.x,last.x+1):
		for z in range(first.y,last.y+1):
			var group: Variant = _cells.get(Vector2i(x,z))
			if group == null:
				continue
			for other: Body in group:
				if other == b:
					continue
				inspected += 1
				_checks += 1
				var threshold := b.radius + other.radius
				var separation := b.position-other.position
				var approaching := -separation.dot(motion)
				if approaching > 0.0 and (separation + motion*minf(approaching/length_sq,1.0)).length_squared() < threshold*threshold:
					_blocker = other
					return false
				if inspected >= NEIGHBOURS:
					# Dense cells yield rather than advance into an unchecked neighbour.
					return false
	return true

func _waypoint(b: Body, p: Vector3, final: bool) -> Vector3:
	var target := p
	for passage in b.passages:
		var bounds: AABB = passage.bounds
		var axis: int = passage.axis
		var side: int = passage.side
		if not final and p[axis] >= bounds.position[axis]-3.5 and p[axis] <= bounds.end[axis]+3.5:
			var apron := maxf(0,maxf(bounds.position[axis]-p[axis],p[axis]-bounds.end[axis]))
			target[side] = passage.lane + passage.direction * minf(1.0,apron*0.36)
	for zone in _zones:
		var bounds: AABB = zone.bounds
		if bounds.grow(0.01).has_point(p):
			if bounds.size.x >= bounds.size.z:
				target.z = clampf(target.z, bounds.position.z+b.radius, bounds.end.z-b.radius)
				target.x = p.x
			else:
				target.x = clampf(target.x, bounds.position.x+b.radius, bounds.end.x-b.radius)
				target.z = p.z
	return target

func _move(b: Body, route: Corridor, dt: float) -> void:
	b.blocked = ""
	if route == null or route.version < 0 or not route.reachable or route.version != b.revision or b.path.is_empty():
		b.velocity = Vector3.ZERO
		b.arrived = false
		b.blocked = "no_route"
		return
	b.arrived = false
	var target := b.path[b.cursor]
	if not _zones.is_empty(): target = _waypoint(b,target,b.cursor+1==b.path.size())
	while b.position.distance_to(target) < 0.36 and b.cursor+1 < b.path.size():
		b.cursor += 1
		target = b.path[b.cursor]
		if not _zones.is_empty(): target = _waypoint(b,target,b.cursor+1==b.path.size())
	_advance(b,target,dt,1.0,false)

func _move_direct(b: Body, dt: float) -> void:
	b.arrived = false
	b.blocked = ""
	if b.drive==null or _needs_leg(b) or b.leg_cursor>=b.leg.points.size():
		b.velocity = Vector3.ZERO
		b.blocked = "control_revoked" if b.revoked else ("no_route" if b.drive.fraction>0 else "")
		return
	var target := b.leg.points[b.leg_cursor]
	var fraction := 0.0 if _braking_turn(b) else b.drive.fraction
	_advance(b,target,dt,fraction,true)
	if b.position.distance_squared_to(target)<.000001: b.leg_cursor += 1

func _advance(b: Body, target: Vector3, dt: float, fraction: float, direct: bool) -> void:
	var delta := target - b.position
	if not direct and b.courtesy_time > 0.0:
		b.courtesy_time -= dt
		delta = b.courtesy
		b.arrived = false
	var distance := delta.length()
	if not direct and distance < 0.06 and b.cursor+1 == b.path.size():
		b.arrived = true
		b.velocity = Vector3.ZERO
		return
	var direction := delta.normalized()
	var flat := Vector3(direction.x,0,direction.z).normalized()
	var speed := 3.4*fraction
	if b.profile == "mounted":
		var previous_speed := b.velocity.length()
		var angle := b.heading.signed_angle_to(flat, Vector3.UP) if not flat.is_zero_approx() else 0.0
		var limit := 3.0 * dt / (1.0 + 0.22 * previous_speed)
		b.heading = b.heading.rotated(Vector3.UP,clampf(angle,-limit,limit)).normalized()
		var desired_speed := minf(9.0*fraction, sqrt(2.0 * 8.0 * distance))
		desired_speed *= maxf(0.0, b.heading.dot(flat))
		speed = move_toward(previous_speed, desired_speed, (8.0 if previous_speed > desired_speed else 4.0) * dt)
		if direct:
			# Turn on the certified strip; a turning arc outside it has no navigation proof.
			if b.heading.dot(flat)<.999: speed = 0
		else:
			direction = (b.heading * Vector2(direction.x,direction.z).length() + Vector3.UP * direction.y).normalized()
	elif not flat.is_zero_approx():
		b.heading = flat
	var travel := minf(distance, speed*dt)
	if direct:
		var limit := b.scene_travel
		if _legs_clear_scenery:
			limit = minf(distance,(9.0 if b.profile=="mounted" else 3.4)*dt)
			if delta.length_squared()<.000001 or (b.drive.fraction<=0 and (b.profile=="foot" or b.velocity.is_zero_approx())):
				limit = 0.0
		if travel>limit:
			travel = limit
			b.blocked = "scene"
	var candidate := b.position + direction * travel
	for passage in b.passages:
		var box: AABB = passage.bounds
		var axis: int = passage.axis
		var side: int = passage.side
		var entered := candidate[axis] >= box.position[axis] and candidate[axis] <= box.end[axis]
		var outside := b.position[axis] < box.position[axis] or b.position[axis] > box.end[axis]
		if outside and entered and absf(candidate[side]-passage.lane) > 0.03:
			candidate = b.position
			candidate[side] = move_toward(candidate[side],passage.lane,travel)
	# Direct movement needs only a yes/no answer. An intersecting live blocker
	# guarantees a yield even when earlier neighbours or the inspection cap changed.
	var blocked_again := false
	var witness := b.last_drive_block
	if direct and witness!=null:
		if b.position==witness.origin and candidate==witness.candidate:
			var prior: Body = _bodies.get(witness.index)
			blocked_again = prior!=null and prior.position==witness.other_position and b.radius+prior.radius==witness.radii
		if not blocked_again: b.last_drive_block=null
	if blocked_again or not _clear_step(b,candidate):
		b.wait += dt
		b.blocked = "yield"
		_yields += 1
		var obstruction := _blocker
		if direct and not blocked_again and obstruction!=null:
			witness = DriveBlock.new()
			witness.index = obstruction.index
			witness.other_position = obstruction.position
			witness.origin = b.position
			witness.candidate = candidate
			witness.radii = b.radius+obstruction.radius
			b.last_drive_block = witness
		candidate = b.position
		if not direct and b.profile == "foot" and b.wait > 0.20:
			var right := direction.cross(Vector3.UP).normalized()
			if obstruction != null and obstruction.profile == "foot" and obstruction.courtesy_time <= 0.0 and (b.cursor+1 == b.path.size() or b.heading.dot(obstruction.heading) < -0.5):
				# Settled ranks also yield. The recipient moves on its own bounded step.
				var away := obstruction.position-b.position
				var lateral := right if away.dot(right) >= 0.0 else -right
				obstruction.courtesy = (lateral + direction*0.2).normalized()
				obstruction.courtesy_time = 0.38
			for sign_value: float in [1.0,-1.0]:
				var aside := b.position + (right*sign_value + direction*0.2).normalized()*travel*0.5
				if _clear_step(b,aside):
					candidate = aside
					break
	else:
		b.wait = 0.0
	b.velocity = (candidate-b.position) / dt
	b.position = candidate
	var new_cell := _cell(b.position)
	if b.grid_cell != new_cell: _relocate(b,new_cell)

func step(tick: int, dt: float) -> Dictionary:
	if _busy or _stage != null: return R.fail("InvalidState","movement_stage")
	if not _drivers.is_empty() or _airborne_count>0:
		var staged := stage_step(tick,dt)
		if not staged.ok: return staged
		var published := commit_step(staged.value.stage_token)
		if not published.ok: return published
		staged.value.erase("stage_token")
		return staged
	_busy = true
	var result := _run_step(tick,dt)
	_busy = false
	return result

func _run_step(tick: int, dt: float) -> Dictionary:
	if _engine == null or tick < 0 or not is_finite(dt) or dt <= 0 or dt > 0.1:
		return R.fail("InvalidArgument", "movement_step")
	if tick <= _tick:
		return R.fail("StaleVersion", "tick")
	var ready := _prepare(tick)
	if not ready.ok:
		return ready
	var joins := _members(tick, _remaining_queries(tick))
	if not joins.ok:
		return joins
	if not _drivers.is_empty():
		var drives := _prepare_drives(tick)
		if not drives.ok: return drives
		var clearances := _scene_clearances(tick,dt)
		if not clearances.ok: return clearances
	_tick = tick
	_checks = 0
	_yields = 0
	var bodies := _bodies.values()
	_prepare_grid(bodies)
	if not _had_drives and _airborne_count==0:
		for b: Body in bodies:
			_move(b, _routes.get(b.route_key), dt)
	else:
		for b: Body in bodies:
			if b.drive!=null and not _authorized(b.drive.handle,b.drive.context,tick):
				_drivers.erase(b.drive.handle.index)
				b.drive = null
				b.leg = null
				b.revoked = true
			if b.airborne:
				var moved := _move_airborne(b,dt,tick)
				if not moved.ok: return moved
			elif b.drive!=null or b.revoked:
				_move_direct(b,dt)
			else:
				_move(b, _routes.get(b.route_key), dt)
	var shared: int = _queue.attempts_at(tick)
	var members: int = _access.attempts_at(tick)
	var direct: int = _direct.attempts_at(tick)
	return R.ok({"queried":shared,"member_queried":members,"intent_queried":direct,
		"total_queried":shared+members+direct,"nav_revision":_revision,
		"neighbour_checks":_checks,"yielding":_yields})

func _move_airborne(b: Body,dt: float,tick: int) -> Dictionary:
	var desired: Variant = null if b.drive==null else b.drive.direction*(b.drive.fraction*3.4)
	var sweep: Callable = _engine.query_sweep_batch.bind({"scope_id":_scope,"tick":tick})
	var flight := JumpMotion.advance(b.position,b.velocity,desired,dt,b.radius,SCENERY_MASK,sweep,
		func(next: Vector3): return _clear_step(b,next))
	if not flight.ok: return flight
	b.position = flight.value.position
	b.velocity = flight.value.velocity
	b.blocked = flight.value.blocked
	var cell := _cell(b.position)
	if cell!=b.grid_cell: _relocate(b,cell)
	if flight.value.landed:
		b.airborne=false
		_airborne_count -= 1
		b.assignment_stamp=RefCounted.new()
		b.revision=-1
		b.access_version=-1
		b.leg=null
		_members_ready=false
	return R.ok()
