extends "res://contracts/ports/mission_port.gd"

const R = preload("res://contracts/result.gd")
const V = preload("res://contracts/values.gd")
const S = preload("res://contracts/schema.gd")
const C = preload("res://contracts/canonical.gd")
const Entities = preload("res://mission/runtime/entities.gd")
const FieldDeployment = preload("res://mission/runtime/field_deployment.gd")
const PHASES := ["input","ai","movement","action","damage","objectives","snapshot"]

var _core: RefCounted
var _engine: RefCounted
var _key: String
var _builder: Callable
var _phase := "New"
var _mission := ""
var _tick := 0
var _token := {}
var _spec := {}
var _systems := {}
var _entities := Entities.new()
var _busy := false
var _reports := []
var _outcome := {}
var _result := {}
var _field: RefCounted
var _clear_sites := Callable()
var _retry_wave := false

func _init(core: RefCounted, engine: RefCounted, mission_key: String, result_builder: Callable = Callable(),
		instance_id: String = "") -> void:
	_core = core
	_engine = engine
	_key = mission_key
	_builder = result_builder
	_mission = instance_id
	if _mission.is_empty():
		# A fresh authority can start after every local service has been replaced.
		var bytes := Crypto.new().generate_random_bytes(16)
		if bytes.size() == 16:
			bytes[6] = (bytes[6] & 0x0f) | 0x40
			bytes[8] = (bytes[8] & 0x3f) | 0x80
			var raw := bytes.hex_encode()
			_mission = "mission/%s-%s-%s-%s-%s" % [raw.left(8),raw.substr(8,4),raw.substr(12,4),raw.substr(16,4),raw.right(12)]

func prepare(spec: Dictionary, scene: Dictionary, ruleset: Dictionary) -> Dictionary:
	if _phase != "New" or _busy or _key.is_empty():
		return R.fail("InvalidState","phase")
	if _mission.is_empty() or not C.encode(_mission).ok:
		return R.fail("InvalidArgument","instance_id")
	for index in _mission.length():
		if _mission.unicode_at(index) < 32 or (_mission.unicode_at(index) >= 127 and _mission.unicode_at(index) <= 159):
			return R.fail("InvalidArgument","instance_id")
	var checked := S.validate_shape("EncounterSpec",spec)
	if not checked.ok:
		return checked
	if scene.get("id") != spec.scene_def_id or ruleset.get("id") != spec.ruleset_id:
		return R.fail("InvalidArgument","definitions")
	var field: RefCounted
	if spec.ruleset_id == "base:ruleset/field_battle" or ruleset.get("battle_mode") == "field":
		var indexed := FieldDeployment.build(checked.value,scene,ruleset)
		if not indexed.ok:
			return indexed
		field = indexed.value
	var teams := {}
	for side in spec.sides:
		if teams.has(side.team_key):
			return R.fail("Conflict","team_key")
		teams[side.team_key] = true
	_phase = "Preparing"
	var opened: Dictionary = _core.open_scope(_mission)
	if not opened.ok:
		_phase = "New"
		return opened
	_token = opened.value
	var engine_token: Dictionary = _engine.open_scope(_mission)
	if not engine_token.ok:
		return _undo_prepare(engine_token)
	var loaded: Dictionary = _engine.load_scene(scene,engine_token.value)
	if not loaded.ok:
		_engine.release_scope(_mission)
		return _undo_prepare(loaded)
	_spec = checked.value
	_entities = Entities.new(_spec.reserved_sources)
	_field = field
	_phase = "Deployment"
	return R.ok(view())

func _undo_prepare(error: Dictionary) -> Dictionary:
	_core.cancel_scope(_mission)
	_token = {}
	_phase = "New"
	return error

func view() -> Dictionary:
	return _make_view(_entities)

func _make_view(entities: Entities) -> Dictionary:
	# Rows, specification and reports are immutable from the time they are published.
	# A snapshot can share them across ticks and still outlive the Mission.
	var reports: Array = _reports
	reports.make_read_only()
	var spec: Dictionary = _spec
	spec.make_read_only()
	var snapshot := {"mission_id":_mission,"mission_key":_key,"phase":_phase,"tick":_tick,
		"scene_def_id":_spec.get("scene_def_id"),"ruleset_id":_spec.get("ruleset_id"),
		"encounter_spec":spec,"entities":entities.rows(),"spawned_slots":entities.spawned_slots(),"system_reports":reports}
	snapshot.make_read_only()
	return snapshot

