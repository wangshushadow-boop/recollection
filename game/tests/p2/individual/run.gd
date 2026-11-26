extends SceneTree

const Brain = preload("res://mission/ai/individual/ports/field_individual.gd")
const AI = preload("res://mission/ai/ports/field_ai.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const Movement = preload("res://mission/movement/ports/field_movement.gd")
const EnginePort = preload("res://infrastructure/engine/adapter.gd")
const R = preload("res://contracts/result.gd")
const S = preload("res://contracts/schema.gd")
const A := {"index":0,"generation":1}
const B := {"index":1,"generation":1}
const H := {"index":2,"generation":1}
const SCOPE := "individual-fixture"
const ORDERS := {"fire_allowed":true,"engage_allowed":true,"slot_tolerance":1.0,"focus_target":null,"movement_limit":24.0}
var engine: RefCounted
var nav := 0
var errors := 0
var checks := 0
var rays := 0
var paths := 0
var sweeps := 0


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		errors += 1
		printerr("FAIL ",label)


static func mm(p: Vector3) -> Array:
	return [roundi(p.x*1000),roundi(p.y*1000),roundi(p.z*1000)]


func clear_ray(a: Vector3,b: Vector3) -> bool:
	if a.is_equal_approx(b):
		return true
	rays += 1
	var r: Dictionary = engine.query_sweep_batch([{"from":mm(a+Vector3.UP),"to":mm(b+Vector3.UP),"mask":4}],{"scope_id":SCOPE,"tick":0})
	return r.ok and r.value.is_empty()


func path(a: Vector3,b: Vector3,rev: int) -> bool:
	paths += 1
	var r: Dictionary = engine.query_path_batch([{"from":mm(a),"to":mm(b)}],rev,SCOPE)
	return r.ok and r.value[0].reachable


func sweep(queries: Array,t: int) -> Dictionary:
	sweeps += queries.size()
	var r: Dictionary = engine.query_sweep_batch(queries,{"scope_id":SCOPE,"tick":t})
	if not r.ok:
		return r
	var hits := []
	for hit: Dictionary in r.value:
		var row := {"query_index":hit.query_index,"fraction_ppm":hit.fraction_ppm,"region":hit.region}
		if hit.entity_handle == "defender":
			row.target = B
		hits.append(row)
	return R.ok(hits)


func unit(h: Dictionary, p: Vector3, team: int, role: String) -> Dictionary:
	return {"handle":h,"team_key":team,"formation_id":team,"position":p,"role":role,"control_revision":0,"order_revision":0}


func context(p: Vector3) -> Dictionary:
	return {"slot_position":p,"exit_position":null,"heading":Vector3.RIGHT,"nav_revision":nav,"can_travel":path}


func job_for(ai: RefCounted,tick: int,rows: Array) -> Dictionary:
	rows[0].urgent = true
	var r: Dictionary = ai.publish(tick,nav,rows)
	if not r.ok:
		return {}
	for job: Dictionary in ai.schedule().value.jobs:
		if job.layer=="individual" and job.subject==A:
			return job
	return {}


func actions(intents: Array) -> Array:
	return intents.filter(func(i): return not i.has("yaw") and not i.has("desired_direction"))


func poses(a: Vector3, b: Vector3) -> Dictionary:
	return {0:{"position_mm":mm(a+Vector3.UP*0.7),"facing_ppm":[1000000,0,0]},
		1:{"position_mm":mm(b+Vector3.UP*0.7),"facing_ppm":[-1000000,0,0]}}


func roles(role: String, weapon: String) -> void:
	var archer := not weapon.is_empty()
	var mounted := role in ["cavalry","mounted_archer"]
	var p := Vector3(-4,0,15) if archer else Vector3(-4,0,8)
	var enemy := Vector3(6,0,15) if archer else Vector3(-3,0,8)
	var rows := [unit(A,p,0,role),unit(B,enemy,1,"infantry")]
	var com := Combat.new(SCOPE)
	var profile := {"team":0,"role":"cavalry" if mounted else role,"ammo":2}
	if archer:
		profile.ranged = weapon
	com.enlist(A,profile)
	com.enlist(B,{"team":1,"role":"infantry"})
	if mounted:
		com.enlist(H,{"team":0,"role":"mount"})
		com.mount(A,H)
	var mirror: RefCounted = com.fork()
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var phases := []
	var modes := {}
	var hit_count := 0
	var starts := []
	for t in range(1,27):
		var job := job_for(ai,t,rows)
		var sensed: Dictionary = ai.sense(A).value
		var draft: RefCounted = brain.fork()
		var before: Dictionary = com.view(A).value
		var proposed: Dictionary = draft.decide(job,sensed,before,ORDERS,context(p))
		check(proposed.ok,"role decision "+role)
		if not proposed.ok: return
		var plan: Dictionary = proposed.value
		modes[plan.mode] = true
		check(ai.collect(job,plan.intents).ok,"actual BAI collect")
		var batch: Dictionary = ai.drain().value[0]
		var input := actions(batch.intents)
		for intent in input:
			if intent.has("input_phase"):
				phases.append(intent.input_phase)
				if intent.input_phase=="start": starts.append(t)
				check(S.validate_shape("AttackIntent",intent).ok,"wire-compatible attack")
			else:
				check(S.validate_shape("EquipIntent" if intent.has("slot") else "BlockIntent",intent).ok,"wire-compatible equipment/guard")
		var actual: Dictionary = com.step_field(t,input,poses(p,enemy),sweep)
		# Player transport has no target hint. The same authority must produce identical hits and action states.
		var player_input: Array = input.duplicate(true)
		for cmd in player_input:
			if cmd.has("target_hint"): cmd.target_hint = null
		var replay: Dictionary = mirror.step_field(t,player_input,poses(p,enemy),sweep)
		check(actual.ok and replay==actual and mirror.view(A)==com.view(A) and mirror.view(B)==com.view(B),"same player/AI combat and contact results")
		if not actual.ok: return
		hit_count += actual.value.hits.size()
		var receipt: Dictionary = R.ok() if input.is_empty() else actual.value.receipts[0]
		check(receipt.ok and draft.accept(batch,plan,receipt).ok,"actual receipt and brain memory")
		brain = draft
	check("start" in phases and "hold" in phases and "release" in phases and hit_count>0,"real attack cycle and physics hit "+role)
	check(modes.has("MountedArchery" if role=="mounted_archer" else ("MountedStrike" if mounted else ("Aim" if archer else "Melee"))),"role mode "+role)
	if mounted:
		check(modes.has("Equip") if archer else modes.has("Disengage"),"mounted equip or disengage")
	if weapon=="crossbow":
		check(starts.size()>=2 and starts[1]-starts[0]>=16,"crossbow load time observed")
	print("L3_ROLE role=",role," weapon=",weapon," starts=",starts," hits=",hit_count," modes=",modes.keys())


func edges() -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.add_actor(A)
	var pos := Vector3(-3,0,0)
	var hidden := unit(B,Vector3(3,0,0),1,"infantry")
	var visible := unit(H,pos+Vector3.FORWARD,1,"infantry")
	var rows := [unit(A,pos,0,"infantry"),hidden,visible]
	var job := job_for(ai,1,rows)
	var view: Dictionary = ai.sense(A).value
	var local := context(pos)
	var orders := ORDERS.duplicate()
	orders.focus_target = B
	var draft: RefCounted = brain.fork()
	var packet: Dictionary = draft.decide(job,view,com.view(A).value,orders,local).value
	check(view.visible_enemies.size()==1 and packet.target==H and actions(packet.intents)[0].target_hint==H,"real wall occludes given focus")
	check(ai.collect(job,packet.intents).ok,"first job accepted")
	var batch: Dictionary = ai.drain().value[0]
	check(not brain.accept(batch,packet,R.ok()).ok,"cross-branch proposal rejected")
	check(draft.accept(batch,packet,R.fail("InvalidState","start")).ok and not draft.accept(batch,packet,R.ok()).ok,"actual action rejection and duplicate")
	var original: Dictionary = brain.decide(job,view,com.view(A).value,orders,local)
	check(original.ok and original.value.intents==packet.intents,"unpublished branch retry identical")
	brain = draft
	job = job_for(ai,2,rows)
	view = ai.sense(A).value
	var blocked: Dictionary = brain.decide(job,view,com.view(A).value,orders,local).value
	check(actions(blocked.intents).is_empty(),"rejected action backs off")
	var new_h := {"index":2,"generation":2}
	rows[2] = unit(new_h,pos+Vector3.FORWARD,1,"infantry")
	job = job_for(ai,3,rows)
	view = ai.sense(A).value
	var renewed: Dictionary = brain.decide(job,view,com.view(A).value,orders,local).value
	check(renewed.target==new_h and not ai.collect(packet.job,packet.intents).ok,"old target generation and stale async job rejected")
	rows.remove_at(2)
	job = job_for(ai,4,rows)
	view = ai.sense(A).value
	check(brain.decide(job,view,com.view(A).value,orders,local).value.target==null,"retired target clears lock")
	local.nav_revision = nav+1
	check(not brain.decide(job,view,com.view(A).value,orders,local).ok,"stale navigation rejected")
	local = context(pos)
	local.exit_position = pos+Vector3.LEFT*5
	var routing: Dictionary = com.view(A).value
	routing.routing = true
	var routed: Dictionary = brain.decide(job,view,routing,orders,local).value
	check(routed.mode=="Routing" and routed.intents[0].desired_direction==[-1000000,0,0],"legal, reachable retreat")
	local.exit_position = Vector3(200,0,0)
	check(brain.decide(job,view,routing,orders,local).value.intents.is_empty(),"unreachable exit suppressed")
	var motion := Movement.new(engine,SCOPE)
	motion.spawn(A,pos)
	var move: Dictionary = routed.intents[0]
	check(S.validate_shape("MoveIntent",move).ok,"same movement wire shape")
	var destination := pos+Vector3(move.desired_direction[0],0,move.desired_direction[2])/1000000.0*5
	motion.set_corridor("exit",pos,destination)
	motion.assign(A,"exit")
	for t in 150: motion.step(t,1.0/60)
	check(motion.view(A).value.position.distance_to(destination)<0.3,"low-frequency decision yields continuous real MOV")
	var dead: Dictionary = com.view(A).value
	dead.hp = 0
	check(brain.decide(job,view,dead,orders,local).value.intents.is_empty(),"incapacitated has no input")
	var alien := AI.new(SCOPE,clear_ray)
	check(not Brain.new(SCOPE,alien.get_instance_id()).decide(job,view,com.view(A).value,orders,local).ok,"old instance cannot control reopened mission")


class LateJob:
	extends RefCounted
	var ready := Semaphore.new()
	var resume := Semaphore.new()
	var packet: Dictionary

	func run(brain: RefCounted,job: Dictionary,sense: Dictionary,combat: Dictionary,orders: Dictionary,local: Dictionary) -> void:
		ready.post()
		resume.wait()
		packet = brain.decide(job,sense,combat,orders,local)


func worker_lifecycle() -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.add_actor(A)
	var rows := [unit(A,Vector3(-3,0,8),0,"infantry"),unit(B,Vector3(-2,0,8),1,"infantry")]
	var job := job_for(ai,1,rows)
	var local := context(rows[0].position)
	# The worker gets the captured walkable area; no physics/nav calls cross the owner-thread boundary.
	local.can_travel = func(_from: Vector3,_to: Vector3,rev: int): return rev==job.stamp.nav_revision
	var late := LateJob.new()
	var id := WorkerThreadPool.add_task(late.run.bind(brain,job,ai.sense(A).value,com.view(A).value,ORDERS,local))
	late.ready.wait()
	ai.close()
	var reopened := AI.new(SCOPE,clear_ray)
	job_for(reopened,1,rows)
	late.resume.post()
	WorkerThreadPool.wait_for_task_completion(id)
	check(late.packet.ok and not ai.collect(job,late.packet.value.intents).ok and not reopened.collect(job,late.packet.value.intents).ok,"actual late worker cannot issue to either a closed or reopened mission")


func target_lock() -> void:
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.add_actor(A)
	var p := Vector3(-6,0,13)
	var rows := [unit(A,p,0,"infantry"),unit(B,p+Vector3.RIGHT*2,1,"infantry"),unit(H,p+Vector3.RIGHT*3,1,"infantry")]
	for t in [1,2,21]:
		var job := job_for(ai,t,rows)
		var proposed: Dictionary = brain.decide(job,ai.sense(A).value,com.view(A).value,ORDERS,context(p)).value
		check(proposed.target==(H if t==21 else B),"keep visible target until lock expiry")
		ai.collect(job,proposed.intents)
		check(brain.accept(ai.drain().value[0],proposed,R.ok()).ok,"adopt bounded target memory")
		rows[1].position=p+Vector3.RIGHT*3.2
		rows[2].position=p+Vector3.RIGHT*2.5


func constraints_and_authority() -> void:
	var active := [0]
	var ai := AI.new(SCOPE,clear_ray,60,func(_layer,_subject): return {"control_revision":active[0]})
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	com.enlist(A,{"team":0,"role":"archer","ranged":"crossbow"})
	var home := Vector3(-5,0,12)
	var rows := [unit(A,home,0,"archer"),unit(B,home+Vector3.RIGHT*6,1,"infantry")]
	var local := context(home)
	var job := job_for(ai,10,rows)
	var sense: Dictionary = ai.sense(A).value
	var hold := ORDERS.duplicate()
	hold.engage_allowed = false
	var prepare: Dictionary = brain.decide(job,sense,com.view(A).value,hold,local).value
	check(prepare.mode=="Aim" and actions(prepare.intents)[0].input_phase=="start","independent firing permission from a held formation")
	hold.fire_allowed = false
	check(brain.decide(job,sense,com.view(A).value,hold,local).value.intents.is_empty(),"holding both fire and engagement")
	local.slot_position = home+Vector3.FORWARD*4
	var slot: Dictionary = brain.decide(job,sense,com.view(A).value,hold,local).value
	check(slot.mode=="MoveToSlot" and slot.intents.size()==1 and slot.intents[0].desired_direction==[0,0,-1000000],"formation orders take precedence")
	check(ai.collect(job,prepare.intents).ok,"job first collected under grant")
	active[0] = 1
	check(ai.drain().value.is_empty(),"revocation between collection and adoption discards late output")
	active[0] = 0
	local = context(home)
	var old_branch: RefCounted = brain.fork()
	old_branch.forget(A)
	check(not old_branch.decide(job,sense,com.view(A).value,ORDERS,local).ok,"explicit retirement invalidates old generation")
	rows[1].position=home+Vector3.RIGHT
	job=job_for(ai,12,rows)
	sense=ai.sense(A).value
	local.threat_handle=B
	local.threat_direction="left"
	local.react_at=11
	check(actions(brain.decide(job,sense,com.view(A).value,ORDERS,local).value.intents)[0].direction=="left","skilled local reaction")
	var bow := Combat.new(SCOPE)
	bow.enlist(A,{"team":0,"role":"archer","ranged":"bow"})
	var evasion:Dictionary=brain.decide(job,sense,bow.view(A).value,ORDERS,local).value
	check(evasion.mode=="React" and actions(evasion.intents).is_empty() and evasion.intents.any(func(i):return i.has("desired_direction")),"drawn bow dodges a close threat")
	local.reaction_skill=0.0
	check(brain.decide(job,sense,com.view(A).value,ORDERS,local).value.mode!="React","novice reaction waits for observed swing")
	job=job_for(ai,18,rows)
	sense=ai.sense(A).value
	var late: Dictionary = brain.decide(job,sense,com.view(A).value,ORDERS,local).value
	check(late.mode=="React" and actions(late.intents)[0].direction!="left","replayable imperfect direction assessment")
	local.incapacitated=[B]
	check(brain.decide(job,sense,com.view(A).value,ORDERS,local).value.target==null,"confirmed locally incapacitated contact excluded")
	local.erase("incapacitated")
	local.erase("threat_handle")
	local.can_travel=func(_a,_b,_rev): return false
	check(brain.decide(job,sense,com.view(A).value,ORDERS,local).value.target==null,"unreachable contact cannot retain old lock")
	var malformed := ORDERS.duplicate()
	malformed.slot_tolerance = NAN
	check(not brain.decide(job,sense,com.view(A).value,malformed,local).ok,"invalid slot range rejected")


func crowd_sweep(queries: Array,t: int) -> Dictionary:
	# The crowd uses static level colliders in this slice; physical human targets are covered in roles().
	var result: Dictionary = engine.query_sweep_batch(queries,{"scope_id":SCOPE,"tick":t})
	if not result.ok: return result
	var walls := []
	for hit in result.value:
		walls.append({"query_index":hit.query_index,"fraction_ppm":hit.fraction_ppm,"target":null})
	return R.ok(walls)


func stress() -> void:
	var n := 1000
	var ai := AI.new(SCOPE,clear_ray)
	var brain := Brain.new(SCOPE,ai.get_instance_id())
	var com := Combat.new(SCOPE)
	var mov := Movement.new(engine,SCOPE)
	var handles := []
	var world := {}
	var groups := ["line-foot","line-mounted"]
	for i in 2:
		mov.set_corridor(groups[i],Vector3(-12,0,0),Vector3(4,0,0),"foot" if i==0 else "mounted")
	var pts := PackedVector3Array()
	var rows := []
	var locals := []
	for i in n:
		var role: String = ["infantry","archer","cavalry","mounted_archer"][i%4]
		var h := {"index":i,"generation":1}
		var point := Vector3(-52+(i%50)*2.0,0,-25+floori(i/50.0)*2)
		handles.append(h)
		var mounted := role in ["cavalry","mounted_archer"]
		mov.spawn(h,point,"mounted" if mounted else "foot",Vector3.RIGHT)
		mov.assign(h,groups[1 if mounted else 0],point-Vector3(-12,0,0))
		pts.append(point)
		rows.append(unit(h,point,i%2,role))
		var profile := {"team":i%2,"role":"cavalry" if role=="mounted_archer" else role}
		if role=="mounted_archer": profile.ranged = "bow"
		com.enlist(h,profile)
		if role in ["cavalry","mounted_archer"]:
			var horse := {"index":i+n,"generation":1}
			com.enlist(horse,{"team":i%2,"role":"mount"})
			com.mount(h,horse)
		var member := context(point)
		# One connected area was verified on the real mesh. Do not request a navigation path per candidate.
		member.can_travel = func(a: Vector3,b: Vector3,rev: int): return rev==nav and absf(a.x)<65 and absf(b.x)<65 and absf(a.z)<45 and absf(b.z)<45
		locals.append(member)
	var movement_roster: Variant = mov.bind_roster(handles).value
	var warm := ceili(n/8.0)+6
	for t in warm:
		if not mov.step(t,1.0/60).ok:
			check(false,"real crowd path admission")
			return
	var token: Dictionary = ai.publish(0,nav,rows).value
	var granted := 0
	var reacted := 0
	var backlog := 0
	var costs := []
	var worst := 0
	var eligible := 0
	var executed := 0
	var displaced := false
	var total_ticks := []
	var motion_cost := []
	var pose_cost := []
	var combat_cost := []
	for t in range(1,121):
		var total_begin := Time.get_ticks_usec()
		if not mov.step(warm+t,1.0/60).ok:
			check(false,"low-frequency jobs while MOV advances")
			return
		var moved := Time.get_ticks_usec()
		motion_cost.append(moved-total_begin)
		var motion: Dictionary = mov.read_poses(movement_roster).value
		pts = motion.positions
		for index in n:
			world[index] = {"position_mm":mm(pts[index]+Vector3.UP*0.7),"facing_ppm":mm(motion.headings[index]*1000)}
		pose_cost.append(Time.get_ticks_usec()-moved)
		displaced = displaced or pts[0].distance_squared_to(rows[0].position)>0.1
		var urgent: Dictionary = rows[t%n].handle
		ai.advance(t,nav,token,pts,[urgent],[],1)
		var selected: Dictionary = ai.schedule().value
		for count in selected.backlog.values(): backlog=maxi(backlog,count)
		var draft: RefCounted = brain.fork()
		var proposals := {}
		var elapsed := 0
		for job in selected.jobs:
			if job.layer!="individual": continue
			var sensed: Dictionary = ai.sense(job.subject,8,2).value
			var local: Dictionary = locals[job.subject.index].duplicate()
			if job.urgent and not sensed.visible_enemies.is_empty():
				local.threat_handle = sensed.visible_enemies[0].handle
				if sensed.self.position.distance_squared_to(sensed.visible_enemies[0].position)<=9.0:
					eligible += 1
			var auth: Dictionary = com.view(job.subject).value
			var begin := Time.get_ticks_usec()
			var r: Dictionary = draft.decide(job,sensed,auth,ORDERS,local)
			elapsed += Time.get_ticks_usec()-begin
			if not r.ok or not ai.collect(job,r.value.intents).ok:
				check(false,"load proposal")
				return
			proposals[job.id] = r.value
			granted += 1
			if job.urgent and r.value.mode=="React": reacted+=1
		var drained: Array = ai.drain().value
		var combat_inputs := []
		var indices := {}
		for batch in drained:
			var input := actions(batch.intents)
			if not input.is_empty():
				indices[batch.job.id] = combat_inputs.size()
				combat_inputs.append(input[0])
		var before_com := Time.get_ticks_usec()
		var applied: Dictionary = com.step_field(t,combat_inputs,world,crowd_sweep)
		combat_cost.append(Time.get_ticks_usec()-before_com)
		if not applied.ok:
			check(false,"real crowd COM apply "+str(applied))
			return
		for batch in drained:
			var receipt: Dictionary = R.ok()
			if indices.has(batch.job.id):
				receipt = applied.value.receipts[indices[batch.job.id]]
				if receipt.ok: executed+=1
			var begin := Time.get_ticks_usec()
			var accepted: Dictionary = draft.accept(batch,proposals[batch.job.id],receipt)
			elapsed += Time.get_ticks_usec()-begin
			if not accepted.ok:
				check(false,"load accept")
				return
		total_ticks.append(Time.get_ticks_usec()-total_begin)
		costs.append(elapsed)
		worst = maxi(worst,proposals.size())
		brain = draft
	costs.sort()
	total_ticks.sort()
	motion_cost.sort()
	pose_cost.sort()
	combat_cost.sort()
	print("L3_LOAD_DOMAINS_US movement_p95=",motion_cost[113]," pose_read_and_dict_p95=",pose_cost[113]," combat_inclusive_p95=",combat_cost[113])
	check(granted>=10000 and reacted==eligible and eligible>0 and backlog==0 and displaced and executed>0,"1000 real jobs, eligible urgent reactions, continuous MOV and actual COM receipts")
	print("L3_LOAD confirmed_COM_actions=",executed," eligible_emergencies=",eligible," real_MOV_displaced=",displaced," instrumented_workload_p95_us=",total_ticks[113])
	print("T-BAI-I-04 humans=",n," additional_mounts=500 ticks=120 jobs=",granted," successful_reactions=",reacted," backlog=",backlog," max_jobs_tick=",worst," L3_decide_accept_p95_us=",costs[113])


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	engine = EnginePort.new(root,true)
	var scope: Dictionary = engine.open_scope(SCOPE)
	var loaded: Dictionary = engine.load_scene({"id":"base:scene/individual","simulation_scene":"res://tests/p2/individual/arena.tscn"},scope.value)
	check(loaded.ok,"load real navigation and combat field")
	for i in 120:
		await physics_frame
		var synced: Dictionary = engine.sync_navigation(SCOPE)
		if synced.ok and synced.value.status=="applied":
			nav = synced.value.applied_revision
			if path(Vector3(-4,0,0),Vector3(-2,0,0),nav) and not clear_ray(Vector3(-3,0,0),Vector3(3,0,0)): break
	for setup in [["infantry",""],["archer","bow"],["archer","crossbow"],["cavalry",""],["mounted_archer","bow"]]:
		roles(setup[0],setup[1])
	check(errors==0,"T-BAI-I-01/03 actual role combat and player parity")
	edges()
	constraints_and_authority()
	target_lock()
	worker_lifecycle()
	preload("res://tests/p2/individual/transition_cases.gd").run(self)
	check(errors==0,"T-BAI-I-02 visibility, rollback, rejection")
	stress()
	engine.release_scope(SCOPE)
	print("P2-BAI-I-001 ","PASS" if errors==0 else "FAIL"," checks=",checks," errors=",errors," paths=",paths," los=",rays," sweeps=",sweeps)
	quit(0 if errors==0 else 1)
