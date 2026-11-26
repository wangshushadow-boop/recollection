extends SceneTree

const Adapter = preload("res://infrastructure/engine/adapter.gd")
const Combat = preload("res://mission/combat/ports/field_combat.gd")
const FLOOR := {"id":"field:scene/river_plain","simulation_scene":"res://content/base/field/river_plain.tscn"}
const WALL := {"id":"test:scene/wall","simulation_scene":"res://tests/p1/engine/arena.tscn"}
const A := "field/left"
const B := "field/right"
var engine: Adapter
var checks := 0
var failures := 0

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		printerr("FAIL ",label)
		failures += 1

func actor(index: int, generation: int, x: float, team: Variant) -> Dictionary:
	return {"handle":{"index":index,"generation":generation},"team_key":team,"position":Vector3(x,0,0),
		"facing":Vector3.LEFT,"shield":false}

func site(x: float, team: Variant) -> Dictionary:
	return {"team_key":team,"spawn_position_mm":[roundi(x*1000),0,0]}

func sweep(scope: String, x: float, y: float, radius := 0) -> Array:
	var query := {"from":[roundi((x-1)*1000),roundi(y*1000),0],"to":[roundi((x+1)*1000),roundi(y*1000),0],"radius_mm":radius}
	var reply := engine.field_sweep(scope,[query],1)
	check(reply.ok,"sweep executes %s" % [reply])
	return reply.get("value",[])

func regions(rows: Array, h: Dictionary) -> Array:
	return rows.filter(func(r): return r.target == h).map(func(r): return r.region)

func frozen_actor(index: int, generation: int, x: float, freeze_handle := true) -> Dictionary:
	var row := actor(index,generation,x,0)
	row.type = "human"
	row.mounted = false
	if freeze_handle:
		row.handle.make_read_only()
	row.make_read_only()
	return row

func unchanged_bodies() -> void:
	var left := frozen_actor(31,1,-8)
	var right := frozen_actor(32,1,8,false)
	check(engine.field_stage_bodies(A,[left,right]).ok and engine.field_commit_bodies(A).ok,"commit immutable and shallow-readonly inputs")
	check(engine.field_stage_bodies(A,[left,right]).ok and engine.field_commit_bodies(A).ok,"repeat committed immutable input")
	var duplicate := engine.field_stage_bodies(A,[left,left])
	check(not duplicate.ok and duplicate.error.code=="Conflict","duplicate unchanged handle rejected")
	right.handle.generation = 0
	var invalid := engine.field_stage_bodies(A,[left,right])
	check(not invalid.ok and invalid.error.code=="InvalidArgument","shallow-readonly row revalidates edited nested handle")
	check(regions(sweep(A,8,1.1),{"index":32,"generation":1})==["body"],"failed batch leaves original handle live")
	var moved := frozen_actor(31,1,-4)
	check(engine.field_stage_bodies(A,[moved]).ok and regions(sweep(A,-4,1.1),left.handle)==["body"],"replacement immutable pose moves proxy")
	check(engine.field_rollback_bodies(A).ok and regions(sweep(A,-8,1.1),left.handle)==["body"],"rollback restores cached committed pose")
	check(engine.field_stage_bodies(A,[left]).ok and engine.field_commit_bodies(A).ok,"original input can retry after rollback")
	check(engine.field_stage_bodies(A,[]).ok and engine.field_commit_bodies(A).ok,"retire immutable input")
	var retired := engine.field_stage_bodies(A,[left])
	check(not retired.ok and retired.error.code=="StaleVersion","retired immutable input cannot restore old generation")
	var replacement := frozen_actor(31,2,-2)
	check(engine.field_stage_bodies(A,[replacement]).ok and engine.field_commit_bodies(A).ok,"recreate body under next generation")
	check(not engine.field_stage_bodies(A,[left]).ok and regions(sweep(A,-2,1.1),replacement.handle)==["body"],"old generation cannot replace committed successor")

