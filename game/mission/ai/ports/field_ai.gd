extends RefCounted
## Mission-thread coordinator. Workers receive immutable jobs and permitted views.
## Consumers forward drained suggestions to the regular COM/MOV/FORM input ports.
const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const Perception = preload("res://mission/ai/perception/field_perception.gd")
const Schedule = preload("res://mission/ai/scheduler/field_schedule.gd")

var _mission: String
var _los: Callable
var _hz: int
var _live: Callable
var _live_required := false
var _tick := -1
var _nav := -1
var _visibility_revision := -1
var _roster := {}
var _roster_version := 0
var _last_generation := {}
var _board: RefCounted
var _scheduler := Schedule.new()
var _issued := {}
var _results := {}
var _serial := 0
var _issued_total := 0
var _stale_results := 0
var _closed := false
var _busy := false
var _checkpoint := {}

func _init(mission_id: String, line_of_sight: Callable, tick_hz := 60, live_stamp: Callable = Callable()) -> void:
	_mission = mission_id
	_los = line_of_sight
	_hz = tick_hz
	_live = live_stamp
	_live_required = not live_stamp.is_null()

func begin_tick() -> Dictionary:
	if _busy or _closed or not _checkpoint.is_empty():
		return R.fail("InvalidState","ai_transaction")
	_checkpoint = {"board":_board,"tick":_tick,"nav":_nav,"visibility":_visibility_revision,
		"roster":_roster,"version":_roster_version,"generations":_last_generation,
		"issued":_issued.duplicate(),"results":_results.duplicate(),"issued_total":_issued_total,"stale":_stale_results}
	if _board != null:
		_board.begin_tick()
	_scheduler.begin_tick()
	return R.ok()

func commit_tick() -> void:
	if _busy or _checkpoint.is_empty():
		return
	if _checkpoint.board != null:
		_checkpoint.board.commit_tick()
	_scheduler.commit_tick()
	_checkpoint = {}

func rollback_tick() -> void:
	if _busy or _checkpoint.is_empty():
		return
	_board = _checkpoint.board
	if _board != null:
		_board.rollback_tick()
	_scheduler.rollback_tick()
	_tick = _checkpoint.tick
	_nav = _checkpoint.nav
	_visibility_revision = _checkpoint.visibility
	_roster = _checkpoint.roster
	_roster_version = _checkpoint.version
	_last_generation = _checkpoint.generations
	_issued = _checkpoint.issued
	_results = _checkpoint.results
	_issued_total = _checkpoint.issued_total
	_stale_results = _checkpoint.stale
	_checkpoint = {}

func publish(tick: int, nav_revision: int, units: Array) -> Dictionary:
	if _closed or _busy:
		return R.fail("InvalidState","ai_scope")
	if tick <= _tick or nav_revision < _nav:
		return R.fail("StaleVersion","ai_snapshot")
	if _mission.is_empty() or not _los.is_valid() or _hz < 5 or _hz > 240 or not V.integer(tick) or not V.integer(nav_revision):
		return R.fail("InvalidArgument","ai_snapshot")
	var next := Perception.new()
	var checked := next.build(units)
	if not checked.ok:
		return checked
	for id in next.actors:
		var generation: int = next.actors[id].handle.generation
		var previous: int = _last_generation.get(id,0)
		if generation < previous or (generation==previous and not _board.actors.has(id)):
			return R.fail("StaleVersion","actor_generation")
	if _board != null:
		for group in next.formations:
			if _board.formations.has(group):
				var before: Dictionary = _board.formations[group][0]
				var after: Dictionary = next.formations[group][0]
				if after.control_revision < before.control_revision or after.order_revision < before.order_revision:
					return R.fail("StaleVersion","formation_revision")
	if not _checkpoint.is_empty() and is_same(_last_generation,_checkpoint.generations):
		_last_generation = _last_generation.duplicate()
	for id in next.actors:
		_last_generation[id] = next.actors[id].handle.generation
	_board = next
	_roster_version += 1
	_roster = {"scope_id":_mission,"instance":get_instance_id(),"version":_roster_version}
	_roster.make_read_only()
	_tick = tick
	_nav = nav_revision
	_issued.clear()
	_results.clear()
	return R.ok(_roster)

