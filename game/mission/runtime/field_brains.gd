extends RefCounted
## Dispatches the current Mission's grants. FORM, MOV and COM execute all commands.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const Board = preload("res://mission/ai/ports/field_ai.gd")
const Tactics = preload("res://mission/ai/tactical/ports/field_tactics.gd")
const Squads = preload("res://mission/ai/formation/ports/field_formation_ai.gd")
const Individual = preload("res://mission/ai/individual/ports/field_individual.gd")
const AI_BATCHES := 4
const CHARGE_LOOKAHEAD := 12.0

class MemberWork:
	var job: Dictionary
	var observed: Dictionary
	var combat: Dictionary
	var rules: Dictionary
	var local: Dictionary
	var decision: Dictionary
	var destination: Variant

	# Only used when there are no enemy candidates. The FSM can then ask
	# for one move to the formation slot or exit, after choosing its action.
	func record_move(_from: Vector3, to: Vector3, _nav: int) -> bool:
		destination = to
		return true

var _scope: String
var _engine: RefCounted
var _form: RefCounted
var _teams := {}
var _ai: RefCounted
var _l1 := {}
var _l2 := {}
var _l3: RefCounted
var _domains: Array = []
var _valid := true
var _roster := {}
var _identity: Array = []
var _member_indexes := {}
var _vitals: Array = []
var _field_cache := {}
var _field := {}
var _sequence := {}
var _checkpoint := {}
var _draft: RefCounted
var _units := {}
var _groups := {}
var _pending := []
var _action_count := 0
var _move_count := 0
var _accepted := false
var _path_error := {}
var _busy := false
var _visible := {}
var _watched := {}

func _init(scope: String, engine: RefCounted, form: RefCounted, teams: Array) -> void:
	_scope = scope
	_engine = engine
	_form = form
	_ai = Board.new(scope,_los,60,_live)
	_l3 = Individual.new(scope,_ai.get_instance_id())
	_domains = [_ai]
	var issuers := {}
	var contexts := {}
	for t in teams:
		if not t is Dictionary or not t.has("team_key") or _teams.has(t.team_key) or not t.get("issuer") is String or t.issuer.is_empty() or issuers.has(t.issuer) or t.get("context")==null or contexts.has(t.context) or not t.get("sites") is Array or not t.get("exit_position") is Vector3:
			_valid = false
			return
		issuers[t.issuer] = true
		contexts[t.context] = true
		_teams[t.team_key] = t.duplicate(true)
		_teams[t.team_key].context = t.context
		# A general charge can search across the field before a scout sees anyone.
		# Its direction comes from friendly terrain, never the opposing roster.
		for site in t.sites:
			if site is Dictionary and site.get("objective")==true and site.get("position") is Vector3:
				var front: Vector3 = site.position-t.exit_position
				front.y = 0.0
				if not front.is_finite() or front.is_zero_approx(): continue
				_teams[t.team_key]["assault_axis"] = front.normalized()
				break
		_l1[t.team_key] = Tactics.new(scope,t.team_key,_granted.bind(t.team_key),_probe,_team_intel,_ai.collect.bind([]))
		_l2[t.team_key] = Squads.new(scope,t.issuer,_ai.formation_view,_form.view,t.team_key,_ai.collect)
		_domains.append(_l1[t.team_key])
		_domains.append(_l2[t.team_key])

static func _mm(p: Vector3) -> Array:
	return [roundi(p.x*1000),roundi(p.y*1000),roundi(p.z*1000)]

func _los(a: Vector3,b: Vector3) -> bool:
	return _engine.field_los(_scope,a,b)

func _path(a: Vector3,b: Vector3,nav: int) -> bool:
	var reply: Dictionary = _engine.query_path_batch([{"from":_mm(a),"to":_mm(b)}],nav,_scope)
	if not reply.ok:
		_path_error = reply
		return false
	return reply.value[0].reachable

