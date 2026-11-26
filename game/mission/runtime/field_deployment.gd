extends RefCounted

const R = preload("res://contracts/result.gd")
const Canon = preload("res://contracts/canonical.gd")
const V = preload("res://contracts/values.gd")
const Entities = preload("res://mission/runtime/entities.gd")
const Sources = preload("res://contracts/field_sources.gd")

var _index: RefCounted
var _sides := []
var _zones := {}
var _sources := []
var _source_starts := PackedInt64Array()
var _capacity: int
var _nav_revision := -1
var _reachable := {}
var wave_size: int
var cooldown: int

static func _point(value: Variant) -> bool:
	if typeof(value) != TYPE_ARRAY or value.size() != 3:
		return false
	for v in value:
		if not V.integer(v, -2147483648, 2147483647):
			return false
	return true

static func build(spec: Dictionary, scene: Dictionary, ruleset: Dictionary) -> Dictionary:
	var indexed := Sources.build(spec)
	if not indexed.ok:
		return indexed
	var definitions: Variant = scene.get("field_zones")
	if typeof(definitions) != TYPE_ARRAY or definitions.size() != spec.sides.size():
		return R.fail("InvalidArgument","scene.field_zones")
	var size: Variant = ruleset.get("wave_size",spec.battle_limit)
	var delay: Variant = ruleset.get("wave_cooldown_ticks",60)
	if not V.integer(size,1,V.MAX_U32) or not V.integer(delay,1,V.MAX_U32):
		return R.fail("InvalidArgument","ruleset.wave")
	var director = new()
	director._capacity = spec.battle_limit
	director._index = indexed.value
	director.wave_size = mini(size,spec.battle_limit)
	director.cooldown = delay
	var all_points := {}
	var total_quota := 0
	for definition in definitions:
		if typeof(definition) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument","scene.field_zones")
		var key: Variant = definition.get("team_key")
		var points: Variant = definition.get("points_mm")
		var quota: Variant = definition.get("quota")
		if director._zones.has(key) or not _point(definition.get("rally_mm")) or typeof(points) != TYPE_ARRAY or points.is_empty() or not V.integer(quota,1,spec.battle_limit):
			return R.fail("InvalidArgument","scene.field_zones")
		var point_set := {}
		for point in points:
			if not _point(point) or all_points.has(point):
				return R.fail("Conflict","scene.field_zones.points_mm")
			var owned: Array = Entities.freeze(point)
			all_points[owned] = true
			point_set[owned] = true
		total_quota += quota
		director._zones[key] = {"quota":quota,"rally":Entities.freeze(definition.rally_mm),"points":point_set}
		if definition.has("opening_slot"):
			if not V.integer(definition.opening_slot,0,100000) or quota!=points.size():return R.fail("InvalidArgument","field.opening_slots")
			director._zones[key]["opening_slot"]=definition.opening_slot
			director._zones[key]["opening_points"]=point_set.keys()
	if total_quota > spec.battle_limit:
		return R.fail("InvalidArgument","scene.field_zones.quota")
	for side in spec.sides:
		if not director._zones.has(side.team_key):
			return R.fail("NotFound","scene.field_zones.team_key")
		var ranges := []
		for allocation in side.roster_allocations:
			ranges.append(allocation.source_slot_range)
		ranges.sort_custom(func(a,b): return a[0] < b[0])
		var zone: Dictionary=director._zones[side.team_key]
		if zone.has("opening_slot") and (ranges.is_empty() or zone.opening_slot!=ranges[0][0] or zone.opening_slot+zone.quota>ranges[0][1]):
			return R.fail("InvalidArgument","field.opening_slots")
		director._sides.append({"team":side.team_key,"ranges":ranges})
	director._sources = spec.reserved_sources.duplicate()
	director._sources.sort_custom(func(a,b): return a.source_slot_range[0] < b.source_slot_range[0])
	for row in director._sources:
		director._source_starts.append(row.source_slot_range[0])
	return R.ok(director)

func _counts(entities: RefCounted) -> Dictionary:
	var result := {}
	for row in entities.rows():
		if row.source_slot != null:
			var team: Variant = row.components.team_key
			result[team] = result.get(team,0) + 1
	return result