func register_system(phase: String, system: Dictionary) -> Dictionary:
	if _busy or _phase != "Deployment":
		return R.fail("InvalidState","phase")
	var id: Variant = system.get("id")
	if phase not in PHASES or typeof(id) != TYPE_STRING or id.is_empty() or typeof(system.get("run")) != TYPE_CALLABLE or not system.run.is_valid():
		return R.fail("InvalidArgument","system")
	if _systems.has(id):
		return R.fail("Conflict","system.id")
	for key in ["commit","rollback"]:
		if system.has(key) and (typeof(system[key]) != TYPE_CALLABLE or not system[key].is_valid()):
			return R.fail("InvalidArgument","system."+key)
	if system.has("commit") != system.has("rollback"):
		return R.fail("InvalidArgument","system.transaction")
	if typeof(system.get("can_retire",false)) != TYPE_BOOL or (system.get("can_retire",false) and phase not in ["damage","objectives"]):
		return R.fail("InvalidArgument","system.can_retire")
	var gate: Variant = system.get("can_gate_waves",false)
	if not gate is bool or (gate and (_field==null or phase!="objectives")):
		return R.fail("InvalidArgument","system.can_gate_waves")
	_systems[id] = {"can_gate_waves":gate,"phase":phase,"run":system.run,"commit":system.get("commit",Callable()),
		"rollback":system.get("rollback",Callable()),"can_retire":system.get("can_retire",false)}
	return R.ok()

# BOOT installs the trusted live occupancy/visibility query for this Mission.
func bind_field_clearance(query: Callable) -> Dictionary:
	if _busy or _phase not in ["New","Deployment"] or not query.is_valid():
		return R.fail("InvalidState","field.spawn_clearance")
	_clear_sites = query
	return R.ok()

func _active() -> bool:
	return not _busy and _phase in ["Deployment","Running"]

func allocate_entity(source_slot: Variant, components: Dictionary) -> Dictionary:
	if not _active():
		return R.fail("InvalidState","phase")
	if _field != null and (source_slot != null or components.get("type") not in ["mount","projectile","siege_engine"]):
		return R.fail("Unauthorized","field.deployment")
	return _entities.allocate(source_slot,components,_spec.battle_limit)

func apply_deployment(orders: Array) -> Dictionary:
	if _busy or _phase != "Deployment":
		return R.fail("InvalidState","phase")
	if _field != null:
		_busy = true
		var deployed: Dictionary = _field.deploy(_entities,orders,_engine,_mission,_clear_sites)
		_busy = false
		if not deployed.ok:
			return deployed
		var completed := _complete_deployment(deployed.value)
		if not completed.ok:
			return completed
		_entities = deployed.value.entities
		return R.ok(deployed.value.handles)
	var staged: Entities = _entities.fork()
	var handles := []
	for order in orders:
		if typeof(order) != TYPE_DICTIONARY or not order.has("source_slot") or typeof(order.get("components")) != TYPE_DICTIONARY:
			return R.fail("InvalidArgument","deployment")
		var allocated := staged.allocate(order.source_slot,order.components,_spec.battle_limit)
		if not allocated.ok:
			return allocated
		handles.append(allocated.value)
	_entities = staged
	return R.ok(Entities.freeze(handles))

func resolve_entity(mission_id: String, handle: Dictionary) -> Dictionary:
	if _phase in ["New","Disposed"]:
		return R.fail("NotFound","mission_id")
	return _entities.resolve(mission_id,handle,_mission)

func remove_entity(mission_id: String, handle: Dictionary) -> Dictionary:
	if not _active():
		return R.fail("InvalidState","phase")
	return _entities.remove(mission_id,handle,_mission)

# A field assembly can bind nonsource companions in the same unpublished store.
func _complete_deployment(_deployment: Dictionary) -> Dictionary:
	return R.ok()

func _retire_companions(_store: Entities, _retiring: Array) -> void:
	pass

# Called after every registered projection has succeeded, before any commit hook.
func _seal_tick() -> Dictionary:
	return R.ok()

func _needs_opening_wave(store: Entities) -> bool:
	return store.active_sources==0