func _probe(scope: String, nav: int, _id: int, a: Vector3,b: Vector3,enemy: Variant,_role: String) -> Dictionary:
	if scope!=_scope:
		return R.fail("NotFound","mission_id")
	var reachable := _path(a,b,nav)
	return R.ok({"reachable":reachable,"line":enemy!=null and _los(b,enemy)}) if _path_error.is_empty() else _path_error

func _team_intel(key: Variant) -> Dictionary:
	var read: Dictionary = _ai.team_view(key)
	return read.value if read.ok else {}

func _visible_groups(key: Variant) -> Array:
	var contacts := {}
	for row in _team_intel(key).get("visible_enemies",[]):
		contacts[row.formation_id] = true
	var ids := contacts.keys()
	ids.sort()
	return ids

func visible_formations(team_key: Variant) -> Array:
	if not _teams.has(team_key): return []
	_watched[team_key] = true
	if _checkpoint.is_empty() and not _visible.has(team_key):
		_visible[team_key] = _visible_groups(team_key)
	return _visible.get(team_key,[]).duplicate()

static func _order_state(view: Dictionary) -> Array:
	return [view.active,view.queued,view.routing,view.fire_mode,view.layout,view.distance_mm,
		view.mounted,view.facing_target_id,view.use_ranged,view.facing_microradians,view.terrain_feedback]

func _live_group(id: int) -> Dictionary:
	if not _groups.has(id):
		return {}
	var g: Dictionary = _groups[id]
	var read: Dictionary = _form.view(id)
	if not read.ok or not is_same(read.value.team_key,g.team_key) or read.value.members_revision!=g.members_revision or read.value.control_revision!=g.control_revision or _order_state(read.value)!=g.order_state:
		return {}
	return {"control_revision":g.control_revision,"order_revision":g.order_revision}

func _live(layer: String, subject: Variant) -> Dictionary:
	if layer=="tactical":
		var revisions := {}
		for id in _groups:
			if is_same(_groups[id].team_key,subject):
				var current := _live_group(id)
				if current.is_empty(): return {}
				revisions[id] = [current.control_revision,current.order_revision]
		return {"formation_revisions":revisions}
	if layer=="individual":
		var member: Dictionary = _form.member_formation(subject)
		if not member.ok or _units.get(subject.index,{}).get("formation_id")!=member.value:
			return {}
		# Validate all group grants together before releasing the batch and again at execution.
		var g: Dictionary = _groups[member.value]
		return {"control_revision":g.control_revision,"order_revision":g.order_revision}
	return _live_group(subject)

func _granted(scope: String, id: int, control: int, order: int, team: Variant) -> bool:
	if scope!=_scope or _live_group(id)!={"control_revision":control,"order_revision":order}:
		return false
	var view: Dictionary = _form.view(id).value
	return is_same(view.team_key,team) and _teams[team].issuer in [view.owner,view.delegate]

