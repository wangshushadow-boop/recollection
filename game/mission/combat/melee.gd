extends RefCounted
## Mission-local, fixed-step melee. Candidates come from authority collision queries.
## A coordinator may advance a fork and publish it only after later phases succeed.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const S = preload("res://contracts/schema.gd")
const DIRECTIONS := ["up", "left", "right", "thrust"]

# Private game tuning in simulation ticks and abstract hit points.
const WINDUP_TICKS := 3
const CANCEL_TICKS := 2
const ACTIVE_TICKS := 2
const RECOVERY_TICKS := 3
const STAGGER_TICKS := 2
const MAX_CHARGE := 4
const DEFAULT_TIMING := {"windup_ticks":WINDUP_TICKS,"active_ticks":ACTIVE_TICKS,"recovery_ticks":RECOVERY_TICKS}
const COMMANDER_MELEE := {"windup_ticks":9,"active_ticks":4,"recovery_ticks":9}
const COMMANDER_BOW := {"windup_ticks":18,"active_ticks":3,"recovery_ticks":9}

var _tick := 0
var _actors := {}
var _querying := false
# Only these actors have a pending timed transition. Entries follow their authority row across forks.
var _timed := {}


func fork():
	var copy = get_script().new()
	copy._tick = _tick
	copy._actors = _actors.duplicate()
	copy._timed = _timed.duplicate()
	return copy


func add_actor(handle: Dictionary, hp: Variant = 100, weapon_slot: Variant = 0, max_targets: Variant = 1) -> Dictionary:
	if _querying:
		return R.fail("InvalidState", "collision_query")
	var valid := S.validate_shape("AgentHandle", handle)
	if not valid.ok:
		return valid
	if not V.integer(hp, 1) or not V.integer(weapon_slot, 0, V.MAX_U32) or not V.integer(max_targets, 1, V.MAX_U32):
		return R.fail("InvalidArgument", "combatant")
	if _actors.has(handle.index):
		return R.fail("Conflict", "actor_handle")
	_actors[handle.index] = {"handle":valid.value, "hp":hp, "weapon_slot":weapon_slot, "max_targets":max_targets,
		"phase":"Ready", "since":_tick, "direction":"", "charge":0, "attack_id":"", "hit_set":{}}
	return R.ok()


func _actor(handle: Dictionary, states: Dictionary) -> Dictionary:
	if handle.size() != 2 or not V.integer(handle.get("index"), 0, V.MAX_U32) or not V.integer(handle.get("generation"), 1, V.MAX_U32):
		return {}
	var row: Dictionary = states.get(handle.get("index"), {})
	if row.is_empty() or row.handle != handle:
		return {}
	return row


func remove_actor(handle: Dictionary) -> Dictionary:
	if _querying:
		return R.fail("InvalidState", "collision_query")
	if _actor(handle, _actors).is_empty():
		return R.fail("NotFound", "actor_handle")
	_actors.erase(handle.index)
	_timed.erase(handle.index)
	return R.ok()


func view(handle: Dictionary) -> Dictionary:
	var state := _actor(handle, _actors)
	if state.is_empty():
		return R.fail("NotFound", "actor_handle")
	var visible := state.duplicate(true)
	visible.erase("hit_set")
	visible.merge(_timing(state))
	visible["weapon_kind"] = _weapon(state)
	return R.ok(visible)


static func _enter(state: Dictionary, phase: String, tick: int) -> void:
	state.phase = phase
	state.since = tick
	if phase not in ["Active", "Hold", "Windup"]:
		state.attack_id = ""
		state.charge = 0
		state.hit_set = {}


static func _track_phase(clocks: Dictionary, index: int, phase: String) -> void:
	if phase in ["Windup", "Active", "Recovery", "Stagger"]:
		clocks[index] = true
	else:
		clocks.erase(index)


static func _weapon(state: Dictionary) -> String:
	return state.weapons[state.weapon_slot] if state.has("weapons") else "melee"


static func _timing(state: Dictionary) -> Dictionary:
	if state.get("action_profile","")=="commander":
		return COMMANDER_BOW if _weapon(state)=="bow" else COMMANDER_MELEE
	return DEFAULT_TIMING


