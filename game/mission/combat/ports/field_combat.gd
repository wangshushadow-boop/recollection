extends "res://mission/combat/melee.gd"
## Authority-side assembly port. Actor rows and fixed ticks are inherited from melee.
const Sweeps = preload("res://mission/combat/field_sweeps.gd")
const MAX_NEIGHBORS := 4
const NEIGHBOR_MM := 8000
const MAX_SOURCES := 16
const SPREAD_TICKS := 15
const ROUTE_AT := 25
const REGROUP_AT := 55
const MAX_VIEW_ACTORS := 4096
const MAX_VIEW_SHOTS := 4096
var _scope_id: String
# Actor rows use copy-on-write. A previous projection stays valid while its row is identical.
var _view_cache := {}
var _shots := {}
var _ride_paths := {}
var _pending_spread := {}
var _sampling := {}
var _vital_changes := {}
# Sparse MOV projections share immutable maps across forks until a link or shield changes.
var _mounts := {}
var _shielded := {}


func _init(scope_id: String = "") -> void:
	_scope_id = scope_id


func fork():
	var copy = super.fork()
	copy._scope_id = _scope_id
	copy._view_cache = _view_cache.duplicate()
	copy._shots = _shots.duplicate()
	copy._ride_paths = _ride_paths.duplicate()
	copy._pending_spread = _pending_spread.duplicate()
	copy._vital_changes = _vital_changes.duplicate()
	_mounts.make_read_only()
	_shielded.make_read_only()
	copy._mounts = _mounts
	copy._shielded = _shielded
	return copy


func add_actor(handle: Dictionary, hp: Variant = 100, weapon_slot: Variant = 0, max_targets: Variant = 1) -> Dictionary:
	if not V.integer(weapon_slot,0,0):
		return R.fail("InvalidArgument","weapon_slot")
	return enlist(handle,{"team":0,"role":"infantry","hp":hp,"max_targets":max_targets})


func enlist(handle: Dictionary, profile: Dictionary) -> Dictionary:
	var role: Variant = profile.get("role")
	if not V.integer(profile.get("team"), 0, V.MAX_U32) or typeof(role) != TYPE_STRING or role not in ["infantry","archer","cavalry","mount"]:
		return R.fail("InvalidArgument", "profile")
	for field in ["hp","max_targets","shield","ammo","morale"]:
		var minimum := 1 if field in ["hp","max_targets"] else 0
		var maximum := 100 if field == "morale" else 1000000
		if profile.has(field) and not V.integer(profile[field], minimum, maximum):
			return R.fail("InvalidArgument", field)
	if typeof(profile.get("commander",false)) != TYPE_BOOL:
		return R.fail("InvalidArgument", "commander")
	var armor: Variant = profile.get("armor",{})
	if typeof(armor) != TYPE_DICTIONARY:
		return R.fail("InvalidArgument", "armor")
	for region in armor:
		if region not in ["head","body","limb"] or not V.integer(armor[region], 0, 100000):
			return R.fail("InvalidArgument", "armor")
	var weapons := ["melee"]
	if role == "archer" or profile.has("ranged"):
		var ranged: Variant = profile.get("ranged","bow")
		if typeof(ranged) != TYPE_STRING or not Sweeps.RANGE_PER_TICK.has(ranged):
			return R.fail("InvalidArgument","ranged")
		weapons.append(ranged)
	var result := super.add_actor(handle, profile.get("hp",100), 1 if role == "archer" else 0, profile.get("max_targets",1))
	if not result.ok:
		return result
	var morale: int = profile.get("morale",70)
	var routing: bool = role != "mount" and morale <= ROUTE_AT
	_actors[handle.index].merge({"team":profile.team, "role":role, "weapons":weapons, "shield":profile.get("shield",0),
		"ammo":profile.get("ammo",8), "armor":armor.duplicate(), "reload_until":0, "mount_handle":null, "rider_handle":null,
		"morale":morale, "routing":routing, "commander":profile.get("commander",false), "last_spread":-SPREAD_TICKS})
	if routing:
		_pending_spread[handle.index] = {"handle":_actors[handle.index].handle, "initial":true}
	_vital_changes[handle.index] = true
	if _actors[handle.index].shield > 0:
		if _shielded.is_read_only():
			_shielded = _shielded.duplicate()
		_shielded[handle.index] = true
	return R.ok()