func _index(tick: int,nav: int,units: Array) -> Dictionary:
	var identity := []
	var vitals := []
	var positions := PackedVector3Array()
	var urgent := []
	var changes := []
	for row in units:
		if not row is Dictionary or not row.get("handle") is Dictionary or not _teams.has(row.get("team_key")) or not V.integer(row.get("formation_id")) or not row.get("heading") is Vector3 or not row.get("slot_position") is Vector3 or not row.get("position") is Vector3:
			return R.fail("InvalidArgument","field_ai_member")
		if not row.heading.is_finite() or not row.slot_position.is_finite() or (row.get("terrain")!=null and not row.terrain is Dictionary):
			return R.fail("InvalidArgument","field_ai_pose")
		var handle: Dictionary = row.handle
		var id: int = row.formation_id
		if not _groups.has(id):
			var f: Dictionary = _form.view(id)
			if not f.ok: return R.fail("StaleVersion","field_ai_member")
			var index: Dictionary = _member_indexes.get(id,{})
			# FORM rolls back its numeric revision; compare its owned snapshot as well.
			if index.is_empty() or index.revision!=f.value.members_revision or index.members!=f.value.members:
				var generations := {}
				for member: Dictionary in f.value.members:
					generations[member.index] = member.generation
				index = {"revision":f.value.members_revision,"members":f.value.members,"generations":generations}
			_groups[id] = {"team_key":f.value.team_key,"control_revision":f.value.control_revision,
				"order_revision":row.get("order_revision"),"members_revision":f.value.members_revision,"order_state":_order_state(f.value),
				"count":0,"member_index":index,"center":Vector3.ZERO,"heading":row.heading,
				"terrain":row.get("terrain"),"slot_error":0.0}
		var g: Dictionary = _groups[id]
		var actor_index: Variant = handle.get("index")
		var generation: Variant = handle.get("generation")
		if handle.size()!=2 or not actor_index is int or not generation is int or g.member_index.generations.get(actor_index)!=generation or _units.has(actor_index):
			return R.fail("StaleVersion","field_ai_member")
		if not is_same(g.team_key,row.team_key) or g.control_revision!=row.get("control_revision") or g.order_revision!=row.get("order_revision"):
			return R.fail("StaleVersion","field_ai_group")
		identity.append([actor_index,generation,row.team_key,id,row.get("role"),g.control_revision,g.order_revision])
		var condition := [row.get("hp",100),row.get("ammo",0),row.get("morale",70)]
		if vitals.size()<_vitals.size() and condition!=_vitals[vitals.size()]:
			changes.append({"handle":handle,"hp":condition[0],"ammo":condition[1],"morale":condition[2]})
		vitals.append(condition)
		positions.append(row.position)
		if row.get("urgent",false): urgent.append(handle)
		_units[handle.index] = row
		g.center += row.position
		g.slot_error = maxf(g.slot_error,row.position.distance_to(row.slot_position))
		g.count += 1
	for g: Dictionary in _groups.values():
		if g.count!=g.member_index.members.size():
			return R.fail("StaleVersion","field_ai_roster")
		g.center /= g.count
	var read: Dictionary
	if _roster.is_empty() or identity!=_identity:
		read = _ai.publish(tick,nav,units)
		if read.ok:
			_roster = read.value
			for prior in _identity:
				if not _units.has(prior[0]) or _units[prior[0]].handle.generation!=prior[1]:
					_draft.forget({"index":prior[0],"generation":prior[1]})
			_identity = identity
	else:
		# Dynamic obstacles may move without a navigation revision.
		read = _ai.advance(tick,nav,_roster,positions,urgent,changes)
	_vitals = vitals
	return read

# The field pipeline owns these pose columns and formation snapshots for the opening of this step.
func _field_roster_matches() -> bool:
	if _field_cache.is_empty() or not is_same(_field_cache.token,_field.token):
		return false
	for id in _field_cache.groups:
		var prior: Dictionary = _field_cache.groups[id]
		var current: Dictionary = _field.groups.get(id,{})
		if current.is_empty() or current.members_revision!=prior.members_revision or current.members!=prior.member_index.members:
			return false
		if current.control_revision!=prior.control_revision or _field.layout_cache.get(id,{}).get("order_revision",0)!=prior.order_revision:
			return false
	return true

func _publish_field(tick: int,nav: int,combat: RefCounted) -> Dictionary:
	var humans: Array = _field.humans
	var vitals: Dictionary = combat.field_ai_vitals(_scope,humans)
	if not vitals.ok: return vitals
	var rows := []
	var offsets := {}
	for i in humans.size():
		var h: Dictionary = humans[i]
		var id: int = _field.membership[h.index]
		var pos: Vector3 = _field.positions[i]
		var actor: Dictionary = vitals.value.actors[i]
		rows.append({"handle":h,"team_key":_field.rows[h.index].components.team_key,"role":_field.roles[h.index],
			"formation_id":id,"control_revision":_field.groups[id].control_revision,
			"order_revision":_field.layout_cache.get(id,{}).get("order_revision",0),
			"position":pos,"heading":_field.look.get(h.index,_field.headings[i]),
			"slot_position":_field.targets.get(h.index,pos),"hp":actor.hp,"ammo":actor.ammo,"morale":actor.morale})
		var group_offsets: Array = offsets.get_or_add(id,[])
		group_offsets.append(i)
	var published := _index(tick,nav,rows)
	if not published.ok: return published
	var members := {}
	for i in rows.size():
		var row: Dictionary = rows[i]
		members[row.handle.index] = {"handle":row.handle,"formation_id":row.formation_id,
			"team_key":row.team_key,"role":row.role,"offset":i}
	_units = members
	_field_cache = {"token":_field.token,"members":members,"groups":_groups,"offsets":offsets}
	return published