static func _elapsed_phase(state: Dictionary, tick: int) -> String:
	var elapsed: int = tick - state.since
	match state.phase:
		"Windup":
			if elapsed >= _timing(state).windup_ticks:
				return "Hold"
		"Active":
			if elapsed >= _timing(state).active_ticks:
				return "Recovery"
		"Recovery":
			if elapsed >= _timing(state).recovery_ticks:
				return "Ready"
		"Stagger":
			if elapsed >= STAGGER_TICKS:
				return "Ready"
	return state.phase


static func _cancel_allowed(state: Dictionary, tick: int) -> bool:
	if _weapon(state)=="bow" or state.get("action_profile","")=="commander":
		return state.phase in ["Windup","Hold"]
	return state.phase == "Windup" and tick - state.since < CANCEL_TICKS


static func _apply(state: Dictionary, intent: Dictionary, tick: int) -> Dictionary:
	if state.get("role") == "mount" or state.get("routing", false):
		return R.fail("InvalidState", "actor")
	if intent.has("item_ref"):
		if not state.has("weapons") or not V.integer(intent.slot, 0, state.weapons.size()-1):
			return R.fail("NotFound", "slot")
		if intent.item_ref != null and intent.item_ref != state.weapons[intent.slot]:
			return R.fail("Unauthorized", "item_ref")
		if state.phase not in ["Ready", "Guard"]:
			return R.fail("InvalidState", "equip")
		state.weapon_slot = intent.slot
		_enter(state, "Ready", tick)
		return R.ok()
	if intent.direction not in DIRECTIONS:
		return R.fail("InvalidArgument", "direction")
	if intent.has("held"):
		if intent.held:
			if _weapon(state)=="bow":
				return R.fail("InvalidState","guard")
			if state.phase not in ["Ready", "Guard"] and not _cancel_allowed(state, tick):
				return R.fail("InvalidState", "guard")
			state.direction = intent.direction
			_enter(state, "Guard", tick)
		elif state.phase == "Guard":
			_enter(state, "Ready", tick)
		else:
			return R.fail("InvalidState", "guard")
		return R.ok()
	if intent.weapon_slot != state.weapon_slot:
		return R.fail("InvalidArgument", "weapon_slot")
	match intent.input_phase:
		"start":
			if state.phase != "Ready":
				return R.fail("InvalidState", "start")
			if state.has("weapons") and state.weapons[state.weapon_slot] != "melee":
				if state.ammo <= 0:
					return R.fail("InsufficientResource", "ammo")
				if tick < state.reload_until:
					return R.fail("InvalidState", "reload")
			state.direction = intent.direction
			_enter(state, "Windup", tick)
		"hold":
			if state.direction != intent.direction or state.phase not in ["Windup", "Hold"]:
				return R.fail("InvalidState", "hold")
		"release":
			if state.direction != intent.direction or state.phase != "Hold":
				return R.fail("InvalidState", "release")
			state.charge = mini(MAX_CHARGE, tick - state.since)
			_enter(state, "Active", tick)
			state.attack_id = "%d:%d:%d" % [tick, state.handle.index, state.handle.generation]
			state.hit_set = {}
			if state.has("weapons") and state.weapons[state.weapon_slot] != "melee":
				state.ammo -= 1
				state.reload_until = tick + int({"bow":8,"crossbow":16,"throw":6}[state.weapons[state.weapon_slot]])
		"cancel":
			if not _cancel_allowed(state, tick):
				return R.fail("InvalidState", "cancel")
			_enter(state, "Ready", tick)
		_:
			return R.fail("InvalidArgument", "input_phase")
	return R.ok()


# A known local action contains only fixed ASCII strings, integers and booleans.
# Delegate all other representations to the v1 validator for its exact error or acceptance.
static func _schema_keys(data: Dictionary, fields: Dictionary) -> bool:
	if data.size() != fields.size():
		return false
	for key in data:
		if typeof(key) != TYPE_STRING or not fields.has(key):
			return false
	return true


static func _canonical_handle(value: Variant) -> bool:
	return (
		typeof(value) == TYPE_DICTIONARY and _schema_keys(value, S.SHAPES.AgentHandle)
		and V.integer(value.index, 0, V.MAX_U32) and V.integer(value.generation, 1, V.MAX_U32)
	)