func step_fixed(tick: Variant, inputs: Array) -> Dictionary:
	if not _active():
		return R.fail("InvalidState","phase")
	if tick != _tick+1 or not V.integer(tick):
		return R.fail("StaleVersion","tick")
	var batch := S.validate_shape("IntentBatch",{"mission_id":_mission,"source_tick":tick,"control_revision":0,"inputs":inputs})
	if not batch.ok:
		return batch
	for intent in batch.value.inputs:
		if not resolve_entity(_mission,intent.actor_handle).ok:
			return R.fail("NotFound","actor_handle")
		if intent.get("target_hint") != null and not resolve_entity(_mission,intent.target_hint).ok:
			return R.fail("NotFound","target_hint")
	var ids := _systems.keys()
	ids.sort()
	var reports := []
	var staged: Entities = _entities
	var attempted := []
	var retry_wave := false
	_busy = true
	var opening := _field != null and _tick == 0 and _needs_opening_wave(staged)
	if opening:
		var initial: Dictionary = _field.auto_wave(staged,_spec.battle_limit,_engine,_mission,_clear_sites,{},true)
		if not initial.ok:
			return _abort_tick(initial,attempted)
		if initial.value.handles.is_empty() and staged.active_sources==0:
			return _abort_tick(R.fail("Unavailable","deployment.spawn_site"),attempted)
		var completed := _complete_deployment(initial.value)
		if not completed.ok:
			return _abort_tick(completed,attempted)
		staged = initial.value.entities
	var context := _make_view(staged)
	var ending := false
	var excluded_teams := {}
	for phase: String in PHASES:
		# Ordinary reinforcements enter after this tick's damage, retirement
		# and objective checks. Their first movement and action run next tick.
		if phase == "snapshot" and _field != null and not opening and not ending and (_retry_wave or tick % _field.cooldown == 0):
			if staged.active_sources < _spec.battle_limit and staged.spawned.size() < staged.reserved_count:
				var limit := mini(_field.wave_size,_spec.battle_limit-staged.active_sources)
				var wave: Dictionary = _field.auto_wave(staged,limit,_engine,_mission,_clear_sites,excluded_teams)
				if not wave.ok:
					if wave.error.code not in ["Unavailable","StaleVersion"]:
						return _abort_tick(wave,attempted)
					retry_wave = true
				else:
					var completed := _complete_deployment(wave.value)
					if not completed.ok:
						return _abort_tick(completed,attempted)
					staged = wave.value.entities
					context = _make_view(staged)
		for id in ids:
			var system: Dictionary = _systems[id]
			if system.phase != phase:
				continue
			var phase_context := context
			if _field != null:
				phase_context = context.duplicate()
				var current := reports.duplicate()
				current.make_read_only()
				phase_context["phase_reports"] = current
				phase_context.make_read_only()
			attempted.append(system)
			var report: Variant = system.run.call(phase_context,batch.value)
			if typeof(report) != TYPE_DICTIONARY or typeof(report.get("ok")) != TYPE_BOOL:
				return _abort_tick(R.fail("InvalidArgument","system.result"),attempted)
			if not report.ok:
				return _abort_tick(report,attempted)
			if not C.encode(report.get("value")).ok:
				return _abort_tick(R.fail("InvalidArgument","system.value"),attempted)
			if phase == "objectives" and typeof(report.get("value")) == TYPE_DICTIONARY and report.value.get("outcome") != null:
				ending = true
			if _field != null and typeof(report.get("value")) == TYPE_DICTIONARY and report.value.has("withdrawn_team_keys"):
				if not system.can_gate_waves:
					return _abort_tick(R.fail("Unauthorized","system.wave_eligibility"),attempted)
				var filtered: Dictionary = _field.exclude_teams(report.value.withdrawn_team_keys,excluded_teams)
				if not filtered.ok:
					return _abort_tick(filtered,attempted)
			if system.can_retire:
				var payload: Variant = report.get("value")
				if typeof(payload) != TYPE_DICTIONARY or typeof(payload.get("retire_handles",[])) != TYPE_ARRAY:
					return _abort_tick(R.fail("InvalidArgument","system.retire_handles"),attempted)
				var retiring: Array = payload.get("retire_handles",[])
				if not retiring.is_empty():
					if staged == _entities:
						staged = staged.fork()
					_retire_companions(staged,retiring)
					for handle in retiring:
						if typeof(handle) != TYPE_DICTIONARY:
							return _abort_tick(R.fail("InvalidArgument","system.retire_handles"),attempted)
						var removed := staged.remove(_mission,handle,_mission)
						if not removed.ok:
							return _abort_tick(removed,attempted)
					context = _make_view(staged)
			var entry := {"id":id,"phase":phase,"value":Entities.freeze(report.get("value"))}
			entry.make_read_only()
			reports.append(entry)
	# All fallible work precedes commit. Registered commit hooks publish a
	# prevalidated domain candidate and may not query or produce fallible work.
	var sealed := _seal_tick()
	if not sealed.ok:
		return _abort_tick(sealed,attempted)
	for system in attempted:
		if system.commit.is_valid():
			system.commit.call()
	_entities = staged
	_retry_wave = retry_wave
	_reports = reports
	_tick = tick
	_phase = "Running"
	_busy = false
	return R.ok(view())