## Positions follow the authoritative roster's publish order. A new roster, a
## generation or an order/control revision change must go through publish().
## Only a supplied occluder epoch enables cross-tick reuse of unchanged rays.
func advance(tick: int, nav_revision: int, roster_token: Dictionary, positions: PackedVector3Array,
		urgent_handles: Array = [], state_changes: Array = [], visibility_revision: int = -1) -> Dictionary:
	if _busy or _board == null:
		return R.fail("InvalidState","ai_scope")
	if not is_same(_roster,roster_token) or tick <= _tick or nav_revision < _nav:
		return R.fail("StaleVersion","ai_roster")
	if not V.integer(tick) or not V.integer(nav_revision) or not V.integer(visibility_revision,-1):
		return R.fail("InvalidArgument","ai_stamp")
	if visibility_revision >= 0 and visibility_revision < _visibility_revision:
		return R.fail("StaleVersion","visibility_revision")
	var updated: Dictionary = _board.advance(tick,visibility_revision,nav_revision!=_nav,positions,urgent_handles,state_changes)
	if not updated.ok:
		return updated
	_tick = tick
	_nav = nav_revision
	_visibility_revision = maxi(_visibility_revision,visibility_revision)
	_issued.clear()
	_results.clear()
	return R.ok()

func _stamp(layer: String, subject: Variant) -> Dictionary:
	var stamp := {"scope_id":_mission,"instance":get_instance_id(),"tick":_tick,"nav_revision":_nav}
	if layer == "individual" or layer == "formation":
		var own: Dictionary = _board.actors[subject.index] if layer == "individual" else _board.formations[subject][0]
		stamp.control_revision = own.control_revision
		stamp.order_revision = own.order_revision
		if layer == "individual":
			stamp.generation = own.handle.generation
	else:
		stamp.formation_revisions = _board.team_revisions(subject)
	stamp.make_read_only()
	return stamp

func _rank_scheduled(jobs: Array, batches: int) -> PackedByteArray:
	# Only rank the current individual grants. A rejected prefetch leaves all
	# jobs on the normal ordered sense/collect path.
	if _board != null and not _busy and not _closed:
		var valid := true
		for job in jobs:
			if not job is Dictionary or job.get("layer")!="individual" or not is_same(_issued.get(job.get("id")),job):
				valid = false
				break
		if valid:
			_busy = true
			var no_enemies: PackedByteArray = _board._rank_scheduled(jobs,_tick,batches)
			_busy = false
			return no_enemies
	var ordered := PackedByteArray()
	ordered.resize(jobs.size())
	return ordered

func sense(handle: Dictionary, radius := 18.0, limit := 8) -> Dictionary:
	if _board == null or _busy:
		return R.fail("InvalidState","ai_scope")
	if not _los.is_valid():
		return R.fail("Unavailable","visibility")
	var own: Dictionary = _board.resolve(handle)
	if not own.ok:
		return own
	_busy = true
	var result: Dictionary = _board.sense(own.value,radius,limit,_stamp("individual",handle),_los)
	_busy = false
	return result

func team_view(team_key: Variant) -> Dictionary:
	if _board == null or not _board.teams.has(team_key):
		return R.fail("NotFound","team_key")
	return _board.group_view(team_key,true,_stamp("tactical",team_key))

func formation_view(formation_id: int) -> Dictionary:
	if _board == null or not _board.formations.has(formation_id):
		return R.fail("NotFound","formation_id")
	return _board.group_view(formation_id,false,_stamp("formation",formation_id))

func schedule(budgets: Dictionary = {}) -> Dictionary:
	if _board == null or _busy:
		return R.fail("InvalidState","ai_scope")
	if not _los.is_valid():
		return R.fail("Unavailable","visibility")
	var selected := _scheduler.due(_tick,_hz,_board,budgets)
	if not selected.ok:
		return selected
	for job in selected.value.jobs:
		if job.layer != "individual":
			# A due group starts with current, locally confirmed observations.
			sense(_board.next_scout(job.subject,job.layer=="tactical"),18.0,2)
		# A copied grant from a discarded attempt must never match a new grant.
		_serial += 1
		job.id = _serial
		job.stamp = _stamp(job.layer,job.subject)
		job.make_read_only()
		_issued[job.id] = job
	_issued_total += selected.value.jobs.size()
	selected.value.jobs.make_read_only()
	return selected