# First-wave preview uses the same ordered allocation ranges and side quota as auto_wave.
func opening_roles(team: Variant, kit_for: Callable) -> Dictionary:
	var counts := {}
	for side in _sides:
		if not is_same(side.team,team): continue
		var remaining: int = _zones[team].quota
		for bounds in side.ranges:
			var slot: int = bounds[0]
			var end: int = mini(bounds[1],slot+remaining)
			remaining -= end-slot
			while slot < end:
				var source: Dictionary = _sources[_source_starts.bsearch(slot,false)-1]
				var next: int = mini(end,source.source_slot_range[1])
				var role: String = kit_for.call(source).role
				counts[role] = counts.get(role,0)+next-slot
				slot = next
			if remaining==0: break
		break
	return counts

# An explicit deployment may override neither its team nor its trusted loadout.
func _bind(slot: Variant, components: Dictionary) -> Dictionary:
	var team := _index.team_for_slot(slot) as Dictionary
	if not team.ok:
		return team
	if not is_same(components.get("type","human"),"human") or not is_same(components.get("team_key",team.value),team.value):
		return R.fail("Conflict","deployment.team_key")
	var zone: Dictionary = _zones[team.value]
	if not _point(components.get("spawn_position_mm")) or not zone.points.has(components.spawn_position_mm):
		return R.fail("InvalidArgument","deployment.spawn_position_mm")
	var source: Dictionary = _sources[_source_starts.bsearch(slot,false)-1]
	var row := components.duplicate()
	row.merge({"type":"human","team_key":team.value,"source_party_id":source.source_party_id,
		"troop_def_id":source.troop_def_id,"hero_id":source.hero_id,"loadout_snapshot_id":source.loadout_snapshot_id},true)
	return R.ok(row)

# The scope adapter checks the rally-to-site path; the injected live-world query
# checks occupancy and enemy proximity. Both consume the same ordered batch.
func _check_sites(rows: Array, engine: RefCounted, scope: String, clear_sites: Callable) -> Dictionary:
	if rows.is_empty():
		return R.ok([])
	if not clear_sites.is_valid():
		return R.fail("Unavailable","field.spawn_clearance")
	var sync: Dictionary = engine.sync_navigation(scope)
	if not sync.ok:
		return sync
	if sync.value.status != "applied":
		return R.fail("Unavailable","navigation_sync")
	var paths := []
	var missing := []
	for row in rows:
		if sync.value.applied_revision != _nav_revision or not _reachable.has(row.spawn_position_mm):
			paths.append({"from":_zones[row.team_key].rally,"to":row.spawn_position_mm})
			missing.append(row.spawn_position_mm)
	if not paths.is_empty():
		var nav: Dictionary = engine.query_path_batch(paths, sync.value.applied_revision, scope)
		if not nav.ok:
			return nav
		if nav.value.size() != paths.size():
			return R.fail("InvalidState","navigation_batch")
		if sync.value.applied_revision != _nav_revision:
			_reachable.clear()
			_nav_revision = sync.value.applied_revision
		for i in missing.size():
			_reachable[missing[i]] = nav.value[i].reachable
	var sites := []
	for row in rows:
		sites.append({"team_key":row.team_key,"spawn_position_mm":row.spawn_position_mm})
	var clear: Variant = clear_sites.call(scope, Entities.freeze(sites))
	if typeof(clear) != TYPE_DICTIONARY or typeof(clear.get("ok")) != TYPE_BOOL:
		return R.fail("InvalidArgument","field.spawn_clearance")
	if not clear.ok:
		return clear
	if typeof(clear.get("value")) != TYPE_ARRAY or clear.value.size() != rows.size():
		return R.fail("InvalidArgument","field.spawn_clearance")
	var valid := []
	for i in rows.size():
		if typeof(clear.value[i]) != TYPE_BOOL:
			return R.fail("InvalidArgument","field.spawn_clearance")
		valid.append(_reachable[rows[i].spawn_position_mm] and clear.value[i])
	return R.ok(valid)