static func _known_action(kind: String, intent: Dictionary) -> bool:
	if kind == "EquipIntent" or not _schema_keys(intent, S.SHAPES[kind]):
		return false
	if not _canonical_handle(intent.actor_handle) or typeof(intent.direction) != TYPE_STRING or intent.direction not in DIRECTIONS:
		return false
	if kind == "BlockIntent":
		return typeof(intent.held) == TYPE_BOOL
	return (
		typeof(intent.input_phase) == TYPE_STRING and intent.input_phase in ["start", "hold", "release", "cancel"]
		and V.integer(intent.weapon_slot, 0, V.MAX_U32)
		and (intent.target_hint == null or _canonical_handle(intent.target_hint))
	)


static func _contact_less(a: Dictionary, b: Dictionary) -> bool:
	if a.contact_order != b.contact_order:
		return a.contact_order < b.contact_order
	if a.attacker.index != b.attacker.index:
		return a.attacker.index < b.attacker.index
	return a.target.index < b.target.index


static func _contacts(states: Dictionary, candidates: Array) -> Dictionary:
	var ordered := []
	for c in candidates:
		if typeof(c) != TYPE_DICTIONARY or typeof(c.get("attack_id")) != TYPE_STRING or not V.integer(c.get("contact_order")):
			return R.fail("InvalidArgument", "contact")
		if typeof(c.get("projectile", false)) != TYPE_BOOL or typeof(c.get("mount_impact",false)) != TYPE_BOOL or typeof(c.get("region", "body")) != TYPE_STRING:
			return R.fail("InvalidArgument", "contact")
		if not V.integer(c.get("charge_bonus", 0), 0, 5) or typeof(c.get("guard_facing",true)) != TYPE_BOOL:
			return R.fail("InvalidArgument", "contact")
		if c.get("projectile", false) or c.get("mount_impact",false):
			if not V.integer(c.get("power"), 1, 100000) or not V.integer(c.get("team"), 0, V.MAX_U32):
				return R.fail("InvalidArgument", "contact_power")
		for field: String in ["attacker", "target"]:
			if not S.validate_shape("AgentHandle", c.get(field)).ok:
				return R.fail("InvalidArgument", "contact." + field)
		ordered.append(c)
	ordered.sort_custom(_contact_less)
	var damages := {}
	var events := []
	var applied_projectiles := {}
	for c: Dictionary in ordered:
		var attacker: Dictionary = states.get(c.attacker.index, {})
		var target: Dictionary = states.get(c.target.index, {})
		var projectile: bool = c.get("projectile", false) == true
		var impact: bool = c.get("mount_impact",false)
		var weapon := not projectile and not impact
		if target.is_empty() or target.handle != c.target or target.phase == "Downed" or c.attacker == c.target:
			continue
		if impact and (attacker.get("handle") != c.attacker or attacker.get("rider_handle") == null or attacker.phase == "Downed"):
			continue
		if weapon and (attacker.is_empty() or attacker.handle != c.attacker or attacker.phase != "Active" or attacker.attack_id != c.attack_id):
			continue
		if target.has("team") and target.team == c.get("team",attacker.get("team")):
			continue
		var region: String = c.get("region", "body")
		if region == "shield" and (target.get("shield",0) <= 0 or target.phase != "Guard"):
			continue
		if projectile:
			if applied_projectiles.has(c.attack_id):
				continue
			applied_projectiles[c.attack_id] = true
		var target_key := "%d:%d" % [c.target.index, c.target.generation]
		if weapon:
			if attacker.hit_set.has(target_key) or attacker.hit_set.size() >= attacker.max_targets:
				continue
			attacker = attacker.duplicate()
			attacker.hit_set = attacker.hit_set.duplicate()
			attacker.hit_set[target_key] = true
			states[c.attacker.index] = attacker
		var raw: int = 10 + attacker.charge + c.get("charge_bonus",0) if weapon else c.power
		var shield_block: bool = target.phase == "Guard" and region == "shield" and target.get("shield",0) > 0
		var blocked: bool = shield_block or (weapon and target.phase == "Guard" and target.direction == attacker.direction and c.get("guard_facing",true))
		var armor: int = target.get("armor", {}).get(region, 0)
		var weighted: int = raw * (2 if region == "head" else 1)
		var damage: int = 0 if blocked else roundi(weighted * 100.0 / (100 + armor))
		var info := {"attack_id":c.attack_id, "attacker":c.attacker, "target":target.handle, "blocked":blocked, "damage":damage}
		if impact:
			info["kind"] = "mount_impact"
		if target.has("armor"):
			info["breakdown"] = {"raw":raw,"zone":region,"zone_total":weighted,"armor":armor,"mitigated":weighted-damage,
				"mount_bonus":c.get("charge_bonus",0),"blocked":blocked,"actual":damage}
			if shield_block:
				target = target.duplicate()
				target.shield = maxi(0,target.shield-raw)
				states[c.target.index] = target
				info["shield_remaining"] = target.shield
				info["shield_broken"] = target.shield == 0
		if damage > 0:
			damages[c.target.index] = damages.get(c.target.index, 0) + damage
		events.append(info)
	return R.ok({"damages":damages, "events":events})