func mount(rider: Dictionary, horse: Dictionary) -> Dictionary:
	if _querying:
		return R.fail("InvalidState","collision_query")
	var a := _actor(rider, _actors)
	var b := _actor(horse, _actors)
	if a.is_empty() or b.is_empty():
		return R.fail("NotFound","actor_handle")
	if a.role != "cavalry" or b.role != "mount" or a.team != b.team or a.phase == "Downed" or b.phase == "Downed" or a.routing or b.routing:
		return R.fail("InvalidState", "mount")
	if a.mount_handle != null or b.rider_handle != null:
		return R.fail("Conflict", "mount")
	a = a.duplicate()
	b = b.duplicate()
	a.mount_handle = b.handle
	b.rider_handle = a.handle
	_actors[rider.index] = a
	_actors[horse.index] = b
	_ride_paths[horse.index] = {}
	if _mounts.is_read_only():
		_mounts = _mounts.duplicate()
	_mounts[rider.index] = b.handle
	return R.ok()


func _unlink(rider: Dictionary, horse: Dictionary, fallen: bool) -> void:
	var a: Dictionary = _actors[rider.index].duplicate()
	var b: Dictionary = _actors[horse.index].duplicate()
	a.mount_handle = null
	b.rider_handle = null
	if fallen and a.phase != "Downed":
		_enter(a, "Stagger", _tick)
		_track_phase(_timed, rider.index, a.phase)
	_actors[rider.index] = a
	_actors[horse.index] = b
	_ride_paths.erase(horse.index)
	if _mounts.is_read_only():
		_mounts = _mounts.duplicate()
	_mounts.erase(rider.index)


func dismount(rider: Dictionary) -> Dictionary:
	if _querying:
		return R.fail("InvalidState","collision_query")
	var state := _actor(rider,_actors)
	if state.is_empty():
		return R.fail("NotFound","actor_handle")
	if state.get("mount_handle") == null:
		return R.fail("InvalidState","mount")
	_unlink(rider,state.mount_handle,false)
	return R.ok()


func remove_actor(handle: Dictionary) -> Dictionary:
	if _querying:
		return R.fail("InvalidState","collision_query")
	var state := _actor(handle,_actors)
	if state.get("mount_handle") != null:
		_unlink(handle,state.mount_handle,false)
	elif state.get("rider_handle") != null:
		_unlink(state.rider_handle,handle,true)
	var removed := super.remove_actor(handle)
	if removed.ok:
		_view_cache.erase(handle.index)
		_vital_changes.erase(handle.index)
		_remove_shield(handle.index)
	return removed


func _remove_shield(index: int) -> void:
	if _shielded.has(index):
		if _shielded.is_read_only():
			_shielded = _shielded.duplicate()
		_shielded.erase(index)


func field_motion_traits(scope_id: String) -> Dictionary:
	if scope_id.is_empty() or scope_id != _scope_id:
		return R.fail("NotFound", "combat_scope")
	_mounts.make_read_only()
	_shielded.make_read_only()
	return R.ok({"mounts":_mounts, "shielded":_shielded})


static func _vitals(state: Dictionary) -> Dictionary:
	var row := {"handle":state.handle, "hp":state.hp, "ammo":state.ammo, "morale":state.morale}
	row.make_read_only()
	return row


# Roster bootstrap reads current authority, including actors that did not change this tick.
func field_ai_vitals(scope_id: String, handles: Array) -> Dictionary:
	if scope_id.is_empty() or scope_id != _scope_id:
		return R.fail("NotFound", "combat_scope")
	if handles.size() > MAX_VIEW_ACTORS:
		return R.fail("InvalidArgument", "view_limit")
	var rows := []
	var seen := {}
	for handle in handles:
		if typeof(handle) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument", "actor_handle")
		var state := _actor(handle, _actors)
		if state.is_empty():
			return R.fail("NotFound", "actor_handle")
		if seen.has(handle.index):
			return R.fail("Conflict", "actor_handle")
		seen[handle.index] = true
		rows.append(_vitals(state))
	return R.ok({"actors":rows})


# Non-draining. A rejected/retried field tick sees the same last successful combat changes.
func field_ai_changes(scope_id: String) -> Dictionary:
	if scope_id.is_empty() or scope_id != _scope_id:
		return R.fail("NotFound", "combat_scope")
	var rows := []
	for index in _vital_changes:
		rows.append(_vitals(_actors[index]))
	return R.ok({"actors":rows})