func _fresh(job: Dictionary) -> bool:
	if not _live.is_valid():
		return not _live_required
	_busy = true
	var current: Variant = _live.call(job.layer,job.subject)
	_busy = false
	if typeof(current) != TYPE_DICTIONARY or current.is_empty():
		return false
	for field in current:
		if not job.stamp.has(field) or job.stamp[field] != current[field]:
			return false
	return true

static func _data(value: Variant, depth: int) -> bool:
	if depth > 6:
		return false
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY:
			if value.size() > 64:
				return false
			for k in value:
				if typeof(value)==TYPE_DICTIONARY and typeof(k) not in [TYPE_STRING,TYPE_INT]:
					return false
				if not _data(value[k] if typeof(value)==TYPE_DICTIONARY else k,depth+1):
					return false
			return true
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING: return true
		TYPE_FLOAT: return is_finite(value)
		TYPE_VECTOR3: return value.is_finite()
	return false

func _allowed(job: Dictionary, intent: Dictionary) -> bool:
	if job.layer == "individual":
		if not Perception.handle_ok(intent.get("actor_handle")) or intent.actor_handle != job.subject:
			return false
		if intent.get("target_hint") != null:
			var hint: Variant = intent.target_hint
			return Perception.handle_ok(hint) and _board.seen_by(job.subject.index,hint)
		return true
	var ids: Variant = intent.get("formation_ids",[intent.get("formation_id")])
	if typeof(ids) != TYPE_ARRAY or ids.is_empty():
		return false
	if intent.has("formation_id") and intent.formation_id not in ids:
		return false
	for id in ids:
		if not V.integer(id,0,V.MAX_U32) or not _board.formations.has(id):
			return false
		if job.layer == "formation" and id != job.subject:
			return false
		if job.layer == "tactical" and _board.formations[id][0].team_key != job.subject:
			return false
	var target: Variant = intent.get("target_formation_id")
	if target != null:
		if not V.integer(target,0,V.MAX_U32) or target in ids or not _board.formations.has(target):
			return false
		var team: Variant = job.subject if job.layer == "tactical" else _board.formations[job.subject][0].team_key
		var allied := is_same(_board.formations[target][0].team_key,team)
		if intent.get("order_type") == "follow":
			return allied
		if allied or intent.get("order_type") not in ["face_enemy","charge"]:
			return false
		var view: Dictionary = team_view(team).value if job.layer == "tactical" else formation_view(job.subject).value
		for contact in view.visible_enemies:
			if contact.formation_id == target:
				return true
		return false
	return true

func collect(job: Dictionary, intents: Array) -> Dictionary:
	if _closed or _busy or _board == null:
		return R.fail("InvalidState","ai_scope")
	var known: Variant = _issued.get(job.get("id"))
	if known == null or job != known or not _fresh(known):
		_stale_results += 1
		return R.fail("StaleVersion","decision_job")
	if intents.size() > 16:
		return R.fail("InvalidArgument","intent_count")
	for item in intents:
		if typeof(item) != TYPE_DICTIONARY or not _data(item,0) or not _allowed(known,item):
			return R.fail("Unauthorized","decision_intent")
	_results[known.id] = {"job":known,"intents":intents.duplicate(true)}
	_issued.erase(known.id)
	return R.ok()

func drain() -> Dictionary:
	if _board == null or _busy:
		return R.fail("InvalidState","ai_scope")
	var keys := _results.keys()
	keys.sort()
	var rows := []
	for id in keys:
		if _fresh(_results[id].job):
			var row: Dictionary = _results[id]
			if not _checkpoint.is_empty() and _checkpoint.results.has(id):
				rows.append({"job":row.job,"intents":row.intents.duplicate(true)})
			else:
				rows.append(row)
		else:
			_stale_results += 1
	_results.clear()
	return R.ok(rows)

func metrics() -> Dictionary:
	return {"examined":_board.examined if _board else 0,"rays":_board.rays if _board else 0,
		"cache_hits":_board.cache_hits if _board else 0,"los_us":_board.los_us if _board else 0,
		"scouts":_board.scouts if _board else 0,"stale_results":_stale_results,"issued_total":_issued_total}

func close() -> Dictionary:
	if _busy:
		return R.fail("InvalidState","ai_callback")
	commit_tick()
	_closed = true
	_board = null
	_last_generation.clear()
	_issued.clear()
	_results.clear()
	_scheduler = Schedule.new()
	return R.ok()