func step(tick: Variant, intents: Array, query_contacts: Callable = Callable()) -> Dictionary:
	if _querying:
		return R.fail("InvalidState", "collision_query")
	if not V.integer(tick, 1) or tick != _tick + 1:
		return R.fail("StaleVersion", "tick")
	# Structural errors reject the tick; an illegal action receives a rejection
	# receipt and cannot stall other actors' fixed-step clocks.
	var next := _actors.duplicate()
	var clocks := _timed.duplicate()
	for index in _timed:
		var state: Dictionary = next[index]
		var phase := _elapsed_phase(state, tick)
		if phase != state.phase:
			state = state.duplicate()
			_enter(state, phase, tick)
			next[index] = state
			_track_phase(clocks, index, phase)
	var receipts := []
	for intent in intents:
		if typeof(intent) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument", "intent")
		var kind := "BlockIntent" if intent.has("held") else ("EquipIntent" if intent.has("item_ref") else "AttackIntent")
		if not _known_action(kind, intent):
			var validated := S.validate_shape(kind, intent)
			if not validated.ok:
				return validated
		var state: Dictionary = next.get(intent.actor_handle.index, {})
		if state.is_empty() or state.handle.generation != intent.actor_handle.generation:
			receipts.append(R.fail("NotFound", "actor_handle"))
			continue
		var prior_phase: String = state.phase
		state = state.duplicate()
		var receipt := _apply(state, intent, tick)
		if receipt.ok:
			next[intent.actor_handle.index] = state
			if state.phase != prior_phase:
				_track_phase(clocks, intent.actor_handle.index, state.phase)
		receipts.append(receipt)
	var candidates := []
	if not query_contacts.is_null():
		if not query_contacts.is_valid():
			return R.fail("Unavailable", "collision_query")
		var active := []
		for index in clocks:
			var state: Dictionary = next[index]
			if state.phase == "Active":
				var swing := {"attacker":state.handle.duplicate(), "attack_id":state.attack_id, "direction":state.direction}
				if state.has("weapons"):
					swing.merge({"weapon":state.weapons[state.weapon_slot],"released":state.since,"charge":state.charge,"team":state.team})
					if swing.weapon=="melee":swing["active_ticks"]=_timing(state).active_ticks
				active.append(swing)
		active.sort_custom(func(a, b): return a.attacker.index < b.attacker.index)
		if not active.is_empty() or _needs_sweep():
			_querying = true
			var result: Variant = _query_active(tick, active, next, query_contacts)
			_querying = false
			if typeof(result) != TYPE_DICTIONARY or typeof(result.get("ok")) != TYPE_BOOL:
				return R.fail("InvalidArgument", "collision_query")
			if not result.ok:
				return result if typeof(result.get("error")) == TYPE_DICTIONARY else R.fail("Unavailable", "collision_query")
			if typeof(result.get("value")) != TYPE_ARRAY:
				return R.fail("InvalidArgument", "collision_query")
			candidates = result.value
	var contacts := _contacts(next, candidates)
	if not contacts.ok:
		return contacts
	# All contact eligibility was sampled before any simultaneous damage.
	for index in contacts.value.damages:
		var state: Dictionary = next[index].duplicate()
		state.hp = maxi(0, state.hp - contacts.value.damages[index])
		_enter(state, "Downed" if state.hp == 0 else "Stagger", tick)
		next[index] = state
		_track_phase(clocks, index, state.phase)
	_timed = clocks
	_actors = next
	_tick = tick
	return R.ok({"tick":_tick, "receipts":receipts, "hits":contacts.value.events.duplicate(true)})


func has_pending_projectiles() -> bool:
	return false


func _needs_sweep() -> bool:
	return has_pending_projectiles()


func _query_active(tick: int, active: Array, _states: Dictionary, query: Callable) -> Variant:
	return query.call(tick, active)