func _index_field(tick: int,nav: int,combat: RefCounted) -> Dictionary:
	if not _field_roster_matches():
		return _publish_field(tick,nav,combat)
	_units = _field_cache.members
	for id in _field_cache.groups:
		var group: Dictionary = _field_cache.groups[id].duplicate()
		group.order_state = _order_state(_field.groups[id])
		_groups[id] = group
	var changes := []
	for change: Dictionary in _field.changes:
		var row: Dictionary = _units.get(change.handle.index,{})
		if not row.is_empty() and row.handle==change.handle:
			# _index compares with this snapshot when rebuilding or returning to the row-based port.
			if changes.is_empty():
				_vitals = _vitals.duplicate()
			_vitals[row.offset] = [change.hp,change.ammo,change.morale]
			changes.append(change)
	return _ai.advance(tick,nav,_roster,_field.positions,[],changes)

func _ground(id: int, nav: int) -> Dictionary:
	var g: Dictionary = _groups[id]
	if g.terrain!=null: return R.ok(g.terrain)
	var origin: Vector3 = g.center
	var heading: Vector3 = g.heading
	var slot_error: float = g.slot_error
	if not _field.is_empty() and not is_same(_groups,_field_cache.groups):
		# Only a scheduled formation consumes its center, maximum slot error and first member's heading.
		var offsets: Array = _field_cache.offsets[id]
		var humans: Array = _field.humans
		var positions: PackedVector3Array = _field.positions
		var targets: Dictionary = _field.targets
		var first: int = offsets[0]
		heading = _field.look.get(humans[first].index,_field.headings[first])
		origin = Vector3.ZERO
		slot_error = 0.0
		for i: int in offsets:
			var pos := positions[i]
			origin += pos
			slot_error = maxf(slot_error,pos.distance_to(targets.get(humans[i].index,pos)))
		origin /= offsets.size()
	var across: Vector3 = heading.cross(Vector3.UP).normalized()
	if across==Vector3.ZERO: across=Vector3.RIGHT
	var paths := []
	for half: float in [0.5,1.0,2.0]:
		for signum: float in [-1.0,1.0]:
			paths.append({"from":_mm(origin),"to":_mm(origin+across*half*signum)})
	var reply: Dictionary = _engine.query_path_batch(paths,nav,_scope)
	if not reply.ok: return reply
	var width := 0.5
	for i in 3:
		if not reply.value[i*2].reachable or not reply.value[i*2+1].reachable:
			break
		width = [1.0,2.0,4.0][i]
	return R.ok({"reachable":width>=1.0,"clear_width":width,"spacing":1.0,"yaw":atan2(-heading.x,-heading.z),"slot_error":slot_error})

func _tactical(job: Dictionary) -> Dictionary:
	var team: Variant = job.subject
	var feedback := []
	for id in _groups:
		if is_same(_groups[id].team_key,team):
			var current: Dictionary = _l2[team].view(id)
			if current.ok and current.value.feedback!=null:
				feedback.append(current.value.feedback)
	var started: Dictionary = _l1[team].stage(job,_team_intel(team),_teams[team].sites,feedback)
	return _l1[team].commit() if started.ok else started

