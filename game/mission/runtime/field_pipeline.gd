extends "res://mission/runtime/runtime.gd"
## Field assembly lives inside the existing Mission entity store and tick barrier.
const Move = preload("res://mission/movement/ports/field_movement.gd")
const Form = preload("res://mission/formation/ports/field_formation.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const Rules = preload("res://mission/rules/ports/field_rules.gd")
const Results = preload("res://mission/results/ports/field_results.gd")
const Sources = preload("res://contracts/field_sources.gd")
const ROLES := ["infantry","archer","cavalry","mounted_archer"]
var _registry: RefCounted
var _principal: Callable
var _factory: Callable
var _results := Results.new()
var _move: RefCounted
var _form: RefCounted
var _com: RefCounted
var _rules: RefCounted
var _brains: RefCounted
var _owners: RefCounted
var _kits := {}
var _teams := {}
var _credentials := {}
var _local := {}
var _zones := {}
var _base_groups := {}
var _frame := {}
var _draft := {}
var _input := {}
var _user_handle: Variant
var _player_pose := {}
var _watching := false
var _accessing := false
var _control_revision := 0
var _commander_hero: Variant
var _layout_specs := {}
var _consumed := {}
var _mount_orders := {}
var _allow_jump := false

class PoseProjection:
	var source: Dictionary
	var pose: Dictionary
	var body: Dictionary
	var combat: Dictionary

func _init(core: RefCounted, engine: RefCounted, key: String, registry: RefCounted, resolve_principal: Callable, brains_factory: Callable) -> void:
	super(core,engine,key,_results.build_result)
	_registry = registry
	_principal = resolve_principal
	_factory = brains_factory

static func _meters(mm: Array) -> Vector3:
	return Vector3(mm[0],mm[1],mm[2])*0.001

static func _mm(v: Vector3, scale: int = 1000) -> Array:
	return [roundi(v.x*scale),roundi(v.y*scale),roundi(v.z*scale)]

static func _kit_key(source: Dictionary) -> String:
	return "troop/"+source.troop_def_id if source.troop_def_id!=null else "equipment/"+source.loadout_snapshot_id

func _kit(source: Dictionary) -> Dictionary:
	return _kits[_kit_key(source)]

func _load_kit(source: Dictionary) -> Dictionary:
	var id := _kit_key(source)
	if _kits.has(id):
		return R.ok()
	var equipment: String=source.loadout_snapshot_id
	var role: Variant
	if source.troop_def_id!=null:
		var definition: Dictionary = _registry.get_definition(source.troop_def_id,"troop")
		if not definition.ok:return definition
		role=definition.value.get("role")
		if role not in ROLES or definition.value.equipment_set_ids.is_empty():
			return R.fail("InvalidArgument","field.troop_loadout")
		equipment=definition.value.equipment_set_ids[0]
	elif source.hero_id==null:
		return R.fail("InvalidArgument","field.source_identity")
	var equipped: Dictionary = _registry.get_definition(equipment,"equipment")
	if not equipped.ok:
		return equipped
	var slots: Dictionary = equipped.value.slots
	var metadata: Dictionary = equipped.value.get("metadata",{})
	if role==null:
		role=metadata.get("role",ROLES[int(slots.has("ranged"))+2*int(slots.has("mount"))])
	var profile := {"role":role,"melee":"","ranged":"","mounted":slots.has("mount"),"shield":0,"action_profile":metadata.get("action_profile","")}
	for slot in slots:
		var item: Dictionary = _registry.get_definition(slots[slot],"item")
		if not item.ok: return item
		if slot not in item.value.slot_tags: return R.fail("Conflict","field.equipment_slot")
		if slot in ["ranged","melee"]: profile[slot] = item.value.category
		if slot=="shield":
			profile.shield = item.value.get("metadata",{}).get("durability")
			if not V.integer(profile.shield,1,1000000):return R.fail("InvalidArgument","field.shield")
	if role not in ROLES or profile.action_profile not in ["","commander"] or profile.melee.is_empty() or profile.mounted != (role in ["cavalry","mounted_archer"]):
		return R.fail("Conflict","field.troop_loadout")
	# A hero's formation role can remain infantry while carrying a secondary bow.
	if (role in ["archer","mounted_archer"] and profile.ranged.is_empty()) or (source.troop_def_id!=null and not profile.ranged.is_empty() and role not in ["archer","mounted_archer"]):
		return R.fail("Conflict","field.troop_loadout")
	_kits[id] = profile
	return R.ok()

func prepare(spec: Dictionary, scene: Dictionary, ruleset: Dictionary) -> Dictionary:
	if _phase!="New" or _registry==null or not _factory.is_valid() or not _principal.is_valid():
		return R.fail("InvalidState","field.prepare")
	var indexed := Sources.build(spec)
	if not indexed.ok: return indexed
	if not scene.get("field_exit_zones") is Array or not scene.get("field_zones") is Array:
		return R.fail("InvalidArgument","field.exit_zones")
	if ruleset.get("battle_mode")!="field":
		return R.fail("InvalidArgument","field.ruleset")
	var deployment:=FieldDeployment.build(spec,scene,ruleset)
	if not deployment.ok:return deployment
	_teams.clear()
	_credentials.clear()
	_zones.clear()
	_kits.clear()
	_base_groups.clear()
	_owners = indexed.value
	if not scene.get("field_allow_jump",false) is bool:return R.fail("InvalidArgument","field.allow_jump")
	_allow_jump=scene.get("field_allow_jump",false)
	for source in spec.reserved_sources:
		var kit := _load_kit(source)
		if not kit.ok: return kit
	var local:Variant=scene.get("field_player",{"issuer_id":"player","team_key":spec.sides[0].team_key})
	if not local is Dictionary or not local.get("issuer_id") is String or local.issuer_id.is_empty() or not local.has("team_key"):
		return R.fail("InvalidArgument","field.player")
	_local=local.duplicate()
	var sites:Variant=scene.get("field_sites",[])
	if not sites is Array:return R.fail("InvalidArgument","field.sites")
	for site in sites:
		if not site is Dictionary or not site.get("id") is String or not site.get("position") is Vector3 or not site.position.is_finite() or not site.get("objective") is bool:
			return R.fail("InvalidArgument","field.site")
	for side in spec.sides:
		if is_same(side.team_key,_local.team_key):_commander_hero=side.commander_hero_id
	for zone in scene.field_zones:
		_zones[zone.team_key] = zone
	_move = Move.new(_engine,_mission,_drive_authorized)
	_form = Form.new(_mission,_form_actor,_reachable)
	_com = Combat.new(_mission)
	var rules := Rules.build(_mission,spec,scene.field_exit_zones,_authorize_rules,_read_condition,_read_position,
		func(h):return resolve_entity(_mission,h))
	if not rules.ok: return rules
	_rules = rules.value
	var setup := _open_teams(spec,scene)
	if not setup.ok: return setup
	_brains = _factory.call(_mission,_engine,_form,_teams.values())
	if _brains==null: return R.fail("Unavailable","field.brains")
	bind_field_clearance(_engine.field_clearance)
	var opened := super.prepare(spec,scene,ruleset)
	if not opened.ok: return opened
	var tracker := _results.open(view())
	if not tracker.ok:
		dispose()
		return tracker
	for pair in [["input",{"id":"field.start","run":_start,"commit":_publish,"rollback":_revert}],
		["ai",{"id":"field.ai","run":_think}],["movement",{"id":"field.movement","run":_walk}],
		["action",{"id":"field.combat","run":_fight}],["damage",{"id":"field.casualties","run":_casualties,"can_retire":true}],
		["objectives",_rules.system()],["snapshot",{"id":"field.results","run":_snapshot}]]:
		var added := register_system(pair[0],pair[1])
		if not added.ok:
			dispose()
			return added
	return opened

func _open_teams(spec: Dictionary, scene: Dictionary) -> Dictionary:
	var local_grant := RefCounted.new()
	_credentials[local_grant] = _local
	for i in spec.sides.size():
		var key: Variant = spec.sides[i].team_key
		if not _zones.has(key): return R.fail("NotFound","field.zone")
		var zone: Dictionary = _zones[key]
		var exits: Array = scene.field_exit_zones.filter(func(z):return is_same(z.team_key,key))
		if exits.size()!=1: return R.fail("InvalidArgument","field.exit_zones")
		var center := (_meters(exits[0].min_mm)+_meters(exits[0].max_mm))*.5
		var issuer := "field-captain-%d"%i
		if issuer==_local.issuer_id: return R.fail("Conflict","field.issuer")
		var token := RefCounted.new()
		_credentials[token] = {"team_key":key,"issuer_id":issuer}
		var sites: Array = scene.get("field_sites",[]).duplicate()
		if sites.is_empty():
			sites.append({"id":"rally-%d"%i,"position":_meters(zone.rally_mm),"objective":false})
		_teams[key] = {"team_key":key,"issuer":issuer,"context":token,"sites":sites,"exit_position":center,"ordinal":i}
		for j in ROLES.size():
			var id: int = 1+i*ROLES.size()+j
			var player_side := is_same(key,_local.team_key)
			var created: Dictionary = _form.add_formation(id,key,_local.issuer_id if player_side else issuer,[])
			if not created.ok: return created
			if player_side:
				var delegated: Dictionary = _form.set_delegate(id,issuer,local_grant,0)
				if not delegated.ok: return delegated
			_base_groups[id] = key
	return R.ok() if _teams.has(_local.team_key) else R.fail("NotFound","field.player_team")

func _complete_deployment(deployment: Dictionary) -> Dictionary:
	for handle in deployment.handles:
		var row: Dictionary = deployment.entities.occupied[handle.index]
		var kit: Dictionary = _kit(row.components)
		if kit.mounted:
			var companion: Dictionary = deployment.entities.allocate(null,{"type":"mount","rider_handle":handle,
				"team_key":row.components.team_key,"spawn_position_mm":row.components.spawn_position_mm},_spec.battle_limit)
			if not companion.ok: return companion
	return R.ok()

func _retire_companions(store: Entities, retiring: Array) -> void:
	var riders := {}
	for handle in retiring:
		riders[handle.index] = handle
	for row in store.rows():
		var rider: Variant = row.components.get("rider_handle")
		if rider!=null and riders.get(rider.index)==rider and not riders.has(row.handle.index):
			store.remove(_mission,row.handle,_mission)

func _identity(token: Variant) -> Dictionary:
	if token is RefCounted and _credentials.has(token): return R.ok(_credentials[token])
	var grant: Variant = _principal.call(token)
	if not grant is Dictionary or not is_same(grant.get("ok"),true) or not grant.get("value") is Dictionary:
		return R.fail("Unauthorized","field.principal")
	if not grant.value.get("issuer_id") is String or grant.value.issuer_id.is_empty() or not is_same(grant.value.get("team_key"),_local.team_key):
		return R.fail("Unauthorized","field.principal")
	return R.ok({"issuer_id":grant.value.issuer_id,"team_key":grant.value.team_key})

func _form_actor(token: Variant) -> Dictionary:
	var grant := _identity(token)
	return R.ok(grant.value.issuer_id) if grant.ok else grant

func _authorize_rules(token: Variant, team: Variant, _action: String) -> bool:
	var grant := _identity(token)
	return grant.ok and is_same(grant.value.team_key,team) and (grant.value.issuer_id==_local.issuer_id or _credentials.has(token))

func _drive_authorized(scope: String, h: Dictionary, token: Variant, _tick_id: int) -> bool:
	var grant := _identity(token)
	var rows: Dictionary = _draft.get("rows",_frame.get("rows",{}))
	var row: Dictionary = rows.get(h.index,{})
	if scope!=_mission or not grant.ok or row.is_empty() or row.handle!=h or row.source_slot==null or not is_same(row.components.team_key,grant.value.team_key):
		return false
	var player: Variant = _draft.get("player",_user_handle)
	if _credentials.has(token): return h!=player or _rules.view().control_mode=="delegate"
	return grant.value.issuer_id==_local.issuer_id and h==player and _rules.view().control_mode=="direct"

func _read_condition(h: Dictionary) -> Dictionary:
	var com: RefCounted = _draft.get("com",_com)
	return com.view(h)

func _read_position(h: Dictionary) -> Dictionary:
	var read: Dictionary = _move.view(h,_draft.get("stage"))
	return R.ok(_mm(read.value.position)) if read.ok else read

func _reachable(id: int, target: Array) -> bool:
	var g: Dictionary = _form.view(id)
	if not g.ok: return false
	var origin: Array = _zones[g.value.team_key].rally_mm
	var read: Dictionary = _engine.query_path_batch([{"from":origin,"to":target}],_draft.get("nav",_frame.get("nav",0)),_mission)
	return read.ok and read.value[0].reachable

func request_end(outcome: Dictionary) -> Dictionary:
	if not _active() or _rules==null: return R.fail("InvalidState","phase")
	var decision: Variant = _rules.view().outcome
	if decision==null or decision!=outcome: return R.fail("Conflict","field.outcome")
	return super.request_end(outcome)

func _pending_input_authorized() -> bool:
	var batch:Dictionary=_input.batch
	if batch.control_revision!=_control_revision:return false
	if batch.inputs.is_empty():
		var grant:=_identity(_input.context)
		return grant.ok and grant.value.issuer_id==_local.issuer_id
	# Admission binds every intent to one actor generation. A new casualty is a
	# consequence of this tick, so verify control against the opening roster.
	return _drive_authorized(_mission,batch.inputs[0].actor_handle,_input.context,batch.source_tick)

func step_fixed(tick: Variant, inputs: Array) -> Dictionary:
	# Player input is admitted only via the credentialed gateway. AI runs in the same fixed tick.
	if not inputs.is_empty() or _accessing: return R.fail("Unauthorized","field.input")
	if _rules!=null and _rules.view().outcome!=null: return R.fail("InvalidState","field.outcome")
	if _input.get("denied",false) and _active() and V.integer(tick,1) and tick==_tick+1:
		_accessing=true
		var still_authorized:=_pending_input_authorized()
		_accessing=false
		if not still_authorized:_input={}
	var previous_mode: String=_rules.view().control_mode if _rules!=null else ""
	var result:=super.step_fixed(tick,[])
	if result.ok:
		if _rules.view().control_mode!=previous_mode:_control_revision+=1
		if not _watching and _user_handle!=null and _rules.view().outcome==null:
			_watching=_rules.watch_commander(_user_handle,_local.team_key).ok
	elif not _input.is_empty() and result.error.code=="Unauthorized":
		_input["denied"]=true
	return result

func _start(ctx: Dictionary, batch: Dictionary) -> Dictionary:
	var nav: Dictionary = _engine.sync_navigation(_mission)
	if not nav.ok: return nav
	if nav.value.status!="applied": return R.fail("Unavailable","field.navigation")
	var movement: Dictionary = _move.begin_step(batch.source_tick)
	if not movement.ok: return movement
	_draft = {"stage":movement.value,"nav":nav.value.applied_revision,"com":_com.fork(),"player":_user_handle,
		"rows":{},"pose":{},"orders":{},"layout_cache":_layout_specs.duplicate(),"look":_frame.get("look",{}),"moves":[],"actions":[],"ai":[],"move_receipts":[]}
	_draft.aim_pitch = _frame.get("aim_pitch",0.0) if _frame.get("aim_handle")==_user_handle else 0.0
	_draft["resolved_mount_orders"]=[]
	_draft["interactions"]=[]
	var begun: Dictionary = _form.begin_tick()
	if not begun.ok: return begun
	var stable := is_same(ctx.entities,_frame.get("roster"))
	if stable:
		_draft.rows=_frame.rows
	else:
		_draft.look = _draft.look.duplicate()
		for row in ctx.entities: _draft.rows[row.handle.index] = row
	for old in [] if stable else _frame.get("roster",[]):
		if _draft.rows.get(old.handle.index,{}).get("handle")!=old.handle:
			var removed: Dictionary = _draft.com.remove_actor(old.handle)
			if not removed.ok: return removed
			if old.source_slot!=null:
				removed = _move.despawn(old.handle,_draft.stage)
				if not removed.ok: return removed
			_draft.look.erase(old.handle.index)
	var new_mounts := []
	for row in [] if stable else ctx.entities:
		if _frame.get("rows",{}).get(row.handle.index,{}).get("handle")==row.handle: continue
		var body: Dictionary = row.components
		var ordinal: int = _teams[body.team_key].ordinal
		if row.source_slot==null:
			var horse: Dictionary = _draft.com.enlist(row.handle,{"team":ordinal,"role":"mount"})
			if not horse.ok: return horse
			new_mounts.append(row)
			continue
		var kit: Dictionary = _kit(body)
		var combat_role: String = "cavalry" if kit.mounted else kit.role
		var is_commander: bool = body.hero_id!=null and body.hero_id==_spec.sides[ordinal].get("commander_hero_id")
		var profile := {"team":ordinal,"role":combat_role,"commander":is_commander}
		if kit.shield>0: profile.shield=kit.shield
		if not kit.action_profile.is_empty(): profile.action_profile=kit.action_profile
		if not kit.ranged.is_empty(): profile["ranged"]=kit.ranged
		var enlist: Dictionary = _draft.com.enlist(row.handle,profile)
		if not enlist.ok: return enlist
		var face := _meters(_zones[_spec.sides[(ordinal+1)%_spec.sides.size()].team_key].rally_mm)-_meters(_zones[body.team_key].rally_mm)
		if face.is_zero_approx(): face = Vector3.FORWARD
		var born: Dictionary = _move.spawn(row.handle,_meters(body.spawn_position_mm),"mounted" if kit.mounted else "foot",face.normalized(),_draft.stage)
		if not born.ok: return born
		if _draft.player==null and is_same(body.team_key,_local.team_key) and (_commander_hero==null or body.hero_id==_commander_hero):
			_draft.player=row.handle
	for row in new_mounts:
		var attached: Dictionary = _draft.com.mount(row.components.rider_handle,row.handle)
		if not attached.ok: return attached
	_draft["roster"] = ctx.entities
	if stable:
		_draft["humans"]=_frame.humans
		_draft["token"]=_frame.token
		_draft["roles"]=_frame.roles
		_draft["horses"]=_frame.horses
	else:
		var humans := []
		var horses := []
		var roles := {}
		for row in ctx.entities:
			if row.source_slot==null:
				horses.append(row)
				roles[row.handle.index]="mount"
			else:
				humans.append(row.handle)
				roles[row.handle.index]=_kit(row.components).role
		var ticket:Dictionary=_move.bind_roster(humans,_draft.stage)
		if not ticket.ok:return ticket
		_draft["humans"]=humans
		_draft["token"]=ticket.value
		_draft["roles"]=roles
		_draft["horses"]=horses
	return _sync_groups(ctx.entities,batch.source_tick)

func _sync_groups(rows: Array, tick: int) -> Dictionary:
	if is_same(rows,_frame.get("roster")):
		return _advance_groups(_frame.groups,rows,tick)
	var desired := {}
	for id in _base_groups: desired[id] = []
	for row in rows:
		if row.source_slot==null: continue
		var known: Dictionary = _form.member_formation(row.handle)
		var id: int
		if known.ok: id=known.value
		else:
			var team: Dictionary = _teams[row.components.team_key]
			id = 1+team.ordinal*ROLES.size()+ROLES.find(_kit(row.components).role)
		if not desired.has(id): desired[id]=[]
		desired[id].append(row.handle)
	for id in _frame.get("groups",{}):
		if not desired.has(id): desired[id]=[]
	for id in desired:
		var group: Dictionary = _form.view(id)
		if not group.ok: continue
		# Release stale generations before another formation attempts to claim their index.
		if group.value.members.any(func(h):return _draft.rows.get(h.index,{}).get("handle")!=h):
			var retained: Array = group.value.members.filter(func(h):return _draft.rows.get(h.index,{}).get("handle")==h)
			var released: Dictionary = _form.assign_members(id,retained)
			if not released.ok: return released
	for id in desired:
		if not _form.view(id).ok: continue
		var assigned: Dictionary = _form.assign_members(id,desired[id])
		if not assigned.ok: return assigned
	return _advance_groups(desired,rows,tick)

func _advance_groups(desired: Dictionary, rows: Array, tick: int) -> Dictionary:
	var advanced: Dictionary = _form.advance(tick)
	if not advanced.ok: return advanced
	var groups := {}
	var same_members := is_same(rows,_frame.get("roster"))
	for id in desired:
		var group: Dictionary = _form.view(id)
		if group.ok:
			groups[id]=group.value
			if same_members and _frame.groups[id].members_revision!=group.value.members_revision:
				same_members=false
		else:
			same_members=false
	_draft["groups"]=groups
	if same_members:
		_draft["membership"]=_frame.membership
		return R.ok()
	var membership_by_index := {}
	for id in groups:
		for h in groups[id].members:membership_by_index[h.index]=id
	for row in rows:
		if row.source_slot!=null and not membership_by_index.has(row.handle.index):
			var membership: Dictionary = _form.member_formation(row.handle)
			if membership.ok and not groups.has(membership.value):
				var new_group:Dictionary=_form.view(membership.value).value
				groups[membership.value]=new_group
				for h in new_group.members:membership_by_index[h.index]=membership.value
	_draft["membership"]=membership_by_index
	return R.ok()

func _project_slots(points: PackedVector3Array, origin: Vector3) -> Dictionary:
	var requests := []
	for p in points: requests.append({"from":_mm(origin),"to":_mm(p)})
	var nav: Dictionary = _engine.query_path_batch(requests,_draft.nav,_mission)
	if not nav.ok: return nav
	var projected := PackedVector3Array()
	for row in nav.value:
		if not row.reachable: return R.fail("Unavailable","field.slot_navigation")
		projected.append(_meters(row.points[-1]))
	return R.ok(projected)

func _formations() -> Dictionary:
	var slot_sources := {}
	var previous: Dictionary = _frame.get("slot_sources",{})
	var same_slots := is_same(_draft.roster,_frame.get("roster"))
	for id in _draft.groups:
		var g: Dictionary = _draft.groups[id]
		if g.members.is_empty(): continue
		var leader: Dictionary = _move.view(g.members[0],_draft.stage)
		if not leader.ok: return leader
		var old: Dictionary = _draft.layout_cache.get(id,{})
		var goal: Vector3 = old.get("anchor",leader.value.position)
		var zone:Dictionary=_zones[g.team_key]
		if old.is_empty() and zone.has("opening_slot"):
			# The general stands ahead of the ranks. Use the ranks themselves as
			# the initial formation center so they do not march through their general.
			goal=Vector3.ZERO
			for member in g.members:goal+=_meters(_draft.rows[member.index].components.spawn_position_mm)
			goal/=g.members.size()
		if g.active!=null:
			if g.active.target_position!=null: goal=_meters(g.active.target_position)
			elif g.active.target_formation_id!=null:
				var enemy: Dictionary = _draft.groups.get(g.active.target_formation_id,{})
				if not enemy.is_empty() and not enemy.members.is_empty():
					var ahead: Dictionary = _move.view(enemy.members[0],_draft.stage)
					if ahead.ok: goal=ahead.value.position
			elif g.active.order_type=="retreat": goal=_teams[g.team_key].exit_position
		var signature := [g.members_revision,g.layout,g.facing_microradians,g.active,_draft.nav]
		var direct: Variant=null
		if zone.has("opening_slot") and _draft.aim_handle!=null and _draft.membership.get(_draft.aim_handle.index)==id:
			direct=_draft.aim_handle
		signature.append(direct)
		if old.is_empty() or old.signature!=signature or old.anchor.distance_squared_to(goal)>4.0:
			var rebuilt: Dictionary = _form.build_slot_targets(id,goal,g.facing_microradians*.000001,1.45,INF,_project_slots.bind(leader.value.position))
			if not rebuilt.ok and rebuilt.error.code!="Unavailable": return rebuilt
			# Projection failures change terrain feedback and can finish the active order.
			# A successful retry clears that feedback before the AI validates its snapshot.
			if not rebuilt.ok or not g.terrain_feedback.is_empty():
				var refreshed: Dictionary = _form.view(id)
				if not refreshed.ok: return refreshed
				_draft.groups[id]=refreshed.value
			if not rebuilt.ok: continue
			var revision: int = old.get("order_revision",0)
			if old.is_empty() or old.signature!=signature: revision+=1
			old={"anchor":goal,"signature":signature,"slots":rebuilt.value.slots,"order_revision":revision}
			_draft.layout_cache[id]=old
			var lanes := {}
			for slot in old.slots:
				var h: Dictionary = slot.member
				if h==direct:
					# The direct player's travel comes from their own MoveIntents, including idle.
					continue
				var pose: Dictionary = _move.view(h,_draft.stage)
				if not pose.ok: return pose
				var profile: String = pose.value.profile
				if not lanes.has(profile):
					var lane := "%d/%s" % [id,profile]
					var route: Dictionary = _move.set_corridor(lane,leader.value.position,goal,profile,_draft.stage)
					if not route.ok: return route
					lanes[profile] = lane
				var assigned: Dictionary = _move.assign(h,lanes[profile],slot.position-goal,_draft.stage)
				if not assigned.ok: return assigned
		slot_sources[id]=old.slots
		if not is_same(old.slots,previous.get(id)): same_slots=false
	_draft["slot_sources"]=slot_sources
	if same_slots and slot_sources.size()==previous.size(): return R.ok(_frame.targets)
	var targets := {}
	for slots in slot_sources.values():
		for slot in slots: targets[slot.member.index]=slot.position
	return R.ok(targets)

# The committed heading overrides are shared until an input really changes one.
func _set_look(index: int, yaw: int) -> void:
	var heading := Vector3.FORWARD.rotated(Vector3.UP,yaw*.000001)
	var look: Dictionary = _draft.look
	if look.get(index) == heading: return
	if is_same(look,_frame.get("look")):
		look = look.duplicate()
		_draft.look = look
	look[index] = heading

func _think(_ctx: Dictionary, batch: Dictionary) -> Dictionary:
	var mounted:=_apply_mount_requests(batch.source_tick)
	if not mounted.ok:return mounted
	var control_mode: String = _rules.view().control_mode
	_draft.aim_handle=_draft.player if control_mode=="direct" else null
	var targets := _formations()
	if not targets.ok: return targets
	_draft["targets"]=targets.value
	# The opening AI reads only positions and headings. Profile/formation changes
	# before movement can change velocity or routes, but neither of those columns.
	var motion: Dictionary
	if is_same(_draft.token,_frame.get("token")):
		motion=_frame.motion
	else:
		var prior: Dictionary=_move.read_poses(_draft.token,_draft.stage)
		if not prior.ok:return prior
		motion=prior.value
	var player: Variant = _draft.player if control_mode!="delegate" else null
	var decision: Dictionary
	if _brains.has_method("decide_compact"):
		var changes: Dictionary = _draft.com.field_ai_changes(_mission)
		if not changes.ok: return changes
		var columns := {"token":_draft.token,"humans":_draft.humans,"rows":_draft.rows,"roles":_draft.roles,
			"membership":_draft.membership,"groups":_draft.groups,"layout_cache":_draft.layout_cache,
			"targets":targets.value,"positions":motion.positions,"headings":motion.headings,
			"look":_draft.look,"changes":changes.value.actors}
		decision = _brains.decide_compact(batch.source_tick,_draft.nav,columns,_draft.com,player)
	else:
		decision = _decide_legacy(batch.source_tick,motion,targets.value,player)
	if not decision.ok: return decision
	_draft["ai"]=decision.value.actions
	_draft["ai_moves"]=decision.value.moves
	_draft["metrics"]=decision.value.metrics
	for aim in decision.value.get("looks",[]):
		_set_look(aim.actor_handle.index,aim.yaw)
	if not _input.is_empty():
		if not _identity(_input.context).ok: return R.fail("Unauthorized","field.input")
		for intent in _input.batch.inputs:
			if not _drive_authorized(_mission,intent.actor_handle,_input.context,batch.source_tick): return R.fail("Unauthorized","field.input")
			if intent.has("desired_direction"):
				_draft.moves.append({"intent":intent,"context":_input.context})
			elif intent.has("yaw"):
				_set_look(intent.actor_handle.index,intent.yaw)
				_draft.aim_pitch=intent.pitch*.000001
			elif intent.has("input_phase") or intent.has("held") or intent.has("item_ref"):
				_draft.actions.append(intent)
			elif intent.get("action") in ["mount","dismount"]:
				continue
			elif intent.get("action")=="jump":
				var attempted:Dictionary=_move.request_jump(intent.actor_handle,_input.context,_draft.stage)
				_draft.interactions.append(attempted)
			else:
				return R.fail("InvalidArgument","field.interaction")
	return R.ok()

func _decide_legacy(tick: int, motion: Dictionary, targets: Dictionary, player: Variant) -> Dictionary:
	var state: Dictionary = _draft.com.field_view(_mission,_draft.humans,0)
	if not state.ok: return state
	var units := []
	for i in _draft.humans.size():
		var h: Dictionary = _draft.humans[i]
		var id: int = _draft.membership[h.index]
		var actor: Dictionary = state.value.actors[i]
		var pos: Vector3 = motion.positions[i]
		units.append({"handle":h,"formation_id":id,"team_key":_draft.rows[h.index].components.team_key,"role":_draft.roles[h.index],
			"heading":_draft.look.get(h.index,motion.headings[i]),"slot_position":targets.get(h.index,pos),
			"position":pos,"control_revision":_draft.groups[id].control_revision,"order_revision":_draft.layout_cache.get(id,{}).get("order_revision",0),
			"ammo":actor.ammo,"hp":actor.hp,"morale":actor.morale,"terrain":null})
	return _brains.decide(tick,_draft.nav,units,_draft.com,player)

func _mount_target(rider: Dictionary, target_ref: String) -> Dictionary:
	for row in _draft.roster:
		if row.components.get("rider_handle")!=rider:continue
		if target_ref!="" and target_ref!="field/%d/%d"%[row.handle.index,row.handle.generation]:
			return R.fail("NotFound","mount")
		var rider_pose:Dictionary=_move.view(rider,_draft.stage)
		var horse_pos:Vector3=_frame.get("pose",{}).get(row.handle.index,{}).get("position",_meters(row.components.spawn_position_mm))
		if not rider_pose.ok or rider_pose.value.position.distance_squared_to(horse_pos)>9.0:
			return R.fail("Unavailable","mount.distance")
		return R.ok(row.handle)
	return R.fail("NotFound","mount")

func _change_mount(rider:Dictionary, action:String, target_ref:String) -> Dictionary:
	var before:Dictionary=_draft.com.view(rider)
	if not before.ok:return before
	if action=="mount":
		if before.value.mount_handle!=null:return R.ok()
		var horse:=_mount_target(rider,target_ref)
		if not horse.ok:return horse
		var changed:Dictionary=_draft.com.mount(rider,horse.value)
		if not changed.ok:return changed
	else:
		if before.value.mount_handle==null:return R.ok()
		var changed:Dictionary=_draft.com.dismount(rider)
		if not changed.ok:return changed
	return _sync_profile(rider)

func _sync_profile(rider: Dictionary) -> Dictionary:
	var state:Dictionary=_draft.com.view(rider)
	if not state.ok:return state
	var profile: String="foot" if state.value.mount_handle==null else "mounted"
	var switched:Dictionary=_move.set_profile(rider,profile,_draft.stage)
	if not switched.ok:_draft["profile_error"]=true
	if switched.ok:
		var member:Dictionary=_form.member_formation(rider)
		if member.ok and _draft.layout_cache.has(member.value):
			# Rebuild profile-specific lanes without losing the committed revision or changing its snapshot.
			var layout: Dictionary = _draft.layout_cache[member.value]
			_draft.layout_cache[member.value] = layout.merged({"signature":null},true)
	return switched

func _apply_mount_requests(tick: int) -> Dictionary:
	for key in _mount_orders:
		var order:Dictionary=_mount_orders[key]
		var history:Dictionary=_form.order_status(order.issuer_id,order.order_id)
		if not history.ok:return history
		var pending:=false
		for id in order.formation_ids:
			var entry:Dictionary=history.value.get(id,{})
			if entry.get("state")=="Pending":pending=true
			if entry.get("state")!="Completed" or entry.get("tick")!=tick:continue
			for h in _draft.groups.get(id,{}).get("members",[]):
				if not _kit(_draft.rows[h.index].components).mounted:continue
				var changed:=_change_mount(h,order.order_type,"")
				if not changed.ok and changed.error.field!="mount.distance":return changed
		if not pending:_draft.resolved_mount_orders.append(key)
	if not _input.is_empty():
		for intent in _input.batch.inputs:
			if intent.get("action") not in ["mount","dismount"]:continue
			if not _drive_authorized(_mission,intent.actor_handle,_input.context,tick):return R.fail("Unauthorized","actor_handle")
			var applied:=_change_mount(intent.actor_handle,intent.action,intent.target_ref)
			if not applied.ok and _draft.get("profile_error",false):return applied
			_draft.interactions.append(applied)
	return R.ok()

static func _project_actor(previous: PoseProjection, row: Dictionary, position: Vector3, velocity: Vector3, heading: Vector3, mounted: bool, shield: bool, aim_pitch: Variant=null) -> PoseProjection:
	var same_geometry := false
	if previous!=null and is_same(previous.source,row):
		same_geometry = previous.pose.position==position and previous.pose.heading==heading and previous.body.mounted==mounted and previous.body.shield==shield
		if same_geometry and previous.pose.velocity==velocity and previous.pose.get("aim_pitch")==aim_pitch:
			return previous
	var next := PoseProjection.new()
	next.source=row
	next.pose={"position":position,"velocity":velocity,"heading":heading}
	if same_geometry:
		next.body=previous.body
	else:
		next.body={"handle":row.handle,"type":"mount" if row.source_slot==null else "human","team_key":row.components.team_key,
			"position":position,"facing":heading,"mounted":mounted,"shield":shield}
		next.body.make_read_only()
	var origin := position+Vector3.UP
	if mounted:origin+=Vector3.UP*.8
	var position_mm := _mm(origin)
	var facing_ppm := _mm(heading,1000000)
	position_mm.make_read_only()
	facing_ppm.make_read_only()
	next.combat={"position_mm":position_mm,"facing_ppm":facing_ppm,"speed_mm_tick":roundi(velocity.length()*1000.0/60.0)}
	if aim_pitch!=null:
		var muzzle := _mm(origin+Vector3.UP*.44)
		var aim := _mm(heading*cos(aim_pitch)+Vector3.UP*sin(aim_pitch),1000000)
		muzzle.make_read_only()
		aim.make_read_only()
		next.combat.shot_origin_mm=muzzle
		next.combat.shot_aim_ppm=aim
		next.pose.shot_origin=_meters(muzzle)
		next.pose.aim_pitch=aim_pitch
	next.pose.make_read_only()
	next.combat.make_read_only()
	return next

static func _store_projection(projection: PoseProjection, slot: int, physical: Array, next: Dictionary, pose: Dictionary, combat: Dictionary) -> void:
	if slot==physical.size(): physical.append(projection.body)
	else: physical[slot]=projection.body
	var index: int=projection.source.handle.index
	next[index]=projection
	pose[index]=projection.pose
	combat[index]=projection.combat

func _walk(_ctx: Dictionary, batch: Dictionary) -> Dictionary:
	for command in _draft.moves:
		var moved: Dictionary = _move.apply_move_intent(_draft.stage,command.intent,command.context)
		if not moved.ok: return moved
	for command in _draft.ai_moves:
		var moved: Dictionary = _move.apply_move_intent(_draft.stage,command.intent,command.context)
		_draft.move_receipts.append(moved)
	var walk: Dictionary = _move.stage_step(batch.source_tick,1.0/60.0,_draft.stage)
	if not walk.ok: return walk
	var moved_poses:Dictionary=_move.read_poses(_draft.token,_draft.stage)
	if not moved_poses.ok:return moved_poses
	_draft["motion"]=moved_poses.value
	var positions: PackedVector3Array=moved_poses.value.positions
	var velocities: PackedVector3Array=moved_poses.value.velocities
	var headings: PackedVector3Array=moved_poses.value.headings
	var previous: Dictionary=_frame.get("projections",{})
	var traits: Dictionary = _draft.com.field_motion_traits(_mission)
	if not traits.ok: return traits
	var mounts: Dictionary = traits.value.mounts
	var shielded: Dictionary = traits.value.shielded
	var stable := is_same(_draft.roster,_frame.get("roster"))
	var same_slots := stable and is_same(mounts,_frame.mounts)
	# A stable slot layout can share the committed tables until the first write.
	var physical: Array = _frame.physical if same_slots else []
	var slots: PackedInt32Array = _frame.human_slots if same_slots else PackedInt32Array()
	var next: Dictionary = previous
	var pose: Dictionary = _frame.get("pose",{})
	var combat: Dictionary = _frame.get("combat_poses",{})
	if stable and not same_slots:
		# A remount rebuilds physical slots; keep the published dictionary order.
		next = next.duplicate()
		pose = pose.duplicate()
		combat = combat.duplicate()
	elif not stable:
		next = {}
		pose = {}
		combat = {}
		for row in _draft.roster: combat[row.handle.index] = null
	var shared := same_slots
	var old_positions: PackedVector3Array=_frame.motion.positions if same_slots else PackedVector3Array()
	var old_velocities: PackedVector3Array=_frame.motion.velocities if same_slots else PackedVector3Array()
	var old_headings: PackedVector3Array=_frame.motion.headings if same_slots else PackedVector3Array()
	var old_look: Dictionary=_frame.look if same_slots else {}
	var look: Dictionary=_draft.look
	var same_shields := same_slots and is_same(shielded,_frame.shielded)
	var ridden := {}
	var aiming_handle: Variant=_draft.aim_handle
	var pitch_unchanged: bool=_frame.get("aim_handle")==aiming_handle and _frame.get("aim_pitch")==_draft.aim_pitch
	var same_look := is_same(old_look,look)
	# Packed column comparison runs in the engine; an unchanged battlefield
	# needs no per-soldier script loop or new projection containers.
	var humans_to_check: int = _draft.humans.size()
	if same_slots and same_look and same_shields and pitch_unchanged:
		if old_positions == positions and old_velocities == velocities and old_headings == headings:
			humans_to_check = 0
	for i in humans_to_check:
		var h: Dictionary = _draft.humans[i]
		var index: int = h.index
		if same_slots and old_positions[i] == positions[i] and old_velocities[i] == velocities[i] and old_headings[i] == headings[i]:
			var aim_changed: bool = not pitch_unchanged and (h == aiming_handle or h == _frame.aim_handle)
			if not aim_changed and (same_shields or shielded.has(index) == _frame.shielded.has(index)):
				if same_look or old_look.get(index,old_headings[i]) == look.get(index,headings[i]):
					continue
		if shared:
			physical = physical.duplicate()
			next = next.duplicate()
			pose = pose.duplicate()
			combat = combat.duplicate()
			shared = false
		var heading: Vector3 = look.get(index,headings[i])
		var mount: Variant=mounts.get(index)
		if not same_slots: slots.append(physical.size())
		var projection := _project_actor(previous.get(index),_draft.rows[index],positions[i],velocities[i],heading,mount!=null,shielded.has(index),_draft.aim_pitch if h==aiming_handle else null)
		_store_projection(projection,slots[i],physical,next,pose,combat)
		if mount!=null:
			var horse: int=mount.index
			projection=_project_actor(previous.get(horse),_draft.rows[horse],positions[i],velocities[i],headings[i],false,false)
			_store_projection(projection,slots[i]+1,physical,next,pose,combat)
			if not same_slots: ridden[horse]=true
	if not same_slots:
		for row in _draft.horses:
			if ridden.has(row.handle.index):continue
			var last: PoseProjection=previous.get(row.handle.index)
			var same_horse := last!=null and is_same(last.source,row)
			var position: Vector3=last.pose.position if same_horse else _meters(row.components.spawn_position_mm)
			var heading: Vector3=last.pose.heading if same_horse else Vector3.FORWARD
			_store_projection(_project_actor(last,row,position,Vector3.ZERO,heading,false,false),physical.size(),physical,next,pose,combat)
	_draft["human_slots"]=slots
	_draft["mounts"]=mounts
	_draft["shielded"]=shielded
	_draft["projections"]=next
	_draft["pose"]=pose
	_draft["combat_poses"]=combat
	var stage: Dictionary = _engine.field_stage_bodies(_mission,physical)
	if not stage.ok: return stage
	_draft["physical"]=physical
	return R.ok()

func _fight(ctx: Dictionary, batch: Dictionary) -> Dictionary:
	var actions: Array = _draft.actions+_draft.ai
	var combat: Dictionary = _draft.com.step_field(batch.source_tick,actions,_draft.combat_poses,func(q,t):return _engine.field_sweep(_mission,q,t))
	if not combat.ok: return combat
	for event in combat.value.events:
		if event.type=="dismounted":
			var switched:=_sync_profile(event.actor_handle)
			if not switched.ok:return switched
	var received: Dictionary = _brains.accept_actions(combat.value.receipts.slice(_draft.actions.size()),_draft.move_receipts)
	if not received.ok: return received
	var observed: Dictionary = _results.observe_combat(ctx,batch,combat.value)
	if not observed.ok: return observed
	_draft["combat_report"]=combat.value
	# Only the observations used by later Mission systems cross the canonical report boundary.
	return R.ok({"events":combat.value.events,"hits":combat.value.hits,"receipts":combat.value.receipts.slice(0,_draft.actions.size()),"interactions":_draft.interactions})

func _casualties(_ctx: Dictionary, _batch: Dictionary) -> Dictionary:
	var retiring := []
	for e in _draft.combat_report.events:
		if e.type=="downed": retiring.append(e.actor_handle)
	return R.ok({"retire_handles":retiring})

func _snapshot(ctx: Dictionary, batch: Dictionary) -> Dictionary:
	var rule_report: Dictionary
	for report in ctx.phase_reports:
		if report.id=="field.rules": rule_report=report.value
	var staged: Dictionary = _results.stage_snapshot(ctx,batch,rule_report)
	if not staged.ok: return staged
	_draft["ending_rows"]=ctx.entities
	if not is_same(ctx.entities,_draft.roster) or _draft.combat_report.events.any(func(e):return e.type=="dismounted"):
		var active := {}
		for row in ctx.entities: active[row.handle.index]=row.handle
		var updated := []
		for p in _draft.physical:
			if active.get(p.handle.index)==p.handle:
				if p.get("mounted",false) and _draft.com.view(p.handle).value.mount_handle==null:
					p=p.duplicate()
					p.mounted=false
				updated.append(p)
		# New reinforcements obtain their first MOV/COM step next tick; stage their actual spawn placement now.
		for row in ctx.entities:
			if _draft.rows.get(row.handle.index,{}).get("handle")==row.handle: continue
			var p := {"handle":row.handle,"type":row.components.type,"team_key":row.components.team_key,"position":_meters(row.components.spawn_position_mm)}
			p["mounted"]=row.source_slot!=null and _kit(row.components).mounted
			updated.append(p)
		_engine.field_rollback_bodies(_mission)
		var placed: Dictionary = _engine.field_stage_bodies(_mission,updated)
		if not placed.ok: return placed
	return R.ok()

func _seal_tick() -> Dictionary:
	if not _input.is_empty() and not _input.batch.inputs.is_empty() and not _pending_input_authorized():
		return R.fail("Unauthorized","field.input")
	return _move.commit_step(_draft.stage)

func _revert() -> void:
	if _draft.is_empty(): return
	_engine.field_rollback_bodies(_mission)
	_results.rollback()
	_brains.rollback_tick()
	_form.rollback_tick()
	_move.rollback_step(_draft.stage)
	_draft={}

func _publish() -> void:
	_engine.field_commit_bodies(_mission)
	_results.commit()
	_brains.commit_tick()
	_form.commit_tick()
	_com=_draft.com
	_user_handle=_draft.player
	if _user_handle!=null and _draft.rows.get(_user_handle.index,{}).get("handle")==_user_handle:
		_player_pose=_draft.pose[_user_handle.index]
	_layout_specs=_draft.layout_cache
	for key in _draft.resolved_mount_orders:_mount_orders.erase(key)
	_frame={"roster":_draft.roster,"rows":_draft.rows,"ending_rows":_draft.ending_rows,"groups":_draft.groups,"nav":_draft.nav,"humans":_draft.humans,"token":_draft.token,
		"membership":_draft.membership,"slot_sources":_draft.slot_sources,"targets":_draft.targets,
		"roles":_draft.roles,"horses":_draft.horses,"motion":_draft.motion,"projections":_draft.projections,"combat_poses":_draft.combat_poses,
		"human_slots":_draft.human_slots,"physical":_draft.physical,"mounts":_draft.mounts,"shielded":_draft.shielded,
		"look":_draft.look,"pose":_draft.pose,"metrics":_draft.metrics,"combat_report":_draft.combat_report,"aim_handle":_draft.aim_handle,"aim_pitch":_draft.aim_pitch}
	_draft={}
	if not _input.is_empty(): _consumed=_input
	_input={}

func _needs_opening_wave(store: Entities) -> bool:
	return store.active_sources<mini(store.reserved_count,_spec.battle_limit)