# Local authority assembly read. Poses come from MOV. Shots retain their own IDs after the shooter retires.
func field_view(scope_id: String, handles: Array, projectile_limit: Variant = 1024) -> Dictionary:
	if scope_id.is_empty() or scope_id != _scope_id:
		return R.fail("NotFound", "combat_scope")
	if handles.size() > MAX_VIEW_ACTORS or not V.integer(projectile_limit, 0, MAX_VIEW_SHOTS):
		return R.fail("InvalidArgument", "view_limit")
	var actors := []
	var seen := {}
	for handle in handles:
		if typeof(handle) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument", "actor_handle")
		var state := _actor(handle, _actors)
		if state.is_empty():
			return R.fail("NotFound", "actor_handle")
		if seen.has(handle.index):
			return R.fail("Conflict", "actor_handle")
		seen[handle.index] = true
		actors.append(_actor_view(state))
	var projectiles := []
	for id: String in _shots:
		if projectiles.size() == projectile_limit:
			break
		var shot: Dictionary = _shots[id]
		var item := {"id":id, "position":Sweeps.v3(shot.position)*0.001, "direction":Sweeps.v3(shot.velocity).normalized()}
		item.make_read_only()
		projectiles.append(item)
	actors.make_read_only()
	projectiles.make_read_only()
	var view_data := {"scope_id":scope_id, "tick":_tick, "actors":actors, "projectiles":projectiles, "projectile_count":_shots.size()}
	view_data.make_read_only()
	return R.ok(view_data)


func _actor_view(state: Dictionary) -> Dictionary:
	var index: int = state.handle.index
	var cached: Variant = _view_cache.get(index)
	if cached != null and is_same(state, cached[0]):
		return cached[1]
	var item := {"handle":state.handle, "team":state.team, "role":state.role,
		"phase":state.phase, "since":state.since, "direction":state.direction,
		"weapon_slot":state.weapon_slot, "mount_handle":state.mount_handle, "hp":state.hp,
		"routing":state.routing, "morale":state.morale, "ammo":state.ammo, "shield":state.shield}
	item.make_read_only()
	_view_cache[index] = [state, item]
	return item


func has_pending_projectiles() -> bool:
	return not _shots.is_empty()


func _needs_sweep() -> bool:
	return super._needs_sweep() or not _ride_paths.is_empty()


func _query_active(tick: int, active: Array, states: Dictionary, query: Callable) -> Variant:
	_sampling = states
	var result: Variant = super._query_active(tick, active, states, query)
	_sampling = {}
	return result


func step(tick: Variant, intents: Array, query_contacts: Callable = Callable()) -> Dictionary:
	var opening := _actors
	var result := super.step(tick, intents, query_contacts)
	if not result.ok:
		return result
	_vital_changes = {}
	for i in intents.size():
		var intent: Dictionary = intents[i]
		if intent.get("input_phase") == "release" and result.value.receipts[i].ok:
			var index: int = intent.actor_handle.index
			if _actors[index].ammo != opening[index].ammo:
				_vital_changes[index] = true
	for hit: Dictionary in result.value.hits:
		if hit.damage > 0:
			_vital_changes[hit.target.index] = true
		if hit.get("shield_broken",false):
			_remove_shield(hit.target.index)
	return result


func step_field(tick: Variant, intents: Array, poses: Dictionary, sweep: Callable, morale_events: Array = []) -> Dictionary:
	if _querying:
		return R.fail("InvalidState","collision_query")
	var morale := {}
	for event in morale_events:
		if typeof(event) != TYPE_DICTIONARY or typeof(event.get("actor_handle")) != TYPE_DICTIONARY or not V.integer(event.get("delta"),-100,100):
			return R.fail("InvalidArgument","morale_event")
		var state := _actor(event.actor_handle,_actors)
		if state.is_empty():
			return R.fail("NotFound","morale_event")
		morale[state.handle.index] = clampi(morale.get(state.handle.index,0) + event.delta,-100,100)
	var flights := _shots.duplicate()
	var rides := _ride_paths.duplicate()
	var events := []
	var result := step(tick, intents, func(t, active): return Sweeps.collect(t,active,_sampling,poses,sweep,flights,events,rides))
	if not result.ok:
		return result
	_shots = flights
	_ride_paths = rides
	var downed := {}
	for hit: Dictionary in result.value.hits:
		var victim: Dictionary = _actors[hit.target.index]
		if hit.get("shield_broken",false):
			events.append({"type":"shield_broken", "actor_handle":victim.handle})
		if hit.damage <= 0:
			continue
		morale[victim.handle.index] = int(morale.get(victim.handle.index,0)) - mini(20,hit.damage)
		if victim.phase == "Downed" and not downed.has(victim.handle.index):
			downed[victim.handle.index] = true
			events.append({"type":"downed", "actor_handle":victim.handle})
			if victim.mount_handle != null or victim.rider_handle != null:
				var rider: Dictionary = victim.handle if victim.mount_handle != null else victim.rider_handle
				var horse: Dictionary = victim.handle if victim.rider_handle != null else victim.mount_handle
				_unlink(rider,horse,victim.rider_handle != null)
				events.append({"type":"dismounted","actor_handle":rider,"mount_handle":horse})
	_resolve_morale(tick, morale, downed, poses, events)
	result.value["events"] = events.duplicate(true)
	result.value["projectiles"] = flights.size()
	return result