func _formation(job: Dictionary, nav: int, tasks: Dictionary, metrics: Dictionary) -> Dictionary:
	var id: int = job.subject
	var team: Variant = _groups[id].team_key
	var officer: Dictionary = _teams[team]
	var brain: RefCounted = _l2[team]
	var ground := _ground(id,nav)
	if not ground.ok: return ground
	var seq: int = _sequence.get(team,0)+1
	var proposal: Dictionary = brain.stage(job,tasks.get(id),ground.value,seq)
	if not proposal.ok and proposal.error.field in ["task_order_revision","task_control_revision"]:
		proposal = brain.stage(job,null,ground.value,seq)
	if not proposal.ok: return proposal
	var d: Dictionary = proposal.value
	var accepted: Dictionary = brain.collect(d.token)
	if not accepted.ok: return accepted
	var drained: Dictionary = _ai.drain()
	if not drained.ok or drained.value.size()!=1 or not is_same(drained.value[0].job,job):
		return R.fail("StaleVersion","field_ai_order")
	var batch: Dictionary = drained.value[0]
	for order in batch.intents:
		var issued: Dictionary = _form.issue_order(order,officer.context,d.control_revision)
		if not issued.ok: return issued
		_sequence[team] = order.client_sequence
		metrics.orders += 1
	return brain.commit(d.token,batch)

static func _holds_position(behavior: String, active: Variant) -> bool:
	if active==null: return behavior=="Hold"
	return active.order_type=="hold" and behavior in ["Hold","Regroup"]

func _prepare_member(job: Dictionary, nav: int, combat: RefCounted, cache: Dictionary) -> Dictionary:
	var row: Dictionary = _units[job.subject.index]
	var group: int = row.formation_id
	if not cache.has(group):
		cache[group] = _l2[row.team_key].view(group)
	var state: Dictionary = cache[group]
	if not state.ok:
		if state.error.code=="NotFound":
			return R.ok() # No L2 grant has published constraints for this formation yet.
		return state
	var observed: Dictionary = _ai.sense(job.subject)
	if not observed.ok: return observed
	var physical: Dictionary = combat.view(job.subject)
	if not physical.ok: return physical
	var work := MemberWork.new()
	work.job = job
	work.observed = observed.value
	work.combat = physical.value
	work.rules = state.value.member_constraint
	var slot: Vector3
	var heading: Vector3
	if _field.is_empty():
		slot = row.slot_position
		heading = row.heading
	else:
		slot = _field.targets.get(job.subject.index,_field.positions[row.offset])
		heading = _field.look.get(job.subject.index,_field.headings[row.offset])
	var active_order: Variant = _groups[group].order_state[0]
	if state.value.behavior=="Charge" and active_order!=null and active_order.order_type=="free_attack":
		if state.value.member_constraint.focus_target!=null:
			slot = state.value.local_goal
		else:
			var axis: Vector3 = _teams[row.team_key].get("assault_axis",heading)
			slot = observed.value.self.position + axis*CHARGE_LOOKAHEAD
	work.local = {"nav_revision":nav,"can_travel":_path,"slot_position":slot,"heading":heading,"exit_position":_teams[row.team_key].exit_position}
	work.local["holding_ground"] = _holds_position(state.value.behavior,active_order)
	work.local["officer_guard"] = work.local.holding_ground and active_order!=null and active_order.issuer_id==_teams[row.team_key].issuer
	for key in ["threat_handle","threat_direction","react_at","reaction_skill"]:
		if row.has(key): work.local[key] = row[key]
	return R.ok(work)

func _admit_member(work: MemberWork, proposals: Dictionary, metrics: Dictionary) -> Dictionary:
	if not work.decision.ok: return work.decision
	var plan: Dictionary = work.decision.value
	if work.destination != null and not _path(work.observed.self.position,work.destination,work.local.nav_revision):
		plan = _draft._without_quiet_move(plan)
	var admitted: Dictionary = _ai.collect(work.job,plan.intents)
	if not admitted.ok: return admitted
	proposals[work.job.id] = plan
	metrics.individual += 1
	var mode: String = plan.mode
	metrics.modes[mode] = metrics.modes.get(mode,0)+1
	var by_role: Dictionary = metrics.role_modes.get_or_add(_units[work.job.subject.index].role,{})
	by_role[mode] = by_role.get(mode,0)+1
	return R.ok()