func _abort_tick(failure: Dictionary, attempted: Array) -> Dictionary:
	for i in range(attempted.size()-1,-1,-1):
		if attempted[i].rollback.is_valid():
			attempted[i].rollback.call()
	_busy = false
	return failure

func submit_worker(stable_key: String, work: Callable) -> Dictionary:
	if not _active():
		return R.fail("InvalidState","phase")
	return _core.submit_worker({"scope_id":_mission,"revision":_tick,"tick":_tick,"mission_id":_mission},
		_token,{"stable_key":stable_key,"run":work})

func collect_workers() -> Array:
	if not _active():
		return []
	return _core.collect_ready(_mission,_tick,{"tick":_tick,"mission_id":_mission})

func request_end(outcome: Dictionary) -> Dictionary:
	if not _active():
		return R.fail("InvalidState","phase")
	if typeof(outcome.get("outcome")) != TYPE_STRING or outcome.outcome.is_empty() or not C.encode(outcome).ok:
		return R.fail("InvalidArgument","outcome")
	_core.cancel_scope(_mission)
	_token = {}
	_outcome = Entities.freeze(outcome)
	_phase = "Ending"
	return R.ok()

func finalize() -> Dictionary:
	if _busy or _phase not in ["Ending","Finalizing"]:
		return R.fail("InvalidState","phase")
	if not _result.is_empty():
		return R.ok(_result)
	if not _builder.is_valid():
		return R.fail("Unavailable","result_builder")
	var ending := view()
	_busy = true
	var built: Variant = _builder.call(ending,_outcome)
	_busy = false
	if typeof(built) != TYPE_DICTIONARY or typeof(built.get("ok")) != TYPE_BOOL:
		return R.fail("InvalidArgument","result_builder")
	if not built.ok:
		return built
	var checked := S.validate_shape("MissionResult",built.get("value"))
	if not checked.ok:
		return checked
	var result: Dictionary = checked.value
	if result.mission_id != _mission or result.duration_ticks != _tick or result.outcome != _outcome.outcome:
		return R.fail("Conflict","mission_result")
	if result.slot_outcomes.size() != _entities.reserved_count:
		return R.fail("Conflict","slot_outcomes")
	for row in result.slot_outcomes:
		if not _entities.has_reserved_slot(row.source_slot_id):
			return R.fail("Conflict","slot_outcomes.source_slot_id")
		if (row.end_status == "not_spawned") == _entities.spawned.has(row.source_slot_id):
			return R.fail("Conflict","slot_outcomes.end_status")
	if _spec.mode == "campaign":
		checked = S.validate_settlement(_spec,result)
		if not checked.ok:
			return checked
	elif result.encounter_id != null or result.reservation_revision != null:
		return R.fail("Unauthorized","campaign_settlement")
	_result = result
	_phase = "Finalizing"
	return R.ok(_result)

func dispose() -> Dictionary:
	if _busy or _phase == "Preparing":
		return R.fail("InvalidState","phase")
	var barrier := {"discarded":0,"removed_jobs":0}
	var released := {"released":0,"cancelled":0}
	if not _token.is_empty():
		barrier = _core.cancel_scope(_mission)
	if _phase in ["Deployment","Running","Ending","Finalizing"]:
		released = _engine.release_scope(_mission)
	_phase = "Disposed"
	_token = {}
	_systems.clear()
	_spec = {}
	_entities = Entities.new()
	_reports = []
	_result = {}
	_outcome = {}
	_builder = Callable()
	_clear_sites = Callable()
	_field = null
	_core = null
	_engine = null
	return R.ok({"phase":_phase,"workers":barrier,"engine":released})