func battle_shot(scope: String, shooter_x: float, target_x: float, blocked: bool) -> void:
	var archer := actor(25,1,shooter_x,0)
	var defender := actor(26,1,target_x,"0")
	check(engine.field_stage_bodies(scope,[archer,defender]).ok,"project both combat actors")
	var combat := Combat.new(scope)
	check(combat.enlist(archer.handle,{"role":"archer","team":0,"ammo":2}).ok and combat.enlist(defender.handle,{"role":"infantry","team":1}).ok,"authoritative enlist")
	var poses := {25:{"position_mm":[roundi(shooter_x*1000),1100,0],"facing_ppm":[1000000,0,0]},
		26:{"position_mm":[roundi(target_x*1000),1100,0],"facing_ppm":[-1000000,0,0]}}
	var events := []
	for tick in range(1,8):
		var intents := []
		if tick==1 or tick==4:
			intents.append({"actor_handle":archer.handle,"input_phase":"start" if tick==1 else "release","weapon_slot":1,"direction":"up","target_hint":null})
		var reply := combat.step_field(tick,intents,poses,func(q,t): return engine.field_sweep(scope,q,t))
		check(reply.ok and reply.value.receipts.all(func(r): return r.ok),"COM and Jolt applied step")
		if reply.ok:
			events.append_array(reply.value.events)
	check(combat.view(defender.handle).value.hp == (100 if blocked else 84),"physical obstruction/hit affects COM health")
	check(events.any(func(e): return e.type=="projectile_obstructed")==blocked,"COM projectile obstruction event")
	check(engine.field_rollback_bodies(scope).ok,"discard combat fixture bodies")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	engine = Adapter.new(root)
	var a := engine.open_scope(A)
	var b := engine.open_scope(B)
	check(a.ok and b.ok and engine.load_scene(FLOOR,a.value).ok and engine.load_scene(WALL,b.value).ok,"load independent worlds")
	await physics_frame
	await physics_frame
	battle_shot(A,0,2.5,false)
	battle_shot(B,-3,-0.5,true)
	var rider := actor(7,1,0.0,0)
	rider.shield = true
	var horse := actor(8,2,14.0,"0")
	horse.type = "mount"
	var h: Dictionary = rider.handle.duplicate()
	check(engine.field_stage_bodies(A,[rider,horse]).ok,"stage actor and mount")
	check(not engine.field_stage_bodies(A,[]).ok,"nested write rejected")
	var hit := regions(sweep(A,0,1.1),h)
	check(hit == ["shield","body"],"front shield and body ordered by actual hit depth " + str(hit))
	check(regions(sweep(A,0,1.65),h) == ["head"],"head region")
	check(regions(sweep(A,0,0.46,15),h) == ["limb"],"Jolt sphere sweep limb")
	check(regions(sweep(A,14,0.85),horse.handle) == ["body"],"separate mount handle")
	check(regions(sweep(B,0,1.1),h).is_empty(),"scope isolation")
	check(engine.field_los(A,Vector3(-1,0,0),Vector3(1,0,0)),"units do not obscure terrain LOS")
	check(not engine.field_los(B,Vector3(-3,-0.55,0),Vector3(-1,-0.55,0)),"authored wall occludes terrain LOS")
	var wall_hits := sweep(B,-2,1)
	check(wall_hits.size()==1 and wall_hits[0].target == null,"terrain hit does not forge actor handle")
	var sites := [site(0.0,0),site(1.5,0),site(1.5,"0"),site(22.0,0)]
	check(engine.field_clearance(A,sites).value == [false,true,false,true],"occupied / ally / nearby enemy / clear")
	check(not engine.field_clearance(B,[{"team_key":0,"spawn_position_mm":[-2000,100,0]}]).value[0],"static wall blocks spawn")
	check(not engine.field_clearance(A,[{"team_key":1,"spawn_position_mm":[0,"0",0]}]).ok,"invalid clearance batch")
	check(engine.field_commit_bodies(A).ok,"first committed baseline")
	var stale := rider.duplicate(true)
	var moved := actor(7,2,8.0,0)
	moved.mounted = true
	check(engine.field_stage_bodies(A,[moved]).ok,"advance generation and move in same fixed step")
	moved.handle.generation = 99
	moved.position = Vector3(90,0,0)
	check(regions(sweep(A,8,2.0),{"index":7,"generation":2}) == ["body"],"staged snapshot owns its input")
	check(sweep(A,0,1.1).is_empty() and sweep(A,14,0.85).is_empty(),"old collider and missing mount detached")
	check(engine.field_rollback_bodies(A).ok and engine.field_rollback_bodies(A).ok,"downstream rollback idempotent")
	check(regions(sweep(A,0,1.1),h) == ["shield","body"] and sweep(A,8,2).is_empty(),"restores prior geometry immediately")
	check(engine.field_stage_bodies(A,[actor(7,2,8.0,0)]).ok and engine.field_commit_bodies(A).ok,"same tick retry")
	check(not engine.field_stage_bodies(A,[actor(7,2,8.0,"enemy")]).ok,"same generation cannot change team")
	check(not engine.field_stage_bodies(A,[stale]).ok and not engine.field_stage_bodies(A,[horse]).ok,"stale and retired generations rejected")
	check(not engine.field_stage_bodies(A,[actor(1,1,18.0,0),actor(7,2,0,0),actor(7,3,4,0)]).ok,"bad last row rejects whole projection")
	check(regions(sweep(A,8,1.1),{"index":7,"generation":2}) == ["body"] and sweep(A,18,1).is_empty(),"failed stage leaves geometry intact")
	check(engine.field_stage_bodies(A,[actor(7,2,-6.0,0)]).ok and regions(sweep(A,-6,1.1),{"index":7,"generation":2}) == ["body"],"existing proxy moved immediately")
	check(engine.field_rollback_bodies(A).ok and sweep(A,-6,1).is_empty(),"moving existing proxy rolls back")
	unchanged_bodies()
	check(engine.release_scope(A).released==1 and not engine.field_los(A,Vector3.ZERO,Vector3.LEFT) and not engine.field_sweep(A,[],1).ok,"release invalidates access")
	var reopened := engine.open_scope(A)
	check(reopened.ok and not engine.query_sweep_batch([],{"scope_id":A,"tick":1,"generation":a.value.generation}).ok,"scope generation barrier")
	check(engine.field_stage_bodies(A,[stale]).ok and engine.field_commit_bodies(A).ok,"scope generation history isolated")
	engine.release_scope(A)
	engine.release_scope(B)
	check(engine.counts().scopes==0,"release all")
	print("FIELD_ENGINE checks=",checks," failures=",failures)
	quit(0 if failures == 0 else 1)