func _decide_range(part: int, members: Array[MemberWork], batches: int) -> void:
	var begin := part * members.size() / batches
	var end := (part+1) * members.size() / batches
	for i in range(begin,end):
		var work := members[i]
		work.decision = _draft.decide(work.job,work.observed,work.combat,work.rules,work.local)

func _flush_quiet(members: Array[MemberWork], proposals: Dictionary, metrics: Dictionary) -> Dictionary:
	var batches := mini(AI_BATCHES,maxi(1,members.size()/8))
	if batches > 1:
		# Decide one disjoint slice on the mission thread while workers handle the rest.
		var group := WorkerThreadPool.add_group_task(_decide_range.bind(members,batches),batches-1,batches-1)
		_decide_range(batches-1,members,batches)
		WorkerThreadPool.wait_for_group_task_completion(group)
	else:
		_decide_range(0,members,1)
	for work in members:
		var admitted := _admit_member(work,proposals,metrics)
		if not admitted.ok: return admitted
	members.clear()
	return R.ok()

func decide(tick: int, nav: int, units: Array, combat: RefCounted, player_handle: Variant) -> Dictionary:
	return _decide(tick,nav,units,{},combat,player_handle)

func decide_compact(tick: int, nav: int, columns: Dictionary, combat: RefCounted, player_handle: Variant) -> Dictionary:
	return _decide(tick,nav,[],columns,combat,player_handle)

func _decide(tick: int,nav: int,units: Array,columns: Dictionary,combat: RefCounted,player_handle: Variant) -> Dictionary:
	if not _valid or _busy or not _checkpoint.is_empty():
		return R.fail("InvalidState","field_brains")
	_checkpoint = {"roster":_roster,"identity":_identity,"vitals":_vitals,"sequence":_sequence.duplicate(),"field_cache":_field_cache}
	_field = columns
	_busy = true
	var computed := R.ok()
	for domain in _domains:
		computed = domain.begin_tick()
		if not computed.ok: break
	if computed.ok:
		_draft = _l3.fork()
		if _field.is_empty():
			_field_cache = {}
			computed = _index(tick,nav,units)
		else:
			computed = _index_field(tick,nav,combat)
	if computed.ok: computed = _dispatch(tick,nav,combat,player_handle)
	_busy = false
	if not computed.ok: rollback_tick()
	return computed

