extends SceneTree

const Field = preload("res://mission/runtime/field_brains.gd")
const Adapter = preload("res://infrastructure/engine/adapter.gd")
const Form = preload("res://mission/formation/ports/field_formation.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const Movement = preload("res://mission/movement/ports/field_movement.gd")
const R = preload("res://contracts/result.gd")
const SCOPE := "test:field_brains"
const ROLES := ["infantry","archer","cavalry","mounted_archer"]
var faults := 0
var checks := 0
var engine: RefCounted
var form: RefCounted
var mov: RefCounted
var com: RefCounted
var field: RefCounted
var credentials := [RefCounted.new(),RefCounted.new()]
var player := RefCounted.new()
var nav := -1
var groups := []
var classes := {}
var counts := {"tactical":0,"formation":0,"individual":0,"orders":0,"actions":0,"moves":0,"hits":0}
var modes := {}
var verified_retry := false
var verified_revocation := false
var tested_player := false

func check(ok: bool,label: String) -> bool:
	checks += 1
	if not ok:
		faults += 1
		printerr("FAIL ",label)
	return ok

static func handle(i: int) -> Dictionary:
	return {"index":i,"generation":1}

func auth(context: Variant) -> Dictionary:
	if is_same(context,player): return R.ok("player")
	for team in 2:
		if is_same(context,credentials[team]): return R.ok("ai"+str(team))
	return R.fail("Unauthorized")

func move_rights(scope: String,h: Dictionary,ctx: Variant,_tick: int) -> bool:
	var member: Dictionary = form.member_formation(h)
	return scope==SCOPE and h!=handle(8) and member.ok and is_same(ctx,credentials[form.view(member.value).value.team_key])

func prepare() -> bool:
	mov = Movement.new(engine,SCOPE,move_rights)
	com = Combat.new(SCOPE)
	form = Form.new(SCOPE,auth,func(_id,p):
		var path: Dictionary=engine.query_path_batch([{"from":[0,0,8000],"to":p}],nav,SCOPE)
		return path.ok and path.value[0].reachable)
	var teams := []
	for team in 2:
		teams.append({"team_key":team,"issuer":"ai"+str(team),"context":credentials[team],
			"sites":[{"id":"objective","position":Vector3(0,0,8),"objective":true},{"id":"slope","position":Vector3(4,0,15)}],
			"exit_position":Vector3(30 if team==1 else -30,0,8)})
	for i in 9:
		var team := 1 if i in [4,5,6,7] else 0
		var role: String = ROLES[i%4]
		var mounted := role in ["cavalry","mounted_archer"]
		var x: float = (-0.5 if team==0 else 0.5) if i%4 in [0,2] else (-6.0 if team==0 else 7.0)
		var p := Vector3(x,0,8+6*(i%4))
		if i==8: p=Vector3(-25,0,8)
		var h := handle(i)
		var profile := {"team":team,"role":"cavalry" if mounted else role,"hp":5000,"ammo":30}
		if role=="mounted_archer": profile.ranged="bow"
		if not check(com.enlist(h,profile).ok and mov.spawn(h,p,"mounted" if mounted else "foot",Vector3.RIGHT if team==0 else Vector3.LEFT).ok,"enlist "+role): return false
		if mounted:
			var horse := handle(100+i)
			if not check(com.enlist(horse,{"team":team,"role":"mount","hp":5000}).ok and com.mount(h,horse).ok,"mount "+role): return false
		var owner: String = "player" if team==0 else "ai1"
		if not check(form.add_formation(i,team,owner,[h]).ok,"FORM deployment"): return false
		classes[i]=role
		groups.append({"handle":h,"team_key":team,"formation_id":i,"role":role})
		if team==0:
			var order := {"mission_id":SCOPE,"issuer_id":"player","client_sequence":i+1,"issued_tick":1,"order_id":"player-"+str(i),"formation_ids":[i],"order_type":"free_attack","parameters":{},"target_position":null,"target_formation_id":null}
			if not check(form.issue_order(order,player,0).ok,"owner order"): return false
	field = Field.new(SCOPE,engine,form,teams)
	check(field.visible_formations(0).is_empty(),"no contacts before first committed observation")
	return true

func project() -> Dictionary:
	var rows := []
	var poses := {}
	var bodies := []
	for person in groups:
		var row: Dictionary=person.duplicate()
		var c: Dictionary=com.view(row.handle).value
		var body: Dictionary=mov.view(row.handle).value
		var formation: Dictionary=form.view(row.formation_id).value
		row.merge({"position":body.position,"heading":body.heading,"slot_position":body.position,
			"control_revision":formation.control_revision,"order_revision":formation.active.client_sequence if formation.active!=null else 0,"hp":c.hp,"ammo":c.ammo,"morale":c.morale})
		rows.append(row)
		bodies.append({"team_key":row.team_key,"handle":row.handle,"position":body.position,"mounted":c.mount_handle!=null,"facing":body.heading})
		if c.mount_handle!=null:
			bodies.append({"team_key":row.team_key,"handle":c.mount_handle,"position":body.position,"type":"mount","facing":body.heading})
		var facing: Vector3=body.heading*1000000
		poses[row.handle.index]={"position_mm":Field._mm(body.position+Vector3.UP*0.8),"facing_ppm":[roundi(facing.x),0,roundi(facing.z)]}
	return {"rows":rows,"poses":poses,"bodies":bodies}

func tick_once(t: int, discarded: Dictionary) -> Dictionary:
	if not check(form.begin_tick().ok and form.advance(t).ok,"FORM step"): return {}
	var frame := project()
	var previously_visible: Array=field.visible_formations(0)
	var stage: Dictionary=mov.begin_step(t)
	var branch: RefCounted=com.fork()
	if not check(stage.ok and engine.field_stage_bodies(SCOPE,frame.bodies).ok,"stage MOV and real Jolt bodies"): return {}
	if t==1 and not tested_player:
		tested_player=true
		var invalid: Array=frame.rows.duplicate(true)
		invalid[0].handle.generation=2
		check(not field.decide(t,nav,invalid,branch,handle(8)).ok,"stale unit rejected and retry remains open")
	var computed: Dictionary=field.decide(t,nav,frame.rows,branch,handle(8))
	if not check(computed.ok,"decide tick "+str(t)+" "+str(computed.get("error"))): return {}
	var decisions: Dictionary=computed.value
	check(field.visible_formations(0)==previously_visible,"candidate observations are private until commit")
	for action in decisions.actions+decisions.looks:
		check(action.actor_handle!=handle(8),"explicit player never receives an AI action")
	var move_receipts := []
	for move in decisions.moves:
		check(move.intent.actor_handle!=handle(8),"explicit player never receives an AI drive")
		move_receipts.append(mov.apply_move_intent(stage.value,move.intent,move.context))
	var combat: Dictionary=branch.step_field(t,decisions.actions,frame.poses,func(q,at):return engine.field_sweep(SCOPE,q,at))
	if not check(combat.ok,"real COM step "+str(combat.get("error"))): return {}
	if t==22 and not verified_revocation:
		check(form.set_delegate(0,"relief",player,0).ok,"owner reassigns command in candidate")
		check(not field.accept_actions(combat.value.receipts,move_receipts).ok,"changed authority rejects an otherwise matching receipt stream")
		verified_revocation=true
		field.rollback_tick()
		form.rollback_tick()
		mov.rollback_step(stage.value)
		engine.field_rollback_bodies(SCOPE)
		return {"discarded":decisions}
	if not decisions.actions.is_empty():
		check(not field.accept_actions([],move_receipts).ok,"missing action receipt rejects partial publication")
	var receipt: Dictionary=field.accept_actions(combat.value.receipts,move_receipts)
	if not check(receipt.ok,"individual receipts "+str(receipt.get("error"))): return {}
	if not check(mov.stage_step(t,1.0/60,stage.value).ok,"real MOV step"): return {}
	if not verified_retry and not decisions.moves.is_empty() and not decisions.actions.is_empty():
		verified_retry=true
		field.rollback_tick()
		form.rollback_tick()
		mov.rollback_step(stage.value)
		engine.field_rollback_bodies(SCOPE)
		return {"discarded":decisions}
	if not discarded.is_empty():
		check(decisions==discarded,"retry same admitted roles, commands, opaque credentials and counts")
	for key in ["tactical","formation","individual","orders"]: counts[key]+=decisions.metrics[key]
	for role in decisions.metrics.role_modes:
		var tally: Dictionary=modes.get_or_add(role,{})
		for mode in decisions.metrics.role_modes[role]:
			tally[mode]=tally.get(mode,0)+decisions.metrics.role_modes[role][mode]
	counts.actions+=decisions.actions.size()
	counts.moves+=decisions.moves.size()
	counts.hits+=combat.value.hits.size()
	check(form.view(0).value.active.issuer_id=="player","standing player order preserved")
	if not check(mov.commit_step(stage.value).ok and engine.field_commit_bodies(SCOPE).ok,"domain commit"): return {}
	com=branch
	field.commit_tick()
	form.commit_tick()
	return {"committed":true}

func _initialize() -> void:
	run.call_deferred()

func verify_roster_retry(tick: int) -> void:
	check(form.begin_tick().ok and form.advance(tick).ok,"begin warmed roster check")
	var rows: Array = project().rows
	var old_handle: Dictionary = rows[0].handle
	for invalid in [{"index":0,"generation":2},{"index":0.0,"generation":1},
			{"index":0,"generation":true},{"index":0,"generation":1,"extra":true},handle(1)]:
		rows[0].handle = invalid
		var rejected: Dictionary = field.decide(tick,nav,rows,com,handle(8))
		check(not rejected.ok and rejected.error.field=="field_ai_member","warmed index rejects invalid membership "+str(invalid))
		field.rollback_tick()
	rows[0].handle = old_handle
	var original: Dictionary = field.decide(tick,nav,rows,com,handle(8))
	check(original.ok,"same tick accepts the original roster")
	field.rollback_tick()
	form.rollback_tick()

	# Each branch changes the same FORM group from the same committed revision.
	# A cache keyed only by the candidate revision could admit the other generation.
	for generation in [2,3]:
		check(form.begin_tick().ok and form.advance(tick).ok,"begin generation fork")
		rows = project().rows
		var replacement := {"index":8,"generation":generation}
		check(form.assign_members(8,[replacement]).ok,"replace a member without changing count")
		rows[8].handle = {"index":8,"generation":generation-1}
		var stale: Dictionary = field.decide(tick,nav,rows,com,replacement)
		check(not stale.ok and stale.error.field=="field_ai_member","old generation rejected after replacement")
		field.rollback_tick()
		rows[8].handle = replacement
		var accepted: Dictionary = field.decide(tick,nav,rows,com,replacement)
		check(accepted.ok,"matching replacement accepted on retried revision")
		field.rollback_tick()
		form.rollback_tick()

	check(form.begin_tick().ok and form.advance(tick).ok,"begin same-size member transfer")
	rows = project().rows
	check(form.assign_members(0,[]).ok and form.assign_members(1,[handle(0)]).ok
		and form.assign_members(0,[handle(1)]).ok,"swap members across two formations")
	var stale_group: Dictionary = field.decide(tick,nav,rows,com,handle(8))
	check(not stale_group.ok and stale_group.error.field=="field_ai_member","reject obsolete formation for a live handle")
	field.rollback_tick()
	for i in 2:
		var dest: Dictionary = form.view(1-i).value
		rows[i].formation_id = dest.id
		rows[i].order_revision = dest.active.client_sequence if dest.active!=null else 0
	rows.reverse()
	check(field.decide(tick,nav,rows,com,handle(8)).ok,"accept valid reordered and transferred members")
	field.rollback_tick()
	form.rollback_tick()
	check(form.begin_tick().ok and form.advance(tick).ok,"begin restored roster")
	var retry: Dictionary = field.decide(tick,nav,project().rows,com,handle(8))
	check(original.ok and retry==original,"retry reproduces decisions with previous membership and row order")
	field.rollback_tick()
	form.rollback_tick()

func run() -> void:
	engine=Adapter.new(root,true)
	var opened: Dictionary=engine.open_scope(SCOPE)
	var scene := {"id":"test:scene/field_brains","simulation_scene":"res://tests/p2/ai/arena.tscn"}
	check(opened.ok and engine.load_scene(scene,opened.value).ok,"real arena")
	for i in 90:
		await physics_frame
		var sync: Dictionary=engine.sync_navigation(SCOPE)
		if sync.ok and sync.value.status=="applied" and not engine.field_los(SCOPE,Vector3(-2,0,0),Vector3(2,0,0)):
			var probe: Dictionary=engine.query_path_batch([{"from":[-6000,0,8000],"to":[-2000,0,8000]}],sync.value.applied_revision,SCOPE)
			if probe.ok and probe.value[0].reachable:
				nav=sync.value.applied_revision
				break
	if check(nav>=0,"navigation synchronized and wall occludes") and prepare():
		for t in range(1,122):
			var result := tick_once(t,{})
			if result.has("discarded"): result=tick_once(t,result.discarded)
			if result.is_empty(): break
	check(verified_retry,"rollback included both action and movement receipts")
	check(verified_revocation,"revoked authority rejects late receipts and allows a clean replay")
	var known: Array=field.visible_formations(0)
	check(not known.is_empty() and known.all(func(id):return form.view(id).value.team_key==1),"projected targets are observed enemy formations")
	known.clear()
	check(not field.visible_formations(0).is_empty() and field.visible_formations("0").is_empty(),"views are detached and preserve team identity")
	for key in counts: check(counts[key]>0,"actual work "+key)
	for pair in [["infantry","Melee"],["archer","Aim"],["cavalry","MountedStrike"],["mounted_archer","MountedArchery"]]:
		check(modes.get(pair[0],{}).has(pair[1]),"observed "+str(pair))
	if faults==0: verify_roster_retry(122)
	print("FIELD_BRAINS counts=",counts," modes=",modes," checks=",checks," failures=",faults)
	engine.release_scope(SCOPE)
	quit(1 if faults else 0)