func deploy(entities: RefCounted, orders: Array, engine: RefCounted, scope: String, clear_sites: Callable) -> Dictionary:
	if orders.size() > _capacity-entities.active_sources:
		return R.fail("Unavailable","battle_limit")
	var counts := _counts(entities)
	var rows := []
	var candidates := []
	var slots := {}
	var sites := {}
	for order in orders:
		if typeof(order) != TYPE_DICTIONARY or not order.has("source_slot") or typeof(order.get("components")) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument","deployment")
		if not Canon.encode(order.components).ok:
			return R.fail("InvalidArgument","components")
		var bound := _bind(order.source_slot,order.components)
		if not bound.ok:
			return bound
		var row: Dictionary = bound.value
		var zone:Dictionary=_zones[row.team_key]
		if zone.has("opening_slot"):
			var offset:int=order.source_slot-zone.opening_slot
			if offset<0 or offset>=zone.quota or row.spawn_position_mm!=zone.opening_points[offset]:
				return R.fail("Conflict","deployment.opening_slot")
		if slots.has(order.source_slot) or entities.spawned.has(order.source_slot) or sites.has(row.spawn_position_mm):
			return R.fail("Conflict","deployment")
		slots[order.source_slot] = true
		sites[row.spawn_position_mm] = true
		var count: int = counts.get(row.team_key,0)+1
		if count > _zones[row.team_key].quota:
			return R.fail("Unavailable","team_quota")
		counts[row.team_key] = count
		var owned: Dictionary = Entities.freeze(row)
		rows.append(owned)
		candidates.append({"slot":order.source_slot,"components":owned})
	var checked := _check_sites(rows,engine,scope,clear_sites)
	if not checked.ok:
		return checked
	if false in checked.value:
		return R.fail("Unavailable","deployment.spawn_site")
	return _allocate(entities,candidates)

func _allocate(entities: RefCounted, candidates: Array) -> Dictionary:
	var staged: RefCounted = entities.fork()
	var handles := []
	for candidate in candidates:
		var spawned: Dictionary = staged.allocate(candidate.slot,candidate.components,_capacity)
		if not spawned.ok:
			return spawned
		handles.append(spawned.value)
	handles.make_read_only()
	return R.ok({"entities":staged,"handles":handles})

# Consume only this step's objective projection; RULES owns withdrawal history.
func exclude_teams(keys: Variant, excluded: Dictionary) -> Dictionary:
	if not keys is Array:
		return R.fail("InvalidArgument","withdrawn_team_keys")
	for key in keys:
		if typeof(key) not in [TYPE_STRING,TYPE_INT] or not _zones.has(key):
			return R.fail("InvalidArgument","withdrawn_team_keys")
		excluded[key] = true
	return R.ok()

func auto_wave(entities: RefCounted, limit: int, engine: RefCounted, scope: String, clear_sites: Callable, excluded: Dictionary = {}, opening:=false) -> Dictionary:
	var counts := _counts(entities)
	var possible := []
	for side in _sides:
		if excluded.has(side.team) or counts.get(side.team,0) >= _zones[side.team].quota:
			continue
		for point in _zones[side.team].points:
			possible.append({"team_key":side.team,"spawn_position_mm":point})
	var checked := _check_sites(possible,engine,scope,clear_sites)
	if not checked.ok:
		return checked
	var sites := {}
	for i in possible.size():
		if checked.value[i]:
			var team: Variant = possible[i].team_key
			if not sites.has(team):
				sites[team] = []
			sites[team].append(possible[i].spawn_position_mm)
	var pending := []
	for side in _sides:
		var available: Array = sites.get(side.team,[])
		var take := mini(mini(limit,available.size()),_zones[side.team].quota-counts.get(side.team,0))
		var team_orders := []
		var zone: Dictionary=_zones[side.team]
		if opening and zone.has("opening_slot"):
			var clear_points: Dictionary={}
			for point in available:clear_points[point]=true
			for offset in zone.quota:
				if team_orders.size()==take:break
				var slot: int=zone.opening_slot+offset
				var point: Array=zone.opening_points[offset]
				if not entities.spawned.has(slot) and clear_points.has(point):
					team_orders.append({"source_slot":slot,"components":{"spawn_position_mm":point}})
			pending.append(team_orders)
			continue
		for bounds in side.ranges:
			var slot: int = bounds[0]
			while slot < bounds[1] and team_orders.size() < take:
				if not entities.spawned.has(slot):
					team_orders.append({"source_slot":slot,"components":{"spawn_position_mm":available[team_orders.size()]}})
				slot += 1
			if team_orders.size() == take:
				break
		pending.append(team_orders)
	var orders := []
	for offset in limit:
		var added := false
		for group in pending:
			if orders.size() == limit:
				break
			if offset < group.size():
				orders.append(group[offset])
				added = true
		if not added or orders.size() == limit:
			break
	var candidates := []
	for order in orders:
		var row := _bind(order.source_slot,order.components)
		if not row.ok:
			return row
		candidates.append({"slot":order.source_slot,"components":row.value})
	if orders.is_empty():
		return R.ok({"entities":entities,"handles":[]})
	return _allocate(entities,candidates)