func _dispatch(tick: int,nav: int,combat: RefCounted,player: Variant) -> Dictionary:
	var scheduled: Dictionary = _ai.schedule()
	if not scheduled.ok: return scheduled
	var metrics := {"tick":tick,"tactical":0,"formation":0,"individual":0,"orders":0,"modes":{},"role_modes":{},"backlog":scheduled.value.backlog}
	var formations := []
	var individuals := []
	for job in scheduled.value.jobs:
		match job.layer:
			"tactical":
				var result := _tactical(job)
				if not result.ok: return result
				metrics.tactical += 1
			"formation":
				formations.append(job)
			"individual":
				if job.subject!=player: individuals.append(job)
	var drained: Dictionary = _ai.drain()
	if not drained.ok or drained.value.size()!=metrics.tactical:
		return R.fail("StaleVersion","field_ai_plan")
	# Taking a tactical view copies the plan. Only scheduled formations need it.
	var tasks := {}
	var teams_read := {}
	for job in formations:
		var team: Variant = _groups[job.subject].team_key
		if not teams_read.has(team):
			for task in _l1[team].view().get("formation_tasks",[]):
				tasks[task.formation_id] = task
			teams_read[team] = true
		var result := _formation(job,nav,tasks,metrics)
		if not result.ok: return result
		metrics.formation += 1
	var states := {}
	var proposals := {}
	var quiet: PackedByteArray = _ai._rank_scheduled(individuals,AI_BATCHES)
	var pending: Array[MemberWork] = []
	for i in individuals.size():
		# Resolve earlier moves before this member can issue any LOS or path queries.
		if not quiet[i] and not pending.is_empty():
			var flushed := _flush_quiet(pending,proposals,metrics)
			if not flushed.ok: return flushed
		var prepared := _prepare_member(individuals[i],nav,combat,states)
		if not prepared.ok:
			if not pending.is_empty():
				var earlier := _flush_quiet(pending,proposals,metrics)
				if not earlier.ok: return earlier
			return prepared
		if prepared.value == null: continue
		var work: MemberWork = prepared.value
		if quiet[i]:
			work.local.can_travel = work.record_move
			pending.append(work)
		else:
			work.decision = _draft.decide(work.job,work.observed,work.combat,work.rules,work.local)
			var admitted := _admit_member(work,proposals,metrics)
			if not admitted.ok: return admitted
	if not pending.is_empty():
		var flushed := _flush_quiet(pending,proposals,metrics)
		if not flushed.ok: return flushed
	if not _path_error.is_empty(): return _path_error
	drained = _ai.drain()
	if not drained.ok or drained.value.size()!=proposals.size():
		return R.fail("StaleVersion","field_ai_decisions")
	for id in _groups:
		if _live_group(id).is_empty(): return R.fail("StaleVersion","field_ai_authority")
	var actions := []
	var moves := []
	var looks := []
	for batch in drained.value:
		var row: Dictionary = _units[batch.job.subject.index]
		var owner := {"batch":batch,"plan":proposals[batch.job.id],"action":-1,"move":-1}
		for intent in batch.intents:
			if intent.has("desired_direction"):
				owner.move = moves.size()
				moves.append({"intent":intent,"context":_teams[row.team_key].context})
			elif intent.has("yaw"):
				looks.append(intent)
			else:
				owner.action = actions.size()
				actions.append(intent)
		_pending.append(owner)
	_action_count = actions.size()
	_move_count = moves.size()
	return R.ok({"actions":actions,"moves":moves,"looks":looks,"metrics":metrics})

func accept_actions(action_receipts: Array,move_receipts: Array) -> Dictionary:
	if _busy or _checkpoint.is_empty() or _accepted:
		return R.fail("InvalidState","field_ai_receipts")
	if action_receipts.size()!=_action_count or move_receipts.size()!=_move_count:
		return R.fail("InvalidArgument","field_ai_receipts")
	for receipt in action_receipts+move_receipts:
		if not receipt is Dictionary or not receipt.get("ok") is bool:
			return R.fail("InvalidArgument","field_ai_receipt")
	for id in _groups:
		if _live_group(id).is_empty():
			return R.fail("StaleVersion","field_ai_authority")
	for member in _pending:
		var action: Dictionary = R.ok() if member.action<0 else action_receipts[member.action]
		var move: Dictionary = R.ok() if member.move<0 else move_receipts[member.move]
		var reply: Dictionary = _draft.accept(member.batch,member.plan,action,move)
		if not reply.ok: return reply
	_accepted = true
	return R.ok()

func _clear() -> void:
	_draft = null
	_field = {}
	_checkpoint = {}
	_groups = {}
	_units = {}
	_pending = []
	_action_count = 0
	_move_count = 0
	_accepted = false
	_path_error = {}

func commit_tick() -> void:
	if _busy or not _accepted: return
	for domain in _domains: domain.commit_tick()
	_member_indexes.clear()
	for id in _groups:
		_member_indexes[id] = _groups[id].member_index
	for team in _watched:
		_visible[team] = _visible_groups(team)
	_l3 = _draft
	_clear()

func rollback_tick() -> void:
	if _busy or _checkpoint.is_empty(): return
	for domain in _domains: domain.rollback_tick()
	_roster = _checkpoint.roster
	_identity = _checkpoint.identity
	_vitals = _checkpoint.vitals
	_field_cache = _checkpoint.field_cache
	_sequence = _checkpoint.sequence
	_clear()
