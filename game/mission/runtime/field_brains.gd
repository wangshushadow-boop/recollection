extends RefCounted
## Dispatches the current Mission's grants. FORM, MOV and COM execute all commands.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const Board = preload("res://mission/ai/ports/field_ai.gd")
const Tactics = preload("res://mission/ai/tactical/ports/field_tactics.gd")
const Squads = preload("res://mission/ai/formation/ports/field_formation_ai.gd")
const Individual = preload("res://mission/ai/individual/ports/field_individual.gd")

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

func _ground(id: int, nav: int) -> Dictionary:
	var g: Dictionary = _groups[id]
	if g.terrain!=null: return R.ok(g.terrain)
	var origin: Vector3 = g.center
	var across: Vector3 = g.heading.cross(Vector3.UP).normalized()
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
	return R.ok({"reachable":width>=1.0,"clear_width":width,"spacing":1.0,"yaw":atan2(-g.heading.x,-g.heading.z),"slot_error":g.slot_error})

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

func _individual(job: Dictionary, nav: int, combat: RefCounted, cache: Dictionary, proposals: Dictionary, metrics: Dictionary) -> Dictionary:
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
	var local := {"nav_revision":nav,"can_travel":_path,"slot_position":row.slot_position,"heading":row.heading,"exit_position":_teams[row.team_key].exit_position}
	for key in ["threat_handle","threat_direction","react_at","reaction_skill"]:
		if row.has(key): local[key] = row[key]
	var decision: Dictionary = _draft.decide(job,observed.value,physical.value,state.value.member_constraint,local)
	if not decision.ok: return decision
	var admitted: Dictionary = _ai.collect(job,decision.value.intents)
	if not admitted.ok: return admitted
	proposals[job.id] = decision.value
	metrics.individual += 1
	var mode: String = decision.value.mode
	metrics.modes[mode] = metrics.modes.get(mode,0)+1
	var by_role: Dictionary = metrics.role_modes.get_or_add(row.role,{})
	by_role[mode] = by_role.get(mode,0)+1
	return R.ok()

func decide(tick: int, nav: int, units: Array, combat: RefCounted, player_handle: Variant) -> Dictionary:
	if not _valid or _busy or not _checkpoint.is_empty():
		return R.fail("InvalidState","field_brains")
	_checkpoint = {"roster":_roster,"identity":_identity,"vitals":_vitals,"sequence":_sequence.duplicate()}
	_busy = true
	var computed := R.ok()
	for domain in _domains:
		computed = domain.begin_tick()
		if not computed.ok: break
	if computed.ok:
		_draft = _l3.fork()
		computed = _index(tick,nav,units)
	if computed.ok: computed = _dispatch(tick,nav,combat,player_handle)
	_busy = false
	if not computed.ok: rollback_tick()
	return computed

func _dispatch(tick: int,nav: int,combat: RefCounted,player: Variant) -> Dictionary:
	var scheduled: Dictionary = _ai.schedule()
	if not scheduled.ok: return scheduled
	var metrics := {"tick":tick,"tactical":0,"formation":0,"individual":0,"orders":0,"modes":{},"role_modes":{},"backlog":scheduled.value.backlog}
	var jobs: Array = scheduled.value.jobs
	for job in jobs:
		if job.layer!="tactical": continue
		var result := _tactical(job)
		if not result.ok: return result
		metrics.tactical += 1
	var drained: Dictionary = _ai.drain()
	if not drained.ok or drained.value.size()!=metrics.tactical:
		return R.fail("StaleVersion","field_ai_plan")
	var tasks := {}
	for team in _l1:
		for task in _l1[team].view().get("formation_tasks",[]):
			tasks[task.formation_id] = task
	for job in jobs:
		if job.layer!="formation": continue
		var result := _formation(job,nav,tasks,metrics)
		if not result.ok: return result
		metrics.formation += 1
	var states := {}
	var proposals := {}
	for job in jobs:
		if job.layer!="individual" or job.subject==player: continue
		var result := _individual(job,nav,combat,states,proposals,metrics)
		if not result.ok: return result
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
	_sequence = _checkpoint.sequence
	_clear()