func _change_morale(index: int, delta: int, events: Array) -> bool:
	var state: Dictionary = _actors[index]
	if state.phase == "Downed" or state.role == "mount":
		return false
	var value := clampi(state.morale + delta, 0, 100)
	var routing: bool = value <= ROUTE_AT or (state.routing and value < REGROUP_AT)
	if state.morale == value and state.routing == routing:
		return false
	var changed: bool = state.routing != routing
	state = state.duplicate()
	state.morale = value
	state.routing = routing
	if changed:
		if routing:
			_enter(state,"Ready",_tick)
			_track_phase(_timed, index, state.phase)
		events.append({"type":"routed" if routing else "regrouped", "actor_handle":state.handle, "morale":value})
	_actors[index] = state
	_vital_changes[index] = true
	return changed and routing


func _resolve_morale(tick: int, morale: Dictionary, downed: Dictionary, poses: Dictionary, events: Array) -> void:
	if tick % 60 == 0:
		for state: Dictionary in _actors.values():
			if not state.routing and state.morale != 70:
				var index: int = state.handle.index
				morale[index] = morale.get(index,0) + signi(70-state.morale)
	var sources := {}
	var affected := morale.keys()
	affected.sort()
	for index in affected:
		if _change_morale(index,morale[index],events):
			sources[index] = true
	for index in _pending_spread:
		var state: Dictionary = _actors.get(index,{})
		var pending: Dictionary = _pending_spread[index]
		if state.get("handle") == pending.handle and (state.routing or state.phase == "Downed"):
			sources[index] = true
			if pending.get("initial",false) and state.routing:
				events.append({"type":"routed","actor_handle":state.handle,"morale":state.morale})
	_pending_spread = {}
	sources.merge(downed)
	if sources.is_empty():
		return
	# Index allies once when a loss or routing transition actually occurs.
	var grid := {}
	var positions := {}
	for index in poses:
		var pose: Variant = poses[index]
		if not _actors.has(index) or typeof(pose) != TYPE_DICTIONARY or not Sweeps.vector(pose.get("position_mm"),1000000000):
			continue
		var pos := Sweeps.v3(pose.position_mm)
		positions[index] = pos
		var cell := Vector2i(floori(pos.x / NEIGHBOR_MM), floori(pos.z / NEIGHBOR_MM))
		if not grid.has(cell):
			grid[cell] = []
		grid[cell].append(index)
	var ordered := sources.keys()
	ordered.sort()
	for index in ordered.slice(MAX_SOURCES):
		_pending_spread[index] = {"handle":_actors[index].handle}
	for index in ordered.slice(0, MAX_SOURCES):
		if not positions.has(index):
			continue
		var source: Dictionary = _actors[index]
		var pos: Vector3 = positions[index]
		var cell := Vector2i(floori(pos.x / NEIGHBOR_MM), floori(pos.z / NEIGHBOR_MM))
		var nearby := []
		for dx in range(-1,2):
			for dz in range(-1,2):
				nearby.append_array(grid.get(cell + Vector2i(dx,dz),[]))
		nearby.sort()
		var count := 0
		for other in nearby:
			var ally: Dictionary = _actors[other]
			if other == index or ally.team != source.team or ally.role == "mount" or ally.phase == "Downed" or tick-ally.last_spread < SPREAD_TICKS:
				continue
			if pos.distance_squared_to(positions[other]) > NEIGHBOR_MM*NEIGHBOR_MM:
				continue
			ally = ally.duplicate()
			ally.last_spread = tick
			_actors[other] = ally
			if _change_morale(other,-12 if source.commander else -6,events):
				_pending_spread[other] = {"handle":ally.handle}
			events.append({"type":"morale_spread","actor_handle":ally.handle,"source":source.handle})
			count += 1
			if count == MAX_NEIGHBORS:
				break
